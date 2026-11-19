#!/usr/bin/env python3
"""Focused tests for H4 statistics, ordering, and inventory rules."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import statistics
import subprocess
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("h4_harness", HERE / "harness.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load H4 harness")
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)

PARITY_SPEC = importlib.util.spec_from_file_location(
    "h4_build_parity", HERE / "build_parity.py"
)
if PARITY_SPEC is None or PARITY_SPEC.loader is None:
    raise RuntimeError("cannot load H4 build parity helper")
build_parity = importlib.util.module_from_spec(PARITY_SPEC)
PARITY_SPEC.loader.exec_module(build_parity)


class SequenceExecutor:
    def __init__(self, values: list[float], check: str = "ok"):
        self.values = iter(values)
        self.check = check

    def __call__(self, _: str) -> tuple[float, str]:
        return next(self.values), self.check


class HarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = harness.load_manifest(harness.DEFAULT_MANIFEST)
        self.stats = self.manifest["statistics"]

    def test_required_statistics_are_locked(self) -> None:
        self.assertGreaterEqual(self.stats["warmup_pairs"], 2)
        self.assertEqual(self.stats["warmup_pairs"] % 2, 0)
        self.assertGreaterEqual(self.stats["measured_pairs"], 7)
        self.assertEqual(self.stats["measured_pairs"] % 2, 0)
        self.assertEqual(self.stats["max_relative_mad"], 0.03)
        self.assertEqual(self.stats["retries"], 1)
        self.assertEqual(
            self.manifest["fastcall_measurement"],
            {"min_sample_seconds": 0.25},
        )

    def test_pinned_cares_digest_verifier(self) -> None:
        completed = subprocess.run(
            ["sh", str(HERE / "test_build_pinned_cares.sh")],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            "portable c-ares digest verifier tests passed",
            completed.stdout,
        )

    def test_fastcall_minimum_duration_cannot_be_weakened(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["fastcall_measurement"]["min_sample_seconds"] = 0.249
        with self.assertRaises(harness.HarnessError):
            harness.validate_manifest(manifest)

    def test_pair_order_alternates(self) -> None:
        self.assertEqual(harness.condition_order(0), ("baseline", "candidate"))
        self.assertEqual(harness.condition_order(1), ("candidate", "baseline"))
        self.assertEqual(harness.condition_order(2), ("baseline", "candidate"))

    def test_fastcall_schedule_balances_order_and_traversal(self) -> None:
        cycle = [harness.fastcall_pair_schedule(index) for index in range(8)]
        expected = [
            (("baseline", "candidate"), "forward"),
            (("candidate", "baseline"), "forward"),
            (("baseline", "candidate"), "reverse"),
            (("candidate", "baseline"), "reverse"),
        ]
        self.assertEqual(cycle[:4], expected)
        self.assertEqual(cycle[4:], expected)
        self.assertEqual(
            [harness.fastcall_warmup_schedule(index) for index in range(2)],
            [
                (("baseline", "candidate"), "forward"),
                (("candidate", "baseline"), "reverse"),
            ],
        )

    def test_fastcall_attempt_uses_balanced_schedule(self) -> None:
        record = {
            "ns_per_op": 10.0,
            "elapsed_seconds": 0.25,
            "iterations": 25_000_000,
        }
        with mock.patch.object(
            harness,
            "run_fastcall_process",
            return_value={"base.type": record},
        ) as run:
            samples, orders, traversals = harness.fastcall_attempt(
                Path("/tmp/lus"),
                {"base.type": "base"},
                {"base.type": 5_000_000},
                self.stats,
                self.manifest["fastcall_measurement"],
            )
        self.assertEqual(
            orders,
            [
                list(harness.fastcall_pair_schedule(index)[0])
                for index in range(self.stats["measured_pairs"])
            ],
        )
        self.assertEqual(
            traversals,
            [
                harness.fastcall_pair_schedule(index)[1]
                for index in range(self.stats["measured_pairs"])
            ],
        )
        measured_calls = run.call_args_list[
            self.stats["warmup_pairs"] * 2 :
        ]
        expected = []
        for index in range(self.stats["measured_pairs"]):
            order, traversal = harness.fastcall_pair_schedule(index)
            expected.extend(
                (condition == "candidate", traversal == "reverse")
                for condition in order
            )
        self.assertEqual(
            [
                (call.kwargs["enabled"], call.kwargs["reverse"])
                for call in measured_calls
            ],
            expected,
        )
        self.assertEqual(len(samples["base.type"]["baseline"]), 8)
        self.assertEqual(len(samples["base.type"]["candidate"]), 8)

    def test_stable_pair_has_balanced_measurements(self) -> None:
        calls = self.stats["warmup_pairs"] + self.stats["measured_pairs"]
        baseline = SequenceExecutor([10.0] * calls)
        candidate = SequenceExecutor([8.0] * calls)
        result = harness.stable_pair(
            baseline,
            candidate,
            self.stats,
            "synthetic",
        )
        self.assertTrue(result["stable"])
        self.assertEqual(
            len(result["baseline_samples"]), self.stats["measured_pairs"]
        )
        self.assertEqual(
            len(result["candidate_samples"]), self.stats["measured_pairs"]
        )
        self.assertEqual(result["speedup"], 1.25)
        self.assertEqual(result["attempts"], 1)

    def test_unstable_attempt_retries_once(self) -> None:
        calls = self.stats["warmup_pairs"] + self.stats["measured_pairs"]
        noisy = [8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0]
        baseline = SequenceExecutor(
            [10.0] * self.stats["warmup_pairs"]
            + noisy
            + [10.0] * calls
        )
        candidate = SequenceExecutor(
            [8.0] * self.stats["warmup_pairs"]
            + [8.0] * self.stats["measured_pairs"]
            + [8.0] * calls
        )
        result = harness.stable_pair(
            baseline,
            candidate,
            self.stats,
            "synthetic retry",
        )
        self.assertTrue(result["stable"])
        self.assertEqual(result["attempts"], 2)

    def test_unstable_second_attempt_stops_after_one_retry(self) -> None:
        noisy_attempt = [10.0] * self.stats["warmup_pairs"] + [
            8.0,
            9.0,
            10.0,
            11.0,
            12.0,
            13.0,
            14.0,
            15.0,
        ]
        baseline = SequenceExecutor(noisy_attempt * 2)
        candidate = SequenceExecutor([8.0] * len(noisy_attempt) * 2)
        result = harness.stable_pair(
            baseline,
            candidate,
            self.stats,
            "synthetic double instability",
        )
        self.assertFalse(result["stable"])
        self.assertEqual(result["attempts"], 2)

    def test_speedup_is_the_median_of_paired_ratios(self) -> None:
        baseline_values = [100.0, 101.0, 102.0, 103.0, 104.0, 105.0, 106.0, 107.0]
        candidate_values = [80.0, 82.0, 81.0, 84.0, 83.0, 85.0, 86.0, 87.0]
        baseline = SequenceExecutor(
            [100.0] * self.stats["warmup_pairs"] + baseline_values
        )
        candidate = SequenceExecutor(
            [80.0] * self.stats["warmup_pairs"] + candidate_values
        )
        result = harness.stable_pair(
            baseline,
            candidate,
            self.stats,
            "synthetic pairing",
        )
        expected = statistics.median(
            left / right
            for left, right in zip(baseline_values, candidate_values)
        )
        self.assertTrue(result["stable"])
        self.assertAlmostEqual(result["speedup"], expected)

    def test_relative_mad_uses_median(self) -> None:
        self.assertEqual(harness.relative_mad([10.0] * 7), 0.0)
        self.assertAlmostEqual(
            harness.relative_mad([9.8, 9.9, 10.0, 10.0, 10.0, 10.1, 10.2]),
            0.01,
        )

    def test_single_result_requires_one_time_and_check(self) -> None:
        value, check = harness.parse_single_result(
            "TIME 1.250000000\nCHECK token\n",
            "synthetic",
        )
        self.assertEqual(value, 1.25)
        self.assertEqual(check, "token")
        with self.assertRaises(harness.HarnessError):
            harness.parse_single_result("TIME 1.0\n", "synthetic")

    def test_loopback_dynamic_argument_is_allocated_per_process(self) -> None:
        case = {
            "id": "network.receive_line",
            "script": "experiment_receive_line.lus",
            "dynamic_args": ["loopback_port"],
        }
        probe = mock.MagicMock()
        probe.__enter__.return_value = probe
        probe.getsockname.return_value = ("127.0.0.1", 54321)
        with mock.patch.object(harness.socket, "socket", return_value=probe):
            with mock.patch.object(
                harness,
                "run_process",
                return_value="TIME 1.0\nCHECK token\n",
            ) as run:
                value, check = harness.single_executor(Path("/tmp/lus"), case)(
                    "baseline"
                )
        self.assertEqual((value, check), (1.0, "token"))
        self.assertEqual(run.call_args.args[0][-1], "54321")
        probe.bind.assert_called_once_with(("127.0.0.1", 0))

    def test_release_baseline_version_is_exact(self) -> None:
        harness.require_release_baseline({"version": "Lus 1.6.2 (manual)"})
        with self.assertRaises(harness.HarnessError):
            harness.require_release_baseline({"version": "Lus 1.7.0 (manual)"})

    def test_valid_case_below_point_nine_eight_blocks(self) -> None:
        case = {"promotion_warning_below": 1.02, "block_below": 0.98}
        measurement = {"stable": True, "speedup": 0.979}
        self.assertEqual(
            harness.classify_case(case, measurement, self.manifest["gates"]),
            "block",
        )

    def test_overall_gate_requires_one_point_zero_five(self) -> None:
        cases = [{"status": "pass"}]
        categories = {"vm": 1.20}
        self.assertEqual(
            harness.final_status(
                cases, categories, 1.049, self.manifest["gates"]
            ),
            "block",
        )
        self.assertEqual(
            harness.final_status(cases, categories, 1.05, self.manifest["gates"]),
            "warning",
        )

    def test_category_regression_cannot_hide_in_strong_overall(self) -> None:
        cases = [{"status": "pass"}, {"status": "pass"}]
        categories = {"slow": 0.949, "fast": 1.30}
        self.assertGreater(statistics.geometric_mean(categories.values()), 1.05)
        self.assertEqual(
            harness.final_status(
                cases,
                categories,
                statistics.geometric_mean(categories.values()),
                self.manifest["gates"],
            ),
            "block",
        )

    def test_regression_and_promotion_warnings_are_distinct(self) -> None:
        gates = self.manifest["gates"]
        self.assertEqual(gates["regression_warning_below"], 0.95)
        self.assertEqual(gates["regression_block_below"], 0.90)
        self.assertEqual(gates["case_promotion_warning_below"], 1.02)
        self.assertEqual(gates["overall_promotion_warning_below"], 1.08)
        self.assertEqual(gates["category_block_below"], 0.95)

    def test_fastcall_workload_covers_each_registration_once(self) -> None:
        expected = harness.validate_fastcall_inventory()
        workload = harness.workload_fastcalls()
        batches = harness.workload_fastcall_batches()
        self.assertEqual(len(expected), 63)
        self.assertEqual(len(workload), len(expected))
        self.assertEqual(set(batches), set(expected))
        self.assertTrue(all(batch > 0 for batch in batches.values()))
        self.assertIn("time.instant", expected)

    def test_release_suite_keeps_candidate_only_cases_separate(self) -> None:
        release_ids = {
            case["id"]
            for case in self.manifest["cases"]
            if "release" in case["suites"]
        }
        self.assertEqual(len(release_ids), 13)
        self.assertNotIn("sqlite.memory", release_ids)
        self.assertNotIn("time.constructors", release_ids)

    def test_fastcall_output_requires_each_exact_label_once(self) -> None:
        expected = {"base.type": "base", "time.instant": "time"}
        batches = {"base.type": 5_000_000, "time.instant": 1_000_000}
        output = (
            "base\tbase.type\t10.0\t0.25\t25000000\n"
            "time\ttime.instant\t8.0\t0.4\t50000000\n"
        )
        self.assertEqual(
            harness.parse_fastcall_output(output, expected, batches, 0.25),
            {
                "base.type": {
                    "ns_per_op": 10.0,
                    "elapsed_seconds": 0.25,
                    "iterations": 25_000_000,
                },
                "time.instant": {
                    "ns_per_op": 8.0,
                    "elapsed_seconds": 0.4,
                    "iterations": 50_000_000,
                },
            },
        )
        with self.assertRaises(harness.HarnessError):
            harness.parse_fastcall_output(output + output, expected, batches, 0.25)

    def test_fastcall_output_rejects_malformed_or_missing_totals(self) -> None:
        expected = {"base.type": "base"}
        batches = {"base.type": 5_000_000}
        for output in (
            "base\tbase.type\t10.0\n",
            "base\tbase.type\t10.0\tbad\t25000000\n",
            "unexpected stdout\n",
        ):
            with self.subTest(output=output):
                with self.assertRaises(harness.HarnessError):
                    harness.parse_fastcall_output(
                        output, expected, batches, 0.25
                    )

    def test_fastcall_output_rejects_short_or_inconsistent_totals(self) -> None:
        expected = {"base.type": "base"}
        batches = {"base.type": 5_000_000}
        invalid = (
            "base\tbase.type\t10.0\t0.249999\t25000000\n",
            "base\tbase.type\t10.0\t0.25\t24000000\n",
            "base\tbase.type\t11.0\t0.25\t25000000\n",
        )
        for output in invalid:
            with self.subTest(output=output):
                with self.assertRaises(harness.HarnessError):
                    harness.parse_fastcall_output(
                        output, expected, batches, 0.25
                    )

    def parity_snapshot(self) -> dict:
        options = {
            "buildtype": "release",
            "optimization": "3",
            "debug": False,
            "b_lto": True,
            "b_lto_mode": "default",
            "b_lto_threads": 0,
            "b_pgo": "off",
            "b_sanitize": [],
            "b_ndebug": "if-release",
            "c_args": [],
            "c_link_args": [],
            "c_std": "gnu11",
            "default_library": "shared",
            "prefer_static": False,
            "b_pie": False,
            "b_staticpic": True,
        }
        metadata = json.loads(
            (harness.ROOT / "release/dependencies.json").read_text(
                encoding="utf-8"
            )
        )
        cares = metadata["caresSource"]
        return {
            "build_dir": "/tmp/build",
            "source_root": str(harness.ROOT / "lus"),
            "meson_version": "1.11.2",
            "ninja_version": "1.13.0",
            "compiler": {
                "id": "gcc",
                "exelist": ["cc"],
                "linker_exelist": ["cc"],
                "version": "14.2.0",
                "full_version": "gcc 14.2.0",
                "linker_id": "ld.bfd",
            },
            "options": options,
            "dependencies": [
                {
                    "name": "libcares",
                    "type": "pkgconfig",
                    "version": cares["version"],
                    "compile_args": [],
                    "link_args": ["-lcares"],
                },
                {
                    "name": "zlib",
                    "type": "pkgconfig",
                    "version": "1.3.1",
                    "compile_args": [],
                    "link_args": ["-lz"],
                }
            ],
            "external_link_inputs": [
                {"kind": "library", "name": "m"},
                {
                    "kind": "file",
                    "name": "libcares.a",
                    "sha256": "1" * 64,
                },
                {"kind": "library", "name": "z"},
            ],
            "project_sources": {"src/lua.c": "0" * 64},
            "pinned_cares": {
                "name": "c-ares",
                "version": cares["version"],
                "url": cares["url"],
                "expected_sha256": cares["sha256"],
                "archive_sha256": cares["sha256"],
                "library_sha256": "1" * 64,
                "dependency_version": cares["version"],
            },
        }

    def parity_deltas(self, baseline: dict, candidate: dict) -> dict:
        metadata_path = harness.ROOT / "release/dependencies.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        generated = metadata["generatedData"]
        files = {
            "vendor/sqlite/sqlite3.c": generated["sqlite"]["cSha256"],
            "src/ltzdata.c": generated["tzdataGeneratedSha256"],
            "src/lwinzones.c": generated["cldrGeneratedSha256"],
        }
        candidate["project_sources"].update(files)
        features = {
            "sqlite": {
                "version": generated["sqlite"]["version"],
                "source_sha256": generated["sqlite"]["sourceSha256"],
                "files": [
                    {
                        "path": "vendor/sqlite/sqlite3.c",
                        "expected_sha256": generated["sqlite"]["cSha256"],
                        "sha256": generated["sqlite"]["cSha256"],
                    },
                    {
                        "path": "vendor/sqlite/sqlite3.h",
                        "expected_sha256": generated["sqlite"]["headerSha256"],
                        "sha256": generated["sqlite"]["headerSha256"],
                    },
                ],
            },
            "tzdata": {
                "version": generated["tzdata"],
                "source_sha256": generated["tzdataSourceSha256"],
                "additional_source_sha256": generated["tzcodeSourceSha256"],
                "files": [
                    {
                        "path": "src/ltzdata.c",
                        "expected_sha256": generated["tzdataGeneratedSha256"],
                        "sha256": generated["tzdataGeneratedSha256"],
                    }
                ],
            },
            "cldr": {
                "version": generated["cldr"],
                "source_sha256": generated["cldrSourceSha256"],
                "files": [
                    {
                        "path": "src/lwinzones.c",
                        "expected_sha256": generated["cldrGeneratedSha256"],
                        "sha256": generated["cldrGeneratedSha256"],
                    }
                ],
            },
        }
        return {
            "classification": "candidate-only-source-feature-deltas",
            "dependency_metadata": "release/dependencies.json",
            "dependency_metadata_sha256": hashlib.sha256(
                metadata_path.read_bytes()
            ).hexdigest(),
            "candidate_only_sources": [
                {"path": path, "sha256": digest}
                for path, digest in sorted(files.items())
            ],
            "features": features,
        }

    def test_build_flag_parity_rejects_one_mismatch(self) -> None:
        candidate = self.parity_snapshot()
        baseline = copy.deepcopy(candidate)
        baseline["options"]["b_lto"] = False
        deltas = self.parity_deltas(baseline, candidate)
        result = build_parity.compare_snapshots(baseline, candidate, deltas)
        self.assertEqual(result["status"], "block")
        self.assertFalse(result["checks"]["options"]["values"]["b_lto"]["match"])

    def test_build_dependency_parity_is_exact(self) -> None:
        candidate = self.parity_snapshot()
        baseline = copy.deepcopy(candidate)
        baseline["dependencies"][0]["version"] = "1.2.13"
        deltas = self.parity_deltas(baseline, candidate)
        result = build_parity.compare_snapshots(baseline, candidate, deltas)
        self.assertEqual(result["status"], "block")
        self.assertFalse(result["checks"]["dependencies"]["match"])

    def test_build_link_closure_rejects_omitted_library(self) -> None:
        candidate = self.parity_snapshot()
        baseline = copy.deepcopy(candidate)
        baseline["external_link_inputs"].pop()
        deltas = self.parity_deltas(baseline, candidate)
        result = build_parity.compare_snapshots(baseline, candidate, deltas)
        self.assertEqual(result["status"], "block")
        self.assertFalse(result["checks"]["external_link_inputs"]["match"])

    def test_pinned_cares_rejects_digest_tampering(self) -> None:
        candidate = self.parity_snapshot()
        baseline = copy.deepcopy(candidate)
        candidate["pinned_cares"]["archive_sha256"] = "f" * 64
        deltas = self.parity_deltas(baseline, candidate)
        result = build_parity.compare_snapshots(baseline, candidate, deltas)
        self.assertEqual(result["status"], "block")
        self.assertFalse(result["checks"]["pinned_cares"]["match"])

    def test_pinned_cares_archive_digest_is_verified(self) -> None:
        metadata = json.loads(
            (harness.ROOT / "release/dependencies.json").read_text(
                encoding="utf-8"
            )
        )
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "c-ares.tar.gz"
            archive.write_bytes(b"tampered")
            with self.assertRaises(build_parity.ParityError):
                build_parity.pinned_cares_input(archive, metadata)

    def test_generated_source_pin_tampering_is_rejected(self) -> None:
        metadata = json.loads(
            (harness.ROOT / "release/dependencies.json").read_text(
                encoding="utf-8"
            )
        )
        generated = copy.deepcopy(metadata["generatedData"])
        generated["sqlite"]["sourceSha256"] = "f" * 64
        with self.assertRaises(build_parity.ParityError):
            build_parity.validate_source_input_pins(generated)

    def test_pinned_cares_rejects_dependency_version_tampering(self) -> None:
        candidate = self.parity_snapshot()
        baseline = copy.deepcopy(candidate)
        candidate["pinned_cares"]["dependency_version"] = "1.34.7"
        deltas = self.parity_deltas(baseline, candidate)
        result = build_parity.compare_snapshots(baseline, candidate, deltas)
        self.assertEqual(result["status"], "block")
        self.assertFalse(result["checks"]["pinned_cares"]["match"])

    def test_baseline_setup_replays_release_flags(self) -> None:
        command = build_parity.baseline_setup_command(
            self.parity_snapshot(),
            Path("/tmp/source"),
            Path("/tmp/build"),
        )
        self.assertIn("--buildtype=release", command)
        self.assertIn("-Doptimization=3", command)
        self.assertIn("-Db_lto=true", command)
        self.assertIn("-Db_pgo=off", command)

    def test_compiler_specific_lto_mode_can_be_unavailable(self) -> None:
        snapshot = self.parity_snapshot()
        snapshot["options"]["b_lto_mode"] = None
        command = build_parity.baseline_setup_command(
            snapshot,
            Path("/tmp/source"),
            Path("/tmp/build"),
        )
        self.assertFalse(
            any(argument.startswith("-Db_lto_mode=") for argument in command)
        )

        rows = [
            {"name": name, "value": value}
            for name, value in snapshot["options"].items()
            if name != "b_lto_mode"
        ]
        with mock.patch.object(build_parity, "run_json", return_value=rows):
            options = build_parity.option_map(Path("/tmp/build"))
        self.assertIsNone(options["b_lto_mode"])

    def test_platform_independent_parity_option_is_required(self) -> None:
        snapshot = self.parity_snapshot()
        rows = [
            {"name": name, "value": value}
            for name, value in snapshot["options"].items()
            if name != "b_lto"
        ]
        with mock.patch.object(build_parity, "run_json", return_value=rows):
            with self.assertRaises(build_parity.ParityError):
                build_parity.option_map(Path("/tmp/build"))

    def evidence_case(self, case_id: str, category: str) -> dict:
        measured = self.stats["measured_pairs"]
        baseline = [10.0] * measured
        candidate = [8.0] * measured
        pairs = [1.25] * measured
        return {
            "id": case_id,
            "category": category,
            "stable": True,
            "attempts": 1,
            "orders": [
                ["baseline", "candidate"]
                if index % 2 == 0
                else ["candidate", "baseline"]
                for index in range(measured)
            ],
            "baseline_samples": baseline,
            "candidate_samples": candidate,
            "baseline_median": 10.0,
            "candidate_median": 8.0,
            "baseline_relative_mad": 0.0,
            "candidate_relative_mad": 0.0,
            "pair_speedups": pairs,
            "pair_relative_mad": 0.0,
            "speedup": 1.25,
            "check": "token",
            "promotion_warning_below": 1.02,
            "block_below": 0.98,
            "status": "pass",
        }

    def benchmark_evidence(self, mode: str) -> dict:
        inventory = harness.expected_evidence_inventory(mode, self.manifest)
        cases = [
            self.evidence_case(case_id, category)
            for case_id, category in inventory.items()
        ]
        if mode == "fastcall":
            batches = harness.workload_fastcall_batches()
            minimum = self.manifest["fastcall_measurement"][
                "min_sample_seconds"
            ]
            for case in cases:
                batch = batches[case["id"]]
                baseline_count = batch * math.ceil(
                    minimum * 1e9 / (10.0 * batch)
                )
                candidate_count = batch * math.ceil(
                    minimum * 1e9 / (8.0 * batch)
                )
                case.update(
                    {
                        "traversal_directions": [
                            harness.fastcall_pair_schedule(index)[1]
                            for index in range(self.stats["measured_pairs"])
                        ],
                        "baseline_elapsed_seconds": [
                            10.0 * baseline_count / 1e9
                        ]
                        * self.stats["measured_pairs"],
                        "candidate_elapsed_seconds": [
                            8.0 * candidate_count / 1e9
                        ]
                        * self.stats["measured_pairs"],
                        "baseline_iteration_counts": [baseline_count]
                        * self.stats["measured_pairs"],
                        "candidate_iteration_counts": [candidate_count]
                        * self.stats["measured_pairs"],
                        "batch_iterations": batch,
                    }
                )
        categories = {category: 1.25 for category in inventory.values()}
        gates = dict(
            self.manifest["fastcall_gates"]
            if mode == "fastcall"
            else self.manifest["gates"]
        )
        result = {
            "schema_version": 1,
            "mode": mode,
            "statistics": dict(self.stats),
            "gates": gates,
            "cases": cases,
            "category_geomeans": categories,
            "category_statuses": {
                category: "pass" for category in categories
            },
            "overall_geomean": 1.25,
            "status": "pass",
        }
        if mode == "fastcall":
            result.update(
                {
                    "fastcall_measurement": dict(
                        self.manifest["fastcall_measurement"]
                    ),
                    "exact_label_count": len(cases),
                    "time_geomean": 1.25,
                    "time_status": "pass",
                }
            )
        return result

    def parity_evidence(self) -> dict:
        baseline = self.parity_snapshot()
        candidate = copy.deepcopy(baseline)
        deltas = self.parity_deltas(baseline, candidate)
        return build_parity.compare_snapshots(baseline, candidate, deltas)

    def test_evidence_ingestion_preserves_raw_samples(self) -> None:
        release = self.benchmark_evidence("release")
        fastcall = self.benchmark_evidence("fastcall")
        combined = harness.ingest_evidence(
            self.parity_evidence(), release, fastcall
        )
        self.assertEqual(combined["status"], "success")
        self.assertEqual(combined["qualificationStatus"], "pass")
        self.assertEqual(combined["schemaVersion"], 1)
        self.assertEqual(combined["kind"], "benchmark")
        self.assertEqual(combined["name"], "benchmarks")
        self.assertEqual(
            combined["counts"],
            {"total": 2, "passed": 2, "failed": 0, "skipped": 0},
        )
        self.assertEqual(
            combined["release"]["cases"][0]["baseline_samples"],
            [10.0] * self.stats["measured_pairs"],
        )
        harness.enforce_ingested_evidence(combined)

    def test_evidence_ingestion_fails_on_missing_raw_sample(self) -> None:
        release = self.benchmark_evidence("release")
        release["cases"][0]["candidate_samples"].pop()
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                release,
                self.benchmark_evidence("fastcall"),
            )

    def test_evidence_ingestion_rejects_missing_release_case(self) -> None:
        release = self.benchmark_evidence("release")
        release["cases"].pop()
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                release,
                self.benchmark_evidence("fastcall"),
            )

    def test_evidence_ingestion_rejects_missing_fastcall_label(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        fastcall["cases"].pop()
        fastcall["exact_label_count"] -= 1
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_missing_fastcall_totals(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        del fastcall["cases"][0]["baseline_elapsed_seconds"]
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_short_fastcall_sample(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        fastcall["cases"][0]["baseline_elapsed_seconds"][0] = 0.249
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_fastcall_count_mismatch(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        fastcall["cases"][0]["baseline_iteration_counts"][0] += 1
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_missing_fastcall_traversal(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        fastcall["cases"][0]["traversal_directions"].pop()
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_unbalanced_fastcall_traversal(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        fastcall["cases"][0]["traversal_directions"][1] = "reverse"
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_inconsistent_fastcall_sample(self) -> None:
        fastcall = self.benchmark_evidence("fastcall")
        fastcall["cases"][0]["baseline_samples"][0] += 0.1
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                self.benchmark_evidence("release"),
                fastcall,
            )

    def test_evidence_ingestion_rejects_nonalternating_order(self) -> None:
        release = self.benchmark_evidence("release")
        release["cases"][0]["orders"][1] = ["baseline", "candidate"]
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                release,
                self.benchmark_evidence("fastcall"),
            )

    def test_evidence_ingestion_rejects_changed_statistics(self) -> None:
        release = self.benchmark_evidence("release")
        release["statistics"]["warmup_pairs"] = 0
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                self.parity_evidence(),
                release,
                self.benchmark_evidence("fastcall"),
            )

    def test_evidence_ingestion_recomputes_flag_parity(self) -> None:
        parity = self.parity_evidence()
        parity["candidate"]["options"]["optimization"] = "2"
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                parity,
                self.benchmark_evidence("release"),
                self.benchmark_evidence("fastcall"),
            )

    def test_evidence_ingestion_rejects_link_parity_tampering(self) -> None:
        parity = self.parity_evidence()
        parity["candidate"]["external_link_inputs"].pop()
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                parity,
                self.benchmark_evidence("release"),
                self.benchmark_evidence("fastcall"),
            )

    def test_evidence_ingestion_rejects_source_digest_tampering(self) -> None:
        parity = self.parity_evidence()
        parity["source_feature_deltas"]["features"]["sqlite"]["files"][0][
            "sha256"
        ] = "f" * 64
        with self.assertRaises(harness.HarnessError):
            harness.ingest_evidence(
                parity,
                self.benchmark_evidence("release"),
                self.benchmark_evidence("fastcall"),
            )

    def test_ci_runs_full_h4_and_preserves_raw_evidence(self) -> None:
        workflow = (harness.ROOT / ".github/workflows/build.yml").read_text(
            encoding="utf-8"
        )
        benchmark_job = workflow.split("\n  benchmark:\n", 1)[1].split(
            "\n  build:\n", 1
        )[0]
        self.assertNotIn("h4/micro", benchmark_job)
        for required in (
            "--buildtype=release",
            "-Doptimization=3",
            "-Db_lto=true",
            "-Db_pgo=off",
            "--candidate-build lus/build-benchmark",
            "build_pinned_cares.sh",
            "--cares-source-archive",
            "H4_CARES_SOURCE_ARCHIVE",
            "harness.py validate",
            "test_harness.py",
            "harness.py release",
            "harness.py fastcall",
            "harness.py ingest",
            "harness.py enforce",
            "evidence/h4/release.json",
            "evidence/h4/release.md",
            "evidence/h4/fastcall.json",
            "evidence/h4/fastcall.md",
            "evidence/h4/build-parity.json",
            "name: evidence-benchmarks",
            "path: evidence/benchmarks.json",
            "name: h4-raw-benchmarks",
            "path: evidence/h4",
        ):
            self.assertIn(required, benchmark_job)
        self.assertNotIn("libc-ares-dev", benchmark_job)


if __name__ == "__main__":
    unittest.main()
