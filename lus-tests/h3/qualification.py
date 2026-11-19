#!/usr/bin/env python3
"""Validate and run independent H3 system integration cases."""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "lus-tests" / "h3" / "manifest.json"
SKIPS_PATH = ROOT / "lus-tests" / "h3" / "platform-skips.json"
RESULT_PREFIX = "LUS_TEST_RESULT "
EVENT_PREFIX = "LUS_TEST_EVENT "


class H3Error(RuntimeError):
    pass


def validate_manifest_data(data: dict, root: Path = ROOT) -> list[dict]:
    if (
        set(data) != {"schema_version", "entries"}
        or type(data["schema_version"]) is not int
        or data["schema_version"] != 1
    ):
        raise H3Error("unsupported H3 manifest schema")
    entries = data["entries"]
    if not isinstance(entries, list) or not entries:
        raise H3Error("H3 manifest needs at least one entry")
    allowed = {"id", "source", "harness", "timeout", "fixture", "container"}
    seen_ids = set()
    seen_sources = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) - allowed:
            raise H3Error(f"invalid H3 entry {index}")
        required = {"id", "source", "harness", "timeout", "container"}
        if not required <= set(entry):
            raise H3Error(f"incomplete H3 entry {index}")
        test_id = entry["id"]
        source = entry["source"]
        if not isinstance(test_id, str) or not test_id.startswith("h3/"):
            raise H3Error(f"invalid H3 id in entry {index}")
        if test_id in seen_ids:
            raise H3Error(f"duplicate H3 id: {test_id}")
        if not isinstance(source, str) or source in seen_sources:
            raise H3Error(f"duplicate or invalid H3 source in entry {index}")
        source_path = root / source
        if not source_path.is_file():
            raise H3Error(f"missing H3 source: {source}")
        if entry["harness"] not in {"framework", "raw"}:
            raise H3Error(f"invalid H3 harness: {test_id}")
        if type(entry["timeout"]) is not int or entry["timeout"] <= 0:
            raise H3Error(f"invalid H3 timeout: {test_id}")
        if not isinstance(entry["container"], bool):
            raise H3Error(f"invalid H3 container flag: {test_id}")
        if entry.get("fixture") not in {None, "tls"}:
            raise H3Error(f"unknown H3 fixture: {test_id}")
        text = source_path.read_text(encoding="utf-8")
        uses_framework = "framework.new" in text
        if uses_framework != (entry["harness"] == "framework"):
            raise H3Error(f"wrong H3 harness classification: {test_id}")
        if uses_framework and "tests:finish()" not in text:
            raise H3Error(f"H3 framework case omits tests:finish(): {test_id}")
        seen_ids.add(test_id)
        seen_sources.add(source)
    if root == ROOT:
        discovered = {
            str(path.relative_to(root))
            for path in (root / "lus-tests" / "h3").glob("*.lus")
        }
        if discovered != seen_sources:
            missing = sorted(discovered - seen_sources)
            stale = sorted(seen_sources - discovered)
            raise H3Error(
                f"H3 inventory mismatch, unregistered={missing}, stale={stale}"
            )
    return entries


def read_manifest() -> list[dict]:
    try:
        data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise H3Error(f"cannot read H3 manifest: {error}") from error
    return validate_manifest_data(data)


def platform_name() -> str:
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform.startswith("win"):
        return "windows"
    return sys.platform


