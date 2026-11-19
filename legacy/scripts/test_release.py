#!/usr/bin/env python3
"""Regression tests for fail-closed release metadata validation."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("lus_release", ROOT / "scripts/release.py")
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def stable_fixture(root: Path) -> None:
    write(
        root / "CHANGELOG.md",
        "# Changelog\n\n"
        "## 1.7.0\n\n"
        "**Release date:** August 30, 2026\n\n"
        "- Complete release note.\n\n"
        "### Details\n\n"
        "- Nested details remain in the notes.\n\n"
        "## 1.6.2\n\n- Previous release.\n",
    )
    write(
        root / "lus-spec/stdlib/probe.md",
        "---\nname: probe\nkind: function\nmodule: base\n"
        "since: 1.7.0\nstability: stable\n---\n",
    )
    write(
        root / "lus-site/src/manual/acquis-30.mdx",
        "---\ntitle: Acquis 30\nacquis: true\ndraft: false\n---\n",
    )
    write(
        root / "lus-site/src/news/changelog-1.7.0.md",
        "---\ntitle: Lus 1.7.0\ndate: 2026-08-30\n---\n\nRelease news.\n",
    )


def publisher_fixture(**metadata_changes) -> str:
    notice = (
        "Third-party notices for the bundled Open VSX publisher\n\n"
        "Package: ovsx@0.10.9\n"
        "License: EPL-2.0\n"
        "License file: LICENSE\n"
    )
    metadata = {
        "externalBuiltins": release.PUBLISHER_EXTERNAL_BUILTINS,
        "noticeSha256": hashlib.sha256(notice.encode()).hexdigest(),
        "ovsxVersion": release.dependencies()["ovsx"],
        "packages": [
            {
                "license": "EPL-2.0",
                "licenseFiles": [{"name": "LICENSE", "sha256": "a" * 64}],
                "name": "ovsx",
                "version": release.dependencies()["ovsx"],
            }
        ],
        "schemaVersion": 1,
    }
    metadata.update(metadata_changes)
    notice_lines = "\n".join(f"// {line}" for line in notice.splitlines())
    return (
        "// LUS_OPEN_VSX_PUBLISHER_METADATA "
        + json.dumps(metadata, separators=(",", ":"), sort_keys=True)
        + "\n// LUS_OPEN_VSX_PUBLISHER_NOTICE_BEGIN\n"
        + notice_lines
        + "\n// LUS_OPEN_VSX_PUBLISHER_NOTICE_END\n"
        + 'console.log("publisher");\n'
    )


def sanitizer_fixture() -> dict:
    address_counts = {
        "h1": release.SANITIZER_H1_COUNT,
        "h2": release.SANITIZER_H2_COUNT,
        "functional": 119,
        "qualification": release.SANITIZER_QUALIFICATION_COUNT,
        "total": 121,
    }
    thread_counts = {"functional": 4, "qualification": 1, "total": 5}
    compiler = {"id": "clang", "version": "20.1.8", "full_version": "clang"}
    return {
        "schemaVersion": 1,
        "kind": "sanitizer",
        "name": "sanitizer",
        "status": "success",
        "scope": "combined",
        "release_complete": True,
        "platform": "linux",
        "compiler": compiler,
        "sanitizers": ["address", "undefined"],
        "leak_detection": {
            "requested": True,
            "runtime_status": "available",
            "reason": None,
            "enabled_for_suite": True,
            "probe": {
                "requested_option": "detect_leaks=1",
                "probe_kind": "intentional-leak",
                "expected_exit_status": 23,
                "exit_status": 23,
                "runtime_status": "available",
                "report_markers": {
                    marker: True
                    for marker in release.LEAK_SANITIZER_REPORT_MARKERS
                },
                "leak_report_observed": True,
            },
        },
        "counts": {
            "total": 126,
            "passed": 126,
            "failed": 0,
            "skipped": 0,
            "functional": 123,
            "qualification": 3,
        },
        "tests": {
            "h1": release.SANITIZER_H1_COUNT,
            "h2": release.SANITIZER_H2_COUNT,
            "qualification": release.SANITIZER_QUALIFICATION_COUNT,
        },
        "address_undefined": {"status": "passed", "counts": address_counts},
        "thread_sanitizer": {
            "compiler": copy.deepcopy(compiler),
            "options": "halt_on_error=1:abort_on_error=1",
            "tests": release.THREAD_SANITIZER_TESTS,
            "counts": thread_counts,
            "status": "passed",
        },
    }


def write_vsix_fixture(
    path: Path,
    names: list[str],
    timestamp: tuple[int, int, int, int, int, int],
    compression: int,
    archive_comment: bytes = b"",
    member_extra: bytes = b"",
) -> None:
    with zipfile.ZipFile(path, "w", compression=compression) as archive:
        archive.comment = archive_comment
        for name in names:
            info = zipfile.ZipInfo(name, timestamp)
            info.compress_type = compression
            info.create_system = 0
            info.external_attr = 0o600 << 16
            info.comment = b"source comment"
            info.extra = member_extra
            archive.writestr(info, ("payload:" + name).encode())


class VsixDeterminismTests(unittest.TestCase):
    def test_normalization_removes_order_timestamp_mode_and_compression_drift(self) -> None:
        names = sorted(release.VSIX_MEMBERS)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_raw = root / "first-raw.vsix"
            second_raw = root / "second-raw.vsix"
            first = root / "first.vsix"
            second = root / "second.vsix"
            write_vsix_fixture(
                first_raw,
                list(reversed(names)),
                (2024, 1, 2, 3, 4, 6),
                zipfile.ZIP_DEFLATED,
                archive_comment=b"first archive",
                member_extra=b"\x01\x00\x00\x00",
            )
            write_vsix_fixture(
                second_raw,
                names,
                (2025, 5, 6, 7, 8, 10),
                zipfile.ZIP_STORED,
                archive_comment=b"second archive",
            )
            self.assertNotEqual(first_raw.read_bytes(), second_raw.read_bytes())
            release.normalize_vsix(first_raw, first)
            release.normalize_vsix(second_raw, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(release.validate_vsix_envelope(archive), names)
                for name in names:
                    self.assertEqual(archive.read(name), ("payload:" + name).encode())
            with zipfile.ZipFile(first_raw) as archive:
                with self.assertRaises(release.ReleaseError):
                    release.validate_vsix_envelope(archive)

    def test_normalization_rejects_incomplete_and_duplicate_archives(self) -> None:
        names = sorted(release.VSIX_MEMBERS)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing = root / "missing.vsix"
            duplicate = root / "duplicate.vsix"
            write_vsix_fixture(
                missing,
                names[:-1],
                (2024, 1, 2, 3, 4, 6),
                zipfile.ZIP_STORED,
            )
            with self.assertRaises(release.ReleaseError):
                release.normalize_vsix(missing, root / "missing-output.vsix")
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                write_vsix_fixture(
                    duplicate,
                    [*names, names[0]],
                    (2024, 1, 2, 3, 4, 6),
                    zipfile.ZIP_STORED,
                )
            with self.assertRaises(release.ReleaseError):
                release.normalize_vsix(duplicate, root / "duplicate-output.vsix")


class WasmEvidenceTests(unittest.TestCase):
    REQUIRED = ["lus.node.js", "lus.wasm", "lus.web.js"]

    def make_fixture(self, root: Path) -> argparse.Namespace:
        dist = root / "dist"
        embedded = root / "embedded"
        dist.mkdir()
        embedded.mkdir()
        (dist / "lus.node.js").write_bytes(b"node loader\n")
        (dist / "lus.web.js").write_bytes(b"web loader\n")
        (dist / "lus.wasm").write_bytes(b"wasm bytes\n")
        (embedded / "main.lus").write_bytes(b"return true\n")
        proof = root / "node-proof.wasm"
        proof.write_bytes((dist / "lus.wasm").read_bytes())
        return argparse.Namespace(
            dist=str(dist),
            embedded_tree=str(embedded),
            node_wasm_proof=str(proof),
            output=str(root / "evidence.json"),
        )

    def test_wasm_evidence_writes_complete_byte_parity_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_fixture(root)
            with mock.patch.object(
                release,
                "manifest",
                return_value={
                    "components": {"wasm": {"requiredPaths": self.REQUIRED}}
                },
            ):
                release.command_wasm_evidence(args)
            evidence = json.loads(Path(args.output).read_text(encoding="utf-8"))
            self.assertEqual(evidence["status"], "success")
            self.assertEqual(
                evidence["details"]["nodeWebModuleParity"]["result"],
                "byte-equal",
            )
            self.assertEqual(
                sorted(evidence["details"]["artifacts"]), self.REQUIRED
            )

    def test_wasm_evidence_rejects_missing_inventory_and_parity_drift(self) -> None:
        mutations = {
            "missing-proof": lambda root, args: Path(args.node_wasm_proof).unlink(),
            "missing-artifact": lambda root, args: (
                Path(args.dist) / "lus.node.js"
            ).unlink(),
            "inventory-extra": lambda root, args: (
                Path(args.dist) / "unexpected.map"
            ).write_bytes(b"map"),
            "parity-drift": lambda root, args: Path(
                args.node_wasm_proof
            ).write_bytes(b"different wasm"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                args = self.make_fixture(root)
                mutate(root, args)
                with mock.patch.object(
                    release,
                    "manifest",
                    return_value={
                        "components": {"wasm": {"requiredPaths": self.REQUIRED}}
                    },
                ):
                    with self.assertRaises(release.ReleaseError):
                        release.command_wasm_evidence(args)
                self.assertFalse(Path(args.output).exists())


class StableMetadataTests(unittest.TestCase):
    def test_valid_metadata_and_complete_notes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stable_fixture(root)
            self.assertEqual(release.stable_metadata_errors(root, "1.7.0"), [])
            heading, notes = release.changelog_section(root, "1.7.0")
            self.assertEqual(heading, "## 1.7.0")
            self.assertIn("### Details", notes)
            self.assertNotIn("Previous release", notes)

    def test_every_stable_marker_fails_closed(self) -> None:
        mutations = {
            "wip": lambda root: write(
                root / "CHANGELOG.md",
                (root / "CHANGELOG.md")
                .read_text(encoding="utf-8")
                .replace("## 1.7.0", "## 1.7.0 (WIP)"),
            ),
            "wrong-date": lambda root: write(
                root / "CHANGELOG.md",
                (root / "CHANGELOG.md")
                .read_text(encoding="utf-8")
                .replace("August 30, 2026", "August 31, 2026"),
            ),
            "tbd": lambda root: write(
                root / "CHANGELOG.md",
                (root / "CHANGELOG.md")
                .read_text(encoding="utf-8")
                .replace("August 30, 2026", "TBD"),
            ),
            "unstable-spec": lambda root: write(
                root / "lus-spec/stdlib/probe.md",
                (root / "lus-spec/stdlib/probe.md")
                .read_text(encoding="utf-8")
                .replace("stability: stable", "stability: unstable"),
            ),
            "draft-acquis": lambda root: write(
                root / "lus-site/src/manual/acquis-30.mdx",
                (root / "lus-site/src/manual/acquis-30.mdx")
                .read_text(encoding="utf-8")
                .replace("draft: false", "draft: true"),
            ),
            "missing-news": lambda root: (
                root / "lus-site/src/news/changelog-1.7.0.md"
            ).unlink(),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stable_fixture(root)
                mutate(root)
                self.assertTrue(release.stable_metadata_errors(root, "1.7.0"))

    def test_stable_tag_and_target_must_match(self) -> None:
        commit = "a" * 40
        args = argparse.Namespace(
            tag="v1.7.0",
            commit=commit,
            notes_output="unused",
        )
        common = (
            mock.patch.object(release, "canonical_version", return_value="1.7.0"),
            mock.patch.object(release, "release_commit", return_value=commit),
            mock.patch.object(release, "stable_metadata_errors", return_value=[]),
            mock.patch.object(
                release,
                "changelog_section",
                return_value=("## 1.7.0", "release notes\n"),
            ),
        )
        with common[0], common[1], common[2], common[3]:
            with self.assertRaises(release.ReleaseError):
                release.command_stable_release(
                    argparse.Namespace(**{**vars(args), "tag": "v1.7.1"})
                )
        with common[0], common[1], common[2], common[3], mock.patch.object(
            release, "resolve_tag_commit", return_value="b" * 40
        ):
            with self.assertRaises(release.ReleaseError):
                release.command_stable_release(args)
        with mock.patch.object(
            release, "canonical_version", return_value="1.7.0"
        ), mock.patch.object(release, "release_commit", return_value="b" * 40):
            with self.assertRaises(release.ReleaseError):
                release.command_stable_release(args)

    def test_release_notes_are_replaced_from_changelog(self) -> None:
        commit = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stable_fixture(root)
            output = root / "notes.md"
            output.write_text("drifted notes\n", encoding="utf-8")
            args = argparse.Namespace(
                tag="v1.7.0",
                commit=commit,
                notes_output=str(output),
            )
            with mock.patch.object(release, "ROOT", root), mock.patch.object(
                release, "canonical_version", return_value="1.7.0"
            ), mock.patch.object(
                release, "release_commit", return_value=commit
            ), mock.patch.object(
                release, "resolve_tag_commit", return_value=commit
            ):
                release.command_stable_release(args)
            self.assertIn("Complete release note", output.read_text(encoding="utf-8"))
            self.assertNotIn("drifted", output.read_text(encoding="utf-8"))


class ToolVersionTests(unittest.TestCase):
    def test_ninja_accepts_only_the_reviewed_wheel_decoration(self) -> None:
        expected = "1.13.0"
        self.assertTrue(release.tool_version_matches("ninja", expected, expected))
        self.assertTrue(
            release.tool_version_matches(
                "ninja",
                expected + ".git.kitware.jobserver-pipe-1",
                expected,
            )
        )
        for actual in (
            "1.12.1.git.kitware.jobserver-pipe-1",
            "1.13.0.git.kitware.jobserver-pipe-2",
            "1.13.0.git.kitware.jobserver-pipe-1.extra",
            "1.13.0git.kitware.jobserver-pipe-1",
            "1.13.0.arbitrary",
            "",
            None,
        ):
            with self.subTest(actual=actual):
                self.assertFalse(
                    release.tool_version_matches("ninja", actual, expected)
                )

    def test_other_tool_versions_remain_exact(self) -> None:
        self.assertTrue(release.tool_version_matches("meson", "1.11.2", "1.11.2"))
        self.assertFalse(
            release.tool_version_matches(
                "meson",
                "1.11.2.git.kitware.jobserver-pipe-1",
                "1.11.2",
            )
        )


class OpenVsxPublisherEvidenceTests(unittest.TestCase):
    def test_embedded_notice_and_inventory_are_validated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            publisher = Path(temporary) / "publisher.cjs"
            write(publisher, publisher_fixture())
            metadata = release.open_vsx_publisher_metadata(publisher)
            self.assertEqual(metadata["ovsxVersion"], release.dependencies()["ovsx"])
            self.assertEqual(
                metadata["externalBuiltins"],
                release.PUBLISHER_EXTERNAL_BUILTINS,
            )

    def test_embedded_publisher_metadata_fails_closed(self) -> None:
        mutations = {
            "code-loading-builtin": {
                "externalBuiltins": [
                    *release.PUBLISHER_EXTERNAL_BUILTINS,
                    "child_process",
                ]
            },
            "missing-package": {"packages": []},
            "wrong-version": {"ovsxVersion": "0.10.8"},
            "notice-drift": {"noticeSha256": "0" * 64},
        }
        for name, changes in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                publisher = Path(temporary) / "publisher.cjs"
                write(publisher, publisher_fixture(**changes))
                with self.assertRaises(release.ReleaseError):
                    release.open_vsx_publisher_metadata(publisher)


class SanitizerEvidenceTests(unittest.TestCase):
    def test_complete_release_sanitizer_evidence_is_accepted(self) -> None:
        release.validate_sanitizer_fragment(sanitizer_fixture())

    def test_every_release_sanitizer_invariant_fails_closed(self) -> None:
        def set_path(value, path, replacement) -> None:
            target = value
            for component in path[:-1]:
                target = target[component]
            target[path[-1]] = replacement

        mutations = {
            "partial-scope": (("scope",), "address-undefined-only"),
            "release-incomplete": (("release_complete",), False),
            "wrong-platform": (("platform",), "darwin"),
            "missing-ubsan": (("sanitizers",), ["address"]),
            "h1-drift": (("tests", "h1"), 107),
            "h2-drift": (("tests", "h2"), 10),
            "missing-asan-meta": (("tests", "qualification"), 1),
            "asan-not-passed": (("address_undefined", "status"), "failed"),
            "asan-total-drift": (("address_undefined", "counts", "total"), 120),
            "tsan-not-passed": (("thread_sanitizer", "status"), "failed"),
            "tsan-options-drift": (("thread_sanitizer", "options"), ""),
            "missing-tsan-test": (
                ("thread_sanitizer", "tests"),
                release.THREAD_SANITIZER_TESTS[:-1],
            ),
            "missing-tsan-meta": (
                ("thread_sanitizer", "counts", "qualification"),
                0,
            ),
            "combined-total-drift": (("counts", "total"), 125),
            "combined-pass-drift": (("counts", "passed"), 125),
            "combined-failure": (("counts", "failed"), 1),
            "combined-skip": (("counts", "skipped"), 1),
            "combined-functional-drift": (("counts", "functional"), 122),
            "combined-meta-drift": (("counts", "qualification"), 2),
            "boolean-count": (("counts", "total"), True),
            "non-clang": (("compiler", "id"), "gcc"),
            "leaks-disabled": (("leak_detection", "enabled_for_suite"), False),
            "leaks-unproven": (
                ("leak_detection", "probe", "leak_report_observed"),
                False,
            ),
            "leak-exit-drift": (
                ("leak_detection", "probe", "exit_status"),
                0,
            ),
            "leak-marker-missing": (
                (
                    "leak_detection",
                    "probe",
                    "report_markers",
                    release.LEAK_SANITIZER_REPORT_MARKERS[0],
                ),
                False,
            ),
        }
        for name, (path, replacement) in mutations.items():
            with self.subTest(name=name):
                value = sanitizer_fixture()
                set_path(value, path, replacement)
                with self.assertRaises(release.ReleaseError):
                    release.validate_sanitizer_fragment(value)

    def test_generic_status_cannot_replace_or_shadow_sanitizer_evidence(self) -> None:
        requirements = {
            "evidence": {
                "requiredTestPlatforms": [],
                "requiredToolchainPlatforms": [],
                "requiredStatuses": ["sanitizer"],
            }
        }
        gate = {
            "schemaVersion": 1,
            "kind": "qualityGate",
            "name": "quality-gate",
            "event": "push",
            "status": "success",
        }
        with mock.patch.object(release, "manifest", return_value=requirements):
            release.validate_fragments([sanitizer_fixture(), gate], "push")
            generic = copy.deepcopy(sanitizer_fixture())
            generic["kind"] = "status"
            with self.assertRaises(release.ReleaseError):
                release.validate_fragments([generic, gate], "push")
            with self.assertRaises(release.ReleaseError):
                release.validate_fragments(
                    [generic, sanitizer_fixture(), gate], "push"
                )


class SupplyChainTests(unittest.TestCase):
    def valid_workflow(self) -> tuple[str, dict]:
        values = copy.deepcopy(release.dependencies())
        text = "\n".join(
            [
                "pnpm --dir lus-site test",
                "pnpm build:local-wasm",
                "python3 lus-install/test_install.py",
                "shellcheck --version",
                'test "$actual" = "$SHELLCHECK_VERSION"',
                "scripts/release.py binary-versions",
                "scripts/release.py stable-release",
                '--tag "$GITHUB_REF_NAME"',
                '--commit "$GITHUB_SHA"',
                "--notes-output release-notes.md",
                '--target "$GITHUB_SHA"',
                "--notes-file release-notes.md",
                "lus-tests/h4/build_pinned_cares.sh",
                "lus-tests/h4/build_pinned_cares.sh",
                "  sanitize:",
                "    steps:",
                "      - run: sudo apt-get install -y clang libclang-rt-dev curl make",
                "      - run: |",
                '          cares_root="$RUNNER_TEMP/sanitizer-cares"',
                '          cares_pc=$(lus-tests/h4/build_pinned_cares.sh "$cares_root")',
                '          PKG_CONFIG_PATH="$cares_pc" pkg-config --modversion libcares',
                '          echo "PKG_CONFIG_PATH=$cares_pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"',
                "  benchmark:",
                "  build:",
                "    steps:",
                "      - uses: actions/checkout@" + "a" * 40,
                "        with:",
                "          fetch-depth: 0",
                "      - name: Compare the stable 1.6.2 ABI",
                "        run: |",
                "          git archive v1.6.2",
                "          -Db_lto=false",
                '          meson compile -C "$baseline_build"',
                '          --baseline-library "$baseline_library"',
                "      - name: Next step",
                "  build-wasm:",
                "Build pinned static c-ares on Windows",
                "caresSource.sha256",
                "Get-FileHash -Algorithm SHA256",
                "-DCARES_STATIC=ON",
                "-DCARES_SHARED=OFF",
                f"choco install pkgconfiglite --version {values['pkgconfiglite']}",
                f"choco install pkgconfiglite --version {values['pkgconfiglite']}",
                f"choco install innosetup --version {values['innoSetup']}",
                "--name unix-installer --status success",
                "--name windows-installer --status success",
                "evidence/unix-installer.json",
                "evidence/windows-installer.json",
                values["alpineImage"],
                values["debianSmokeImage"],
                "--provenance hosted-runner-version-recorded",
                "--provenance hosted-runner-pinned-emscripten",
            ]
        )
        return text, values

    def valid_publish_workflow(self) -> tuple[str, dict]:
        values = copy.deepcopy(release.dependencies())
        text = "\n".join(
            [
                "env:",
                f'  NODE_VERSION: "{values["node"]}"',
                f'  OVSX_VERSION: "{values["ovsx"]}"',
                'contents/release/manifest.json?ref=$TAG',
                "expected_publisher_sha=$(node -e",
                "gh release download",
                "SHA256SUMS",
                'publisher="lus-$version-open-vsx-publisher.cjs"',
                '--pattern "$publisher"',
                'test "$(find . -maxdepth 1 -type f | wc -l)" -eq 3',
                'for name in "$vsix" "$publisher"',
                "sha256sum --check --strict PUBLISH-SUMS",
                'test "$(sha256sum "$publisher" | awk \'{ print $1 }\')" = "$expected_publisher_sha"',
                'chmod 0444 "$vsix" "$publisher" PUBLISH-SUMS',
                'node "$publisher_path" --version',
                "sha256sum --check --strict PUBLISH-SUMS",
                'test "$(sha256sum "$publisher" | awk \'{ print $1 }\')" = "$expected_publisher_sha"',
                'echo "PUBLISHER_PATH=$publisher_path" >> "$GITHUB_ENV"',
                'echo "PUBLISH_INPUTS_DIR=$PWD" >> "$GITHUB_ENV"',
                'echo "EXPECTED_PUBLISHER_SHA256=$expected_publisher_sha" >> "$GITHUB_ENV"',
                "OVSX_PAT: ${{ secrets.OVSX_PAT }}",
                'run: node "$PUBLISHER_PATH" "$VSIX_PATH"',
                "sha256sum --check --strict PUBLISH-SUMS",
                'test "$(sha256sum "$PUBLISHER_PATH" | awk \'{ print $1 }\')" = "$EXPECTED_PUBLISHER_SHA256"',
            ]
        )
        return text, values

    def test_missing_site_test_installer_smoke_and_notes_fail(self) -> None:
        text, values = self.valid_workflow()
        for name, needle in (
            ("site", "pnpm --dir lus-site test"),
            ("installer", "python3 lus-install/test_install.py"),
            ("shellcheck", "shellcheck --version"),
            ("abi-tag", "git archive v1.6.2"),
            ("abi-non-lto", "-Db_lto=false"),
            ("abi-fetch", "fetch-depth: 0"),
            ("sanitizer-compiler-rt", "libclang-rt-dev"),
            ("sanitizer-cares", 'cares_root="$RUNNER_TEMP/sanitizer-cares"'),
            ("notes", "--notes-file release-notes.md"),
        ):
            with self.subTest(name=name):
                errors = release.workflow_release_errors(
                    text.replace(needle, "missing"), values
                )
                self.assertTrue(errors)

    def test_pin_and_generated_hash_drift_fail(self) -> None:
        values = copy.deepcopy(release.dependencies())
        self.assertEqual(release.dependency_integrity_errors(ROOT, values), [])
        values["generatedData"]["sqlite"]["cSha256"] = "0" * 64
        errors = release.dependency_integrity_errors(ROOT, values)
        self.assertTrue(any("sqlite3.c SHA-256" in error for error in errors))

        values = copy.deepcopy(release.dependencies())
        values["generatedData"]["sqlite"]["patchSha256"] = "0" * 64
        errors = release.dependency_integrity_errors(ROOT, values)
        self.assertTrue(
            any("sqlite-lus-vfs.patch SHA-256" in error for error in errors)
        )

        values = copy.deepcopy(release.dependencies())
        values["caresSource"]["version"] = "1.34.7"
        errors = release.dependency_integrity_errors(ROOT, values)
        self.assertTrue(any("caresSource.url" in error for error in errors))

    def test_mutable_container_pin_fails(self) -> None:
        text, values = self.valid_workflow()
        values["alpineImage"] = "alpine:3.22.1"
        errors = release.workflow_release_errors(text, values)
        self.assertTrue(any("immutable container digest" in error for error in errors))

    def test_windows_tool_pin_drift_fails(self) -> None:
        text, values = self.valid_workflow()
        for name, expected in (
            ("pkgconfiglite", values["pkgconfiglite"]),
            ("innoSetup", values["innoSetup"]),
        ):
            with self.subTest(name=name):
                errors = release.workflow_release_errors(
                    text.replace(expected, "99.99.99"), values
                )
                self.assertTrue(
                    any("pinned" in error.lower() for error in errors), errors
                )

    def test_installer_evidence_is_required(self) -> None:
        evidence = release.manifest()["evidence"]
        expected = {"unix-installer", "windows-installer"}
        self.assertTrue(expected <= set(evidence["requiredStatuses"]))
        self.assertTrue(expected <= set(evidence["qualityGateJobs"]))

    def test_open_vsx_publish_workflow_is_credential_minimal(self) -> None:
        text, values = self.valid_publish_workflow()
        self.assertEqual(release.publish_workflow_errors(text, values), [])
        self.assertIn(
            "lus-1.7.0-open-vsx-publisher.cjs",
            release.expected_assets(),
        )

    def test_open_vsx_publish_workflow_rejects_mutable_execution(self) -> None:
        text, values = self.valid_publish_workflow()
        mutations = {
            "checkout": text + "\nactions/checkout@" + "a" * 40,
            "install": text + "\npnpm install --frozen-lockfile",
            "npx": text.replace(
                'run: node "$PUBLISHER_PATH" "$VSIX_PATH"',
                'run: npx --yes "ovsx@$OVSX_VERSION" publish "$VSIX_PATH"',
            ),
            "source-tool": text + "\npython3 scripts/release.py check",
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assertTrue(release.publish_workflow_errors(mutated, values))

    def test_open_vsx_publish_workflow_fails_closed_on_input_drift(self) -> None:
        text, values = self.valid_publish_workflow()
        required = (
            'contents/release/manifest.json?ref=$TAG',
            "expected_publisher_sha=$(node -e",
            '--pattern "$publisher"',
            'for name in "$vsix" "$publisher"',
            "sha256sum --check --strict PUBLISH-SUMS",
            'test "$(sha256sum "$publisher" | awk \'{ print $1 }\')" = "$expected_publisher_sha"',
            'node "$publisher_path" --version',
            'chmod 0444 "$vsix" "$publisher" PUBLISH-SUMS',
            'echo "PUBLISHER_PATH=$publisher_path" >> "$GITHUB_ENV"',
            'echo "EXPECTED_PUBLISHER_SHA256=$expected_publisher_sha" >> "$GITHUB_ENV"',
        )
        for value in required:
            with self.subTest(missing=value):
                self.assertTrue(
                    release.publish_workflow_errors(
                        text.replace(value, "missing"), values
                    )
                )

        secret = "OVSX_PAT: ${{ secrets.OVSX_PAT }}"
        early_secret = secret + "\n" + text.replace(secret + "\n", "")
        errors = release.publish_workflow_errors(early_secret, values)
        self.assertTrue(any("before exposing" in error for error in errors), errors)

        duplicate_secret = text + "\n" + secret
        errors = release.publish_workflow_errors(duplicate_secret, values)
        self.assertTrue(any("exactly once" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
