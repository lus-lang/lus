#!/usr/bin/env python3
"""Paired H4 performance measurement and evidence reporting."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import socket
import statistics
import subprocess
import sys
from typing import Callable, Iterable


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DEFAULT_MANIFEST = HERE / "benchmarks.json"
FASTCALL_WORKLOAD = HERE / "bench_fastcall.lus"
FASTCALL_SOURCE = ROOT / "lus" / "src" / "lfastcall.c"
FASTCALL_MIN_SAMPLE_SECONDS = 0.25
BUILD_PARITY_OPTIONS = {
    "buildtype",
    "optimization",
    "debug",
    "b_lto",
    "b_lto_mode",
    "b_lto_threads",
    "b_pgo",
    "b_sanitize",
    "b_ndebug",
    "c_args",
    "c_link_args",
    "c_std",
    "default_library",
    "prefer_static",
    "b_pie",
    "b_staticpic",
}


class HarnessError(RuntimeError):
    pass


def relative_mad(values: list[float]) -> float:
    center = statistics.median(values)
    if center <= 0:
        raise HarnessError("benchmark measurements must be positive")
    deviations = [abs(value - center) for value in values]
    return statistics.median(deviations) / center


def geomean(values: Iterable[float]) -> float:
    positive = list(values)
    if not positive or any(value <= 0 for value in positive):
        raise HarnessError("geometric means require positive values")
    return math.exp(sum(math.log(value) for value in positive) / len(positive))


def condition_order(index: int) -> tuple[str, str]:
    if index % 2 == 0:
        return ("baseline", "candidate")
    return ("candidate", "baseline")


def fastcall_pair_schedule(index: int) -> tuple[tuple[str, str], str]:
    cycle_index = index % 4
    order = condition_order(cycle_index)
    traversal = "forward" if cycle_index < 2 else "reverse"
    return order, traversal


def fastcall_warmup_schedule(index: int) -> tuple[tuple[str, str], str]:
    order = condition_order(index)
    traversal = "forward" if index % 2 == 0 else "reverse"
    return order, traversal


def load_manifest(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load benchmark manifest {path}: {exc}") from exc
    validate_manifest(data)
    return data


def validate_manifest(data: dict) -> None:
    if data.get("schema_version") != 1:
        raise HarnessError("benchmark manifest schema_version must be 1")
    stats = data.get("statistics", {})
    warmup_pairs = stats.get("warmup_pairs", 0)
    measured_pairs = stats.get("measured_pairs", 0)
    if warmup_pairs < 2 or warmup_pairs % 2 != 0:
        raise HarnessError(
            "at least two and an even number of warmup pairs are required"
        )
    if measured_pairs < 7 or measured_pairs % 2 != 0:
        raise HarnessError(
            "at least seven and an even number of measured pairs are required"
        )
    if stats.get("max_relative_mad") != 0.03:
        raise HarnessError("relative MAD threshold must be exactly 0.03")
    if stats.get("retries") != 1:
        raise HarnessError("the stability policy requires exactly one retry")

    fastcall_measurement = data.get("fastcall_measurement")
    if fastcall_measurement != {
        "min_sample_seconds": FASTCALL_MIN_SAMPLE_SECONDS
    }:
        raise HarnessError(
            "fastcall samples must run for at least 0.25 seconds"
        )

    gates = data.get("gates", {})
    fastcall_gates = data.get("fastcall_gates", {})
    for name, values in (("gates", gates), ("fastcall_gates", fastcall_gates)):
        if values.get("invalid_case_blocks") is not True:
            raise HarnessError(f"{name} must block invalid measurements")
        if values.get("case_promotion_warning_below", 0) < values.get(
            "case_block_below", math.inf
        ):
            raise HarnessError(
                f"{name} case promotion warning must be at least its block"
            )
        if values.get("overall_promotion_warning_below", 0) < values.get(
            "overall_block_below", math.inf
        ):
            raise HarnessError(
                f"{name} overall promotion warning must be at least its block"
            )
        if values.get("category_block_below") != 0.95:
            raise HarnessError(f"{name} category block threshold must be 0.95x")
        if values.get("regression_warning_below") != 0.95:
            raise HarnessError(f"{name} regression warning must begin at 0.95x")
        if values.get("regression_block_below") != 0.90:
            raise HarnessError(f"{name} regression block must begin at 0.90x")
    if gates.get("case_block_below") != 0.98:
        raise HarnessError("the valid case block threshold must be 0.98x")
    if gates.get("overall_block_below") != 1.05:
        raise HarnessError("the overall block threshold must be 1.05x")
    if fastcall_gates.get("case_block_below") != 0.98:
        raise HarnessError("fastcall valid cases must block below 0.98x")
    if fastcall_gates.get("overall_block_below") != 1.05:
        raise HarnessError("fastcall overall must block below 1.05x")
    if fastcall_gates.get("time_block_below") != 1.10:
        raise HarnessError("time fastcalls must block below 1.10x")
    if fastcall_gates.get("time_promotion_warning_below", 0) < 1.10:
        raise HarnessError(
            "the time promotion warning must be at least its 1.10x block"
        )

    seen: set[str] = set()
    for case in data.get("cases", []):
        case_id = case.get("id")
        if not case_id or case_id in seen:
            raise HarnessError(f"duplicate or empty benchmark id: {case_id}")
        seen.add(case_id)
        script = HERE / case.get("script", "")
        if not script.is_file():
            raise HarnessError(f"benchmark script does not exist: {script}")
        if case.get("block_below") != 0.98:
            raise HarnessError(f"{case_id} must block below 0.98x")
        warning = case.get("promotion_warning_below")
        target = case.get("target_speedup")
        if not isinstance(warning, (int, float)) or warning < 0.98:
            raise HarnessError(f"{case_id} needs a valid warning threshold")
        if not isinstance(target, (int, float)) or target < warning:
            raise HarnessError(f"{case_id} needs a valid promotion target")
        if not case.get("revert_guidance"):
            raise HarnessError(f"{case_id} needs revert guidance")
        if not case.get("suites"):
            raise HarnessError(f"{case_id} needs at least one suite")
        dynamic_args = case.get("dynamic_args", [])
        if not isinstance(dynamic_args, list) or any(
            value != "loopback_port" for value in dynamic_args
        ):
            raise HarnessError(f"{case_id} has an unknown dynamic argument")
    pgo = data.get("pgo", {})
    if pgo.get("promotion_warning_below", 0) < pgo.get(
        "block_below", math.inf
    ):
        raise HarnessError("the PGO promotion warning must be at least its block")
    if pgo.get("target_speedup", 0) < pgo.get(
        "promotion_warning_below", math.inf
    ):
        raise HarnessError("the PGO target must be at least its warning")
    if not pgo.get("revert_guidance"):
        raise HarnessError("the PGO experiment needs revert guidance")


def expected_fastcalls() -> dict[str, str]:
    text = FASTCALL_SOURCE.read_text(encoding="utf-8")
    pattern = re.compile(
        r'\[FC_[A-Z0-9_]+\]\s*=\s*\{"([^"]+)",\s*FC_MOD_([A-Z0-9_]+)'
    )
    expected: dict[str, str] = {}
    for function, module_name in pattern.findall(text):
        category = module_name.lower()
        label = f"{category}.{function}"
        if label in expected:
            raise HarnessError(f"duplicate registered fastcall label: {label}")
        expected[label] = category
    if not expected:
        raise HarnessError("no fastcall registrations were found")
    return expected


def workload_fastcalls() -> list[tuple[str, str]]:
    text = FASTCALL_WORKLOAD.read_text(encoding="utf-8")
    pattern = re.compile(r'add\(\s*"([^"]+)"\s*,\s*"([^"]+)"')
    return pattern.findall(text)


def workload_fastcall_batches() -> dict[str, int]:
    text = FASTCALL_WORKLOAD.read_text(encoding="utf-8")
    constants = {
        name: int(value)
        for name, value in re.findall(
            r"local\s+([A-Z][A-Z0-9_]*)\s*=\s*([0-9]+)", text
        )
    }
    rows = re.findall(
        r'add\(\s*"[^"]+"\s*,\s*"([^"]+)"\s*,\s*([A-Z][A-Z0-9_]*)',
        text,
    )
    batches: dict[str, int] = {}
    for label, constant in rows:
        if label in batches:
            raise HarnessError(f"duplicate fastcall batch label: {label}")
        batch = constants.get(constant)
        if batch is None or batch <= 0:
            raise HarnessError(
                f"{label} has an invalid fixed-size batch: {constant}"
            )
        batches[label] = batch
    return batches


def validate_fastcall_inventory() -> dict[str, str]:
    expected = expected_fastcalls()
    rows = workload_fastcalls()
    counts = collections.Counter(label for _, label in rows)
    duplicates = sorted(label for label, count in counts.items() if count != 1)
    actual = {label: category for category, label in rows}
    missing = sorted(set(expected) - set(actual))
    unexpected = sorted(set(actual) - set(expected))
    wrong_categories = sorted(
        label
        for label in set(expected) & set(actual)
        if expected[label] != actual[label]
    )
    batches = workload_fastcall_batches()
    missing_batches = sorted(set(expected) - set(batches))
    unexpected_batches = sorted(set(batches) - set(expected))
    if (
        duplicates
        or missing
        or unexpected
        or wrong_categories
        or missing_batches
        or unexpected_batches
    ):
        details = {
            "duplicates": duplicates,
            "missing": missing,
            "unexpected": unexpected,
            "wrong_categories": wrong_categories,
            "missing_batches": missing_batches,
            "unexpected_batches": unexpected_batches,
        }
        raise HarnessError(f"fastcall workload inventory mismatch: {details}")
    return expected


def resolve_binary(value: str) -> Path:
    binary = Path(value).expanduser().resolve()
    if not binary.is_file():
        raise HarnessError(f"benchmark binary does not exist: {binary}")
    if not os.access(binary, os.X_OK):
        raise HarnessError(f"benchmark binary is not executable: {binary}")
    return binary


def binary_metadata(binary: Path) -> dict[str, str]:
    digest = hashlib.sha256()
    try:
        with binary.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise HarnessError(f"cannot hash benchmark binary {binary}: {exc}") from exc
    version = run_process([str(binary), "-E", "-v"], timeout=30).strip()
    if not version:
        raise HarnessError(f"benchmark binary emitted no version: {binary}")
    return {
        "path": str(binary),
        "version": version,
        "sha256": digest.hexdigest(),
    }


def require_release_baseline(metadata: dict[str, str]) -> None:
    if not metadata["version"].startswith("Lus 1.6.2 "):
        raise HarnessError(
            "the release baseline must report Lus 1.6.2, got "
            f"{metadata['version']!r}"
        )


def require_unchanged_binary(before: dict[str, str], binary: Path) -> None:
    after = binary_metadata(binary)
    if before != after:
        raise HarnessError(f"benchmark binary changed during measurement: {binary}")


def run_process(command: list[str], timeout: int = 180) -> str:
    process_env = os.environ.copy()
    process_env["LC_ALL"] = "C"
    process_env["LANG"] = "C"
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=process_env,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HarnessError(f"benchmark command failed to run: {command}: {exc}") from exc
    if completed.returncode != 0:
        output = completed.stdout.strip()
        error = completed.stderr.strip()
        raise HarnessError(
            f"benchmark command exited {completed.returncode}: {command}\n"
            f"stdout: {output}\nstderr: {error}"
        )
    return completed.stdout


def parse_single_result(output: str, case_id: str) -> tuple[float, str]:
    times: list[float] = []
    checks: list[str] = []
    for line in output.splitlines():
        time_match = re.fullmatch(
            r"TIME\s+([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)", line.strip()
        )
        if time_match:
            times.append(float(time_match.group(1)))
        check_match = re.fullmatch(r"CHECK\s+(.+)", line.strip())
        if check_match:
            checks.append(check_match.group(1))
    if len(times) != 1:
        raise HarnessError(
            f"{case_id} emitted {len(times)} TIME lines instead of exactly one"
        )
    if len(checks) != 1:
        raise HarnessError(
            f"{case_id} emitted {len(checks)} CHECK lines instead of exactly one"
        )
    if not math.isfinite(times[0]) or times[0] <= 0:
        raise HarnessError(f"{case_id} emitted an invalid time: {times[0]}")
    return times[0], checks[0]


def single_executor(binary: Path, case: dict) -> Callable[[str], tuple[float, str]]:
    script = HERE / case["script"]
    extra_args = [str(value) for value in case.get("args", [])]

    def execute(_: str) -> tuple[float, str]:
        dynamic_args = []
        for value in case.get("dynamic_args", []):
            if value == "loopback_port":
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                    probe.bind(("127.0.0.1", 0))
                    dynamic_args.append(str(probe.getsockname()[1]))
        output = run_process(
            [str(binary), "-E", str(script), *extra_args, *dynamic_args]
        )
        return parse_single_result(output, case["id"])

    return execute


def stable_pair(
    baseline: Callable[[str], tuple[float, str]],
    candidate: Callable[[str], tuple[float, str]],
    stats: dict,
    progress: str,
) -> dict:
    max_mad = stats["max_relative_mad"]
    expected_check: str | None = None
    attempts = stats["retries"] + 1
    final: dict | None = None

    for attempt in range(attempts):
        order_index = 0
        for _ in range(stats["warmup_pairs"]):
            for condition in condition_order(order_index):
                value, check = (
                    baseline(condition)
                    if condition == "baseline"
                    else candidate(condition)
                )
                if value <= 0:
                    raise HarnessError(f"{progress} emitted a nonpositive warmup")
                if expected_check is None:
                    expected_check = check
                elif check != expected_check:
                    raise HarnessError(
                        f"{progress} correctness token changed during warmup: "
                        f"{expected_check!r} versus {check!r}"
                    )
            order_index += 1

        samples = {"baseline": [], "candidate": []}
        orders: list[list[str]] = []
        for pair in range(stats["measured_pairs"]):
            order = condition_order(order_index + pair)
            orders.append(list(order))
            for condition in order:
                value, check = (
                    baseline(condition)
                    if condition == "baseline"
                    else candidate(condition)
                )
                if expected_check is None:
                    expected_check = check
                elif check != expected_check:
                    raise HarnessError(
                        f"{progress} correctness token changed during measurement: "
                        f"{expected_check!r} versus {check!r}"
                    )
                samples[condition].append(value)

        baseline_median = statistics.median(samples["baseline"])
        candidate_median = statistics.median(samples["candidate"])
        baseline_mad = relative_mad(samples["baseline"])
        candidate_mad = relative_mad(samples["candidate"])
        pair_speedups = [
            baseline_value / candidate_value
            for baseline_value, candidate_value in zip(
                samples["baseline"], samples["candidate"]
            )
        ]
        pair_mad = relative_mad(pair_speedups)
        stable = (
            baseline_mad <= max_mad
            and candidate_mad <= max_mad
            and pair_mad <= max_mad
        )
        final = {
            "attempts": attempt + 1,
            "stable": stable,
            "check": expected_check,
            "orders": orders,
            "baseline_samples": samples["baseline"],
            "candidate_samples": samples["candidate"],
            "baseline_median": baseline_median,
            "candidate_median": candidate_median,
            "baseline_relative_mad": baseline_mad,
            "candidate_relative_mad": candidate_mad,
            "pair_speedups": pair_speedups,
            "pair_relative_mad": pair_mad,
            "speedup": statistics.median(pair_speedups),
        }
        if stable:
            return final
        if attempt + 1 < attempts:
            print(
                f"{progress}: relative MAD exceeded {max_mad:.1%}. "
                "Retrying once.",
                file=sys.stderr,
            )
    if final is None:
        raise HarnessError(f"{progress} produced no measurements")
    return final


def classify_case(case: dict, measurement: dict, gates: dict) -> str:
    if not measurement["stable"]:
        return "block" if gates["invalid_case_blocks"] else "warning"
    block_below = max(case.get("block_below", 0.98), gates["case_block_below"])
    warning_below = case.get(
        "promotion_warning_below",
        gates["case_promotion_warning_below"],
    )
    if measurement["speedup"] < block_below:
        return "block"
    if measurement["speedup"] < gates["regression_block_below"]:
        return "block"
    if measurement["speedup"] < gates["regression_warning_below"]:
        return "warning"
    if measurement["speedup"] < warning_below:
        return "warning"
    return "pass"


def aggregate_cases(cases: list[dict]) -> tuple[dict[str, float], float | None]:
    categories: dict[str, list[float]] = {}
    valid: list[float] = []
    for case in cases:
        if not case["stable"]:
            continue
        categories.setdefault(case["category"], []).append(case["speedup"])
        valid.append(case["speedup"])
    category_geomeans = {
        category: geomean(speedups)
        for category, speedups in sorted(categories.items())
    }
    overall = geomean(valid) if valid else None
    return category_geomeans, overall


def category_statuses(categories: dict[str, float], gates: dict) -> dict[str, str]:
    statuses = {}
    for category, speedup in categories.items():
        if speedup < gates["category_block_below"]:
            statuses[category] = "block"
        elif speedup < gates["regression_warning_below"]:
            statuses[category] = "warning"
        else:
            statuses[category] = "pass"
    return statuses


def final_status(
    cases: list[dict],
    categories: dict[str, float],
    overall: float | None,
    gates: dict,
) -> str:
    if any(case["status"] == "block" for case in cases):
        return "block"
    if any(
        value < gates["category_block_below"] for value in categories.values()
    ):
        return "block"
    if overall is None or overall < gates["overall_block_below"]:
        return "block"
    if any(case["status"] == "warning" for case in cases):
        return "warning"
    if overall < gates["regression_warning_below"]:
        return "warning"
    if overall < gates["overall_promotion_warning_below"]:
        return "warning"
    return "pass"


def compare_cases(
    manifest: dict,
    baseline_binary: Path,
    candidate_binary: Path,
    suite: str,
    case_id: str | None,
    pgo: bool,
) -> dict:
    baseline_metadata = binary_metadata(baseline_binary)
    candidate_metadata = binary_metadata(candidate_binary)
    selected = []
    for case in manifest["cases"]:
        if case_id is not None and case["id"] == case_id:
            selected.append(case)
        elif case_id is None and suite in case["suites"]:
            selected.append(case)
    if not selected:
        target = case_id if case_id is not None else suite
        raise HarnessError(f"no benchmark cases matched {target}")

    stats = manifest["statistics"]
    gates = dict(manifest["gates"])
    if pgo:
        gates["overall_promotion_warning_below"] = manifest["pgo"][
            "promotion_warning_below"
        ]
        gates["overall_block_below"] = manifest["pgo"]["block_below"]

    results = []
    for index, case in enumerate(selected, 1):
        print(
            f"[{index}/{len(selected)}] measuring {case['id']}",
            file=sys.stderr,
        )
        measurement = stable_pair(
            single_executor(baseline_binary, case),
            single_executor(candidate_binary, case),
            stats,
            case["id"],
        )
        result = dict(case)
        result.update(measurement)
        result["status"] = classify_case(case, result, gates)
        results.append(result)

    categories, overall = aggregate_cases(results)
    category_states = category_statuses(categories, gates)
    status = final_status(results, categories, overall, gates)
    require_unchanged_binary(baseline_metadata, baseline_binary)
    require_unchanged_binary(candidate_metadata, candidate_binary)
    return {
        "schema_version": 1,
        "mode": "pgo" if pgo else "compare",
        "suite": suite,
        "baseline": str(baseline_binary),
        "candidate": str(candidate_binary),
        "binaries": {
            "baseline": baseline_metadata,
            "candidate": candidate_metadata,
        },
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "statistics": stats,
        "gates": gates,
        "cases": results,
        "category_geomeans": categories,
        "category_statuses": category_states,
        "overall_geomean": overall,
        "status": status,
        "revert_guidance": manifest["pgo"]["revert_guidance"] if pgo else None,
    }


def parse_fastcall_output(
    output: str,
    expected: dict[str, str],
    batches: dict[str, int],
    min_sample_seconds: float,
) -> dict[str, dict[str, float | int]]:
    rows: list[tuple[str, str, float, float, int]] = []
    pattern = re.compile(
        r"([^\t]+)\t([^\t]+)\t"
        r"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\t"
        r"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\t([0-9]+)"
    )
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        match = pattern.fullmatch(stripped)
        if match is None:
            raise HarnessError(f"malformed fastcall output line: {stripped!r}")
        rows.append(
            (
                match.group(1),
                match.group(2),
                float(match.group(3)),
                float(match.group(4)),
                int(match.group(5)),
            )
        )
    counts = collections.Counter(label for _, label, _, _, _ in rows)
    duplicates = sorted(label for label, count in counts.items() if count != 1)
    actual = {label for _, label, _, _, _ in rows}
    missing = sorted(set(expected) - actual)
    unexpected = sorted(actual - set(expected))
    wrong_categories = sorted(
        label
        for category, label, _, _, _ in rows
        if label in expected and expected[label] != category
    )
    if duplicates or missing or unexpected or wrong_categories:
        details = {
            "duplicates": duplicates,
            "missing": missing,
            "unexpected": unexpected,
            "wrong_categories": wrong_categories,
        }
        raise HarnessError(f"fastcall output inventory mismatch: {details}")
    result: dict[str, dict[str, float | int]] = {}
    for _, label, ns_per_op, elapsed_seconds, iterations in rows:
        if (
            not math.isfinite(ns_per_op)
            or ns_per_op <= 0
            or not math.isfinite(elapsed_seconds)
            or elapsed_seconds < min_sample_seconds
        ):
            raise HarnessError(
                f"{label} emitted an invalid or short fastcall measurement"
            )
        batch = batches.get(label)
        if batch is None or iterations <= 0 or iterations % batch != 0:
            raise HarnessError(
                f"{label} emitted an invalid fixed-size iteration count"
            )
        computed = elapsed_seconds * 1e9 / iterations
        if not math.isclose(
            ns_per_op, computed, rel_tol=1e-12, abs_tol=1e-9
        ):
            raise HarnessError(
                f"{label} nanoseconds per operation are inconsistent with totals"
            )
        result[label] = {
            "ns_per_op": ns_per_op,
            "elapsed_seconds": elapsed_seconds,
            "iterations": iterations,
        }
    return result


def run_fastcall_process(
    binary: Path,
    enabled: bool,
    reverse: bool,
    expected: dict[str, str],
    batches: dict[str, int],
    min_sample_seconds: float,
) -> dict[str, dict[str, float | int]]:
    command = [str(binary)]
    if not enabled:
        command.append("--no-fastcall")
    command.append("-E")
    command.append(str(FASTCALL_WORKLOAD))
    command.append("reverse" if reverse else "forward")
    command.append(f"{min_sample_seconds:.9f}")
    return parse_fastcall_output(
        run_process(command, timeout=600),
        expected,
        batches,
        min_sample_seconds,
    )


def fastcall_attempt(
    binary: Path,
    expected: dict[str, str],
    batches: dict[str, int],
    stats: dict,
    measurement: dict,
) -> tuple[
    dict[str, dict[str, list[dict[str, float | int]]]],
    list[list[str]],
    list[str],
]:
    min_sample_seconds = measurement["min_sample_seconds"]
    for warmup in range(stats["warmup_pairs"]):
        order, traversal = fastcall_warmup_schedule(warmup)
        for condition in order:
            run_fastcall_process(
                binary,
                enabled=condition == "candidate",
                reverse=traversal == "reverse",
                expected=expected,
                batches=batches,
                min_sample_seconds=min_sample_seconds,
            )

    samples = {
        label: {"baseline": [], "candidate": []}
        for label in expected
    }
    orders = []
    traversal_directions = []
    for pair in range(stats["measured_pairs"]):
        order, traversal = fastcall_pair_schedule(pair)
        orders.append(list(order))
        traversal_directions.append(traversal)
        for condition in order:
            values = run_fastcall_process(
                binary,
                enabled=condition == "candidate",
                reverse=traversal == "reverse",
                expected=expected,
                batches=batches,
                min_sample_seconds=min_sample_seconds,
            )
            for label, value in values.items():
                samples[label][condition].append(value)
    return samples, orders, traversal_directions


def compare_fastcalls(manifest: dict, binary: Path) -> dict:
    metadata = binary_metadata(binary)
    expected = validate_fastcall_inventory()
    batches = workload_fastcall_batches()
    stats = manifest["statistics"]
    measurement = manifest["fastcall_measurement"]
    gates = manifest["fastcall_gates"]
    final_samples = None
    final_orders = None
    final_traversal_directions = None
    attempts = stats["retries"] + 1

    for attempt in range(attempts):
        print(
            f"measuring {len(expected)} exact fastcall labels, "
            f"attempt {attempt + 1}/{attempts}",
            file=sys.stderr,
        )
        samples, orders, traversal_directions = fastcall_attempt(
            binary,
            expected,
            batches,
            stats,
            measurement,
        )
        unstable = []
        for label, condition_samples in samples.items():
            baseline_values = [
                float(record["ns_per_op"])
                for record in condition_samples["baseline"]
            ]
            candidate_values = [
                float(record["ns_per_op"])
                for record in condition_samples["candidate"]
            ]
            pair_speedups = [
                baseline_value / candidate_value
                for baseline_value, candidate_value in zip(
                    baseline_values,
                    candidate_values,
                )
            ]
            if (
                relative_mad(baseline_values) > stats["max_relative_mad"]
                or relative_mad(candidate_values) > stats["max_relative_mad"]
                or relative_mad(pair_speedups) > stats["max_relative_mad"]
            ):
                unstable.append(label)
        final_samples = samples
        final_orders = orders
        final_traversal_directions = traversal_directions
        if not unstable:
            break
        if attempt + 1 < attempts:
            print(
                f"{len(unstable)} fastcall labels exceeded "
                f"{stats['max_relative_mad']:.1%} relative MAD. Retrying once.",
                file=sys.stderr,
            )

    if (
        final_samples is None
        or final_orders is None
        or final_traversal_directions is None
    ):
        raise HarnessError("fastcall suite produced no measurements")

    results = []
    for label, category in expected.items():
        baseline_records = final_samples[label]["baseline"]
        candidate_records = final_samples[label]["candidate"]
        baseline_values = [
            float(record["ns_per_op"]) for record in baseline_records
        ]
        candidate_values = [
            float(record["ns_per_op"]) for record in candidate_records
        ]
        baseline_median = statistics.median(baseline_values)
        candidate_median = statistics.median(candidate_values)
        baseline_mad = relative_mad(baseline_values)
        candidate_mad = relative_mad(candidate_values)
        pair_speedups = [
            baseline_value / candidate_value
            for baseline_value, candidate_value in zip(
                baseline_values, candidate_values
            )
        ]
        pair_mad = relative_mad(pair_speedups)
        stable = (
            baseline_mad <= stats["max_relative_mad"]
            and candidate_mad <= stats["max_relative_mad"]
            and pair_mad <= stats["max_relative_mad"]
        )
        case = {
            "id": label,
            "category": category,
            "stable": stable,
            "attempts": attempt + 1,
            "orders": final_orders,
            "traversal_directions": final_traversal_directions,
            "baseline_samples": baseline_values,
            "candidate_samples": candidate_values,
            "baseline_elapsed_seconds": [
                float(record["elapsed_seconds"])
                for record in baseline_records
            ],
            "candidate_elapsed_seconds": [
                float(record["elapsed_seconds"])
                for record in candidate_records
            ],
            "baseline_iteration_counts": [
                int(record["iterations"]) for record in baseline_records
            ],
            "candidate_iteration_counts": [
                int(record["iterations"]) for record in candidate_records
            ],
            "batch_iterations": batches[label],
            "baseline_median": baseline_median,
            "candidate_median": candidate_median,
            "baseline_relative_mad": baseline_mad,
            "candidate_relative_mad": candidate_mad,
            "pair_speedups": pair_speedups,
            "pair_relative_mad": pair_mad,
            "speedup": statistics.median(pair_speedups),
            "promotion_warning_below": gates[
                "case_promotion_warning_below"
            ],
            "block_below": gates["case_block_below"],
        }
        case["status"] = classify_case(case, case, gates)
        results.append(case)

    categories, overall = aggregate_cases(results)
    category_states = category_statuses(categories, gates)
    status = final_status(results, categories, overall, gates)
    time_geomean = categories.get("time")
    time_status = "block"
    if time_geomean is not None:
        if time_geomean < gates["time_block_below"]:
            time_status = "block"
        elif time_geomean < gates["time_promotion_warning_below"]:
            time_status = "warning"
        else:
            time_status = "pass"
    if time_status == "block":
        status = "block"
    elif time_status == "warning" and status == "pass":
        status = "warning"

    require_unchanged_binary(metadata, binary)

    return {
        "schema_version": 1,
        "mode": "fastcall",
        "baseline": f"{binary} --no-fastcall",
        "candidate": str(binary),
        "binaries": {
            "baseline": {
                **metadata,
                "options": ["--no-fastcall"],
            },
            "candidate": metadata,
        },
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "statistics": stats,
        "fastcall_measurement": measurement,
        "gates": gates,
        "exact_label_count": len(expected),
        "cases": results,
        "category_geomeans": categories,
        "category_statuses": category_states,
        "overall_geomean": overall,
        "time_geomean": time_geomean,
        "time_status": time_status,
        "status": status,
    }


def load_evidence(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot load {label} evidence {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise HarnessError(f"{label} evidence must be a JSON object")
    return value


def same_number(left: object, right: float) -> bool:
    return isinstance(left, (int, float)) and math.isclose(
        float(left), right, rel_tol=1e-9, abs_tol=1e-12
    )


def validate_fastcall_totals(
    case: dict,
    measured_pairs: int,
    measurement: dict,
    expected_batch: int,
) -> None:
    if case.get("batch_iterations") != expected_batch:
        raise HarnessError(
            f"{case.get('id')} evidence has an invalid fixed-size batch"
        )
    min_sample_seconds = measurement["min_sample_seconds"]
    traversal_directions = case.get("traversal_directions")
    if (
        not isinstance(traversal_directions, list)
        or len(traversal_directions) != measured_pairs
    ):
        raise HarnessError(
            f"{case.get('id')} evidence needs {measured_pairs} "
            "traversal_directions entries"
        )
    for index, traversal in enumerate(traversal_directions):
        expected_traversal = fastcall_pair_schedule(index)[1]
        if traversal != expected_traversal:
            raise HarnessError(
                f"{case.get('id')} evidence has an unbalanced fastcall "
                "traversal schedule"
            )
    for condition in ("baseline", "candidate"):
        samples = case.get(f"{condition}_samples")
        elapsed = case.get(f"{condition}_elapsed_seconds")
        counts = case.get(f"{condition}_iteration_counts")
        for name, values in (
            (f"{condition}_elapsed_seconds", elapsed),
            (f"{condition}_iteration_counts", counts),
        ):
            if not isinstance(values, list) or len(values) != measured_pairs:
                raise HarnessError(
                    f"{case.get('id')} evidence needs {measured_pairs} "
                    f"{name} entries"
                )
        for index, (sample, duration, count) in enumerate(
            zip(samples, elapsed, counts), 1
        ):
            if (
                isinstance(duration, bool)
                or not isinstance(duration, (int, float))
                or not math.isfinite(float(duration))
                or duration < min_sample_seconds
            ):
                raise HarnessError(
                    f"{case.get('id')} {condition} sample {index} is shorter "
                    "than the fastcall minimum duration"
                )
            if (
                type(count) is not int
                or count <= 0
                or count % expected_batch != 0
            ):
                raise HarnessError(
                    f"{case.get('id')} {condition} sample {index} has an "
                    "invalid fixed-size iteration count"
                )
            computed = float(duration) * 1e9 / count
            if not same_number(sample, computed):
                raise HarnessError(
                    f"{case.get('id')} {condition} sample {index} is "
                    "inconsistent with its elapsed time and iteration count"
                )


def validate_case_evidence(
    case: dict,
    stats: dict,
    gates: dict,
    fastcall_measurement: dict | None = None,
    fastcall_batch: int | None = None,
) -> None:
    measured_pairs = stats["measured_pairs"]
    baseline = case.get("baseline_samples")
    candidate = case.get("candidate_samples")
    pair_speedups = case.get("pair_speedups")
    orders = case.get("orders")
    for name, values in (
        ("baseline_samples", baseline),
        ("candidate_samples", candidate),
        ("pair_speedups", pair_speedups),
        ("orders", orders),
    ):
        if not isinstance(values, list) or len(values) != measured_pairs:
            raise HarnessError(
                f"{case.get('id')} evidence needs {measured_pairs} {name} entries"
            )
    if case.get("stable") is not True:
        raise HarnessError(f"{case.get('id')} evidence is not stable")
    if case.get("attempts") not in (1, 2):
        raise HarnessError(f"{case.get('id')} evidence has an invalid attempt count")
    for index, order in enumerate(orders):
        if fastcall_measurement is None:
            expected_order = list(
                condition_order(stats["warmup_pairs"] + index)
            )
        else:
            expected_order = list(fastcall_pair_schedule(index)[0])
        if order != expected_order:
            raise HarnessError(
                f"{case.get('id')} evidence has a nonalternating pair order"
            )
    if not all(isinstance(value, (int, float)) and value > 0 for value in baseline):
        raise HarnessError(f"{case.get('id')} baseline samples are invalid")
    if not all(isinstance(value, (int, float)) and value > 0 for value in candidate):
        raise HarnessError(f"{case.get('id')} candidate samples are invalid")
    if fastcall_measurement is not None:
        if fastcall_batch is None:
            raise HarnessError(f"{case.get('id')} evidence omits its batch size")
        validate_fastcall_totals(
            case,
            measured_pairs,
            fastcall_measurement,
            fastcall_batch,
        )

    computed_pairs = [
        left / right for left, right in zip(baseline, candidate)
    ]
    if any(
        not same_number(recorded, computed)
        for recorded, computed in zip(pair_speedups, computed_pairs)
    ):
        raise HarnessError(f"{case.get('id')} paired speedups do not match samples")
    computed = {
        "baseline_median": statistics.median(baseline),
        "candidate_median": statistics.median(candidate),
        "baseline_relative_mad": relative_mad(baseline),
        "candidate_relative_mad": relative_mad(candidate),
        "pair_relative_mad": relative_mad(computed_pairs),
        "speedup": statistics.median(computed_pairs),
    }
    for name, value in computed.items():
        if not same_number(case.get(name), value):
            raise HarnessError(f"{case.get('id')} evidence has an invalid {name}")
    if any(
        computed[name] > stats["max_relative_mad"]
        for name in (
            "baseline_relative_mad",
            "candidate_relative_mad",
            "pair_relative_mad",
        )
    ):
        raise HarnessError(f"{case.get('id')} evidence exceeds the MAD limit")
    expected_status = classify_case(case, case, gates)
    if case.get("status") != expected_status or expected_status == "block":
        raise HarnessError(f"{case.get('id')} evidence does not pass its case gate")


def expected_evidence_inventory(
    expected_mode: str,
    manifest: dict,
) -> dict[str, str]:
    if expected_mode == "release":
        return {
            case["id"]: case["category"]
            for case in manifest["cases"]
            if "release" in case["suites"]
        }
    if expected_mode == "fastcall":
        return validate_fastcall_inventory()
    raise HarnessError(f"unknown benchmark evidence mode: {expected_mode}")


def validate_benchmark_evidence(
    result: dict,
    expected_mode: str,
    manifest: dict | None = None,
) -> None:
    if manifest is None:
        manifest = load_manifest(DEFAULT_MANIFEST)
    if result.get("schema_version") != 1 or result.get("mode") != expected_mode:
        raise HarnessError(f"invalid {expected_mode} evidence schema or mode")
    stats = result.get("statistics")
    gates = result.get("gates")
    cases = result.get("cases")
    if not isinstance(stats, dict) or not isinstance(gates, dict):
        raise HarnessError(f"{expected_mode} evidence omits statistics or gates")
    expected_stats = manifest["statistics"]
    expected_gates = (
        manifest["fastcall_gates"]
        if expected_mode == "fastcall"
        else manifest["gates"]
    )
    fastcall_measurement = None
    fastcall_batches: dict[str, int] = {}
    if expected_mode == "fastcall":
        fastcall_measurement = result.get("fastcall_measurement")
        if fastcall_measurement != manifest["fastcall_measurement"]:
            raise HarnessError(
                "fastcall evidence does not match the predeclared "
                "minimum sample duration"
            )
        fastcall_batches = workload_fastcall_batches()
    if stats != expected_stats:
        raise HarnessError(
            f"{expected_mode} evidence does not match the predeclared statistics"
        )
    if gates != expected_gates:
        raise HarnessError(
            f"{expected_mode} evidence does not match the predeclared gates"
        )
    if (
        stats.get("warmup_pairs", 0) < 2
        or stats.get("warmup_pairs", 0) % 2 != 0
        or stats.get("measured_pairs", 0) < 7
        or stats.get("measured_pairs", 0) % 2 != 0
        or stats.get("max_relative_mad") != 0.03
        or stats.get("retries") != 1
    ):
        raise HarnessError(f"{expected_mode} evidence has invalid statistics")
    required_gates = {
        "case_block_below": 0.98,
        "category_block_below": 0.95,
        "overall_block_below": 1.05,
    }
    if expected_mode == "fastcall":
        required_gates["time_block_below"] = 1.10
    if any(gates.get(name) != value for name, value in required_gates.items()):
        raise HarnessError(f"{expected_mode} evidence weakens a required gate")
    if not isinstance(cases, list) or not cases:
        raise HarnessError(f"{expected_mode} evidence has no cases")
    seen_ids = set()
    for case in cases:
        if not isinstance(case, dict):
            raise HarnessError(f"{expected_mode} evidence contains a non-object case")
        case_id = case.get("id")
        if not case_id or case_id in seen_ids:
            raise HarnessError(f"{expected_mode} evidence has duplicate case ids")
        seen_ids.add(case_id)
        if expected_mode == "release" and not case.get("check"):
            raise HarnessError(f"{case_id} evidence omits its correctness token")
        validate_case_evidence(
            case,
            stats,
            gates,
            fastcall_measurement,
            fastcall_batches.get(case_id),
        )

    expected_inventory = expected_evidence_inventory(expected_mode, manifest)
    actual_inventory = {case["id"]: case.get("category") for case in cases}
    missing = sorted(set(expected_inventory) - set(actual_inventory))
    unexpected = sorted(set(actual_inventory) - set(expected_inventory))
    wrong_categories = sorted(
        case_id
        for case_id in set(expected_inventory) & set(actual_inventory)
        if expected_inventory[case_id] != actual_inventory[case_id]
    )
    if missing or unexpected or wrong_categories:
        raise HarnessError(
            f"{expected_mode} evidence inventory mismatch: "
            f"missing={missing}, unexpected={unexpected}, "
            f"wrong_categories={wrong_categories}"
        )

    categories, overall = aggregate_cases(cases)
    recorded_categories = result.get("category_geomeans")
    if not isinstance(recorded_categories, dict) or set(categories) != set(
        recorded_categories
    ):
        raise HarnessError(f"{expected_mode} category evidence is incomplete")
    for name, value in categories.items():
        if not same_number(recorded_categories.get(name), value):
            raise HarnessError(f"{expected_mode} category {name} is inconsistent")
    if result.get("category_statuses") != category_statuses(categories, gates):
        raise HarnessError(f"{expected_mode} category statuses are inconsistent")
    if overall is None or not same_number(result.get("overall_geomean"), overall):
        raise HarnessError(f"{expected_mode} overall geomean is inconsistent")

    expected_status = final_status(cases, categories, overall, gates)
    if expected_mode == "fastcall":
        if result.get("exact_label_count") != len(cases):
            raise HarnessError("fastcall evidence does not contain every exact label")
        time_geomean = categories.get("time")
        if time_geomean is None or not same_number(
            result.get("time_geomean"), time_geomean
        ):
            raise HarnessError("fastcall time category evidence is inconsistent")
        if time_geomean < gates["time_block_below"]:
            expected_time_status = "block"
        elif time_geomean < gates["time_promotion_warning_below"]:
            expected_time_status = "warning"
        else:
            expected_time_status = "pass"
        if result.get("time_status") != expected_time_status:
            raise HarnessError("fastcall time status is inconsistent")
        if expected_time_status == "block":
            expected_status = "block"
        elif expected_time_status == "warning" and expected_status == "pass":
            expected_status = "warning"
    if result.get("status") != expected_status or expected_status == "block":
        raise HarnessError(f"{expected_mode} evidence does not pass qualification")


def validate_pinned_cares_evidence(parity: dict, metadata: dict) -> None:
    expected = metadata.get("caresSource")
    baseline = parity["baseline"].get("pinned_cares")
    candidate = parity["candidate"].get("pinned_cares")
    if not isinstance(expected, dict) or baseline != candidate:
        raise HarnessError("pinned c-ares build evidence is inconsistent")
    library_digest = candidate.get("library_sha256") if isinstance(candidate, dict) else None
    if not isinstance(library_digest, str) or not re.fullmatch(
        r"[0-9a-f]{64}", library_digest
    ):
        raise HarnessError("pinned c-ares library digest is invalid")
    required = {
        "name": "c-ares",
        "version": expected.get("version"),
        "url": expected.get("url"),
        "expected_sha256": expected.get("sha256"),
        "archive_sha256": expected.get("sha256"),
        "library_sha256": library_digest,
        "dependency_version": expected.get("version"),
    }
    if candidate != required:
        raise HarnessError("pinned c-ares input does not match release metadata")
    linked = {
        "kind": "file",
        "name": "libcares.a",
        "sha256": library_digest,
    }
    if linked not in parity["candidate"].get("external_link_inputs", []):
        raise HarnessError("the Lus executable did not link the pinned c-ares library")


def validate_source_feature_deltas(parity: dict, metadata: dict) -> None:
    deltas = parity.get("source_feature_deltas")
    if not isinstance(deltas, dict):
        raise HarnessError("build parity evidence omits source feature deltas")
    if deltas.get("classification") != "candidate-only-source-feature-deltas":
        raise HarnessError("build parity evidence misclassifies source feature deltas")
    metadata_path = ROOT / "release" / "dependencies.json"
    if deltas.get("dependency_metadata") != "release/dependencies.json":
        raise HarnessError("source feature metadata path is not canonical")
    if deltas.get("dependency_metadata_sha256") != hashlib.sha256(
        metadata_path.read_bytes()
    ).hexdigest():
        raise HarnessError("source feature dependency metadata digest differs")

    baseline_sources = parity["baseline"].get("project_sources")
    candidate_sources = parity["candidate"].get("project_sources")
    if not isinstance(baseline_sources, dict) or not isinstance(candidate_sources, dict):
        raise HarnessError("build parity evidence omits project source inventories")
    expected_candidates = [
        {"path": path, "sha256": candidate_sources[path]}
        for path in sorted(set(candidate_sources) - set(baseline_sources))
    ]
    if deltas.get("candidate_only_sources") != expected_candidates:
        raise HarnessError("candidate-only source inventory is inconsistent")

    generated = metadata.get("generatedData")
    if not isinstance(generated, dict) or not isinstance(generated.get("sqlite"), dict):
        raise HarnessError("release metadata omits generated source inputs")
    sqlite = generated["sqlite"]
    expected_features = {
        "sqlite": {
            "version": sqlite.get("version"),
            "source_sha256": sqlite.get("sourceSha256"),
            "files": {
                "vendor/sqlite/sqlite3.c": sqlite.get("cSha256"),
                "vendor/sqlite/sqlite3.h": sqlite.get("headerSha256"),
            },
        },
        "tzdata": {
            "version": generated.get("tzdata"),
            "source_sha256": generated.get("tzdataSourceSha256"),
            "additional_source_sha256": generated.get("tzcodeSourceSha256"),
            "files": {
                "src/ltzdata.c": generated.get("tzdataGeneratedSha256"),
            },
        },
        "cldr": {
            "version": generated.get("cldr"),
            "source_sha256": generated.get("cldrSourceSha256"),
            "files": {
                "src/lwinzones.c": generated.get("cldrGeneratedSha256"),
            },
        },
    }
    required_compiled = {
        "vendor/sqlite/sqlite3.c": sqlite.get("cSha256"),
        "src/ltzdata.c": generated.get("tzdataGeneratedSha256"),
        "src/lwinzones.c": generated.get("cldrGeneratedSha256"),
    }
    for path, digest in required_compiled.items():
        if candidate_sources.get(path) != digest or path in baseline_sources:
            raise HarnessError(
                f"candidate-only source feature inventory differs for {path}"
            )
    features = deltas.get("features")
    if not isinstance(features, dict) or set(features) != set(expected_features):
        raise HarnessError("source feature delta inventory is incomplete")
    for name, expected_feature in expected_features.items():
        actual = features[name]
        if not isinstance(actual, dict):
            raise HarnessError(f"source feature evidence is invalid for {name}")
        for field in ("version", "source_sha256"):
            if actual.get(field) != expected_feature[field]:
                raise HarnessError(f"source feature {name} {field} differs")
        if "additional_source_sha256" in expected_feature and actual.get(
            "additional_source_sha256"
        ) != expected_feature["additional_source_sha256"]:
            raise HarnessError(f"source feature {name} code digest differs")
        rows = actual.get("files")
        if not isinstance(rows, list):
            raise HarnessError(f"source feature {name} file inventory is invalid")
        actual_files = {
            row.get("path"): row
            for row in rows
            if isinstance(row, dict) and isinstance(row.get("path"), str)
        }
        if set(actual_files) != set(expected_feature["files"]):
            raise HarnessError(f"source feature {name} files differ")
        for path, digest in expected_feature["files"].items():
            row = actual_files[path]
            if row.get("expected_sha256") != digest or row.get("sha256") != digest:
                raise HarnessError(f"source feature {name} digest differs for {path}")
            if path in candidate_sources and candidate_sources[path] != digest:
                raise HarnessError(
                    f"candidate source inventory differs for {path}"
                )


def validate_parity_evidence(parity: dict) -> None:
    if (
        parity.get("schema_version") != 1
        or parity.get("kind") != "h4-build-parity"
        or parity.get("status") != "pass"
    ):
        raise HarnessError("build parity evidence is not passing")
    checks = parity.get("checks")
    if not isinstance(checks, dict):
        raise HarnessError("build parity evidence omits checks")
    required = {
        "canonical_release",
        "compiler",
        "dependencies",
        "external_link_inputs",
        "meson_version",
        "ninja_version",
        "options",
        "pinned_cares",
        "source_feature_deltas",
    }
    if not required.issubset(checks):
        raise HarnessError("build parity evidence omits a required check")
    if any(checks[name].get("match") is not True for name in required):
        raise HarnessError("build parity evidence contains a mismatch")
    values = checks["options"].get("values")
    if not isinstance(values, dict) or not BUILD_PARITY_OPTIONS.issubset(values):
        raise HarnessError("build parity evidence omits required flag comparisons")
    if any(values[name].get("match") is not True for name in BUILD_PARITY_OPTIONS):
        raise HarnessError("build parity flag comparison contains a mismatch")
    baseline = parity.get("baseline")
    candidate = parity.get("candidate")
    if not isinstance(baseline, dict) or not isinstance(candidate, dict):
        raise HarnessError("build parity evidence omits raw build metadata")
    baseline_options = baseline.get("options", {})
    candidate_options = candidate.get("options", {})
    canonical = {
        "buildtype": "release",
        "optimization": "3",
        "debug": False,
        "b_lto": True,
        "b_pgo": "off",
        "b_sanitize": [],
    }
    if any(candidate_options.get(name) != value for name, value in canonical.items()):
        raise HarnessError("candidate metadata is not the canonical release profile")
    for name in BUILD_PARITY_OPTIONS:
        baseline_value = baseline_options.get(name)
        candidate_value = candidate_options.get(name)
        recorded = values[name]
        if (
            baseline_value != candidate_value
            or recorded.get("baseline") != baseline_value
            or recorded.get("candidate") != candidate_value
        ):
            raise HarnessError(f"build parity evidence is inconsistent for {name}")
    for name in (
        "compiler",
        "dependencies",
        "external_link_inputs",
        "meson_version",
        "ninja_version",
        "pinned_cares",
    ):
        baseline_value = baseline.get(name)
        candidate_value = candidate.get(name)
        recorded = checks[name]
        if baseline_value != candidate_value:
            raise HarnessError(f"build parity raw {name} metadata differs")
        if (
            recorded.get("baseline") != baseline_value
            or recorded.get("candidate") != candidate_value
        ):
            raise HarnessError(f"build parity {name} check is inconsistent")
    try:
        metadata = json.loads(
            (ROOT / "release" / "dependencies.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessError(f"cannot read release dependency metadata: {exc}") from exc
    validate_pinned_cares_evidence(parity, metadata)
    validate_source_feature_deltas(parity, metadata)


def ingest_evidence(
    parity: dict,
    release: dict,
    fastcall: dict,
    manifest: dict | None = None,
) -> dict:
    if manifest is None:
        manifest = load_manifest(DEFAULT_MANIFEST)
    validate_parity_evidence(parity)
    validate_benchmark_evidence(release, "release", manifest)
    validate_benchmark_evidence(fastcall, "fastcall", manifest)
    qualification_status = (
        "warning"
        if "warning" in (release["status"], fastcall["status"])
        else "pass"
    )
    return {
        "schemaVersion": 1,
        "kind": "benchmark",
        "name": "benchmarks",
        "status": "success",
        "qualificationStatus": qualification_status,
        "counts": {"total": 2, "passed": 2, "failed": 0, "skipped": 0},
        "buildParity": parity,
        "release": release,
        "fastcall": fastcall,
    }


def write_evidence(path: Path, value: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise HarnessError(f"cannot write benchmark evidence {path}: {exc}") from exc


def enforce_ingested_evidence(
    value: dict,
    manifest: dict | None = None,
) -> None:
    if (
        value.get("schemaVersion") != 1
        or value.get("kind") != "benchmark"
        or value.get("name") != "benchmarks"
    ):
        raise HarnessError("combined benchmark evidence has an invalid schema")
    if value.get("status") != "success" or value.get(
        "qualificationStatus"
    ) not in ("pass", "warning"):
        raise HarnessError("combined benchmark evidence is blocking")
    rebuilt = ingest_evidence(
        value.get("buildParity", {}),
        value.get("release", {}),
        value.get("fastcall", {}),
        manifest,
    )
    if rebuilt["qualificationStatus"] != value["qualificationStatus"]:
        raise HarnessError("combined benchmark evidence status is inconsistent")
    if value.get("counts") != rebuilt["counts"]:
        raise HarnessError("combined benchmark evidence counts are inconsistent")


def render_report(result: dict) -> str:
    lines = [
        "# H4 paired benchmark report",
        "",
        f"Mode: {result['mode']}",
        f"Baseline: {result['baseline']}",
        f"Candidate: {result['candidate']}",
        f"Baseline version: {result['binaries']['baseline']['version']}",
        f"Candidate version: {result['binaries']['candidate']['version']}",
        f"Baseline SHA-256: {result['binaries']['baseline']['sha256']}",
        f"Candidate SHA-256: {result['binaries']['candidate']['sha256']}",
        f"Platform: {result['environment']['platform']}",
        (
            "Statistics: "
            f"{result['statistics']['warmup_pairs']} alternating warmup pairs, "
            f"{result['statistics']['measured_pairs']} measured pairs, "
            f"{result['statistics']['max_relative_mad']:.1%} maximum relative MAD, "
            f"{result['statistics']['retries']} retry"
        ),
        "",
        "| Case | Category | Baseline | Candidate | Base MAD | Cand MAD | Pair MAD | Speedup | Status |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for case in result["cases"]:
        lines.append(
            f"| {case['id']} | {case['category']} | "
            f"{case['baseline_median']:.6f} | {case['candidate_median']:.6f} | "
            f"{case['baseline_relative_mad']:.2%} | "
            f"{case['candidate_relative_mad']:.2%} | "
            f"{case['pair_relative_mad']:.2%} | "
            f"{case['speedup']:.3f}x | {case['status']} |"
        )
    lines.extend(
        [
            "",
        "| Category | Geomean | Status |",
        "| --- | ---: | --- |",
        ]
    )
    for category, value in result["category_geomeans"].items():
        lines.append(
            f"| {category} | {value:.3f}x | "
            f"{result['category_statuses'][category]} |"
        )
    overall = result["overall_geomean"]
    lines.extend(
        [
            "",
            f"Overall geomean: {overall:.3f}x" if overall is not None else "Overall geomean: unavailable",
        ]
    )
    if result["mode"] == "fastcall":
        time_geomean = result["time_geomean"]
        lines.append(
            f"Time fastcall geomean: {time_geomean:.3f}x "
            f"({result['time_status']})"
            if time_geomean is not None
            else "Time fastcall geomean: unavailable"
        )
        lines.append(f"Exact fastcall labels: {result['exact_label_count']}")
        lines.append(
            "Fastcall gates: "
            f"overall {result['gates']['overall_block_below']:.2f}x, "
            f"time {result['gates']['time_block_below']:.2f}x, "
            f"category {result['gates']['category_block_below']:.2f}x, "
            f"each valid case {result['gates']['case_block_below']:.2f}x"
        )
        lines.append(
            "Promotion warnings: "
            f"overall below "
            f"{result['gates']['overall_promotion_warning_below']:.2f}x, "
            f"time below "
            f"{result['gates']['time_promotion_warning_below']:.2f}x, "
            f"default case below "
            f"{result['gates']['case_promotion_warning_below']:.2f}x"
        )
    else:
        lines.append(
            "Comparison gates: "
            f"overall {result['gates']['overall_block_below']:.2f}x, "
            f"category {result['gates']['category_block_below']:.2f}x, "
            f"each valid case {result['gates']['case_block_below']:.2f}x"
        )
        lines.append(
            "Promotion warnings: "
            f"overall below "
            f"{result['gates']['overall_promotion_warning_below']:.2f}x, "
            f"default case below "
            f"{result['gates']['case_promotion_warning_below']:.2f}x"
        )
    lines.append(
        "Regression policy: warning below "
        f"{result['gates']['regression_warning_below']:.2f}x and block below "
        f"{result['gates']['regression_block_below']:.2f}x. "
        "Stricter qualification blocks take precedence."
    )
    actions = [case for case in result["cases"] if case["status"] != "pass"]
    if actions:
        lines.extend(["", "Actions:"])
        for case in actions:
            guidance = case.get("revert_guidance")
            if guidance:
                lines.append(f"- {case['id']}: {guidance}")
    if result.get("revert_guidance"):
        lines.extend(["", f"Revert guidance: {result['revert_guidance']}"])
    lines.extend(["", f"Outcome: {result['status'].upper()}"])
    return "\n".join(lines) + "\n"


def emit_result(result: dict, json_path: str | None, markdown_path: str | None) -> int:
    report = render_report(result)
    print(report, end="")
    if json_path:
        write_evidence(Path(json_path), result)
    if markdown_path:
        path = Path(markdown_path)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(report, encoding="utf-8")
        except OSError as exc:
            raise HarnessError(f"cannot write benchmark report {path}: {exc}") from exc
    return 1 if result["status"] == "block" else 0


def add_output_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--json", help="write machine-readable evidence")
    parser.add_argument("--markdown", help="write the rendered report")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default=str(DEFAULT_MANIFEST),
        help="benchmark manifest path",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("validate", help="validate manifests and fastcall coverage")

    compare = subparsers.add_parser(
        "compare",
        help="compare two compatible Lus binaries",
    )
    compare.add_argument(
        "--baseline",
        default=os.environ.get("H4_BASELINE"),
        help="baseline Lus binary or H4_BASELINE",
    )
    compare.add_argument("--candidate", required=True, help="candidate Lus binary")
    compare.add_argument("--suite", default="release", help="manifest suite")
    compare.add_argument("--case", help="run one exact manifest case")
    add_output_options(compare)

    release = subparsers.add_parser(
        "release",
        help="run the release suite when H4_BASELINE is available",
    )
    release.add_argument(
        "--baseline",
        default=os.environ.get("H4_BASELINE"),
        help="baseline Lus binary or H4_BASELINE",
    )
    release.add_argument("--candidate", required=True, help="candidate Lus binary")
    add_output_options(release)

    fastcall = subparsers.add_parser(
        "fastcall",
        help="compare enabled fastcalls with --no-fastcall",
    )
    fastcall.add_argument("--binary", required=True, help="Lus binary")
    add_output_options(fastcall)

    pgo = subparsers.add_parser(
        "pgo",
        help="compare plain and PGO release binaries",
    )
    pgo.add_argument("--plain", required=True, help="plain release binary")
    pgo.add_argument("--pgo", required=True, help="PGO release binary")
    add_output_options(pgo)

    ingest = subparsers.add_parser(
        "ingest",
        help="validate and combine raw release evidence",
    )
    ingest.add_argument("--parity", required=True, help="build parity JSON")
    ingest.add_argument("--release", required=True, help="paired release JSON")
    ingest.add_argument("--fastcall", required=True, help="fastcall JSON")
    ingest.add_argument("--output", required=True, help="combined evidence JSON")

    enforce = subparsers.add_parser(
        "enforce",
        help="fail closed unless combined evidence is non-blocking",
    )
    enforce.add_argument("--evidence", required=True, help="combined evidence JSON")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        manifest = load_manifest(Path(args.manifest).resolve())
        if args.command == "validate":
            fastcalls = validate_fastcall_inventory()
            print(
                f"H4 manifest OK: {len(manifest['cases'])} cases and "
                f"{len(fastcalls)} exact fastcall labels"
            )
            return 0
        if args.command == "compare":
            if not args.baseline:
                raise HarnessError(
                    "--baseline is required when H4_BASELINE is not set"
                )
            result = compare_cases(
                manifest,
                resolve_binary(args.baseline),
                resolve_binary(args.candidate),
                args.suite,
                args.case,
                pgo=False,
            )
            return emit_result(result, args.json, args.markdown)
        if args.command == "release":
            if not args.baseline:
                print(
                    "H4 release comparison SKIPPED: set H4_BASELINE to a "
                    "Lus 1.6.2 release binary",
                    file=sys.stderr,
                )
                return 77
            baseline = resolve_binary(args.baseline)
            require_release_baseline(binary_metadata(baseline))
            result = compare_cases(
                manifest,
                baseline,
                resolve_binary(args.candidate),
                "release",
                None,
                pgo=False,
            )
            result["mode"] = "release"
            return emit_result(result, args.json, args.markdown)
        if args.command == "fastcall":
            result = compare_fastcalls(manifest, resolve_binary(args.binary))
            return emit_result(result, args.json, args.markdown)
        if args.command == "pgo":
            result = compare_cases(
                manifest,
                resolve_binary(args.plain),
                resolve_binary(args.pgo),
                "pgo",
                None,
                pgo=True,
            )
            return emit_result(result, args.json, args.markdown)
        if args.command == "ingest":
            output = Path(args.output)
            try:
                result = ingest_evidence(
                    load_evidence(Path(args.parity), "build parity"),
                    load_evidence(Path(args.release), "release"),
                    load_evidence(Path(args.fastcall), "fastcall"),
                    manifest,
                )
            except HarnessError as exc:
                write_evidence(
                    output,
                    {
                        "schemaVersion": 1,
                        "kind": "benchmark",
                        "name": "benchmarks",
                        "status": "failure",
                        "qualificationStatus": "block",
                        "counts": {
                            "total": 2,
                            "passed": 0,
                            "failed": 2,
                            "skipped": 0,
                        },
                        "error": str(exc),
                    },
                )
                raise
            write_evidence(output, result)
            print(
                "H4 evidence ingestion "
                f"{result['qualificationStatus'].upper()}"
            )
            return 0
        if args.command == "enforce":
            evidence = load_evidence(Path(args.evidence), "combined benchmark")
            enforce_ingested_evidence(evidence, manifest)
            print(
                "H4 evidence gate "
                f"{evidence['qualificationStatus'].upper()}"
            )
            return 0
        raise HarnessError(f"unknown command: {args.command}")
    except HarnessError as exc:
        print(f"H4 ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