def validate_skip_data(data: dict, entries: list[dict]) -> list[dict]:
    if (
        set(data) != {"schema_version", "skips"}
        or type(data["schema_version"]) is not int
        or data["schema_version"] != 1
    ):
        raise H3Error("unsupported H3 skip allowlist schema")
    rules = data["skips"]
    if not isinstance(rules, list):
        raise H3Error("H3 skip allowlist needs an array")
    known = {entry["id"]: entry for entry in entries}
    seen = set()
    for index, rule in enumerate(rules):
        required = {"test", "platforms", "description", "reason"}
        if not isinstance(rule, dict) or set(rule) != required:
            raise H3Error(f"invalid H3 skip rule {index}")
        test_id = rule["test"]
        entry = known.get(test_id)
        if entry is None or entry["harness"] != "framework":
            raise H3Error(f"H3 skip rule {index} names an unknown framework test")
        platforms = rule["platforms"]
        if (
            not isinstance(platforms, list)
            or not platforms
            or len(platforms) != len(set(platforms))
            or not set(platforms) <= {"darwin", "linux", "windows"}
        ):
            raise H3Error(f"H3 skip rule {index} has invalid platforms")
        for field in ("description", "reason"):
            if not isinstance(rule[field], str) or not rule[field]:
                raise H3Error(f"H3 skip rule {index} has an invalid {field}")
        key = (
            test_id,
            tuple(platforms),
            rule["description"],
            rule["reason"],
        )
        if key in seen:
            raise H3Error(f"duplicate H3 skip rule {index}")
        seen.add(key)
    return rules


