#!/usr/bin/env python3
"""Prepare and prove a build-compatible H4 baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent.parent
DEPENDENCIES_PATH = ROOT / "release" / "dependencies.json"
PARITY_OPTIONS = (
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
)
OPTIONAL_PARITY_OPTIONS = ("b_lto_mode",)
REQUIRED_PARITY_OPTIONS = tuple(
    name for name in PARITY_OPTIONS if name not in OPTIONAL_PARITY_OPTIONS
)
SETUP_OPTIONS = tuple(name for name in PARITY_OPTIONS if name != "debug")
CANONICAL_RELEASE = {
    "buildtype": "release",
    "optimization": "3",
    "debug": False,
    "b_lto": True,
    "b_pgo": "off",
    "b_sanitize": [],
}


class ParityError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise ParityError(f"cannot hash {path}: {exc}") from exc
    return digest.hexdigest()


def load_dependency_metadata(path: Path = DEPENDENCIES_PATH) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ParityError(f"cannot read dependency metadata {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ParityError("release dependency metadata has an unsupported schema")
    return value


def run_text(command: list[str], *, capture: bool = True) -> str:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            capture_output=capture,
            text=True,
        )
    except OSError as exc:
        raise ParityError(f"cannot run {command}: {exc}") from exc
    if completed.returncode != 0:
        stdout = completed.stdout.strip() if capture else ""
        stderr = completed.stderr.strip() if capture else ""
        raise ParityError(
            f"command exited {completed.returncode}: {command}\n"
            f"stdout: {stdout}\nstderr: {stderr}"
        )
    return completed.stdout.strip() if capture else ""


def run_json(command: list[str]) -> object:
    text = run_text(command)
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ParityError(f"command emitted invalid JSON: {command}: {exc}") from exc


def option_map(build_dir: Path) -> dict[str, object]:
    rows = run_json(["meson", "introspect", "--buildoptions", str(build_dir)])
    if not isinstance(rows, list):
        raise ParityError("Meson build option introspection must be a list")
    available = {
        row.get("name"): row.get("value")
        for row in rows
        if isinstance(row, dict)
    }
    missing = [name for name in REQUIRED_PARITY_OPTIONS if name not in available]
    if missing:
        raise ParityError(f"Meson introspection omitted parity options: {missing}")
    return {name: available.get(name) for name in PARITY_OPTIONS}


def compiler_metadata(build_dir: Path) -> dict:
    data = run_json(["meson", "introspect", "--compilers", str(build_dir)])
    try:
        compiler = data["host"]["c"]
    except (KeyError, TypeError) as exc:
        raise ParityError("Meson did not report the host C compiler") from exc
    fields = (
        "id",
        "exelist",
        "linker_exelist",
        "version",
        "full_version",
        "linker_id",
    )
    return {name: compiler.get(name) for name in fields}


def dependency_metadata(build_dir: Path) -> list[dict]:
    rows = run_json(["meson", "introspect", "--dependencies", str(build_dir)])
    if not isinstance(rows, list):
        raise ParityError("Meson dependency introspection must be a list")
    fields = ("name", "type", "version", "compile_args", "link_args")
    normalized = [
        {name: row.get(name) for name in fields}
        for row in rows
        if isinstance(row, dict)
    ]
    return sorted(normalized, key=lambda row: json.dumps(row, sort_keys=True))


def target_metadata(build_dir: Path) -> list[dict]:
    rows = run_json(["meson", "introspect", "--targets", str(build_dir)])
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise ParityError("Meson target introspection must be a list of objects")
    return rows


def project_source_inventory(targets: list[dict]) -> tuple[Path, dict[str, str]]:
    definitions = [
        Path(row["defined_in"]).resolve()
        for row in targets
        if isinstance(row.get("defined_in"), str)
        and Path(row["defined_in"]).name == "meson.build"
    ]
    if not definitions:
        raise ParityError("Meson targets omit the project source directory")
    source_root = definitions[0].parent
    executable = executable_target(targets)
    linked_names = {Path(value).name for value in link_parameters(executable)}
    selected = [executable]
    for target in targets:
        if target is executable:
            continue
        filenames = target.get("filename", [])
        if isinstance(filenames, str):
            filenames = [filenames]
        if isinstance(filenames, list) and any(
            isinstance(filename, str) and Path(filename).name in linked_names
            for filename in filenames
        ):
            selected.append(target)
    inventory: dict[str, str] = {}
    for target in selected:
        for source_group in target.get("target_sources", []):
            if not isinstance(source_group, dict):
                continue
            for field in ("sources", "generated_sources", "unity_sources"):
                values = source_group.get(field, [])
                if not isinstance(values, list):
                    raise ParityError(f"Meson target source field {field} is invalid")
                for value in values:
                    if not isinstance(value, str):
                        raise ParityError("Meson target source path is not a string")
                    source = Path(value).resolve()
                    try:
                        relative = source.relative_to(source_root).as_posix()
                    except ValueError:
                        continue
                    if not source.is_file():
                        raise ParityError(f"Meson project source is unavailable: {source}")
                    digest = sha256_file(source)
                    previous = inventory.setdefault(relative, digest)
                    if previous != digest:
                        raise ParityError(f"project source changed while hashing: {source}")
    if not inventory:
        raise ParityError("Meson target introspection contains no project sources")
    return source_root, dict(sorted(inventory.items()))


def executable_target(targets: list[dict]) -> dict:
    matches = [
        target
        for target in targets
        if target.get("name") == "lus" and target.get("type") == "executable"
    ]
    if len(matches) != 1:
        raise ParityError("Meson must report exactly one Lus executable target")
    return matches[0]


def internal_output_names(targets: list[dict]) -> set[str]:
    names = set()
    for target in targets:
        filenames = target.get("filename", [])
        if isinstance(filenames, str):
            filenames = [filenames]
        if not isinstance(filenames, list):
            raise ParityError("Meson target filename metadata is invalid")
        for filename in filenames:
            if not isinstance(filename, str):
                raise ParityError("Meson target filename is not a string")
            names.add(Path(filename).name)
    return names


def link_parameters(target: dict) -> list[str]:
    groups = [
        group
        for group in target.get("target_sources", [])
        if isinstance(group, dict) and "linker" in group
    ]
    if len(groups) != 1 or not isinstance(groups[0].get("parameters"), list):
        raise ParityError("Meson omitted the Lus executable link parameters")
    parameters = groups[0]["parameters"]
    if not all(isinstance(value, str) for value in parameters):
        raise ParityError("Meson emitted a non-string link parameter")
    return parameters


def normalize_external_link_inputs(
    build_dir: Path,
    targets: list[dict],
) -> list[dict]:
    """Record the external library closure from the actual target link row."""

    parameters = link_parameters(executable_target(targets))
    internal = internal_output_names(targets)
    normalized: list[dict] = []
    index = 0
    while index < len(parameters):
        value = parameters[index]
        if value == "-framework":
            if index + 1 >= len(parameters):
                raise ParityError("link parameters end after -framework")
            normalized.append(
                {"kind": "framework", "name": parameters[index + 1]}
            )
            index += 2
            continue
        if value.startswith("-l") and len(value) > 2:
            normalized.append({"kind": "library", "name": value[2:]})
            index += 1
            continue
        if value in ("-pthread", "-pthreads"):
            normalized.append({"kind": "thread-flag", "name": value})
            index += 1
            continue
        if value.startswith("/DEFAULTLIB:"):
            normalized.append(
                {"kind": "library", "name": value.split(":", 1)[1]}
            )
            index += 1
            continue
        if value.startswith("-Wl,"):
            for linker_value in value.split(",")[1:]:
                if linker_value.startswith("-l") and len(linker_value) > 2:
                    normalized.append(
                        {"kind": "library", "name": linker_value[2:]}
                    )
            index += 1
            continue

        filename = Path(value).name.lower()
        is_library_file = bool(
            re.search(r"(?:[.]a|[.]so(?:[.][0-9]+)*|[.]dylib|[.]lib|[.]tbd)$", filename)
        )
        if is_library_file and Path(value).name not in internal:
            path = Path(value)
            if not path.is_absolute():
                path = build_dir / path
            if path.is_file():
                normalized.append(
                    {
                        "kind": "file",
                        "name": path.name,
                        "sha256": sha256_file(path.resolve()),
                    }
                )
            else:
                normalized.append({"kind": "library", "name": value})
        index += 1
    if not normalized:
        raise ParityError("Lus executable link metadata has no external inputs")
    return normalized


def dependency_version(dependencies: list[dict], names: set[str]) -> str:
    matches = [
        row.get("version")
        for row in dependencies
        if str(row.get("name", "")).lower() in names
    ]
    if len(matches) != 1 or not isinstance(matches[0], str):
        raise ParityError(f"expected one dependency version for {sorted(names)}")
    return matches[0]


def pinned_cares_input(archive: Path, metadata: dict) -> dict:
    cares = metadata.get("caresSource")
    if not isinstance(cares, dict):
        raise ParityError("dependency metadata omits caresSource")
    version = cares.get("version")
    url = cares.get("url")
    expected = cares.get("sha256")
    if not all(isinstance(value, str) and value for value in (version, url, expected)):
        raise ParityError("dependency metadata contains an invalid c-ares input")
    actual = sha256_file(archive.resolve())
    if actual != expected:
        raise ParityError(
            f"c-ares source digest mismatch: expected {expected}, got {actual}"
        )
    library = archive.resolve().parent / "install" / "lib" / "libcares.a"
    if not library.is_file():
        raise ParityError(
            "the pinned c-ares static library is missing beside its source archive"
        )
    return {
        "name": "c-ares",
        "version": version,
        "url": url,
        "expected_sha256": expected,
        "archive_sha256": actual,
        "library_sha256": sha256_file(library),
    }


def extract_version(path: Path, pattern: str, label: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ParityError(f"cannot read {path}: {exc}") from exc
    match = re.search(pattern, text, re.MULTILINE)
    if match is None:
        raise ParityError(f"cannot determine {label} version from {path}")
    return match.group(1)


def require_script_value(relative: str, name: str, expected: object) -> None:
    path = ROOT / relative
    if not isinstance(expected, str) or not expected:
        raise ParityError(f"dependency metadata omits {name}")
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ParityError(f"cannot read {path}: {exc}") from exc
    match = re.search(rf'^{re.escape(name)}="([^"]+)"', text, re.MULTILINE)
    if match is None or match.group(1) != expected:
        raise ParityError(
            f"{relative} {name} does not match release dependency metadata"
        )


def validate_source_input_pins(generated: dict) -> None:
    sqlite = generated.get("sqlite", {})
    require_script_value(
        "scripts/update-sqlite.sh", "SQLITE_SHA256", sqlite.get("sourceSha256")
    )
    require_script_value(
        "scripts/update-tzdata.sh",
        "TZDATA_SHA256",
        generated.get("tzdataSourceSha256"),
    )
    require_script_value(
        "scripts/update-tzdata.sh",
        "TZCODE_SHA256",
        generated.get("tzcodeSourceSha256"),
    )
    require_script_value(
        "scripts/update-winzones.sh",
        "CLDR_SHA256",
        generated.get("cldrSourceSha256"),
    )


def source_feature_deltas(
    baseline: dict,
    candidate: dict,
    metadata_path: Path,
    metadata: dict,
) -> dict:
    generated = metadata.get("generatedData")
    if not isinstance(generated, dict):
        raise ParityError("dependency metadata omits generatedData")
    validate_source_input_pins(generated)
    sqlite = generated.get("sqlite")
    if not isinstance(sqlite, dict):
        raise ParityError("dependency metadata omits generatedData.sqlite")

    source_root = Path(candidate["source_root"])
    definitions = {
        "sqlite": {
            "version": sqlite.get("version"),
            "source_sha256": sqlite.get("sourceSha256"),
            "version_file": "vendor/sqlite/sqlite3.h",
            "version_pattern": r'^#define SQLITE_VERSION\s+"([^"]+)"',
            "files": {
                "vendor/sqlite/sqlite3.c": sqlite.get("cSha256"),
                "vendor/sqlite/sqlite3.h": sqlite.get("headerSha256"),
            },
        },
        "tzdata": {
            "version": generated.get("tzdata"),
            "source_sha256": generated.get("tzdataSourceSha256"),
            "additional_source_sha256": generated.get("tzcodeSourceSha256"),
            "version_file": "src/ltzdata.c",
            "version_pattern": r'^const char lus_tzdata_version\[\] = "([^"]+)";',
            "files": {
                "src/ltzdata.c": generated.get("tzdataGeneratedSha256"),
            },
        },
        "cldr": {
            "version": generated.get("cldr"),
            "source_sha256": generated.get("cldrSourceSha256"),
            "version_file": "src/lwinzones.c",
            "version_pattern": r"CLDR ([0-9.]+) Windows-to-IANA",
            "files": {
                "src/lwinzones.c": generated.get("cldrGeneratedSha256"),
            },
        },
    }

    features = {}
    for name, definition in definitions.items():
        version = definition["version"]
        source_digest = definition["source_sha256"]
        if not isinstance(version, str) or not version:
            raise ParityError(f"dependency metadata omits the {name} version")
        if not isinstance(source_digest, str) or len(source_digest) != 64:
            raise ParityError(f"dependency metadata omits the {name} source digest")
        version_file = source_root / definition["version_file"]
        actual_version = extract_version(
            version_file,
            definition["version_pattern"],
            name,
        )
        if actual_version != version:
            raise ParityError(
                f"{name} version mismatch: expected {version}, got {actual_version}"
            )
        files = []
        for relative, expected in definition["files"].items():
            if not isinstance(expected, str) or len(expected) != 64:
                raise ParityError(
                    f"dependency metadata omits the {name} digest for {relative}"
                )
            actual = sha256_file(source_root / relative)
            if actual != expected:
                raise ParityError(
                    f"{name} generated source digest mismatch for {relative}"
                )
            files.append(
                {"path": relative, "expected_sha256": expected, "sha256": actual}
            )
        feature = {
            "version": version,
            "source_sha256": source_digest,
            "files": files,
        }
        additional = definition.get("additional_source_sha256")
        if additional is not None:
            if not isinstance(additional, str) or len(additional) != 64:
                raise ParityError(f"dependency metadata omits the {name} code digest")
            feature["additional_source_sha256"] = additional
        features[name] = feature

    baseline_sources = baseline["project_sources"]
    candidate_sources = candidate["project_sources"]
    candidates = [
        {"path": path, "sha256": candidate_sources[path]}
        for path in sorted(set(candidate_sources) - set(baseline_sources))
    ]
    required_compiled = {
        "vendor/sqlite/sqlite3.c",
        "src/ltzdata.c",
        "src/lwinzones.c",
    }
    missing = sorted(required_compiled - {row["path"] for row in candidates})
    if missing:
        raise ParityError(
            "candidate-only source inventory omits release features: "
            + ", ".join(missing)
        )
    return {
        "classification": "candidate-only-source-feature-deltas",
        "dependency_metadata": metadata_path.relative_to(ROOT).as_posix(),
        "dependency_metadata_sha256": sha256_file(metadata_path),
        "candidate_only_sources": candidates,
        "features": features,
    }


def snapshot(build_dir: Path, cares_input: dict) -> dict:
    build_dir = build_dir.resolve()
    if not (build_dir / "meson-private" / "coredata.dat").is_file():
        raise ParityError(f"not a configured Meson build directory: {build_dir}")
    targets = target_metadata(build_dir)
    source_root, sources = project_source_inventory(targets)
    dependencies = dependency_metadata(build_dir)
    cares = dict(cares_input)
    cares["dependency_version"] = dependency_version(
        dependencies, {"libcares", "c-ares", "cares"}
    )
    return {
        "build_dir": str(build_dir),
        "source_root": str(source_root),
        "meson_version": run_text(["meson", "--version"]),
        "ninja_version": run_text(["ninja", "--version"]),
        "compiler": compiler_metadata(build_dir),
        "options": option_map(build_dir),
        "dependencies": dependencies,
        "external_link_inputs": normalize_external_link_inputs(
            build_dir, targets
        ),
        "project_sources": sources,
        "pinned_cares": cares,
    }


def canonical_release_check(candidate: dict) -> dict:
    actual = candidate["options"]
    mismatches = {
        name: {"required": required, "actual": actual.get(name)}
        for name, required in CANONICAL_RELEASE.items()
        if actual.get(name) != required
    }
    return {
        "match": not mismatches,
        "required": CANONICAL_RELEASE,
        "mismatches": mismatches,
    }


def compare_snapshots(
    baseline: dict,
    candidate: dict,
    deltas: dict,
) -> dict:
    option_checks = {
        name: {
            "match": baseline["options"].get(name)
            == candidate["options"].get(name),
            "baseline": baseline["options"].get(name),
            "candidate": candidate["options"].get(name),
        }
        for name in PARITY_OPTIONS
    }
    checks = {
        "canonical_release": canonical_release_check(candidate),
        "compiler": {
            "match": baseline["compiler"] == candidate["compiler"],
            "baseline": baseline["compiler"],
            "candidate": candidate["compiler"],
        },
        "dependencies": {
            "match": baseline["dependencies"] == candidate["dependencies"],
            "baseline": baseline["dependencies"],
            "candidate": candidate["dependencies"],
        },
        "external_link_inputs": {
            "match": baseline["external_link_inputs"]
            == candidate["external_link_inputs"],
            "baseline": baseline["external_link_inputs"],
            "candidate": candidate["external_link_inputs"],
        },
        "meson_version": {
            "match": baseline["meson_version"] == candidate["meson_version"],
            "baseline": baseline["meson_version"],
            "candidate": candidate["meson_version"],
        },
        "ninja_version": {
            "match": baseline["ninja_version"] == candidate["ninja_version"],
            "baseline": baseline["ninja_version"],
            "candidate": candidate["ninja_version"],
        },
        "options": {
            "match": all(check["match"] for check in option_checks.values()),
            "values": option_checks,
        },
        "pinned_cares": {
            "match": baseline["pinned_cares"] == candidate["pinned_cares"]
            and candidate["pinned_cares"].get("version")
            == candidate["pinned_cares"].get("dependency_version")
            and candidate["pinned_cares"].get("expected_sha256")
            == candidate["pinned_cares"].get("archive_sha256")
            and {
                "kind": "file",
                "name": "libcares.a",
                "sha256": candidate["pinned_cares"].get("library_sha256"),
            }
            in candidate["external_link_inputs"],
            "baseline": baseline["pinned_cares"],
            "candidate": candidate["pinned_cares"],
        },
        "source_feature_deltas": {
            "match": deltas.get("classification")
            == "candidate-only-source-feature-deltas"
            and set(deltas.get("features", {})) == {"sqlite", "tzdata", "cldr"}
            and bool(deltas.get("candidate_only_sources")),
        },
    }
    passed = all(check["match"] for check in checks.values())
    return {
        "schema_version": 1,
        "kind": "h4-build-parity",
        "status": "pass" if passed else "block",
        "baseline": baseline,
        "candidate": candidate,
        "source_feature_deltas": deltas,
        "checks": checks,
    }


def meson_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return json.dumps(value, separators=(",", ":"))
    return str(value)


def baseline_setup_command(
    candidate: dict,
    source_dir: Path,
    build_dir: Path,
) -> list[str]:
    options = candidate["options"]
    command = [
        "meson",
        "setup",
        str(build_dir),
        str(source_dir),
        f"--buildtype={options['buildtype']}",
    ]
    for name in SETUP_OPTIONS:
        if name == "buildtype":
            continue
        if options[name] is None and name in OPTIONAL_PARITY_OPTIONS:
            continue
        command.append(f"-D{name}={meson_value(options[name])}")
    return command


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def prepare(
    candidate_build: Path,
    source_dir: Path,
    baseline_build: Path,
    evidence: Path,
    cares_source_archive: Path,
    dependency_metadata_path: Path,
) -> int:
    if dependency_metadata_path.resolve() != DEPENDENCIES_PATH.resolve():
        raise ParityError(
            "H4 qualification requires release/dependencies.json from this tree"
        )
    metadata = load_dependency_metadata(dependency_metadata_path)
    cares_input = pinned_cares_input(cares_source_archive, metadata)
    candidate = snapshot(candidate_build, cares_input)
    canonical = canonical_release_check(candidate)
    if not canonical["match"]:
        result = {
            "schema_version": 1,
            "kind": "h4-build-parity",
            "status": "block",
            "candidate": candidate,
            "checks": {"canonical_release": canonical},
        }
        write_json(evidence, result)
        raise ParityError("candidate build is not the canonical release profile")

    compiler = candidate["compiler"].get("exelist")
    if not isinstance(compiler, list) or not compiler:
        raise ParityError("candidate compiler command is unavailable")
    environment = os.environ.copy()
    environment["CC"] = shlex.join(str(value) for value in compiler)
    command = baseline_setup_command(candidate, source_dir, baseline_build)
    setup = subprocess.run(command, cwd=ROOT, env=environment, check=False)
    if setup.returncode != 0:
        raise ParityError(f"baseline Meson setup exited {setup.returncode}")
    compile_run = subprocess.run(
        ["meson", "compile", "-C", str(baseline_build), "lus:executable"],
        cwd=ROOT,
        env=environment,
        check=False,
    )
    if compile_run.returncode != 0:
        raise ParityError(f"baseline compile exited {compile_run.returncode}")

    baseline = snapshot(baseline_build, cares_input)
    deltas = source_feature_deltas(
        baseline,
        candidate,
        dependency_metadata_path.resolve(),
        metadata,
    )
    result = compare_snapshots(baseline, candidate, deltas)
    result["setup_command"] = command
    result["compiler_command"] = environment["CC"]
    write_json(evidence, result)
    if result["status"] != "pass":
        raise ParityError("baseline and candidate build metadata do not match")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-build", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--baseline-build", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument(
        "--cares-source-archive",
        default=os.environ.get("H4_CARES_SOURCE_ARCHIVE"),
        help="verified c-ares source archive used by both builds",
    )
    parser.add_argument(
        "--dependency-metadata",
        default=str(DEPENDENCIES_PATH),
        help="canonical release dependency metadata",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if not args.cares_source_archive:
            raise ParityError(
                "--cares-source-archive or H4_CARES_SOURCE_ARCHIVE is required"
            )
        return prepare(
            Path(args.candidate_build),
            Path(args.source),
            Path(args.baseline_build),
            Path(args.evidence),
            Path(args.cares_source_archive),
            Path(args.dependency_metadata),
        )
    except (OSError, ParityError) as exc:
        print(f"H4 BUILD PARITY ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
