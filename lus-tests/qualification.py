#!/usr/bin/env python3

import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "lus-tests" / "manifest.json"
SKIPS_PATH = ROOT / "lus-tests" / "platform-skips.json"
RESULT_PREFIX = "LUS_TEST_RESULT "
EVENT_PREFIX = "LUS_TEST_EVENT "
QUALIFICATION_META_TESTS = (
    "qualification/manifest",
    "qualification/selftest",
)
LEAK_SANITIZER_EXIT_STATUS = 23
LEAK_SANITIZER_REPORT_MARKERS = (
    "ERROR: LeakSanitizer: detected memory leaks",
    "SUMMARY: AddressSanitizer:",
)


class QualificationError(RuntimeError):
    pass


def read_json(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise QualificationError("cannot read {}: {}".format(path, error))


def require_keys(value, required, allowed, where):
    if not isinstance(value, dict):
        raise QualificationError("{} must be an object".format(where))
    missing = sorted(set(required) - set(value))
    extra = sorted(set(value) - set(allowed))
    if missing:
        raise QualificationError(
            "{} is missing keys: {}".format(where, ", ".join(missing))
        )
    if extra:
        raise QualificationError(
            "{} has unknown keys: {}".format(where, ", ".join(extra))
        )


def require_string_list(value, where, allow_empty=False):
    if not isinstance(value, list) or (not value and not allow_empty):
        raise QualificationError("{} must be a nonempty array".format(where))
    for item in value:
        if not isinstance(item, str) or not item:
            raise QualificationError("{} must contain nonempty strings".format(where))
    if len(value) != len(set(value)):
        raise QualificationError("{} contains duplicates".format(where))


def h1_source(manifest, test_id):
    override = manifest["h1"]["source_overrides"].get(test_id)
    if override is not None:
        return override
    return "lus-tests/h1/{}.lus".format(test_id.split("/", 1)[1])


def entry_map(manifest):
    entries = {}
    for test_id in manifest["h1"]["entries"]:
        override = manifest["h1"]["overrides"].get(test_id, {})
        entries[test_id] = {
            "id": test_id,
            "kind": "h1",
            "source": h1_source(manifest, test_id),
            "harness": "raw" if test_id in manifest["h1"]["raw"] else "framework",
            "timeout": override.get("timeout", 30),
            "args": override.get("args", []),
            "labels": manifest["labels"]["h1"],
        }
    for source in manifest["h2"]["entries"]:
        item = dict(source)
        item["kind"] = "h2"
        item["timeout"] = item.get("timeout", 30)
        item["labels"] = manifest["labels"]["h2"]
        item["fixtures"] = item.get("fixtures", [])
        item["extra_sources"] = item.get("extra_sources", [])
        item["platforms"] = item.get("platforms", ["darwin", "linux", "windows"])
        entries[item["id"]] = item
    return entries


def active_entries(entries):
    platform = platform_name()
    return {
        test_id: entry
        for test_id, entry in entries.items()
        if entry["kind"] == "h1" or platform in entry["platforms"]
    }


def validate_manifest_data(manifest, root=ROOT):
    require_keys(
        manifest,
        {"schema_version", "labels", "h1", "h2"},
        {"schema_version", "labels", "h1", "h2"},
        "manifest",
    )
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1:
        raise QualificationError("unsupported manifest schema version")
    require_keys(
        manifest["labels"],
        {"h1", "h2"},
        {"h1", "h2"},
        "manifest labels",
    )
    for kind, required_label in (("h1", "h1"), ("h2", "h2")):
        labels = manifest["labels"][kind]
        require_string_list(labels, "{} labels".format(kind))
        if required_label not in labels or len(labels) < 2:
            raise QualificationError(
                "{} needs its suite and a qualification label".format(kind)
            )

    require_keys(
        manifest["h1"],
        {"entries", "raw", "source_overrides", "overrides", "required_roles"},
        {"entries", "raw", "source_overrides", "overrides", "required_roles"},
        "h1 manifest",
    )
    h1 = manifest["h1"]
    require_string_list(h1["entries"], "h1 entries")
    require_string_list(h1["raw"], "h1 raw entries")
    if not set(h1["raw"]).issubset(set(h1["entries"])):
        raise QualificationError("h1 raw entries must be registered")
    if set(h1["source_overrides"]) - set(h1["entries"]):
        raise QualificationError("h1 source override names an unregistered test")
    if set(h1["overrides"]) - set(h1["entries"]):
        raise QualificationError("h1 override names an unregistered test")
    if h1["required_roles"] != {"method-cache": "h1/method-cache"}:
        raise QualificationError("the method-cache correctness role is missing")
    if h1_source(manifest, "h1/method-cache") != "lus-tests/h4/mcache_check.lus":
        raise QualificationError("the method-cache correctness script is omitted")
    if "h1/method-cache" not in h1["raw"]:
        raise QualificationError("the method-cache correctness script needs the raw harness")

    h1_sources = []
    for test_id in h1["entries"]:
        if not test_id.startswith("h1/") or test_id.count("/") != 1:
            raise QualificationError("invalid H1 test id: {}".format(test_id))
        source = h1_source(manifest, test_id)
        source_path = root / source
        if not source_path.is_file():
            raise QualificationError("missing H1 source: {}".format(source))
        h1_sources.append(source)
        text = source_path.read_text(encoding="utf-8")
        uses_framework = "framework.new" in text
        declared_raw = test_id in h1["raw"]
        if uses_framework == declared_raw:
            raise QualificationError(
                "{} has the wrong harness classification".format(test_id)
            )
        if uses_framework and "tests:finish()" not in text:
            raise QualificationError("{} omits tests:finish()".format(test_id))
        override = h1["overrides"].get(test_id, {})
        require_keys(
            override,
            set(),
            {"args", "timeout"},
            "{} override".format(test_id),
        )
        if "args" in override:
            require_string_list(
                override["args"], "{} arguments".format(test_id), allow_empty=True
            )
        if "timeout" in override and (
            type(override["timeout"]) is not int or override["timeout"] <= 0
        ):
            raise QualificationError("{} has an invalid timeout".format(test_id))
    if len(h1_sources) != len(set(h1_sources)):
        raise QualificationError("multiple H1 entries use the same source")
    discovered_h1 = {
        str(path.relative_to(root))
        for path in (root / "lus-tests" / "h1").glob("*.lus")
    }
    registered_h1 = {
        source for source in h1_sources if source.startswith("lus-tests/h1/")
    }
    if discovered_h1 != registered_h1:
        missing = sorted(discovered_h1 - registered_h1)
        stale = sorted(registered_h1 - discovered_h1)
        raise QualificationError(
            "H1 inventory mismatch, unregistered={}, stale={}".format(missing, stale)
        )

    require_keys(
        manifest["h2"],
        {"entries", "required_roles"},
        {"entries", "required_roles"},
        "h2 manifest",
    )
    h2 = manifest["h2"]
    if not isinstance(h2["entries"], list) or not h2["entries"]:
        raise QualificationError("h2 entries must be a nonempty array")
    allowed_h2 = {
        "id",
        "target",
        "source",
        "timeout",
        "fixtures",
        "extra_sources",
        "sqlite_include",
        "wasm_include",
        "lus_c_args",
        "platforms",
    }
    h2_ids = []
    h2_targets = []
    h2_sources = []
    fixture_consumers = {}
    for index, item in enumerate(h2["entries"]):
        where = "h2 entry {}".format(index)
        require_keys(item, {"id", "target", "source"}, allowed_h2, where)
        test_id = item["id"]
        if not isinstance(test_id, str) or not test_id.startswith("h2/"):
            raise QualificationError("{} has an invalid id".format(where))
        for field in ("target", "source"):
            if not isinstance(item[field], str) or not item[field]:
                raise QualificationError("{} has an invalid {}".format(where, field))
        if "timeout" in item and (
            type(item["timeout"]) is not int or item["timeout"] <= 0
        ):
            raise QualificationError("{} has an invalid timeout".format(test_id))
        for field in ("sqlite_include", "wasm_include", "lus_c_args"):
            if field in item and not isinstance(item[field], bool):
                raise QualificationError("{} must be boolean in {}".format(field, test_id))
        platforms = item.get("platforms", ["darwin", "linux", "windows"])
        require_string_list(platforms, "{} platforms".format(test_id))
        if not set(platforms).issubset({"darwin", "linux", "windows"}):
            raise QualificationError("{} has an unknown platform".format(test_id))
        fixtures = item.get("fixtures", [])
        extras = item.get("extra_sources", [])
        require_string_list(fixtures, "{} fixtures".format(test_id), allow_empty=True)
        require_string_list(extras, "{} extra sources".format(test_id), allow_empty=True)
        for relative in [item["source"]] + fixtures + extras:
            if not (root / relative).is_file():
                raise QualificationError("{} references missing {}".format(test_id, relative))
        for fixture in fixtures:
            fixture_consumers.setdefault(fixture, []).append(test_id)
        h2_ids.append(test_id)
        h2_targets.append(item["target"])
        h2_sources.append(item["source"])
    for values, label in (
        (h2_ids, "H2 ids"),
        (h2_targets, "H2 targets"),
        (h2_sources, "H2 sources"),
    ):
        if len(values) != len(set(values)):
            raise QualificationError("{} contain duplicates".format(label))
    discovered_h2 = {
        str(path.relative_to(root))
        for path in (root / "lus-tests" / "h2").glob("test_*.c")
    }
    if discovered_h2 != set(h2_sources):
        missing = sorted(discovered_h2 - set(h2_sources))
        stale = sorted(set(h2_sources) - discovered_h2)
        raise QualificationError(
            "H2 inventory mismatch, unregistered={}, stale={}".format(missing, stale)
        )
    idle_role = h2["required_roles"].get("idle-worker")
    expected_idle = {
        "fixture": "lus-tests/h4/worker_idle.lus",
        "consumer": "h2/worker-idle",
    }
    if idle_role != expected_idle:
        raise QualificationError("the idle-worker role is missing")
    if fixture_consumers.get(expected_idle["fixture"]) != [expected_idle["consumer"]]:
        raise QualificationError("the idle-worker fixture lacks one explicit consumer")

    all_ids = h1["entries"] + h2_ids
    if len(all_ids) != len(set(all_ids)):
        raise QualificationError("test ids are duplicated across harnesses")
    return entry_map(manifest)


def validate_skip_allowlist(data, entries):
    require_keys(
        data,
        {"schema_version", "skips", "sanitizer_limitations"},
        {"schema_version", "skips", "sanitizer_limitations"},
        "platform skip allowlist",
    )
    if (
        type(data["schema_version"]) is not int
        or data["schema_version"] != 1
        or not isinstance(data["skips"], list)
    ):
        raise QualificationError("invalid platform skip allowlist schema")
    seen = set()
    for index, rule in enumerate(data["skips"]):
        where = "skip rule {}".format(index)
        require_keys(
            rule,
            {"test", "platforms", "sanitizers", "description", "reason"},
            {"test", "platforms", "sanitizers", "description", "reason"},
            where,
        )
        if rule["test"] not in entries or entries[rule["test"]]["kind"] != "h1":
            raise QualificationError("{} names an unknown H1 test".format(where))
        require_string_list(rule["platforms"], "{} platforms".format(where))
        require_string_list(rule["sanitizers"], "{} sanitizers".format(where))
        if not set(rule["platforms"]).issubset({"darwin", "linux", "windows"}):
            raise QualificationError("{} has an unknown platform".format(where))
        if not set(rule["sanitizers"]).issubset({"none", "address"}):
            raise QualificationError("{} has an unknown sanitizer".format(where))
        key = (
            rule["test"],
            tuple(rule["platforms"]),
            tuple(rule["sanitizers"]),
            rule["description"],
            rule["reason"],
        )
        if key in seen:
            raise QualificationError("duplicate platform skip rule")
        seen.add(key)
    limitations = data["sanitizer_limitations"]
    if not isinstance(limitations, dict):
        raise QualificationError("sanitizer limitations must be an object")
    darwin = limitations.get("darwin", {}).get("leak_detection", {})
    if darwin.get("requested") is not True or darwin.get("runtime_status") != "unavailable":
        raise QualificationError("the macOS leak-runtime limitation is missing")
    return data["skips"]


def load_validated():
    manifest = read_json(MANIFEST_PATH)
    entries = validate_manifest_data(manifest)
    skips_data = read_json(SKIPS_PATH)
    skips = validate_skip_allowlist(skips_data, entries)
    return manifest, entries, skips_data, skips


def platform_name():
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    return sys.platform


def sanitizer_name(environment=None):
    environment = environment or os.environ
    value = environment.get("LUS_TEST_SANITIZER", "none")
    if value not in {"none", "address"}:
        raise QualificationError("unknown test sanitizer: {}".format(value))
    return value


def parse_framework_output(test_id, stdout, skips):
    result_lines = [line for line in stdout.splitlines() if line.startswith(RESULT_PREFIX)]
    if len(result_lines) != 1:
        raise QualificationError(
            "{} emitted {} framework result records".format(test_id, len(result_lines))
        )
    try:
        result = json.loads(result_lines[0][len(RESULT_PREFIX):])
    except ValueError as error:
        raise QualificationError("{} emitted invalid result JSON: {}".format(test_id, error))
    required = {"name", "tests", "passed", "failed", "soft_failed", "skipped"}
    require_keys(result, required, required, "{} result".format(test_id))
    for key in required - {"name"}:
        if type(result[key]) is not int or result[key] < 0:
            raise QualificationError("{} result has invalid {}".format(test_id, key))
    if result["passed"] + result["failed"] + result["soft_failed"] != result["tests"]:
        raise QualificationError("{} result counts do not add up".format(test_id))
    if result["failed"]:
        raise QualificationError("{} reports hard failures".format(test_id))
    if result["soft_failed"]:
        raise QualificationError("{} reports soft failures".format(test_id))

    events = []
    for line in stdout.splitlines():
        if not line.startswith(EVENT_PREFIX):
            continue
        try:
            event = json.loads(line[len(EVENT_PREFIX):])
        except ValueError as error:
            raise QualificationError("{} emitted invalid event JSON: {}".format(test_id, error))
        require_keys(
            event,
            {"kind", "description", "reason"},
            {"kind", "description", "reason"},
            "{} event".format(test_id),
        )
        if event["kind"] != "skip":
            raise QualificationError("{} emitted an unknown event".format(test_id))
        events.append(event)
    if result["skipped"] != len(events):
        raise QualificationError("{} skip count does not match its events".format(test_id))

    current_platform = platform_name()
    current_sanitizer = sanitizer_name()
    for event in events:
        allowed = any(
            rule["test"] == test_id
            and current_platform in rule["platforms"]
            and current_sanitizer in rule["sanitizers"]
            and event["description"] == rule["description"]
            and event["reason"] == rule["reason"]
            for rule in skips
        )
        if not allowed:
            raise QualificationError(
                "{} used an unexpected skip on {} with {}: {} ({})".format(
                    test_id,
                    current_platform,
                    current_sanitizer,
                    event["description"],
                    event["reason"],
                )
            )


def invoke(command, cwd=ROOT, environment=None):
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    return completed


def run_entry(entry, program, skips):
    if entry["kind"] == "h1":
        command = [program] + entry["args"] + [entry["source"]]
    else:
        command = [program]
    completed = invoke(command)
    if completed.returncode != 0:
        raise QualificationError(
            "{} child process exited with {}".format(entry["id"], completed.returncode)
        )
    if entry["kind"] == "h1" and entry["harness"] == "framework":
        parse_framework_output(entry["id"], completed.stdout, skips)


def records_command():
    manifest, entries, _, _ = load_validated()
    for test_id in manifest["h1"]["entries"]:
        entry = entries[test_id]
        print(
            "|".join(
                ["h1", test_id, str(entry["timeout"]), ",".join(entry["labels"])]
            )
        )
    for item in manifest["h2"]["entries"]:
        entry = entries[item["id"]]
        if platform_name() not in entry["platforms"]:
            continue
        print(
            "|".join(
                [
                    "h2",
                    entry["id"],
                    entry["target"],
                    entry["source"],
                    str(entry["timeout"]),
                    ",".join(entry["labels"]),
                    "true" if entry.get("sqlite_include") else "false",
                    "true" if entry.get("wasm_include") else "false",
                    "true" if entry.get("lus_c_args") else "false",
                    ",".join(entry["extra_sources"]),
                ]
            )
        )


def validate_intro(build_dir, entries):
    entries = active_entries(entries)
    intro_path = Path(build_dir) / "meson-info" / "intro-tests.json"
    tests = read_json(intro_path)
    if not isinstance(tests, list):
        raise QualificationError("Meson test introspection must be an array")
    by_name = {}
    for item in tests:
        by_name.setdefault(item.get("name"), []).append(item)
    for test_id, entry in entries.items():
        matches = by_name.get(test_id, [])
        if len(matches) != 1:
            raise QualificationError(
                "Meson registers {} {} times".format(test_id, len(matches))
            )
        item = matches[0]
        suites = set(item.get("suite", []))
        expected_suites = {"lus:" + label for label in entry["labels"]}
        if not expected_suites.issubset(suites):
            raise QualificationError(
                "{} is missing suites or labels: {}".format(
                    test_id, sorted(expected_suites - suites)
                )
            )
        command = item.get("cmd", [])
        if "run" not in command or "--id" not in command or test_id not in command:
            raise QualificationError("{} bypasses the qualification runner".format(test_id))
    for name in by_name:
        if isinstance(name, str) and (name.startswith("h1/") or name.startswith("h2/")):
            if name not in entries:
                raise QualificationError("Meson registers an unknown test: {}".format(name))
    for name in QUALIFICATION_META_TESTS:
        matches = by_name.get(name, [])
        if len(matches) != 1:
            raise QualificationError("Meson must register {} once".format(name))
        suites = set(matches[0].get("suite", []))
        required = {"lus:h1", "lus:h2", "lus:qualification"}
        if not required.issubset(suites):
            raise QualificationError("{} is missing gate suites".format(name))


def expect_failure(fn, label):
    try:
        fn()
    except QualificationError:
        return
    raise QualificationError("self-test did not reject {}".format(label))


def self_test_manifest(manifest, skips_data):
    changed = copy.deepcopy(manifest)
    changed["h1"]["entries"].append(changed["h1"]["entries"][0])
    expect_failure(lambda: validate_manifest_data(changed), "a duplicate test")

    changed = copy.deepcopy(manifest)
    changed["h1"]["entries"].remove("h1/enum")
    expect_failure(lambda: validate_manifest_data(changed), "an unregistered H1 file")

    changed = copy.deepcopy(manifest)
    changed["h2"]["entries"] = [
        entry for entry in changed["h2"]["entries"] if entry["id"] != "h2/worker-idle"
    ]
    expect_failure(lambda: validate_manifest_data(changed), "an omitted idle-worker test")

    changed = copy.deepcopy(manifest)
    changed["h1"]["required_roles"] = {}
    expect_failure(lambda: validate_manifest_data(changed), "an omitted method-cache role")

    changed = copy.deepcopy(manifest)
    changed["labels"]["h2"] = ["h2"]
    expect_failure(lambda: validate_manifest_data(changed), "a missing qualification label")

    changed = copy.deepcopy(manifest)
    changed["schema_version"] = True
    expect_failure(
        lambda: validate_manifest_data(changed), "a boolean manifest schema version"
    )

    changed = copy.deepcopy(manifest)
    changed["h1"]["overrides"]["h1/enum"] = {"timeout": True}
    expect_failure(lambda: validate_manifest_data(changed), "a boolean H1 timeout")

    changed = copy.deepcopy(manifest)
    changed["h2"]["entries"][0]["timeout"] = True
    expect_failure(lambda: validate_manifest_data(changed), "a boolean H2 timeout")

    changed_skips = copy.deepcopy(skips_data)
    changed_skips["schema_version"] = True
    expect_failure(
        lambda: validate_skip_allowlist(changed_skips, entry_map(manifest)),
        "a boolean skip schema version",
    )


def write_fixture(directory, name, body):
    path = Path(directory) / name
    path.write_text(body, encoding="utf-8")
    return str(path)


def self_test_runner(program, skips):
    prelude = (
        'global require, error, pledge\n'
        'pledge("load", "fs:read=./lus-tests/*", "seal")\n'
        'local framework = require("lus-tests.framework")\n'
        'local tests = framework.new("qualification-fixture")\n'
    )
    with tempfile.TemporaryDirectory(prefix="lus-qualification-") as directory:
        teardown = write_fixture(
            directory,
            "teardown.lus",
            prelude
            + 'tests:after(function() error("teardown failed") end)\n'
            + 'tests:it("body", function() end)\n'
            + "tests:finish()\n",
        )
        soft = write_fixture(
            directory,
            "soft.lus",
            prelude
            + 'tests:soft("soft", function() error("soft failed") end)\n'
            + "tests:finish()\n",
        )
        skipped = write_fixture(
            directory,
            "skip.lus",
            prelude
            + 'tests:skip("unapproved", "self-test")\n'
            + "tests:finish()\n",
        )
        missing_finish = write_fixture(
            directory,
            "missing-finish.lus",
            prelude + 'tests:it("body", function() end)\n',
        )
        child_failure = write_fixture(
            directory,
            "child-failure.lus",
            "global os\nos.exit(9)\n",
        )
        cases = [
            ("teardown", teardown),
            ("soft failure", soft),
            ("unexpected skip", skipped),
            ("missing finish", missing_finish),
        ]
        for label, source in cases:
            entry = {
                "id": "h1/qualification-fixture",
                "kind": "h1",
                "source": source,
                "harness": "framework",
                "args": [],
            }
            expect_failure(lambda entry=entry: run_entry(entry, program, skips), label)

        child_entry = {
            "id": "h1/qualification-child-failure",
            "kind": "h1",
            "source": child_failure,
            "harness": "raw",
            "args": [],
        }
        expect_failure(
            lambda: run_entry(child_entry, program, skips), "a child process failure"
        )

    boolean_count = RESULT_PREFIX + json.dumps(
        {
            "name": "qualification-fixture",
            "tests": True,
            "passed": 1,
            "failed": 0,
            "soft_failed": 0,
            "skipped": 0,
        }
    )
    expect_failure(
        lambda: parse_framework_output(
            "h1/qualification-fixture", boolean_count, skips
        ),
        "a boolean framework result count",
    )


def validate_results(build_dir, entries):
    entries = active_entries(entries)
    log_path = Path(build_dir) / "meson-logs" / "testlog.json"
    try:
        lines = log_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise QualificationError("cannot read {}: {}".format(log_path, error))
    records = []
    for line in lines:
        if line.strip():
            try:
                records.append(json.loads(line))
            except ValueError as error:
                raise QualificationError("invalid Meson test log: {}".format(error))
    found = {}
    meta = {"validate": [], "self-test": []}
    for record in records:
        command = record.get("command", [])
        if "--id" in command:
            index = command.index("--id")
            if index + 1 >= len(command):
                raise QualificationError("test log has a truncated --id argument")
            test_id = command[index + 1]
            found.setdefault(test_id, []).append(record)
        elif "validate" in command:
            meta["validate"].append(record)
        elif "self-test" in command:
            meta["self-test"].append(record)
    for test_id in entries:
        matches = found.get(test_id, [])
        if len(matches) != 1:
            raise QualificationError(
                "test log contains {} {} times".format(test_id, len(matches))
            )
        result = matches[0]
        if result.get("result") != "OK" or result.get("is_fail") is not False:
            raise QualificationError("{} did not pass qualification".format(test_id))
        if result.get("returncode") != 0:
            raise QualificationError("{} returned a failing child status".format(test_id))
    extras = sorted(set(found) - set(entries))
    if extras:
        raise QualificationError("test log contains unknown tests: {}".format(extras))
    for name, matches in meta.items():
        if len(matches) != 1:
            raise QualificationError(
                "test log contains qualification/{} {} times".format(
                    name, len(matches)
                )
            )
        result = matches[0]
        if (
            result.get("result") != "OK"
            or result.get("is_fail") is not False
            or result.get("returncode") != 0
        ):
            raise QualificationError("qualification/{} did not pass".format(name))
    h1_count = sum(1 for item in entries.values() if item["kind"] == "h1")
    h2_count = sum(1 for item in entries.values() if item["kind"] == "h2")
    return {
        "h1": h1_count,
        "h2": h2_count,
        "functional": h1_count + h2_count,
        "qualification": len(QUALIFICATION_META_TESTS),
        "total": h1_count + h2_count + len(QUALIFICATION_META_TESTS),
    }


def validate_sanitizer_build(build_dir):
    info_dir = Path(build_dir) / "meson-info"
    compilers = read_json(info_dir / "intro-compilers.json")
    try:
        compiler = compilers["host"]["c"]
    except (KeyError, TypeError):
        raise QualificationError("sanitizer build has no host C compiler record")
    if compiler.get("id") != "clang":
        raise QualificationError("sanitizer qualification requires Clang")

    options = read_json(info_dir / "intro-buildoptions.json")
    if not isinstance(options, list):
        raise QualificationError("sanitizer build options must be an array")
    values = {
        option.get("name"): option.get("value")
        for option in options
        if isinstance(option, dict)
    }
    sanitizers = values.get("b_sanitize")
    if not isinstance(sanitizers, list) or set(sanitizers) != {
        "address",
        "undefined",
    }:
        raise QualificationError("sanitizer build needs address and undefined")
    if values.get("buildtype") != "debug":
        raise QualificationError("sanitizer build needs the debug build type")
    if values.get("b_lto") is not False:
        raise QualificationError("sanitizer build must disable LTO")
    if values.get("b_lundef") is not False:
        raise QualificationError("sanitizer build must disable undefined-symbol checks")
    return {
        "id": compiler["id"],
        "version": compiler.get("version"),
        "full_version": compiler.get("full_version"),
    }


def validate_thread_sanitizer_build(build_dir):
    info_dir = Path(build_dir) / "meson-info"
    compilers = read_json(info_dir / "intro-compilers.json")
    try:
        compiler = compilers["host"]["c"]
    except (KeyError, TypeError):
        raise QualificationError("thread sanitizer build has no host C compiler record")
    if compiler.get("id") != "clang":
        raise QualificationError("thread sanitizer qualification requires Clang")

    options = read_json(info_dir / "intro-buildoptions.json")
    if not isinstance(options, list):
        raise QualificationError("thread sanitizer build options must be an array")
    values = {
        option.get("name"): option.get("value")
        for option in options
        if isinstance(option, dict)
    }
    sanitizers = values.get("b_sanitize")
    if not isinstance(sanitizers, list) or sanitizers != ["thread"]:
        raise QualificationError("thread sanitizer build needs only thread")
    if values.get("buildtype") != "debug":
        raise QualificationError("thread sanitizer build needs the debug build type")
    if values.get("b_lto") is not False:
        raise QualificationError("thread sanitizer build must disable LTO")
    if values.get("b_lundef") is not False:
        raise QualificationError(
            "thread sanitizer build must disable undefined-symbol checks"
        )
    return {
        "id": compiler["id"],
        "version": compiler.get("version"),
        "full_version": compiler.get("full_version"),
    }


THREAD_SANITIZER_TESTS = (
    "h1/worker",
    "h1/worker2",
    "h2/worker",
    "h2/worker-idle",
)


def validate_thread_results(build_dir, entries):
    active = active_entries(entries)
    missing_manifest = sorted(set(THREAD_SANITIZER_TESTS) - set(active))
    if missing_manifest:
        raise QualificationError(
            "thread sanitizer tests are absent from the manifest: {}".format(
                missing_manifest
            )
        )
    log_path = Path(build_dir) / "meson-logs" / "testlog.json"
    try:
        lines = log_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise QualificationError("cannot read {}: {}".format(log_path, error))
    records = []
    for line in lines:
        if line.strip():
            try:
                records.append(json.loads(line))
            except ValueError as error:
                raise QualificationError(
                    "invalid thread sanitizer test log: {}".format(error)
                )
    found = {}
    manifest_checks = []
    for record in records:
        command = record.get("command", [])
        if "--id" in command:
            index = command.index("--id")
            if index + 1 >= len(command):
                raise QualificationError(
                    "thread sanitizer test log has a truncated --id argument"
                )
            found.setdefault(command[index + 1], []).append(record)
        elif "validate" in command and "--build-dir" in command:
            manifest_checks.append(record)
    if set(found) != set(THREAD_SANITIZER_TESTS):
        raise QualificationError(
            "thread sanitizer result inventory mismatch, expected={}, actual={}".format(
                sorted(THREAD_SANITIZER_TESTS), sorted(found)
            )
        )
    for test_id in THREAD_SANITIZER_TESTS:
        matches = found[test_id]
        if len(matches) != 1:
            raise QualificationError(
                "thread sanitizer log contains {} {} times".format(
                    test_id, len(matches)
                )
            )
        result = matches[0]
        if (
            result.get("result") != "OK"
            or result.get("is_fail") is not False
            or result.get("returncode") != 0
        ):
            raise QualificationError(
                "{} did not pass thread sanitizer qualification".format(test_id)
            )
    if len(manifest_checks) != 1:
        raise QualificationError(
            "thread sanitizer log contains the manifest check {} times".format(
                len(manifest_checks)
            )
        )
    manifest_result = manifest_checks[0]
    if (
        manifest_result.get("result") != "OK"
        or manifest_result.get("is_fail") is not False
        or manifest_result.get("returncode") != 0
    ):
        raise QualificationError(
            "thread sanitizer manifest qualification did not pass"
        )
    return {
        "functional": len(THREAD_SANITIZER_TESTS),
        "qualification": 1,
        "total": len(THREAD_SANITIZER_TESTS) + 1,
    }


def combine_sanitizer_counts(address_results, thread_results=None):
    if (
        address_results.get("functional")
        != address_results.get("h1", 0) + address_results.get("h2", 0)
        or address_results.get("qualification") != len(QUALIFICATION_META_TESTS)
        or address_results.get("total")
        != address_results.get("functional", 0)
        + address_results.get("qualification", 0)
    ):
        raise QualificationError("invalid address and undefined result counts")
    functional = address_results["functional"]
    qualification = address_results["qualification"]
    if thread_results is not None:
        if (
            thread_results.get("functional") != len(THREAD_SANITIZER_TESTS)
            or thread_results.get("qualification") != 1
            or thread_results.get("total")
            != thread_results.get("functional", 0)
            + thread_results.get("qualification", 0)
        ):
            raise QualificationError("invalid thread sanitizer result counts")
        functional += thread_results["functional"]
        qualification += thread_results["qualification"]
    total = functional + qualification
    return {
        "total": total,
        "passed": total,
        "failed": 0,
        "skipped": 0,
        "functional": functional,
        "qualification": qualification,
    }


def self_test_sanitizer_counts(entries):
    active = active_entries(entries)
    h1_count = sum(1 for item in active.values() if item["kind"] == "h1")
    h2_count = sum(1 for item in active.values() if item["kind"] == "h2")
    address = {
        "h1": h1_count,
        "h2": h2_count,
        "functional": h1_count + h2_count,
        "qualification": len(QUALIFICATION_META_TESTS),
        "total": h1_count + h2_count + len(QUALIFICATION_META_TESTS),
    }
    address_only = combine_sanitizer_counts(address)
    if address_only["total"] != address["total"]:
        raise QualificationError("address-only sanitizer count self-test failed")

    changed = copy.deepcopy(address)
    changed["qualification"] = 1
    expect_failure(
        lambda: combine_sanitizer_counts(changed),
        "an address-only result with a missing qualification check",
    )

    thread = {
        "functional": len(THREAD_SANITIZER_TESTS),
        "qualification": 1,
        "total": len(THREAD_SANITIZER_TESTS) + 1,
    }
    combined = combine_sanitizer_counts(address, thread)
    if combined["total"] != address["total"] + thread["total"]:
        raise QualificationError("combined sanitizer count self-test failed")

    changed = copy.deepcopy(thread)
    changed["functional"] -= 1
    expect_failure(
        lambda: combine_sanitizer_counts(address, changed),
        "a combined result with a missing thread sanitizer test",
    )


def self_test_leak_probe():
    report = "\n".join(LEAK_SANITIZER_REPORT_MARKERS)
    with tempfile.TemporaryDirectory(prefix="lus-leak-probe-") as directory:
        good = write_fixture(
            directory,
            "good.log",
            report + "\nexit_status={}\n".format(LEAK_SANITIZER_EXIT_STATUS),
        )
        result = parse_leak_probe(good, "linux", None)
        if (
            result["runtime_status"] != "available"
            or not result["leak_report_observed"]
            or result["exit_status"] != LEAK_SANITIZER_EXIT_STATUS
        ):
            raise QualificationError("intentional leak probe self-test failed")

        zero = write_fixture(directory, "zero.log", report + "\nexit_status=0\n")
        expect_failure(
            lambda: parse_leak_probe(zero, "linux", None),
            "an intentional leak probe with a successful child status",
        )

        missing_report = write_fixture(
            directory,
            "missing-report.log",
            "exit_status={}\n".format(LEAK_SANITIZER_EXIT_STATUS),
        )
        expect_failure(
            lambda: parse_leak_probe(missing_report, "linux", None),
            "an intentional leak probe without the canonical report",
        )

        ambiguous = write_fixture(
            directory,
            "ambiguous.log",
            report
            + "\nexit_status={}\nexit_status={}\n".format(
                LEAK_SANITIZER_EXIT_STATUS, LEAK_SANITIZER_EXIT_STATUS
            ),
        )
        expect_failure(
            lambda: parse_leak_probe(ambiguous, "linux", None),
            "an intentional leak probe with ambiguous exit status records",
        )


def parse_leak_probe(path, platform, limitation):
    probe_path = Path(path)
    try:
        probe_text = probe_path.read_text(encoding="utf-8")
    except OSError as error:
        raise QualificationError("cannot read {}: {}".format(probe_path, error))
    status_lines = [
        line for line in probe_text.splitlines() if line.startswith("exit_status=")
    ]
    if len(status_lines) != 1:
        raise QualificationError("leak-runtime probe has no unique exit status")
    try:
        status = int(status_lines[0].split("=", 1)[1])
    except ValueError:
        raise QualificationError("leak-runtime probe has an invalid exit status")
    unsupported = "detect_leaks is not supported on this platform" in probe_text
    report_markers = {
        marker: marker in probe_text for marker in LEAK_SANITIZER_REPORT_MARKERS
    }
    report_observed = all(report_markers.values())
    expected_unavailable = limitation and limitation.get("runtime_status") == "unavailable"
    if expected_unavailable:
        if platform != "darwin" or status == 0 or not unsupported or report_observed:
            raise QualificationError(
                "macOS leak-runtime probe did not prove the checked limitation"
            )
        runtime_status = "unavailable"
    else:
        if (
            status != LEAK_SANITIZER_EXIT_STATUS
            or unsupported
            or not report_observed
        ):
            raise QualificationError(
                "LeakSanitizer did not detect the intentional leak with the expected report"
            )
        runtime_status = "available"
    return {
        "requested_option": "detect_leaks=1",
        "probe_kind": "intentional-leak",
        "expected_exit_status": (
            None if expected_unavailable else LEAK_SANITIZER_EXIT_STATUS
        ),
        "exit_status": status,
        "runtime_status": runtime_status,
        "report_markers": report_markers,
        "leak_report_observed": report_observed,
    }


def sanitizer_evidence(
    build_dir, thread_build_dir, output, leak_probe, entries, skips_data
):
    compiler = validate_sanitizer_build(build_dir)
    address_results = validate_results(build_dir, entries)
    thread_compiler = None
    thread_results = None
    if thread_build_dir:
        thread_compiler = validate_thread_sanitizer_build(thread_build_dir)
        thread_results = validate_thread_results(thread_build_dir, entries)
    platform = platform_name()
    leak = {
        "requested": True,
        "runtime_status": "requested",
        "reason": None,
    }
    limitation = skips_data.get("sanitizer_limitations", {}).get(platform, {}).get(
        "leak_detection"
    )
    if limitation:
        leak = copy.deepcopy(limitation)
    probe = parse_leak_probe(leak_probe, platform, limitation)
    if not limitation:
        leak["runtime_status"] = probe["runtime_status"]
    leak["enabled_for_suite"] = probe["runtime_status"] == "available"
    leak["probe"] = probe
    evidence = {
        "schemaVersion": 1,
        "kind": "sanitizer",
        "name": "sanitizer",
        "status": "success",
        "scope": "combined" if thread_build_dir else "address-undefined-only",
        "release_complete": bool(thread_build_dir),
        "platform": platform,
        "compiler": compiler,
        "sanitizers": ["address", "undefined"],
        "leak_detection": leak,
        "counts": combine_sanitizer_counts(address_results, thread_results),
        "tests": {
            "h1": address_results["h1"],
            "h2": address_results["h2"],
            "qualification": address_results["qualification"],
        },
        "address_undefined": {
            "status": "passed",
            "counts": address_results,
        },
    }
    if thread_build_dir:
        evidence["thread_sanitizer"] = {
            "compiler": thread_compiler,
            "options": "halt_on_error=1:abort_on_error=1",
            "tests": list(THREAD_SANITIZER_TESTS),
            "counts": thread_results,
            "status": "passed",
        }
    output_path = Path(output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("meson-records")

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--build-dir")

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--id", required=True)
    run_parser.add_argument("--program", required=True)

    self_parser = subparsers.add_parser("self-test")
    self_parser.add_argument("--program", required=True)

    results_parser = subparsers.add_parser("validate-results")
    results_parser.add_argument("--build-dir", required=True)

    sanitizer_build_parser = subparsers.add_parser("validate-sanitizer-build")
    sanitizer_build_parser.add_argument("--build-dir", required=True)

    thread_build_parser = subparsers.add_parser(
        "validate-thread-sanitizer-build"
    )
    thread_build_parser.add_argument("--build-dir", required=True)

    thread_results_parser = subparsers.add_parser("validate-thread-results")
    thread_results_parser.add_argument("--build-dir", required=True)

    evidence_parser = subparsers.add_parser("sanitizer-evidence")
    evidence_parser.add_argument("--build-dir", required=True)
    evidence_parser.add_argument("--thread-build-dir")
    evidence_parser.add_argument("--leak-probe", required=True)
    evidence_parser.add_argument("--output", required=True)

    args = parser.parse_args()
    manifest, entries, skips_data, skips = load_validated()
    if args.command == "meson-records":
        records_command()
    elif args.command == "validate":
        if args.build_dir:
            validate_intro(args.build_dir, entries)
        print("H1/H2 manifest valid: {} tests".format(len(entries)))
    elif args.command == "run":
        entry = entries.get(args.id)
        if entry is None:
            raise QualificationError("unknown test id: {}".format(args.id))
        run_entry(entry, args.program, skips)
    elif args.command == "self-test":
        self_test_manifest(manifest, skips_data)
        self_test_runner(args.program, skips)
        self_test_sanitizer_counts(entries)
        self_test_leak_probe()
        print("qualification self-test passed")
    elif args.command == "validate-results":
        counts = validate_results(args.build_dir, entries)
        print(
            "H1/H2 result log valid: {} functional tests plus {} qualification checks".format(
                counts["functional"], counts["qualification"]
            )
        )
    elif args.command == "validate-sanitizer-build":
        compiler = validate_sanitizer_build(args.build_dir)
        print("sanitizer build valid: {} {}".format(compiler["id"], compiler["version"]))
    elif args.command == "validate-thread-sanitizer-build":
        compiler = validate_thread_sanitizer_build(args.build_dir)
        print(
            "thread sanitizer build valid: {} {}".format(
                compiler["id"], compiler["version"]
            )
        )
    elif args.command == "validate-thread-results":
        counts = validate_thread_results(args.build_dir, entries)
        print(
            "thread sanitizer result log valid: {} functional tests plus {} qualification checks".format(
                counts["functional"], counts["qualification"]
            )
        )
    elif args.command == "sanitizer-evidence":
        sanitizer_evidence(
            args.build_dir,
            args.thread_build_dir,
            args.output,
            args.leak_probe,
            entries,
            skips_data,
        )


if __name__ == "__main__":
    try:
        main()
    except QualificationError as error:
        print("qualification failed: {}".format(error), file=sys.stderr)
        sys.exit(1)