def read_skip_allowlist(entries: list[dict]) -> list[dict]:
    try:
        data = json.loads(SKIPS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise H3Error(f"cannot read H3 skip allowlist: {error}") from error
    return validate_skip_data(data, entries)


def entry_by_id(test_id: str) -> dict:
    entries = read_manifest()
    matches = [entry for entry in entries if entry["id"] == test_id]
    if len(matches) != 1:
        raise H3Error(f"unknown H3 test: {test_id}")
    return matches[0]


def parse_framework(test_id: str, output: str, skip_rules: list[dict]) -> None:
    lines = [line for line in output.splitlines() if line.startswith(RESULT_PREFIX)]
    if len(lines) != 1:
        raise H3Error(f"{test_id} emitted {len(lines)} framework results")
    try:
        result = json.loads(lines[0][len(RESULT_PREFIX):])
    except json.JSONDecodeError as error:
        raise H3Error(f"{test_id} emitted invalid result JSON") from error
    required = {"name", "tests", "passed", "failed", "soft_failed", "skipped"}
    if set(result) != required:
        raise H3Error(f"{test_id} emitted an invalid result shape")
    expected_name = test_id.split("/", 1)[1]
    if result["name"] != expected_name:
        raise H3Error(
            f"{test_id} emitted result for {result['name']!r}, "
            f"expected {expected_name!r}"
        )
    counts = [result[name] for name in required - {"name"}]
    if any(type(value) is not int or value < 0 for value in counts):
        raise H3Error(f"{test_id} emitted invalid result counts")
    if result["tests"] == 0:
        raise H3Error(f"{test_id} reported zero tests")
    total = result["passed"] + result["failed"] + result["soft_failed"]
    if total != result["tests"]:
        raise H3Error(f"{test_id} result counts do not add up")
    if result["failed"] or result["soft_failed"]:
        raise H3Error(
            f"{test_id} reported failed={result['failed']}, "
            f"soft_failed={result['soft_failed']}"
        )
    events = []
    for line in output.splitlines():
        if not line.startswith(EVENT_PREFIX):
            continue
        try:
            event = json.loads(line[len(EVENT_PREFIX):])
        except json.JSONDecodeError as error:
            raise H3Error(f"{test_id} emitted invalid event JSON") from error
        required_event = {"kind", "description", "reason"}
        if set(event) != required_event or event["kind"] != "skip":
            raise H3Error(f"{test_id} emitted an invalid event")
        events.append(event)
    if result["skipped"] != len(events):
        raise H3Error(f"{test_id} skip count does not match its events")
    current_platform = platform_name()
    for event in events:
        allowed = any(
            rule["test"] == test_id
            and current_platform in rule["platforms"]
            and rule["description"] == event["description"]
            and rule["reason"] == event["reason"]
            for rule in skip_rules
        )
        if not allowed:
            raise H3Error(
                f"{test_id} used an unexpected skip on {current_platform}: "
                f"{event['description']} ({event['reason']})"
            )


def isolated_environment(workspace: Path) -> dict[str, str]:
    environment = os.environ.copy()
    temporary = workspace / "tmp"
    temporary.mkdir()
    environment["TMPDIR"] = str(temporary)
    environment["TEMP"] = str(temporary)
    environment["TMP"] = str(temporary)
    root_path = f"{ROOT / '?.lus'};{ROOT / '?' / 'init.lus'}"
    inherited = environment.get("LUA_PATH")
    environment["LUA_PATH"] = root_path + (f";{inherited}" if inherited else ";;")
    environment["LUS_REPOSITORY_ROOT"] = str(ROOT)
    return environment


def invoke(command: list[str], workspace: Path, environment: dict[str, str], timeout: int):
    try:
        completed = subprocess.run(
            command,
            cwd=workspace,
            env=environment,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise H3Error(f"child process exceeded {timeout} seconds") from error
    sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    if completed.returncode != 0:
        raise H3Error(f"child process exited with {completed.returncode}")
    return completed


def run_direct(entry: dict, program: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="lus-h3-") as directory:
        workspace = Path(directory)
        environment = isolated_environment(workspace)
        if entry.get("fixture") == "tls":
            command = [
                sys.executable,
                str(ROOT / "lus-tests" / "h3" / "tls_fixture.py"),
                "--program",
                str(program),
                "--source",
                str(ROOT / entry["source"]),
            ]
        else:
            command = [str(program), str(ROOT / entry["source"])]
        completed = invoke(command, workspace, environment, entry["timeout"])
        if entry["harness"] == "framework":
            parse_framework(
                entry["id"], completed.stdout, read_skip_allowlist(read_manifest())
            )


def container_engine() -> str:
    for name in ("podman", "docker"):
        path = shutil.which(name)
        if path:
            return path
    raise H3Error("H3 container mode requires Podman or Docker")


def run_container(entry: dict, program: Path) -> None:
    if not entry["container"]:
        raise H3Error(f"{entry['id']} requires direct platform execution")
    if not sys.platform.startswith("linux"):
        raise H3Error("H3 container mode requires a Linux-built interpreter")
    try:
        relative_program = program.resolve().relative_to(ROOT)
    except ValueError as error:
        raise H3Error("the H3 interpreter must be inside the repository") from error
    engine = container_engine()
    image = os.environ.get("LUS_H3_CONTAINER_IMAGE", "ubuntu:24.04")
    with tempfile.TemporaryDirectory(prefix="lus-h3-container-") as directory:
        workspace = Path(directory)
        container_workspace = f"/tmp/{workspace.name}"
        command = [
            engine,
            "run",
            "--rm",
            "--volume",
            f"{ROOT}:/src:ro",
            "--workdir",
            container_workspace,
            "--env",
            f"TMPDIR={container_workspace}",
            "--env",
            f"TMP={container_workspace}",
            "--env",
            f"TEMP={container_workspace}",
            "--env",
            "LUA_PATH=/src/?.lus;/src/?/init.lus;;",
            "--env",
            "LUS_REPOSITORY_ROOT=/src",
            image,
            f"/src/{relative_program.as_posix()}",
            f"/src/{entry['source']}",
        ]
        environment = isolated_environment(workspace)
        completed = invoke(command, workspace, environment, entry["timeout"])
    if entry["harness"] == "framework":
        parse_framework(
            entry["id"], completed.stdout, read_skip_allowlist(read_manifest())
        )


def meson_option(command: list, option: str, test_name: str) -> str:
    positions = [index for index, value in enumerate(command) if value == option]
    if len(positions) != 1 or positions[0] + 1 >= len(command):
        raise H3Error(f"{test_name} has an invalid {option} option")
    value = command[positions[0] + 1]
    if not isinstance(value, str) or not value:
        raise H3Error(f"{test_name} has an invalid {option} value")
    return value


def validate_meson_command(
    test: dict, entry: dict, expected_mode: str, required_suites: set[str]
) -> None:
    test_name = test.get("name")
    command = test.get("cmd", [])
    if (
        not isinstance(command, list)
        or len(command) < 3
        or command[2] != "run"
        or Path(command[1]).resolve() != Path(__file__).resolve()
    ):
        raise H3Error(f"{test_name} bypasses the H3 qualification runner")
    if meson_option(command, "--mode", test_name) != expected_mode:
        raise H3Error(f"{test_name} uses the wrong H3 execution mode")
    if meson_option(command, "--id", test_name) != entry["id"]:
        raise H3Error(f"{test_name} runs the wrong H3 id")
    meson_option(command, "--program", test_name)
    suites = set(test.get("suite", []))
    if not required_suites <= suites:
        raise H3Error(f"{test_name} is missing H3 qualification labels")
    timeout = test.get("timeout")
    if type(timeout) is not int or timeout != entry["timeout"]:
        raise H3Error(f"{test_name} has the wrong H3 timeout")
    if test.get("protocol") != "exitcode":
        raise H3Error(f"{test_name} has the wrong H3 protocol")


def validate_meson(build_dir: Path, entries: list[dict]) -> None:
    path = build_dir / "meson-info" / "intro-tests.json"
    try:
        tests = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise H3Error(f"cannot read Meson test introspection: {error}") from error
    by_name = {}
    for test in tests:
        by_name.setdefault(test.get("name"), []).append(test)
    expected = {entry["id"] for entry in entries}
    for entry in entries:
        matches = by_name.get(entry["id"], [])
        if len(matches) != 1:
            raise H3Error(f"Meson registers {entry['id']} {len(matches)} times")
        validate_meson_command(
            matches[0],
            entry,
            "direct",
            {"lus:h3", "lus:h3-ci", "lus:system-integration"},
        )
        local_name = "h3-local/" + entry["id"].split("/", 1)[1]
        local_matches = by_name.get(local_name, [])
        if entry["container"]:
            if len(local_matches) != 1:
                raise H3Error(
                    f"Meson registers {local_name} {len(local_matches)} times"
                )
            validate_meson_command(
                local_matches[0],
                entry,
                "container",
                {"lus:h3-local", "lus:system-integration"},
            )
        if not entry["container"] and local_matches:
            raise H3Error(f"Meson registered unsupported container case {local_name}")
    expected_local = {
        "h3-local/" + entry["id"].split("/", 1)[1]
        for entry in entries
        if entry["container"]
    }
    for name in by_name:
        if isinstance(name, str) and name.startswith("h3/"):
            if name not in expected | {"h3/manifest", "h3/selftest"}:
                raise H3Error(f"Meson registers an unknown H3 test: {name}")
        if isinstance(name, str) and name.startswith("h3-local/"):
            if name not in expected_local:
                raise H3Error(f"Meson registers an unknown local H3 test: {name}")


def expect_error(function, label: str, expected: str | None = None) -> None:
    try:
        function()
    except H3Error as error:
        if expected is not None and expected not in str(error):
            raise H3Error(
                f"H3 self-test for {label} raised the wrong error: {error}"
            ) from error
        return
    raise H3Error(f"H3 self-test accepted {label}")


def command_selftest(args) -> None:
    program = Path(args.program).resolve()
    entries = read_manifest()
    read_skip_allowlist(entries)
    duplicate = {"schema_version": 1, "entries": copy.deepcopy(entries)}
    duplicate["entries"].append(copy.deepcopy(entries[0]))
    expect_error(
        lambda: validate_manifest_data(duplicate),
        "a duplicate entry",
        "duplicate H3 id",
    )
    boolean_schema = {
        "schema_version": True,
        "entries": copy.deepcopy(entries),
    }
    expect_error(
        lambda: validate_manifest_data(boolean_schema),
        "a boolean manifest schema version",
        "unsupported H3 manifest schema",
    )
    boolean_timeout = {"schema_version": 1, "entries": copy.deepcopy(entries)}
    boolean_timeout["entries"][0]["timeout"] = True
    expect_error(
        lambda: validate_manifest_data(boolean_timeout),
        "a boolean manifest timeout",
        "invalid H3 timeout",
    )
    boolean_skip_schema = {"schema_version": True, "skips": []}
    expect_error(
        lambda: validate_skip_data(boolean_skip_schema, entries),
        "a boolean skip schema version",
        "unsupported H3 skip allowlist schema",
    )

    zero = json.dumps(
        {
            "name": "selftest",
            "tests": 0,
            "passed": 0,
            "failed": 0,
            "soft_failed": 0,
            "skipped": 0,
        }
    )
    expect_error(
        lambda: parse_framework("h3/selftest", RESULT_PREFIX + zero, []),
        "a zero-test result",
        "reported zero tests",
    )
    boolean_counts = json.dumps(
        {
            "name": "selftest",
            "tests": True,
            "passed": True,
            "failed": False,
            "soft_failed": False,
            "skipped": False,
        }
    )
    expect_error(
        lambda: parse_framework(
            "h3/selftest", RESULT_PREFIX + boolean_counts, []
        ),
        "boolean result counts",
        "invalid result counts",
    )
    wrong_name = json.dumps(
        {
            "name": "unrelated",
            "tests": 1,
            "passed": 1,
            "failed": 0,
            "soft_failed": 0,
            "skipped": 0,
        }
    )
    expect_error(
        lambda: parse_framework("h3/selftest", RESULT_PREFIX + wrong_name, []),
        "a result for another suite",
        "emitted result for",
    )

    malformed = json.dumps(
        {
            "name": "selftest",
            "tests": 1,
            "passed": 1,
            "failed": 0,
            "soft_failed": 0,
            "skipped": 1,
        }
    )
    expect_error(
        lambda: parse_framework(
            "h3/selftest",
            RESULT_PREFIX
            + malformed
            + "\n"
            + EVENT_PREFIX
            + json.dumps(
                {
                    "kind": "skip",
                    "description": "unapproved",
                    "reason": "self-test",
                }
            ),
            [],
        ),
        "an unexpected skip",
        "used an unexpected skip",
    )
    soft = json.dumps(
        {
            "name": "selftest",
            "tests": 1,
            "passed": 0,
            "failed": 0,
            "soft_failed": 1,
            "skipped": 0,
        }
    )
    expect_error(
        lambda: parse_framework("h3/selftest", RESULT_PREFIX + soft, []),
        "a soft failure",
        "soft_failed=1",
    )

    def meson_records() -> list[dict]:
        records = []
        runner = str(Path(__file__).resolve())
        for entry in entries:
            records.append(
                {
                    "name": entry["id"],
                    "cmd": [
                        sys.executable,
                        runner,
                        "run",
                        "--mode",
                        "direct",
                        "--id",
                        entry["id"],
                        "--program",
                        str(program),
                    ],
                    "suite": [
                        "lus:h3",
                        "lus:h3-ci",
                        "lus:system-integration",
                    ],
                    "timeout": entry["timeout"],
                    "protocol": "exitcode",
                }
            )
            if entry["container"]:
                records.append(
                    {
                        "name": "h3-local/"
                        + entry["id"].split("/", 1)[1],
                        "cmd": [
                            sys.executable,
                            runner,
                            "run",
                            "--mode",
                            "container",
                            "--id",
                            entry["id"],
                            "--program",
                            str(program),
                        ],
                        "suite": ["lus:h3-local", "lus:system-integration"],
                        "timeout": entry["timeout"],
                        "protocol": "exitcode",
                    }
                )
        return records

    def check_meson_records(records: list[dict]) -> None:
        with tempfile.TemporaryDirectory(prefix="lus-h3-meson-selftest-") as directory:
            build_dir = Path(directory)
            info_dir = build_dir / "meson-info"
            info_dir.mkdir()
            (info_dir / "intro-tests.json").write_text(
                json.dumps(records), encoding="utf-8"
            )
            validate_meson(build_dir, entries)

    baseline_records = meson_records()
    check_meson_records(baseline_records)

    wrong_id = copy.deepcopy(baseline_records)
    direct = next(record for record in wrong_id if record["name"] == "h3/files")
    direct["cmd"][direct["cmd"].index("--id") + 1] = "h3/cli"
    expect_error(
        lambda: check_meson_records(wrong_id),
        "a direct registration with the wrong id",
        "runs the wrong H3 id",
    )

    wrong_mode = copy.deepcopy(baseline_records)
    local = next(
        record for record in wrong_mode if record["name"] == "h3-local/files"
    )
    local["cmd"][local["cmd"].index("--mode") + 1] = "direct"
    expect_error(
        lambda: check_meson_records(wrong_mode),
        "a local registration with the wrong mode",
        "uses the wrong H3 execution mode",
    )

    missing_labels = copy.deepcopy(baseline_records)
    local = next(
        record
        for record in missing_labels
        if record["name"] == "h3-local/files"
    )
    local["suite"] = []
    expect_error(
        lambda: check_meson_records(missing_labels),
        "a local registration without labels",
        "is missing H3 qualification labels",
    )

    wrong_timeout = copy.deepcopy(baseline_records)
    direct = next(
        record for record in wrong_timeout if record["name"] == "h3/files"
    )
    direct["timeout"] += 1
    expect_error(
        lambda: check_meson_records(wrong_timeout),
        "a registration with the wrong timeout",
        "has the wrong H3 timeout",
    )

    unknown_local = copy.deepcopy(baseline_records)
    extra = copy.deepcopy(
        next(
            record
            for record in unknown_local
            if record["name"] == "h3-local/files"
        )
    )
    extra["name"] = "h3-local/unregistered"
    unknown_local.append(extra)
    expect_error(
        lambda: check_meson_records(unknown_local),
        "an unknown local registration",
        "registers an unknown local H3 test",
    )

    prelude = (
        "global require, error, pledge\n"
        'pledge("load", "fs")\n'
        'local framework = require("lus-tests.framework")\n'
        'local tests = framework.new("h3-selftest")\n'
    )
    with tempfile.TemporaryDirectory(prefix="lus-h3-selftest-") as directory:
        root = Path(directory)
        cases = {
            "teardown": prelude
            + 'tests:after(function() error("teardown") end)\n'
            + 'tests:it("body", function() end)\n'
            + "tests:finish()\n",
            "child": "global os\nos.exit(9)\n",
        }
        for label, body in cases.items():
            source = root / f"{label}.lus"
            source.write_text(body, encoding="utf-8")
            entry = {
                "id": (
                    "h3/h3-selftest" if label == "teardown"
                    else "h3/selftest-fixture"
                ),
                "source": str(source),
                "harness": "framework" if label == "teardown" else "raw",
                "timeout": 10,
                "container": False,
            }
            expect_error(
                lambda entry=entry: run_direct(entry, program),
                label,
                "child process exited",
            )


def command_records(_args) -> None:
    for entry in read_manifest():
        fixture = entry.get("fixture", "")
        print(
            "|".join(
                [
                    entry["id"],
                    entry["source"],
                    entry["harness"],
                    str(entry["timeout"]),
                    fixture,
                    "true" if entry["container"] else "false",
                ]
            )
        )


def command_validate(args) -> None:
    entries = read_manifest()
    read_skip_allowlist(entries)
    if args.build_dir:
        validate_meson(Path(args.build_dir), entries)
    print(f"validated {len(entries)} independent H3 cases")


def command_run(args) -> None:
    entry = entry_by_id(args.id)
    program = Path(args.program).resolve()
    if not program.is_file():
        raise H3Error(f"missing H3 interpreter: {program}")
    if args.mode == "direct":
        run_direct(entry, program)
    else:
        run_container(entry, program)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--build-dir")
    validate.set_defaults(function=command_validate)
    selftest = commands.add_parser("self-test")
    selftest.add_argument("--program", required=True)
    selftest.set_defaults(function=command_selftest)
    records = commands.add_parser("meson-records")
    records.set_defaults(function=command_records)
    run = commands.add_parser("run")
    run.add_argument("--id", required=True)
    run.add_argument("--program", required=True)
    run.add_argument("--mode", choices=("direct", "container"), required=True)
    run.set_defaults(function=command_run)
    return value


def main() -> int:
    try:
        args = parser().parse_args()
        args.function(args)
        return 0
    except H3Error as error:
        print(f"H3 qualification error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
