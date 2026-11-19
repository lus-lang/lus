#!/usr/bin/env python3
"""Build and validate deterministic Lus release artifacts."""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform as host_platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "release" / "manifest.json"
DEPENDENCIES_PATH = ROOT / "release" / "dependencies.json"
STABLE_RELEASE_DATE = "August 30, 2026"
STABLE_RELEASE_DATE_ISO = "2026-08-30"
PUBLISHER_EXTERNAL_BUILTINS = [
    "assert",
    "crypto",
    "fs",
    "http",
    "https",
    "os",
    "path",
    "querystring",
    "readline",
    "stream",
    "tty",
    "url",
    "util",
]
SANITIZER_H1_COUNT = 108
SANITIZER_H2_COUNT = 11
SANITIZER_QUALIFICATION_COUNT = 2
THREAD_SANITIZER_TESTS = [
    "h1/worker",
    "h1/worker2",
    "h2/worker",
    "h2/worker-idle",
]
LEAK_SANITIZER_REPORT_MARKERS = [
    "ERROR: LeakSanitizer: detected memory leaks",
    "SUMMARY: AddressSanitizer:",
]
VSIX_FIXED_TIMESTAMP = (2026, 8, 30, 0, 0, 0)
VSIX_FILE_EXTERNAL_ATTR = (stat.S_IFREG | 0o644) << 16
VSIX_MEMBERS = {
    "[Content_Types].xml",
    "extension.vsixmanifest",
    "extension/LICENSE.txt",
    "extension/THIRD_PARTY_NOTICES.md",
    "extension/icon.png",
    "extension/language-configuration.json",
    "extension/licenses/LICENSE.EMSCRIPTEN.txt",
    "extension/licenses/LICENSE.LUALS.txt",
    "extension/out/extension.js",
    "extension/package.json",
    "extension/readme.md",
    "extension/syntaxes/lus.tmLanguage.json",
    "extension/wasm/lus.mjs",
    "extension/wasm/lus.wasm",
}


class ReleaseError(RuntimeError):
    pass


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"cannot read {path}: {error}") from error


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def manifest():
    value = read_json(MANIFEST_PATH)
    if value.get("schemaVersion") != 1:
        raise ReleaseError("unsupported release manifest schema")
    return value


def dependencies():
    value = read_json(DEPENDENCIES_PATH)
    if value.get("schemaVersion") != 1:
        raise ReleaseError("unsupported dependency metadata schema")
    return value


def shell_assignment(path: Path, name: str) -> str | None:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    match = re.search(rf'^{re.escape(name)}="([^"]+)"', text, re.MULTILINE)
    return match.group(1) if match else None


def dependency_integrity_errors(root: Path, value: dict) -> list[str]:
    """Validate checked-in generated data and its immutable source pins."""
    errors = []
    generated = value.get("generatedData", {})
    sqlite = generated.get("sqlite", {})
    required_hashes = {
        "generatedData.sqlite.sourceSha256": sqlite.get("sourceSha256"),
        "generatedData.sqlite.cSha256": sqlite.get("cSha256"),
        "generatedData.sqlite.headerSha256": sqlite.get("headerSha256"),
        "generatedData.sqlite.patchSha256": sqlite.get("patchSha256"),
        "generatedData.tzdataSourceSha256": generated.get("tzdataSourceSha256"),
        "generatedData.tzcodeSourceSha256": generated.get("tzcodeSourceSha256"),
        "generatedData.tzdataGeneratedSha256": generated.get(
            "tzdataGeneratedSha256"
        ),
        "generatedData.cldrSourceSha256": generated.get("cldrSourceSha256"),
        "generatedData.cldrGeneratedSha256": generated.get(
            "cldrGeneratedSha256"
        ),
        "caresSource.sha256": value.get("caresSource", {}).get("sha256"),
    }
    for name, digest in required_hashes.items():
        if not re.fullmatch(r"[0-9a-f]{64}", str(digest or "")):
            errors.append(f"{name} must be one lowercase SHA-256 digest")

    checked_files = {
        "lus/vendor/sqlite/sqlite3.c": sqlite.get("cSha256"),
        "lus/vendor/sqlite/sqlite3.h": sqlite.get("headerSha256"),
        "scripts/sqlite-lus-vfs.patch": sqlite.get("patchSha256"),
        "lus/src/ltzdata.c": generated.get("tzdataGeneratedSha256"),
        "lus/src/lwinzones.c": generated.get("cldrGeneratedSha256"),
    }
    for relative, expected in checked_files.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"generated dependency file is missing: {relative}")
        elif re.fullmatch(r"[0-9a-f]{64}", str(expected or "")):
            actual = sha256(path)
            if actual != expected:
                errors.append(
                    f"{relative} SHA-256 is {actual}, expected {expected}"
                )

    script_pins = {
        "scripts/update-sqlite.sh": {
            "SQLITE_RELEASE": sqlite.get("release"),
            "SQLITE_SHA256": sqlite.get("sourceSha256"),
            "SQLITE_C_SHA256": sqlite.get("cSha256"),
            "SQLITE_H_SHA256": sqlite.get("headerSha256"),
            "SQLITE_PATCH_SHA256": sqlite.get("patchSha256"),
        },
        "scripts/update-tzdata.sh": {
            "TZDATA_VERSION": generated.get("tzdata"),
            "TZDATA_SHA256": generated.get("tzdataSourceSha256"),
            "TZCODE_SHA256": generated.get("tzcodeSourceSha256"),
        },
        "scripts/update-winzones.sh": {
            "CLDR_VERSION": generated.get("cldr"),
            "CLDR_SHA256": generated.get("cldrSourceSha256"),
        },
    }
    for relative, pins in script_pins.items():
        path = root / relative
        for name, expected in pins.items():
            actual = shell_assignment(path, name)
            if actual != expected:
                errors.append(f"{relative} {name} is {actual!r}, expected {expected!r}")

    cares = value.get("caresSource", {})
    version = str(cares.get("version", ""))
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", version):
        errors.append("caresSource.version must be an exact three-part version")
    expected_url = (
        f"https://github.com/c-ares/c-ares/releases/download/v{version}/"
        f"c-ares-{version}.tar.gz"
    )
    if cares.get("url") != expected_url:
        errors.append("caresSource.url does not identify the pinned c-ares version")
    return errors


def workflow_release_errors(
    workflow_text: str,
    dependency_values: dict,
    install_workflow_text: str | None = None,
) -> list[str]:
    errors = []
    site_test = "pnpm --dir lus-site test"
    site_build = "pnpm build:local-wasm"
    if site_test not in workflow_text:
        errors.append("build workflow must run the complete site tests")
    elif site_build not in workflow_text or workflow_text.index(
        site_test
    ) > workflow_text.index(site_build):
        errors.append("build workflow must run site tests before the site build")
    if "python3 lus-install/test_install.py" not in workflow_text:
        errors.append("build workflow is missing deterministic Unix installer smoke")
    for required in (
        "shellcheck --version",
        'test "$actual" = "$SHELLCHECK_VERSION"',
    ):
        if required not in workflow_text:
            errors.append(f"lint workflow does not fail closed on ShellCheck: {required}")
    if "scripts/release.py binary-versions" not in workflow_text:
        errors.append("build workflow does not validate actual lus and lusc versions")
    for required in (
        "scripts/release.py stable-release",
        '--tag "$GITHUB_REF_NAME"',
        '--commit "$GITHUB_SHA"',
        "--notes-output release-notes.md",
        '--target "$GITHUB_SHA"',
        "--notes-file release-notes.md",
    ):
        if required not in workflow_text:
            errors.append(f"stable release workflow is missing: {required}")
    if '--notes "Draft release with verified build evidence."' in workflow_text:
        errors.append("stable release notes must come from CHANGELOG.md")
    if workflow_text.count("lus-tests/h4/build_pinned_cares.sh") < 2:
        errors.append("release and H4 builds must both use the pinned c-ares source")
    sanitize_job = re.search(
        r"^  sanitize:\n(?P<body>.*?)(?=^  benchmark:)",
        workflow_text,
        flags=re.DOTALL | re.MULTILINE,
    )
    sanitizer_body = sanitize_job.group("body") if sanitize_job else ""
    for required in (
        "libclang-rt-dev",
        "curl",
        "make",
        "lus-tests/h4/build_pinned_cares.sh",
        'cares_root="$RUNNER_TEMP/sanitizer-cares"',
        'PKG_CONFIG_PATH="$cares_pc" pkg-config --modversion libcares',
        'echo "PKG_CONFIG_PATH=$cares_pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"',
    ):
        if required not in sanitizer_body:
            errors.append(f"sanitizer qualification is missing pinned input: {required}")
    if "libc-ares-dev" in sanitizer_body:
        errors.append("sanitizer qualification must not resolve the system c-ares")
    abi_step = re.search(
        r"- name: Compare the stable 1[.]6[.]2 ABI(?P<body>.*?)"
        r"(?=\n[ ]{6}- name:|\Z)",
        workflow_text,
        flags=re.DOTALL,
    )
    if abi_step is None:
        errors.append("build workflow is missing the stable ABI qualification")
    else:
        abi_body = abi_step.group("body")
        for required in (
            "git archive v1.6.2",
            "-Db_lto=false",
            'meson compile -C "$baseline_build"',
            '--baseline-library "$baseline_library"',
        ):
            if required not in abi_body:
                errors.append(f"non-LTO ABI baseline preparation is missing: {required}")
        if "lus-tests/h4/prepare_baseline.sh" in abi_body:
            errors.append("ABI qualification must not use the LTO H4 baseline helper")
    build_job = re.search(
        r"^  build:\n(?P<body>.*?)(?=^  build-wasm:)",
        workflow_text,
        flags=re.DOTALL | re.MULTILINE,
    )
    if build_job is None or not re.search(
        r"uses: actions/checkout@[0-9a-f]{40}[^\n]*\n"
        r"[ ]+with:\n[ ]+fetch-depth: 0",
        build_job.group("body") if build_job else "",
    ):
        errors.append("build job must fetch the reviewed v1.6.2 ABI tag")
    for required in (
        "Build pinned static c-ares on Windows",
        "caresSource.sha256",
        "Get-FileHash -Algorithm SHA256",
        "-DCARES_STATIC=ON",
        "-DCARES_SHARED=OFF",
    ):
        if required not in workflow_text:
            errors.append(f"Windows release c-ares pinning is missing: {required}")
    tool_pins = {
        "pkgconfiglite": dependency_values.get("pkgconfiglite"),
        "innoSetup": dependency_values.get("innoSetup"),
    }
    for name, version in tool_pins.items():
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", str(version or "")):
            errors.append(f"{name} must be an exact numeric version")
    pkgconfig_pattern = re.compile(
        rf"choco install pkgconfiglite\s+--version\s+"
        rf"{re.escape(str(tool_pins['pkgconfiglite']))}\b"
    )
    if len(pkgconfig_pattern.findall(workflow_text)) < 2:
        errors.append("Windows builds must install the pinned pkgconfiglite version")
    inno_pattern = re.compile(
        rf"choco install innosetup\s+--version\s+"
        rf"{re.escape(str(tool_pins['innoSetup']))}\b"
    )
    if len(inno_pattern.findall(workflow_text)) != 1:
        errors.append("Windows installer must install the pinned Inno Setup version")
    for required in (
        "--name unix-installer --status success",
        "--name windows-installer --status success",
        "evidence/unix-installer.json",
        "evidence/windows-installer.json",
    ):
        if required not in workflow_text:
            errors.append(f"installer evidence wiring is missing: {required}")
    for name, description in (
        ("alpineImage", "immutable Alpine image"),
        ("debianSmokeImage", "immutable Debian smoke image"),
    ):
        if dependency_values.get(name) not in workflow_text:
            errors.append(f"build workflow does not use the {description}")
    for name in ("alpineImage", "debianSmokeImage", "devcontainerImage"):
        if not re.fullmatch(
            r"[^\s@]+@sha256:[0-9a-f]{64}",
            str(dependency_values.get(name, "")),
        ):
            errors.append(f"{name} must be an immutable container digest")
    if "--provenance" not in workflow_text or workflow_text.count(
        "--provenance"
    ) < 2:
        errors.append("toolchain evidence must classify workflow provenance")
    if install_workflow_text is not None and (
        "::warning::" in install_workflow_text
        or "skipped" in install_workflow_text.lower()
    ):
        errors.append("installer workflows must not warn or skip qualification")
    return errors


def canonical_version() -> str:
    header = ROOT / manifest()["versionSource"]
    text = header.read_text(encoding="utf-8")
    fields = []
    for macro in (
        "LUA_VERSION_MAJOR_N",
        "LUA_VERSION_MINOR_N",
        "LUA_VERSION_RELEASE_N",
    ):
        values = re.findall(
            rf"^#define[ \t]+{macro}[ \t]+([0-9]+)[ \t]*$",
            text,
            flags=re.MULTILINE,
        )
        if len(values) != 1:
            raise ReleaseError(
                f"{header} must define {macro} exactly once as a decimal integer"
            )
        fields.append(str(int(values[0])))
    return ".".join(fields)


def expand(value: str, version: str | None = None) -> str:
    return value.replace("{version}", version or canonical_version())


def expected_assets() -> list[str]:
    data = manifest()
    version = canonical_version()
    names = []
    for spec in data["platforms"].values():
        names.append(expand(spec["archive"], version))
        names.extend(spec["compatibilityAssets"].values())
    for spec in data["components"].values():
        if "archive" in spec:
            names.append(expand(spec["archive"], version))
        if "asset" in spec:
            names.append(expand(spec["asset"], version))
        if "compatibilityAsset" in spec:
            names.append(spec["compatibilityAsset"])
        names.extend(spec.get("compatibilityAssets", {}).values())
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise ReleaseError(f"duplicate release asset names: {', '.join(duplicates)}")
    return sorted(names)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    if not root.is_dir():
        raise ReleaseError(f"required directory is missing: {root}")
    digest = hashlib.sha256()
    files = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ReleaseError(f"evidence trees must not contain symlinks: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix().encode("utf-8")
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
        files += 1
    if files == 0:
        raise ReleaseError(f"evidence tree contains no files: {root}")
    return digest.hexdigest()


def source_date_epoch() -> int:
    value = os.environ.get("SOURCE_DATE_EPOCH")
    if value:
        try:
            epoch = int(value)
        except ValueError as error:
            raise ReleaseError("SOURCE_DATE_EPOCH must be an integer") from error
        if epoch < 0:
            raise ReleaseError("SOURCE_DATE_EPOCH must not be negative")
        return epoch
    try:
        result = subprocess.run(
            ["git", "show", "-s", "--format=%ct", "HEAD"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return int(result.stdout.strip())
    except (OSError, subprocess.SubprocessError, ValueError):
        return int(manifest()["sourceDateEpochFallback"])


def copy_file(source: Path, destination: Path, executable: bool = False) -> None:
    if not source.is_file():
        raise ReleaseError(f"required file is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o755 if executable else 0o644)


def copy_tree(source: Path, destination: Path) -> None:
    if not source.is_dir():
        raise ReleaseError(f"required directory is missing: {source}")
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if path.is_symlink():
            raise ReleaseError(f"release trees must not contain symlinks: {path}")
        if path.is_dir():
            (destination / relative).mkdir(parents=True, exist_ok=True)
        elif path.is_file():
            mode = path.stat().st_mode
            copy_file(path, destination / relative, bool(mode & stat.S_IXUSR))


def artifact_license_set(name: str) -> dict:
    value = manifest().get("licenseSets", {}).get(name)
    if not isinstance(value, dict):
        raise ReleaseError(f"unknown artifact license set: {name}")
    return value


def artifact_license_targets(name: str) -> list[str]:
    value = artifact_license_set(name)
    return ["THIRD_PARTY_NOTICES.md"] + [
        Path(relative).name for relative in value.get("licenses", [])
    ]


def copy_licenses(destination: Path, name: str) -> None:
    value = artifact_license_set(name)
    copy_file(
        ROOT / value["notice"],
        destination / "THIRD_PARTY_NOTICES.md",
    )
    for relative in value["licenses"]:
        copy_file(ROOT / relative, destination / Path(relative).name)
    expected = sorted(artifact_license_targets(name))
    actual = sorted(
        path.name for path in destination.iterdir() if path.is_file()
    )
    if actual != expected:
        raise ReleaseError(
            f"{name} license inventory mismatch, "
            f"expected={expected}, actual={actual}"
        )


def normalized_mode(path: Path) -> int:
    if path.is_dir():
        return 0o755
    if path.stat().st_mode & stat.S_IXUSR:
        return 0o755
    return 0o644


def archive_paths(root: Path):
    yield root, Path(root.name)
    for path in sorted(root.rglob("*")):
        yield path, Path(root.name) / path.relative_to(root)


def write_tar_gz(root: Path, output: Path, epoch: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as raw:
        with gzip.GzipFile(
            filename="",
            mode="wb",
            fileobj=raw,
            compresslevel=9,
            mtime=epoch,
        ) as compressed:
            with tarfile.open(
                fileobj=compressed,
                mode="w",
                format=tarfile.PAX_FORMAT,
            ) as archive:
                for path, archive_path in archive_paths(root):
                    info = archive.gettarinfo(str(path), str(archive_path))
                    info.uid = 0
                    info.gid = 0
                    info.uname = "root"
                    info.gname = "root"
                    info.mtime = epoch
                    info.mode = normalized_mode(path)
                    if path.is_file():
                        with path.open("rb") as source:
                            archive.addfile(info, source)
                    else:
                        archive.addfile(info)


def zip_datetime(epoch: int) -> tuple[int, int, int, int, int, int]:
    minimum = 315532800
    value = dt.datetime.fromtimestamp(max(epoch, minimum), tz=dt.timezone.utc)
    return (value.year, value.month, value.day, value.hour, value.minute, value.second)


def write_zip(root: Path, output: Path, epoch: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        output,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for path, archive_path in archive_paths(root):
            name = archive_path.as_posix()
            if path.is_dir():
                name += "/"
                payload = b""
            else:
                payload = path.read_bytes()
            info = zipfile.ZipInfo(name, zip_datetime(epoch))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = normalized_mode(path) << 16
            archive.writestr(info, payload, compress_type=zipfile.ZIP_DEFLATED)


def write_archive(root: Path, output: Path, format_name: str) -> None:
    epoch = source_date_epoch()
    if format_name == "tar.gz":
        write_tar_gz(root, output, epoch)
    elif format_name == "zip":
        write_zip(root, output, epoch)
    else:
        raise ReleaseError(f"unsupported archive format: {format_name}")


def build_option(build_dir: Path, name: str):
    path = build_dir / "meson-info" / "intro-buildoptions.json"
    values = read_json(path)
    matches = [entry.get("value") for entry in values if entry.get("name") == name]
    if len(matches) != 1:
        raise ReleaseError(f"Meson option {name} is missing from {path}")
    return matches[0]


def release_commit() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ReleaseError("cannot determine the release commit") from error
    value = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ReleaseError("the release commit is not a full Git object id")
    return value


def changelog_section(root: Path, version: str) -> tuple[str, str]:
    path = root / "CHANGELOG.md"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ReleaseError(f"cannot read {path}: {error}") from error
    headings = list(re.finditer(r"^## ([^\n]+)$", text, flags=re.MULTILINE))
    matches = [
        (index, match)
        for index, match in enumerate(headings)
        if re.match(rf"^{re.escape(version)}(?:\s|$)", match.group(1))
    ]
    if len(matches) != 1:
        raise ReleaseError(
            f"CHANGELOG.md must contain exactly one {version} section"
        )
    index, heading = matches[0]
    end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
    body = text[heading.end() : end].strip()
    if not body:
        raise ReleaseError(f"CHANGELOG.md {version} section is empty")
    return heading.group(0), body + "\n"


def frontmatter(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ReleaseError(f"cannot read {path}: {error}") from error
    if not text.startswith("---\n"):
        raise ReleaseError(f"frontmatter is missing from {path}")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise ReleaseError(f"frontmatter is unterminated in {path}")
    result = {}
    for line in text[4:end].splitlines():
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        result[name.strip()] = value.strip().strip('"\'')
    return result


def stable_metadata_errors(root: Path, version: str) -> list[str]:
    errors = []
    try:
        heading, notes = changelog_section(root, version)
    except ReleaseError as error:
        return [str(error)]
    if heading != f"## {version}":
        errors.append(f"CHANGELOG.md stable heading must be exactly '## {version}'")
    release_date = re.findall(r"^\*\*Release date:\*\* (.+)$", notes, re.MULTILINE)
    if release_date != [STABLE_RELEASE_DATE]:
        errors.append(
            f"CHANGELOG.md {version} release date must be {STABLE_RELEASE_DATE}"
        )
    if re.search(r"\b(?:WIP|TBD)\b", heading + "\n" + notes, re.IGNORECASE):
        errors.append(f"CHANGELOG.md {version} section contains WIP or TBD")

    specification_paths = []
    for directory in ("stdlib", "capi"):
        specification_paths.extend((root / "lus-spec" / directory).rglob("*.md"))
    for path in sorted(specification_paths):
        try:
            metadata = frontmatter(path)
        except ReleaseError as error:
            errors.append(str(error))
            continue
        if metadata.get("since") == version and metadata.get("stability") != "stable":
            errors.append(
                f"{path.relative_to(root)} is since {version} but is not stable"
            )

    for path in sorted((root / "lus-site" / "src" / "manual").glob("acquis-*.mdx")):
        try:
            metadata = frontmatter(path)
        except ReleaseError as error:
            errors.append(str(error))
            continue
        if metadata.get("draft") == "true":
            errors.append(f"{path.relative_to(root)} is still a draft acquis")

    news = root / "lus-site" / "src" / "news" / f"changelog-{version}.md"
    if not news.is_file():
        errors.append(f"missing dated {version} site news entry: {news.relative_to(root)}")
    else:
        try:
            metadata = frontmatter(news)
        except ReleaseError as error:
            errors.append(str(error))
        else:
            if metadata.get("title") != f"Lus {version}":
                errors.append(f"{news.relative_to(root)} has the wrong title")
            if metadata.get("date") != STABLE_RELEASE_DATE_ISO:
                errors.append(
                    f"{news.relative_to(root)} date must be {STABLE_RELEASE_DATE_ISO}"
                )
    return errors


def resolve_tag_commit(tag: str) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ReleaseError(f"cannot resolve stable release tag {tag}") from error
    value = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ReleaseError(f"stable release tag {tag} did not resolve to a commit")
    return value


def command_stable_release(args) -> None:
    version = canonical_version()
    expected_tag = f"v{version}"
    if args.tag != expected_tag:
        raise ReleaseError(
            f"stable tag is {args.tag!r}, expected exactly {expected_tag!r}"
        )
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise ReleaseError("stable release target must be a full lowercase Git SHA")
    head = release_commit()
    if args.commit != head:
        raise ReleaseError(
            f"stable release target {args.commit} does not match checkout {head}"
        )
    tagged = resolve_tag_commit(args.tag)
    if tagged != args.commit:
        raise ReleaseError(
            f"stable tag {args.tag} targets {tagged}, not release commit {args.commit}"
        )
    errors = stable_metadata_errors(ROOT, version)
    if errors:
        raise ReleaseError("\n".join(errors))
    _heading, notes = changelog_section(ROOT, version)
    output = Path(args.notes_output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(notes, encoding="utf-8")


def binary_version_output(path: Path) -> str:
    try:
        result = subprocess.run(
            [str(path), "-v"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ReleaseError(f"cannot query version from {path}: {error}") from error
    output = (result.stdout + "\n" + result.stderr).strip()
    return output


def command_binary_versions(args) -> None:
    expected = f"Lus {canonical_version()}"
    for name in ("lus", "lusc"):
        path = Path(getattr(args, name)).resolve()
        output = binary_version_output(path)
        versions = re.findall(r"\bLus ([0-9]+\.[0-9]+\.[0-9]+)\b", output)
        if versions != [canonical_version()] or not output.startswith(expected):
            raise ReleaseError(
                f"{name} reports {output!r}, expected one {expected} version"
            )


def sdk_metadata_path(platform_name: str) -> str:
    sdk = manifest()["sdk"]
    if platform_name == "windows-x64":
        return sdk["cmakeConfig"]
    return sdk["pkgConfig"]


def write_build_metadata(
    destination: Path, platform_name: str, runtime_dir: Path, build_dir: Path
) -> None:
    compiler_path = build_dir / "meson-info" / "intro-compilers.json"
    compiler = read_json(compiler_path).get("host", {}).get("c", {})
    value = {
        "schemaVersion": 1,
        "version": canonical_version(),
        "commit": release_commit(),
        "platform": platform_name,
        "toolchain": {
            "compiler": compiler.get("full_version") or compiler.get("version"),
            "compilerId": compiler.get("id"),
        },
        "runtime": {
            "buildDirectoryKind": "separate-optimized-runtime",
            "lto": bool(build_option(runtime_dir, "b_lto")),
        },
        "sdk": {
            "libraryType": "static",
            "lto": False,
            "externalDependencies": [
                "brotli",
                "c-ares",
                "lz4",
                "openssl",
                "sqlite3",
                "threads",
                "zlib",
                "zstd",
            ],
        },
    }
    write_json(destination, value)


def validate_sdk(sdk_root: Path, build_dir: Path, platform_name: str) -> None:
    data = manifest()
    spec = data["platforms"][platform_name]
    if build_option(build_dir, "b_lto") is not False:
        raise ReleaseError("the distributable SDK library must be built with b_lto=false")
    if build_option(build_dir, "pkgconfig.relocatable") is not True:
        raise ReleaseError("the SDK must be built with pkgconfig.relocatable=true")
    required = data["sdk"]["headers"] + spec["libraries"]
    required.append(sdk_metadata_path(platform_name))
    for relative in required:
        if not (sdk_root / relative).is_file():
            raise ReleaseError(f"SDK file is missing: {sdk_root / relative}")
    metadata = sdk_root / sdk_metadata_path(platform_name)
    text = metadata.read_text(encoding="utf-8")
    if platform_name == "windows-x64":
        if "Lus::lus" not in text or "_IMPORT_PREFIX" not in text:
            raise ReleaseError("Windows CMake metadata is not relocatable")
    else:
        prefix_lines = [
            line for line in text.splitlines() if line.startswith("prefix=")
        ]
        if prefix_lines != ["prefix=${pcfiledir}/../.."]:
            raise ReleaseError(
                f"pkg-config metadata is not relocatable: {prefix_lines}"
            )


def command_assemble_platform(args) -> None:
    data = manifest()
    if args.platform not in data["platforms"]:
        raise ReleaseError(f"unknown platform: {args.platform}")
    spec = data["platforms"][args.platform]
    runtime_dir = Path(args.runtime_dir).resolve()
    sdk_root = Path(args.sdk_root).resolve()
    build_dir = Path(args.sdk_build_dir).resolve()
    if runtime_dir == build_dir:
        raise ReleaseError(
            "optimized runtime tools and the non-LTO SDK must use separate builds"
        )
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    validate_sdk(sdk_root, build_dir, args.platform)
    version = canonical_version()
    archive_name = expand(spec["archive"], version)
    root_name = archive_name.removesuffix(".tar.gz").removesuffix(".zip")
    with tempfile.TemporaryDirectory(prefix="lus-release-") as temporary:
        root = Path(temporary) / root_name
        for source_name, destination_name in spec["executables"].items():
            copy_file(
                runtime_dir / source_name,
                root / "bin" / destination_name,
                executable=True,
            )
        sdk_paths = data["sdk"]["headers"] + spec["libraries"]
        sdk_paths.append(sdk_metadata_path(args.platform))
        for relative in sdk_paths:
            copy_file(sdk_root / relative, root / relative)
        write_build_metadata(
            root / data["sdk"]["buildMetadata"],
            args.platform,
            runtime_dir,
            build_dir,
        )
        license_set = spec["licenseSet"]
        license_directory = artifact_license_set(license_set)["directory"]
        copy_licenses(root / license_directory, license_set)
        write_archive(root, output / archive_name, spec["format"])
        for relative, asset_name in spec["compatibilityAssets"].items():
            copy_file(root / relative, output / asset_name, executable=True)


def command_assemble_tree(args) -> None:
    data = manifest()
    spec = data["components"].get(args.component)
    if spec is None or "archive" not in spec:
        raise ReleaseError(f"component is not an archive: {args.component}")
    source = Path(args.input).resolve()
    for relative in spec.get("requiredPaths", []):
        if not (source / relative).is_file():
            raise ReleaseError(f"component file is missing: {source / relative}")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive_name = expand(spec["archive"])
    root_name = archive_name.removesuffix(".tar.gz").removesuffix(".zip")
    with tempfile.TemporaryDirectory(prefix="lus-release-") as temporary:
        root = Path(temporary) / root_name
        copy_tree(source, root)
        license_set = spec["licenseSet"]
        license_directory = artifact_license_set(license_set)["directory"]
        copy_licenses(root / license_directory, license_set)
        write_archive(root, output / archive_name, spec["format"])
        for relative, asset_name in spec.get("compatibilityAssets", {}).items():
            copy_file(source / relative, output / asset_name)


def command_copy_component(args) -> None:
    spec = manifest()["components"].get(args.component)
    if spec is None or "asset" not in spec:
        raise ReleaseError(f"component is not a single asset: {args.component}")
    source = Path(args.source).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    executable = args.component in {"unixInstaller", "windowsInstaller"}
    copy_file(source, output / expand(spec["asset"]), executable)
    compatibility = spec.get("compatibilityAsset")
    if compatibility:
        copy_file(source, output / compatibility, executable)


def parse_meson_log(path: Path) -> tuple[list[dict], dict[str, int]]:
    records = []
    counts = {"total": 0, "passed": 0, "failed": 0, "skipped": 0}
    if not path.is_file():
        raise ReleaseError(f"Meson test log is missing: {path}")
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ReleaseError(f"invalid Meson JSON at {path}:{number}") from error
        records.append(record)
        counts["total"] += 1
        result = record.get("result")
        if result == "OK":
            counts["passed"] += 1
        elif result in {"SKIP", "IGNORED"}:
            counts["skipped"] += 1
        else:
            counts["failed"] += 1
    return records, counts


def command_collect_meson(args) -> None:
    records, counts = parse_meson_log(Path(args.log))
    samples = []
    if args.kind == "benchmark":
        for record in records:
            samples.append(
                {
                    "durationSeconds": record.get("duration"),
                    "name": record.get("name"),
                    "result": record.get("result"),
                    "stdout": record.get("stdout", "")[:131072],
                }
            )
    fragment = {
        "schemaVersion": 1,
        "kind": args.kind,
        "name": args.name,
        "status": args.status,
        "counts": counts,
        "samples": samples,
    }
    write_json(Path(args.output), fragment)


def first_line(command: list[str]) -> str | None:
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    output = (result.stdout + "\n" + result.stderr).strip()
    return output.splitlines()[0] if output else None


def tool_version_matches(name: str, actual: str | None, expected: str) -> bool:
    if name == "ninja":
        return actual in {
            expected,
            expected + ".git.kitware.jobserver-pipe-1",
        }
    return actual == expected


def command_environment(args) -> None:
    tools = {}
    commands = {
        "cc": ["cc", "--version"],
        "cl": ["cl"],
        "emcc": ["emcc", "--version"],
        "meson": ["meson", "--version"],
        "ninja": ["ninja", "--version"],
        "node": ["node", "--version"],
        "pnpm": ["pnpm", "--version"],
        "python": [sys.executable, "--version"],
    }
    for name, command in commands.items():
        value = first_line(command)
        if value:
            tools[name] = value
    dependency_values = dependencies()
    if args.build_dir:
        for name in ("meson", "ninja"):
            expected = dependency_values[name]
            actual = tools.get(name)
            if not tool_version_matches(name, actual, expected):
                raise ReleaseError(
                    f"{args.platform} {name} is {actual!r}, expected {expected!r}"
                )
    if args.provenance == "hosted-runner-pinned-emscripten":
        expected_node = f"v{dependency_values['node']}"
        if tools.get("node") != expected_node:
            raise ReleaseError(
                f"WASM Node is {tools.get('node')!r}, expected {expected_node!r}"
            )
        emcc = tools.get("emcc", "")
        if not re.search(
            rf"\b{re.escape(dependency_values['emscripten'])}\b", emcc
        ):
            raise ReleaseError(
                f"WASM emcc is {emcc!r}, expected Emscripten "
                f"{dependency_values['emscripten']}"
            )
    result = {
        "schemaVersion": 1,
        "kind": "toolchain",
        "name": args.platform,
        "host": host_platform.platform(),
        "provenance": {
            "bitReproducible": False,
            "classification": args.provenance,
            "note": (
                "Exact versions and immutable inputs are recorded where supported. "
                "Hosted runner operating systems and tool installations are not "
                "claimed to be bit reproducible."
            ),
        },
        "tools": tools,
    }
    runner = {
        name: os.environ[value]
        for name, value in (
            ("architecture", "RUNNER_ARCH"),
            ("image", "ImageOS"),
            ("imageVersion", "ImageVersion"),
            ("operatingSystem", "RUNNER_OS"),
        )
        if os.environ.get(value)
    }
    if runner:
        result["hostedRunner"] = runner
    if args.build_dir:
        build_dir = Path(args.build_dir)
        compiler_path = build_dir / "meson-info" / "intro-compilers.json"
        dependency_path = build_dir / "meson-info" / "intro-dependencies.json"
        if compiler_path.is_file():
            result["compilers"] = read_json(compiler_path)
        if dependency_path.is_file():
            values = read_json(dependency_path)
            dependency_values = [
                {
                    "name": entry.get("name"),
                    "version": entry.get("version"),
                }
                for entry in values
                if entry.get("name")
            ]
            result["dependencies"] = dependency_values
            cares_version = dependencies()["caresSource"]["version"]
            cares_matches = [
                entry
                for entry in dependency_values
                if entry.get("name") in {"libcares", "c-ares"}
            ]
            if len(cares_matches) != 1:
                raise ReleaseError(
                    f"{args.platform} build must resolve exactly one c-ares dependency"
                )
            if cares_matches[0].get("version") != cares_version:
                raise ReleaseError(
                    f"{args.platform} resolved c-ares "
                    f"{cares_matches[0].get('version')}, expected {cares_version}"
                )
            result["verifiedInputs"] = {
                "c-ares": {
                    "actualVersion": cares_matches[0]["version"],
                    "sourceSha256": dependencies()["caresSource"]["sha256"],
                    "sourceUrl": dependencies()["caresSource"]["url"],
                }
            }
    write_json(Path(args.output), result)


def command_status(args) -> None:
    details = {}
    for field in args.detail:
        if "=" not in field:
            raise ReleaseError(f"status detail must be NAME=VALUE: {field}")
        name, value = field.split("=", 1)
        details[name] = value
    write_json(
        Path(args.output),
        {
            "schemaVersion": 1,
            "kind": "status",
            "name": args.name,
            "status": args.status,
            "details": details,
        },
    )


def command_wasm_evidence(args) -> None:
    dist = Path(args.dist).resolve()
    embedded = Path(args.embedded_tree).resolve()
    node_wasm_proof = Path(args.node_wasm_proof).resolve()
    required = manifest()["components"]["wasm"]["requiredPaths"]
    actual = sorted(
        path.relative_to(dist).as_posix()
        for path in dist.rglob("*")
        if path.is_file()
    )
    if actual != sorted(required):
        raise ReleaseError(
            f"WASM output inventory mismatch, expected={sorted(required)}, actual={actual}"
        )
    if not node_wasm_proof.is_file():
        raise ReleaseError(f"Node WASM parity proof is missing: {node_wasm_proof}")
    if node_wasm_proof.read_bytes() != (dist / "lus.wasm").read_bytes():
        raise ReleaseError("web and Node builds did not produce identical WASM modules")
    write_json(
        Path(args.output),
        {
            "schemaVersion": 1,
            "kind": "status",
            "name": "wasm",
            "status": "success",
            "details": {
                "artifacts": {
                    relative: sha256(dist / relative) for relative in sorted(required)
                },
                "embeddedInputSha256": tree_sha256(embedded),
                "nodeWebModuleParity": {
                    "nodeSha256": sha256(node_wasm_proof),
                    "webSha256": sha256(dist / "lus.wasm"),
                    "result": "byte-equal",
                },
            },
        },
    )


def normalize_vsix(source: Path, output: Path) -> None:
    source_input = Path(source)
    if source_input.is_symlink() or not source_input.is_file():
        raise ReleaseError("raw VSIX must be a regular file")
    source = source_input.resolve()
    output = Path(output).resolve()
    if source == output:
        raise ReleaseError("raw and normalized VSIX paths must differ")
    try:
        with zipfile.ZipFile(source) as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if len(names) != len(set(names)):
                raise ReleaseError("raw VSIX contains duplicate member names")
            if set(names) != VSIX_MEMBERS:
                raise ReleaseError("raw VSIX inventory differs from the release allowlist")
            payloads = {}
            for info in infos:
                name = info.filename
                parts = Path(name.replace("\\", "/")).parts
                if (
                    info.is_dir()
                    or name.startswith("/")
                    or "\\" in name
                    or ".." in parts
                    or info.flag_bits & 0x1
                ):
                    raise ReleaseError(f"raw VSIX member is unsafe: {name}")
                unix_mode = info.external_attr >> 16
                if (
                    info.create_system == 3
                    and unix_mode != 0
                    and not stat.S_ISREG(unix_mode)
                ):
                    raise ReleaseError(f"raw VSIX member is not regular: {name}")
                payloads[name] = archive.read(info)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise ReleaseError(f"cannot normalize VSIX: {error}") from error

    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", allowZip64=False) as archive:
        for name in sorted(payloads):
            info = zipfile.ZipInfo(name, VSIX_FIXED_TIMESTAMP)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.create_version = 20
            info.extract_version = 20
            info.external_attr = VSIX_FILE_EXTERNAL_ATTR
            info.flag_bits = 0
            info.internal_attr = 0
            info.extra = b""
            info.comment = b""
            archive.writestr(info, payloads[name])
    output.chmod(0o644)


def command_normalize_vsix(args) -> None:
    normalize_vsix(Path(args.input), Path(args.output))


def validate_vsix_envelope(archive: zipfile.ZipFile) -> list[str]:
    infos = archive.infolist()
    names = [info.filename for info in infos]
    if len(names) != len(set(names)):
        raise ReleaseError("VSIX contains duplicate member names")
    if set(names) != VSIX_MEMBERS:
        raise ReleaseError(
            "VSIX inventory mismatch, "
            f"expected={sorted(VSIX_MEMBERS)}, actual={sorted(names)}"
        )
    if names != sorted(VSIX_MEMBERS) or archive.comment != b"":
        raise ReleaseError("VSIX archive order or comment is not canonical")
    for info in infos:
        if (
            info.date_time != VSIX_FIXED_TIMESTAMP
            or info.compress_type != zipfile.ZIP_STORED
            or info.create_system != 3
            or info.create_version != 20
            or info.extract_version != 20
            or info.external_attr != VSIX_FILE_EXTERNAL_ATTR
            or info.flag_bits != 0
            or info.internal_attr != 0
            or info.extra != b""
            or info.comment != b""
        ):
            raise ReleaseError(f"VSIX member metadata is not canonical: {info.filename}")
    return names


def open_vsx_publisher_metadata(path: Path) -> dict:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise ReleaseError("Open VSX publisher bundle is not UTF-8") from error
    prefix = "// LUS_OPEN_VSX_PUBLISHER_METADATA "
    begin = "// LUS_OPEN_VSX_PUBLISHER_NOTICE_BEGIN"
    end = "// LUS_OPEN_VSX_PUBLISHER_NOTICE_END"
    if not lines or not lines[0].startswith(prefix):
        raise ReleaseError("Open VSX publisher metadata marker is missing")
    if lines.count(begin) != 1 or lines.count(end) != 1:
        raise ReleaseError("Open VSX publisher notice markers are invalid")
    begin_index = lines.index(begin)
    end_index = lines.index(end)
    if begin_index != 1 or end_index <= begin_index + 1:
        raise ReleaseError("Open VSX publisher notice is empty or misplaced")
    notice_lines = lines[begin_index + 1 : end_index]
    if any(not line.startswith("// ") for line in notice_lines):
        raise ReleaseError("Open VSX publisher notice contains an invalid line")
    notice = "\n".join(line[3:] for line in notice_lines) + "\n"
    try:
        metadata = json.loads(lines[0][len(prefix) :])
    except json.JSONDecodeError as error:
        raise ReleaseError("Open VSX publisher metadata is invalid") from error
    if not isinstance(metadata, dict) or set(metadata) != {
        "externalBuiltins",
        "noticeSha256",
        "ovsxVersion",
        "packages",
        "schemaVersion",
    }:
        raise ReleaseError("Open VSX publisher metadata has an invalid shape")
    if metadata.get("schemaVersion") != 1:
        raise ReleaseError("Open VSX publisher metadata schema is unsupported")
    if metadata.get("ovsxVersion") != dependencies()["ovsx"]:
        raise ReleaseError("Open VSX publisher version differs from the reviewed pin")
    if metadata.get("externalBuiltins") != PUBLISHER_EXTERNAL_BUILTINS:
        raise ReleaseError("Open VSX publisher external builtin inventory changed")
    if metadata.get("noticeSha256") != hashlib.sha256(notice.encode()).hexdigest():
        raise ReleaseError("Open VSX publisher embedded notice digest is invalid")
    packages = metadata.get("packages")
    if not isinstance(packages, list) or not packages:
        raise ReleaseError("Open VSX publisher package inventory is empty")
    keys = []
    for package in packages:
        if not isinstance(package, dict) or set(package) != {
            "license",
            "licenseFiles",
            "name",
            "version",
        }:
            raise ReleaseError("Open VSX publisher package entry is invalid")
        if not all(
            isinstance(package.get(field), str) and package[field]
            for field in ("license", "name", "version")
        ):
            raise ReleaseError("Open VSX publisher package identity is invalid")
        license_files = package.get("licenseFiles")
        if not isinstance(license_files, list) or not license_files:
            raise ReleaseError("Open VSX publisher package license text is missing")
        for license_file in license_files:
            if (
                not isinstance(license_file, dict)
                or set(license_file) != {"name", "sha256"}
                or not isinstance(license_file.get("name"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", str(license_file.get("sha256")))
            ):
                raise ReleaseError("Open VSX publisher package license entry is invalid")
        keys.append(f'{package["name"]}@{package["version"]}')
    if keys != sorted(set(keys)):
        raise ReleaseError("Open VSX publisher package inventory is not canonical")
    if f'ovsx@{dependencies()["ovsx"]}' not in keys:
        raise ReleaseError("Open VSX publisher package inventory omits ovsx")
    return metadata


def command_vsix_evidence(args) -> None:
    vsix = Path(args.vsix).resolve()
    publisher_input = Path(args.publisher)
    if publisher_input.is_symlink():
        raise ReleaseError("Open VSX publisher bundle must be a regular file")
    publisher = publisher_input.resolve()
    node_js = Path(args.node_js).resolve()
    wasm = Path(args.wasm).resolve()
    if (
        not vsix.is_file()
        or not publisher.is_file()
        or publisher.stat().st_size == 0
        or not node_js.is_file()
        or not wasm.is_file()
    ):
        raise ReleaseError("VSIX evidence inputs are incomplete")
    publisher_spec = manifest()["components"]["vscodePublisher"]
    expected_publisher = expand(publisher_spec["asset"])
    if publisher.name != expected_publisher or publisher.suffix != ".cjs":
        raise ReleaseError("Open VSX publisher bundle has an unexpected name")
    if sha256(publisher) != publisher_spec.get("sha256"):
        raise ReleaseError("Open VSX publisher bundle differs from the tagged digest")
    publisher_metadata = open_vsx_publisher_metadata(publisher)
    source_members = {
        "extension/LICENSE.txt": ROOT / "lus-vscode" / "LICENSE",
        "extension/THIRD_PARTY_NOTICES.md": (
            ROOT / "lus-vscode" / "THIRD_PARTY_NOTICES.md"
        ),
        "extension/icon.png": ROOT / "lus-vscode" / "icon.png",
        "extension/language-configuration.json": (
            ROOT / "lus-vscode" / "language-configuration.json"
        ),
        "extension/licenses/LICENSE.EMSCRIPTEN.txt": (
            ROOT / "licenses" / "LICENSE.EMSCRIPTEN.txt"
        ),
        "extension/licenses/LICENSE.LUALS.txt": (
            ROOT / "licenses" / "LICENSE.LUALS.txt"
        ),
        "extension/out/extension.js": (
            ROOT / "lus-vscode" / "out" / "extension.js"
        ),
        "extension/package.json": ROOT / "lus-vscode" / "package.json",
        "extension/readme.md": ROOT / "lus-vscode" / "README.md",
        "extension/syntaxes/lus.tmLanguage.json": (
            ROOT / "lus-vscode" / "syntaxes" / "lus.tmLanguage.json"
        ),
        "extension/wasm/lus.mjs": node_js,
        "extension/wasm/lus.wasm": wasm,
    }
    generated_members = {"[Content_Types].xml", "extension.vsixmanifest"}
    expected_members = generated_members | set(source_members)
    if expected_members != VSIX_MEMBERS:
        raise ReleaseError("internal VSIX release allowlists disagree")
    with zipfile.ZipFile(vsix) as archive:
        names = validate_vsix_envelope(archive)
        for name in names:
            parts = Path(name.replace("\\", "/")).parts
            if name.startswith("/") or "\\" in name or ".." in parts:
                raise ReleaseError(f"VSIX contains an unsafe member name: {name}")
        for name, source in source_members.items():
            if names.count(name) != 1:
                raise ReleaseError(f"VSIX must contain {name} exactly once")
            if archive.read(name) != source.read_bytes():
                raise ReleaseError(f"VSIX member does not match staged input: {name}")

        try:
            package = json.loads(archive.read("extension/package.json"))
        except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ReleaseError("VSIX package manifest is invalid") from error
        expected_identity = {
            "name": "lus",
            "publisher": "lus",
            "version": canonical_version(),
            "main": "./out/extension.js",
            "extensionKind": ["workspace"],
        }
        for field, expected in expected_identity.items():
            if package.get(field) != expected:
                raise ReleaseError(
                    f"VSIX package manifest has an unexpected {field}: "
                    f"{package.get(field)!r}"
                )

        try:
            xml = ET.fromstring(archive.read("extension.vsixmanifest"))
        except (KeyError, ET.ParseError) as error:
            raise ReleaseError("VSIX XML manifest is invalid") from error
        namespace = {"vsix": "http://schemas.microsoft.com/developer/vsx-schema/2011"}
        identities = xml.findall(".//vsix:Identity", namespace)
        if len(identities) != 1:
            raise ReleaseError("VSIX XML manifest must contain one identity")
        identity = identities[0].attrib
        if (
            identity.get("Id") != "lus"
            or identity.get("Publisher") != "lus"
            or identity.get("Version") != canonical_version()
        ):
            raise ReleaseError("VSIX XML identity does not match Lus release metadata")

        member_hashes = {
            name: hashlib.sha256(archive.read(name)).hexdigest()
            for name in sorted(expected_members)
        }
    write_json(
        Path(args.output),
        {
            "schemaVersion": 1,
            "kind": "status",
            "name": "vscode",
            "status": "success",
            "details": {
                "nodeInputSha256": sha256(node_js),
                "publisherSha256": sha256(publisher),
                "publisher": publisher_metadata,
                "wasmInputSha256": sha256(wasm),
                "vsixSha256": sha256(vsix),
                "version": canonical_version(),
                "members": member_hashes,
                "normalizedArchive": {
                    "compression": "stored",
                    "timestamp": "2026-08-30T00:00:00Z",
                },
            },
        },
    )


def command_quality_gate(args) -> None:
    evidence = manifest()["evidence"]
    permitted = evidence["permittedSkips"]
    if args.event not in permitted:
        raise ReleaseError(f"unknown quality gate event: {args.event}")
    allowed = set(permitted[args.event])
    required = set(evidence["qualityGateJobs"])
    valid_statuses = {"success", "failure", "cancelled", "skipped"}
    jobs = {}
    failures = []
    for value in args.job:
        if "=" not in value:
            raise ReleaseError(f"job result must be NAME=STATUS: {value}")
        name, status_value = value.split("=", 1)
        if name in jobs:
            failures.append(f"duplicate job result: {name}")
        if name not in required:
            failures.append(f"unknown job result: {name}")
        if status_value not in valid_statuses:
            failures.append(f"invalid job status: {name}={status_value}")
        jobs[name] = status_value
        if status_value == "success":
            continue
        if status_value == "skipped" and name in allowed:
            continue
        failures.append(f"{name}={status_value}")
    for name in sorted(required - set(jobs)):
        failures.append(f"missing job result: {name}")
    result = {
        "schemaVersion": 1,
        "kind": "qualityGate",
        "name": "quality-gate",
        "event": args.event,
        "jobs": jobs,
        "permittedSkips": sorted(allowed),
        "status": "failure" if failures else "success",
    }
    if args.output:
        write_json(Path(args.output), result)
    if failures:
        raise ReleaseError("quality gate rejected: " + ", ".join(failures))


def command_collect_assets(args) -> None:
    source = Path(args.artifacts_root).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in expected_assets():
        matches = [path for path in source.rglob(name) if path.is_file()]
        if len(matches) != 1:
            raise ReleaseError(
                f"expected one downloaded copy of {name}, found {len(matches)}"
            )
        copy_file(matches[0], output / name, bool(matches[0].stat().st_mode & stat.S_IXUSR))


def archive_inventory(path: Path) -> list[dict]:
    values = []
    if path.name.endswith(".tar.gz"):
        with tarfile.open(path, "r:gz") as archive:
            for member in sorted(archive.getmembers(), key=lambda item: item.name):
                if not member.isfile():
                    continue
                source = archive.extractfile(member)
                if source is None:
                    raise ReleaseError(f"cannot read {member.name} from {path}")
                payload = source.read()
                values.append(
                    {
                        "path": member.name,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size": len(payload),
                    }
                )
    elif path.suffix in {".zip", ".vsix"}:
        with zipfile.ZipFile(path) as archive:
            for member in sorted(archive.infolist(), key=lambda item: item.filename):
                if member.is_dir():
                    continue
                payload = archive.read(member)
                values.append(
                    {
                        "path": member.filename,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size": len(payload),
                    }
                )
    return values


def load_fragments(root: Path) -> list[dict]:
    values = []
    for path in sorted(root.rglob("*.json")):
        value = read_json(path)
        if not isinstance(value, dict):
            raise ReleaseError(f"invalid evidence fragment: {path}")
        if value.get("schemaVersion") != 1 or not value.get("kind"):
            raise ReleaseError(f"invalid evidence fragment: {path}")
        value["source"] = str(path.relative_to(root))
        values.append(value)
    return values


def json_exact(actual, expected) -> bool:
    """Compare JSON values without treating booleans as integer counts."""
    return json.dumps(actual, sort_keys=True, separators=(",", ":")) == json.dumps(
        expected, sort_keys=True, separators=(",", ":")
    )


def validate_sanitizer_fragment(value: dict) -> None:
    """Require the complete Linux ASAN, UBSAN, and TSan release proof."""
    address_functional = SANITIZER_H1_COUNT + SANITIZER_H2_COUNT
    address_total = address_functional + SANITIZER_QUALIFICATION_COUNT
    thread_functional = len(THREAD_SANITIZER_TESTS)
    thread_qualification = 1
    thread_total = thread_functional + thread_qualification
    expected = {
        "identity": {
            "kind": "sanitizer",
            "name": "sanitizer",
            "status": "success",
            "scope": "combined",
            "release_complete": True,
            "platform": "linux",
            "sanitizers": ["address", "undefined"],
        },
        "tests": {
            "h1": SANITIZER_H1_COUNT,
            "h2": SANITIZER_H2_COUNT,
            "qualification": SANITIZER_QUALIFICATION_COUNT,
        },
        "address_counts": {
            "h1": SANITIZER_H1_COUNT,
            "h2": SANITIZER_H2_COUNT,
            "functional": address_functional,
            "qualification": SANITIZER_QUALIFICATION_COUNT,
            "total": address_total,
        },
        "thread_counts": {
            "functional": thread_functional,
            "qualification": thread_qualification,
            "total": thread_total,
        },
        "counts": {
            "total": address_total + thread_total,
            "passed": address_total + thread_total,
            "failed": 0,
            "skipped": 0,
            "functional": address_functional + thread_functional,
            "qualification": SANITIZER_QUALIFICATION_COUNT
            + thread_qualification,
        },
    }
    actual_identity = {name: value.get(name) for name in expected["identity"]}
    if not json_exact(actual_identity, expected["identity"]):
        raise ReleaseError("sanitizer evidence is not a complete Linux release run")
    if not json_exact(value.get("tests"), expected["tests"]):
        raise ReleaseError("sanitizer evidence has an invalid H1/H2 inventory")
    if not json_exact(value.get("counts"), expected["counts"]):
        raise ReleaseError("sanitizer evidence has invalid combined counts")

    address = value.get("address_undefined")
    if not isinstance(address, dict) or address.get("status") != "passed":
        raise ReleaseError("address and undefined sanitizer evidence did not pass")
    if not json_exact(address.get("counts"), expected["address_counts"]):
        raise ReleaseError("address and undefined sanitizer counts are invalid")

    thread = value.get("thread_sanitizer")
    if not isinstance(thread, dict) or thread.get("status") != "passed":
        raise ReleaseError("thread sanitizer evidence did not pass")
    if thread.get("options") != "halt_on_error=1:abort_on_error=1":
        raise ReleaseError("thread sanitizer halt-on-error options are missing")
    if not json_exact(thread.get("tests"), THREAD_SANITIZER_TESTS):
        raise ReleaseError("thread sanitizer test inventory is invalid")
    if not json_exact(thread.get("counts"), expected["thread_counts"]):
        raise ReleaseError("thread sanitizer counts are invalid")

    for label, compiler in (
        ("address and undefined", value.get("compiler")),
        ("thread", thread.get("compiler")),
    ):
        if (
            not isinstance(compiler, dict)
            or compiler.get("id") != "clang"
            or not isinstance(compiler.get("version"), str)
            or not compiler["version"]
        ):
            raise ReleaseError(f"{label} sanitizer compiler proof is invalid")

    expected_probe = {
        "requested_option": "detect_leaks=1",
        "probe_kind": "intentional-leak",
        "expected_exit_status": 23,
        "exit_status": 23,
        "runtime_status": "available",
        "report_markers": {
            marker: True for marker in LEAK_SANITIZER_REPORT_MARKERS
        },
        "leak_report_observed": True,
    }
    expected_leak = {
        "requested": True,
        "runtime_status": "available",
        "reason": None,
        "enabled_for_suite": True,
        "probe": expected_probe,
    }
    if not json_exact(value.get("leak_detection"), expected_leak):
        raise ReleaseError("Linux leak sanitizer evidence is incomplete")


def validate_fragments(values: list[dict], event: str) -> None:
    requirements = manifest()["evidence"]
    keys = [(value.get("kind"), value.get("name")) for value in values]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        raise ReleaseError(f"duplicate evidence fragments: {duplicates}")
    tests = {value.get("name"): value for value in values if value["kind"] == "test"}
    tools = {
        value.get("name"): value for value in values if value["kind"] == "toolchain"
    }
    statuses = {
        value.get("name"): value
        for value in values
        if value["kind"] in {"benchmark", "sanitizer", "status"}
    }
    if "sanitizer" in requirements["requiredStatuses"]:
        sanitizer_fragments = [
            value
            for value in values
            if value.get("name") == "sanitizer"
            and value.get("kind") in {"benchmark", "sanitizer", "status"}
        ]
        if (
            len(sanitizer_fragments) != 1
            or sanitizer_fragments[0].get("kind") != "sanitizer"
        ):
            raise ReleaseError(
                "expected exactly one dedicated sanitizer evidence fragment"
            )
    for name in requirements["requiredTestPlatforms"]:
        value = tests.get(name)
        if value is None or value.get("status") != "success":
            raise ReleaseError(f"missing successful test evidence for {name}")
        if value.get("counts", {}).get("failed") != 0:
            raise ReleaseError(f"test evidence reports failures for {name}")
        if value.get("counts", {}).get("total", 0) <= 0:
            raise ReleaseError(f"test evidence contains no tests for {name}")
    for name in requirements["requiredToolchainPlatforms"]:
        value = tools.get(name)
        if value is None:
            raise ReleaseError(f"missing toolchain evidence for {name}")
        if not value.get("tools") and not value.get("compilers"):
            raise ReleaseError(f"empty toolchain evidence for {name}")
        provenance = value.get("provenance")
        if not isinstance(provenance, dict) or not provenance.get("classification"):
            raise ReleaseError(f"toolchain evidence omits provenance for {name}")
        if provenance.get("bitReproducible") is not False:
            raise ReleaseError(
                f"toolchain evidence for {name} must not claim bit reproducibility"
            )
        if name != "wasm":
            expected_cares = dependencies()["caresSource"]
            verified = value.get("verifiedInputs", {}).get("c-ares", {})
            if (
                verified.get("actualVersion") != expected_cares["version"]
                or verified.get("sourceSha256") != expected_cares["sha256"]
                or verified.get("sourceUrl") != expected_cares["url"]
            ):
                raise ReleaseError(
                    f"toolchain evidence does not prove pinned c-ares for {name}"
                )
    for name in requirements["requiredStatuses"]:
        value = statuses.get(name)
        if value is None or value.get("status") != "success":
            raise ReleaseError(f"missing successful status evidence for {name}")
        if value.get("kind") in {"benchmark", "sanitizer"}:
            counts = value.get("counts", {})
            if counts.get("total", 0) <= 0 or counts.get("failed") != 0:
                raise ReleaseError(f"invalid count evidence for {name}")
        if name == "sanitizer":
            validate_sanitizer_fragment(value)
    gates = [value for value in values if value["kind"] == "qualityGate"]
    if len(gates) != 1:
        raise ReleaseError(f"expected one quality gate fragment, found {len(gates)}")
    gate = gates[0]
    if gate.get("event") != event or gate.get("status") != "success":
        raise ReleaseError("quality gate evidence does not match the release event")


def command_finalize(args) -> None:
    assets_dir = Path(args.assets).resolve()
    fragment_dir = Path(args.fragments).resolve()
    names = expected_assets()
    actual = sorted(path.name for path in assets_dir.iterdir() if path.is_file())
    unexpected = sorted(set(actual) - set(names))
    missing = sorted(set(names) - set(actual))
    if missing or unexpected:
        raise ReleaseError(
            f"release inventory mismatch, missing={missing}, unexpected={unexpected}"
        )
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise ReleaseError("release commit must be a full lowercase Git SHA")
    if args.commit != release_commit():
        raise ReleaseError("release commit does not match the checked-out candidate")
    integrity_errors = dependency_integrity_errors(ROOT, dependencies())
    if integrity_errors:
        raise ReleaseError("\n".join(integrity_errors))
    fragments = load_fragments(fragment_dir)
    validate_fragments(fragments, args.event)
    asset_values = []
    for name in names:
        path = assets_dir / name
        asset_values.append(
            {
                "archiveInventory": archive_inventory(path),
                "name": name,
                "sha256": sha256(path),
                "size": path.stat().st_size,
            }
        )
    evidence = {
        "schemaVersion": 1,
        "commit": args.commit,
        "version": canonical_version(),
        "dependencies": dependencies(),
        "verifiedGeneratedInputs": {
            "cldr": {
                "generatedSha256": sha256(ROOT / "lus/src/lwinzones.c"),
                "sourceSha256": dependencies()["generatedData"][
                    "cldrSourceSha256"
                ],
            },
            "sqlite": {
                "cSha256": sha256(ROOT / "lus/vendor/sqlite/sqlite3.c"),
                "headerSha256": sha256(ROOT / "lus/vendor/sqlite/sqlite3.h"),
                "patchSha256": sha256(ROOT / "scripts/sqlite-lus-vfs.patch"),
                "sourceSha256": dependencies()["generatedData"]["sqlite"][
                    "sourceSha256"
                ],
            },
            "tzdata": {
                "generatedSha256": sha256(ROOT / "lus/src/ltzdata.c"),
                "sourceSha256": dependencies()["generatedData"][
                    "tzdataSourceSha256"
                ],
                "tzcodeSourceSha256": dependencies()["generatedData"][
                    "tzcodeSourceSha256"
                ],
            },
        },
        "permittedSkips": manifest()["evidence"]["permittedSkips"].get(
            args.event, []
        ),
        "fragments": fragments,
        "assets": asset_values,
    }
    evidence_path = assets_dir / "release-evidence.json"
    write_json(evidence_path, evidence)
    checksum_paths = [assets_dir / name for name in names] + [evidence_path]
    checksum_text = "".join(
        f"{sha256(path)}  {path.name}\n" for path in sorted(checksum_paths)
    )
    (assets_dir / "SHA256SUMS").write_text(checksum_text, encoding="utf-8")


def check_action_pins(expected_actions: dict[str, dict]) -> list[str]:
    errors = []
    seen = set()
    for action, metadata in expected_actions.items():
        if not isinstance(metadata, dict):
            errors.append(f"dependency metadata for {action} is not an object")
            continue
        if not re.fullmatch(r"[0-9a-f]{40}", str(metadata.get("sha", ""))):
            errors.append(f"dependency metadata for {action} has an invalid SHA")
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", str(metadata.get("version", ""))):
            errors.append(f"dependency metadata for {action} has an invalid version")
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = re.search(r"\buses:[ \t]*([^# \t]+)", line)
            if not match:
                continue
            reference = match.group(1)
            if reference.startswith("./"):
                continue
            parsed = re.fullmatch(r"([^@]+)@([0-9a-f]{40})", reference)
            if parsed is None:
                errors.append(f"{path.relative_to(ROOT)}:{number} has an unpinned action")
                continue
            action, revision = parsed.groups()
            metadata = expected_actions.get(action)
            if metadata is None:
                errors.append(f"{path.relative_to(ROOT)}:{number} uses untracked action {action}")
            elif revision != metadata.get("sha"):
                errors.append(
                    f"{path.relative_to(ROOT)}:{number} does not match the pinned {action} revision"
                )
            seen.add(action)
    missing = sorted(set(expected_actions) - seen)
    if missing:
        errors.append("dependency metadata lists unused actions: " + ", ".join(missing))
    return errors


def publish_workflow_errors(text: str, dependency_values: dict) -> list[str]:
    errors = []
    for name, expected in {
        "NODE_VERSION": dependency_values["node"],
        "OVSX_VERSION": dependency_values["ovsx"],
    }.items():
        values = re.findall(
            rf'^[ \t]+{name}:[ \t]+"([^"]+)"$',
            text,
            flags=re.MULTILINE,
        )
        if values != [expected]:
            errors.append(f"publish workflow {name} is {values}, expected {expected}")

    forbidden = {
        "actions/checkout@": "check out release source",
        "corepack ": "activate a package manager",
        "npm ": "run npm",
        "npx ": "resolve publisher code with npx",
        "pnpm ": "run pnpm",
        "yarn ": "run yarn",
        "vsce package": "rebuild the VSIX",
        "scripts/release.py": "depend on checked-out release tooling",
        "registry.npmjs.org": "access the npm registry",
    }
    for needle, description in forbidden.items():
        if needle in text:
            errors.append(f"publish workflow must not {description}")

    required = {
        'contents/release/manifest.json?ref=$TAG': (
            "load the publisher digest from the tagged source tree"
        ),
        "expected_publisher_sha=$(node -e": (
            "parse the tagged publisher digest without release code"
        ),
        'publisher="lus-$version-open-vsx-publisher.cjs"': (
            "name the immutable publisher release asset"
        ),
        '--pattern "$publisher"': "download the publisher release asset",
        'for name in "$vsix" "$publisher"': "verify both release inputs",
        'test "$(find . -maxdepth 1 -type f | wc -l)" -eq 3': (
            "reject extra or missing release inputs"
        ),
        "sha256sum --check --strict PUBLISH-SUMS": "verify exact release bytes",
        'node "$publisher_path" --version': "smoke the verified publisher",
        'chmod 0444 "$vsix" "$publisher" PUBLISH-SUMS': (
            "make both verified inputs read-only"
        ),
        'echo "PUBLISHER_PATH=$publisher_path" >> "$GITHUB_ENV"': (
            "retain the verified publisher path"
        ),
        'echo "PUBLISH_INPUTS_DIR=$PWD" >> "$GITHUB_ENV"': (
            "retain the verified checksum directory"
        ),
        'echo "EXPECTED_PUBLISHER_SHA256=$expected_publisher_sha" >> "$GITHUB_ENV"': (
            "retain the tagged publisher digest"
        ),
        'run: node "$PUBLISHER_PATH" "$VSIX_PATH"': (
            "execute only the verified local publisher"
        ),
        "gh release download": "download release assets",
        "SHA256SUMS": "download release checksums",
    }
    for needle, description in required.items():
        if needle not in text:
            errors.append(f"publish workflow must {description}: {needle}")

    secret = "OVSX_PAT: ${{ secrets.OVSX_PAT }}"
    if text.count(secret) != 1:
        errors.append("publish workflow must expose OVSX_PAT exactly once")
    if text.count('node "$PUBLISHER_PATH" "$VSIX_PATH"') != 1:
        errors.append("publish workflow must invoke the local publisher exactly once")
    anchor_check = (
        'test "$(sha256sum "$publisher" | awk \'{ print $1 }\')" = '
        '"$expected_publisher_sha"'
    )
    if text.count(anchor_check) != 2:
        errors.append("publish workflow must enforce the tagged publisher digest twice")
    post_anchor_check = (
        'test "$(sha256sum "$PUBLISHER_PATH" | awk \'{ print $1 }\')" = '
        '"$EXPECTED_PUBLISHER_SHA256"'
    )
    if text.count(post_anchor_check) != 1:
        errors.append("publish workflow must recheck the tagged digest after publication")
    checksum = "sha256sum --check --strict PUBLISH-SUMS"
    checksum_positions = [match.start() for match in re.finditer(checksum, text)]
    if len(checksum_positions) != 3:
        errors.append(
            "publish workflow must verify both inputs before and after the smoke and publication"
        )
    ordered = [
        "expected_publisher_sha=$(node -e",
        anchor_check,
        'chmod 0444 "$vsix" "$publisher" PUBLISH-SUMS',
        'node "$publisher_path" --version',
        secret,
        'run: node "$PUBLISHER_PATH" "$VSIX_PATH"',
    ]
    if len(checksum_positions) == 3 and all(value in text for value in ordered):
        positions = [text.index(value) for value in ordered]
        anchor_positions = [
            match.start() for match in re.finditer(re.escape(anchor_check), text)
        ]
        expected_order = [
            positions[0],
            checksum_positions[0],
            positions[1],
            positions[2],
            positions[3],
            checksum_positions[1],
            anchor_positions[1] if len(anchor_positions) == 2 else -1,
            positions[4],
            positions[5],
            checksum_positions[2],
            text.index(post_anchor_check) if post_anchor_check in text else -1,
        ]
        if expected_order != sorted(expected_order) or len(set(expected_order)) != 11:
            errors.append(
                "publish workflow must anchor, verify, and smoke read-only inputs before exposing OVSX_PAT"
            )
    return errors


def command_check(_args) -> None:
    version = canonical_version()
    errors = []
    meson_text = (ROOT / "lus" / "meson.build").read_text(encoding="utf-8")
    meson_versions = re.findall(r"^  version: '([0-9]+\.[0-9]+\.[0-9]+)',", meson_text, re.MULTILINE)
    if meson_versions != [version]:
        errors.append(f"lus/meson.build version is {meson_versions}, expected {version}")
    vscode = read_json(ROOT / "lus-vscode" / "package.json")
    if vscode.get("version") != version:
        errors.append("lus-vscode/package.json does not match lua.h")
    required_vsix_licenses = {
        "licenses/LICENSE.EMSCRIPTEN.txt",
        "licenses/LICENSE.LUALS.txt",
    }
    if not required_vsix_licenses <= set(vscode.get("files", [])):
        errors.append("VSIX package allowlist omits required license files")
    deps = dependencies()
    errors.extend(dependency_integrity_errors(ROOT, deps))
    if (
        vscode.get("devDependencies", {}).get("@devcontainers/cli")
        != deps.get("devcontainersCli")
    ):
        errors.append("lus-vscode Dev Containers CLI does not match dependency metadata")
    if vscode.get("devDependencies", {}).get("ovsx") != deps.get("ovsx"):
        errors.append("lus-vscode Open VSX CLI does not match dependency metadata")
    devcontainer = read_json(
        ROOT
        / "lus-vscode"
        / "test"
        / "devcontainer"
        / ".devcontainer"
        / "devcontainer.json"
    )
    if devcontainer.get("image") != deps.get("devcontainerImage"):
        errors.append("VS Code qualification image does not match dependency metadata")
    wasm_build_text = (ROOT / "lus" / "wasm" / "build.sh").read_text(
        encoding="utf-8"
    )
    expected_stack = f"-s STACK_SIZE={deps.get('wasmStackBytes')}"
    if expected_stack not in wasm_build_text:
        errors.append("WASM stack size does not match dependency metadata")
    vcpkg = read_json(ROOT / "release" / "vcpkg.json")
    if vcpkg.get("version-string") != version:
        errors.append("release/vcpkg.json does not match lua.h")
    vcpkg_configuration = read_json(ROOT / "release" / "vcpkg-configuration.json")
    baseline = vcpkg_configuration.get("default-registry", {}).get("baseline")
    if baseline != deps.get("vcpkgBaseline"):
        errors.append("the vcpkg baseline does not match dependency metadata")
    expected_manager = f"pnpm@{deps['pnpm']}"
    for relative in ("lus-vscode/package.json", "lus-site/package.json"):
        value = read_json(ROOT / relative)
        if value.get("packageManager") != expected_manager:
            errors.append(f"{relative} must set packageManager to {expected_manager}")
    for relative in manifest()["licenses"]:
        if not (ROOT / relative).is_file():
            errors.append(f"missing release license file: {relative}")
    license_catalog = set(manifest()["licenses"])
    license_sets = manifest().get("licenseSets", {})
    for name, value in license_sets.items():
        if not isinstance(value, dict) or set(value) != {
            "directory",
            "notice",
            "licenses",
        }:
            errors.append(f"release license set {name} has an invalid shape")
            continue
        directory = PurePosixPath(str(value["directory"]))
        if (
            directory.is_absolute()
            or not directory.parts
            or any(part in {"", ".", ".."} for part in directory.parts)
        ):
            errors.append(f"release license set {name} has an unsafe directory")
        sources = [value["notice"], *value["licenses"]]
        if len(sources) != len(set(sources)):
            errors.append(f"release license set {name} repeats a source file")
        missing_sources = sorted(set(sources) - license_catalog)
        if missing_sources:
            errors.append(
                f"release license set {name} uses unlisted files: {missing_sources}"
            )
        targets = ["THIRD_PARTY_NOTICES.md"] + [
            Path(relative).name for relative in value["licenses"]
        ]
        if len(targets) != len(set(targets)):
            errors.append(f"release license set {name} repeats an artifact filename")
    for name, value in manifest()["platforms"].items():
        if value.get("licenseSet") not in license_sets:
            errors.append(f"release platform {name} has no valid license set")
    for name, value in manifest()["components"].items():
        if "archive" in value and value.get("licenseSet") not in license_sets:
            errors.append(f"release component {name} has no valid license set")
    native_licenses = license_sets.get("native", {})
    if native_licenses.get("directory") != manifest()["sdk"]["licenseDirectory"]:
        errors.append("native license directory does not match the SDK inventory")

    site_package = read_json(ROOT / "lus-site" / "package.json")
    site_dependencies = site_package.get("dependencies", {})
    site_dev_dependencies = site_package.get("devDependencies", {})
    site_licenses = set(license_sets.get("site", {}).get("licenses", []))
    redistributed = manifest().get("redistributedPackages", {}).get("site", {})
    if not isinstance(redistributed, dict) or not redistributed:
        errors.append("site redistributed package allowlist is missing")
    else:
        for package_name, license_path in redistributed.items():
            if package_name not in site_dependencies:
                errors.append(
                    f"site redistributed package {package_name} is not a direct dependency"
                )
            if package_name in site_dev_dependencies:
                errors.append(
                    f"site redistributed package {package_name} is build-only"
                )
            if license_path not in site_licenses:
                errors.append(
                    f"site redistributed package {package_name} has no site license"
                )
    lsp_sources = {
        "lus-language/main.lus": [
            rf'io\.write\("lus-language {re.escape(version)}\\n"\)',
            rf'transport\.log\("starting lus-language {re.escape(version)}"\)',
        ],
        "lus-language/protocol.lus": [
            rf'version = "{re.escape(version)}",',
        ],
        "lus-language/wasm.lus": [
            r'local protocol = require\("lus-language\.protocol"\)',
            r'local server = require\("lus-language\.server"\)',
        ],
    }
    for relative, patterns in lsp_sources.items():
        text = (ROOT / relative).read_text(encoding="utf-8")
        for pattern in patterns:
            if len(re.findall(pattern, text)) != 1:
                errors.append(
                    f"{relative} does not contain one canonical LSP version binding"
                )
        literal_versions = set(
            re.findall(r"\b(?:lus-language )?([0-9]+\.[0-9]+\.[0-9]+)\b", text)
        )
        if literal_versions and literal_versions != {version}:
            errors.append(
                f"{relative} contains noncanonical versions: {sorted(literal_versions)}"
            )
    errors.extend(check_action_pins(deps["githubActions"]))
    workflow_text = (ROOT / ".github" / "workflows" / "build.yml").read_text(
        encoding="utf-8"
    )
    workflow_pins = {
        "MESON_VERSION": deps["meson"],
        "NINJA_VERSION": deps["ninja"],
        "NODE_VERSION": deps["node"],
        "PNPM_VERSION": deps["pnpm"],
        "EMSCRIPTEN_VERSION": deps["emscripten"],
        "SHELLCHECK_VERSION": deps["shellcheck"],
    }
    for name, expected in workflow_pins.items():
        values = re.findall(
            rf'^[ \t]+{name}:[ \t]+"([^"]+)"$',
            workflow_text,
            flags=re.MULTILINE,
        )
        if values != [expected]:
            errors.append(f"build workflow {name} is {values}, expected {expected}")
    publish_text = (
        ROOT / ".github" / "workflows" / "publish-vscode.yml"
    ).read_text(encoding="utf-8")
    errors.extend(publish_workflow_errors(publish_text, deps))
    publisher_spec = manifest()["components"].get("vscodePublisher", {})
    if publisher_spec.get("asset") != "lus-{version}-open-vsx-publisher.cjs" or not re.fullmatch(
        r"[0-9a-f]{64}", str(publisher_spec.get("sha256", ""))
    ):
        errors.append("release manifest has an invalid Open VSX publisher asset")
    for required in (
        "pnpm --dir lus-vscode run test:devcontainer",
        "pnpm --dir lus-vscode run test:wasm",
        "node lus-vscode/scripts/build-open-vsx-publisher.mjs",
        "SOURCE_DATE_EPOCH=315532800",
        "SOURCE_DATE_EPOCH=1788048000",
        'cmp -s "$raw_one" "$raw_two"',
        "python3 scripts/release.py publisher-sha256",
        "python3 scripts/release.py vsix-evidence",
        '--publisher "dist-vscode/lus-$version-open-vsx-publisher.cjs"',
    ):
        if required not in workflow_text:
            errors.append(f"build workflow is missing VS Code qualification: {required}")
    if workflow_text.count("python3 scripts/release.py normalize-vsix") != 2:
        errors.append("build workflow must normalize two independent VSIX packages")
    install_workflow_text = None
    if (ROOT / ".github" / "workflows" / "install-test.yml").exists():
        install_workflow_text = (
            ROOT / ".github" / "workflows" / "install-test.yml"
        ).read_text(encoding="utf-8")
    errors.extend(workflow_release_errors(workflow_text, deps, install_workflow_text))
    evidence_requirements = manifest()["evidence"]
    required_installer_evidence = {"unix-installer", "windows-installer"}
    required_statuses = set(evidence_requirements["requiredStatuses"])
    if not required_installer_evidence <= required_statuses:
        errors.append("release evidence must require both installer statuses")
    skips = {
        name
        for values in evidence_requirements["permittedSkips"].values()
        for name in values
    }
    jobs = set(evidence_requirements["qualityGateJobs"])
    if not required_installer_evidence <= jobs:
        errors.append("quality gate must require both installer jobs")
    if not skips <= jobs:
        errors.append("permitted quality gate skips contain unknown jobs")
    if manifest().get("releaseMetadata") != [
        "release-evidence.json",
        "SHA256SUMS",
    ]:
        errors.append("release metadata inventory is not canonical")
    names = expected_assets()
    if not names:
        errors.append("release manifest defines no assets")
    if errors:
        raise ReleaseError("\n".join(errors))
    print(version)


def command_dependency(args) -> None:
    value = dependencies()
    for part in args.key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ReleaseError(f"unknown dependency metadata key: {args.key}")
        value = value[part]
    if isinstance(value, (dict, list)):
        print(json.dumps(value, sort_keys=True))
    else:
        print(value)


def command_publisher_sha256(_args) -> None:
    digest = manifest()["components"].get("vscodePublisher", {}).get("sha256")
    if not re.fullmatch(r"[0-9a-f]{64}", str(digest or "")):
        raise ReleaseError("Open VSX publisher digest is invalid")
    print(digest)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    version = commands.add_parser("version")
    version.set_defaults(function=lambda _args: print(canonical_version()))

    expected = commands.add_parser("expected-assets")
    expected.set_defaults(function=lambda _args: print("\n".join(expected_assets())))

    dependency = commands.add_parser("dependency")
    dependency.add_argument("key")
    dependency.set_defaults(function=command_dependency)

    publisher_sha256 = commands.add_parser("publisher-sha256")
    publisher_sha256.set_defaults(function=command_publisher_sha256)

    check = commands.add_parser("check")
    check.set_defaults(function=command_check)

    stable = commands.add_parser("stable-release")
    stable.add_argument("--tag", required=True)
    stable.add_argument("--commit", required=True)
    stable.add_argument("--notes-output", required=True)
    stable.set_defaults(function=command_stable_release)

    binary_versions = commands.add_parser("binary-versions")
    binary_versions.add_argument("--lus", required=True)
    binary_versions.add_argument("--lusc", required=True)
    binary_versions.set_defaults(function=command_binary_versions)

    platform_parser = commands.add_parser("assemble-platform")
    platform_parser.add_argument("--platform", required=True)
    platform_parser.add_argument("--runtime-dir", required=True)
    platform_parser.add_argument("--sdk-root", required=True)
    platform_parser.add_argument("--sdk-build-dir", required=True)
    platform_parser.add_argument("--output", required=True)
    platform_parser.set_defaults(function=command_assemble_platform)

    tree = commands.add_parser("assemble-tree")
    tree.add_argument("--component", required=True)
    tree.add_argument("--input", required=True)
    tree.add_argument("--output", required=True)
    tree.set_defaults(function=command_assemble_tree)

    component = commands.add_parser("copy-component")
    component.add_argument("--component", required=True)
    component.add_argument("--source", required=True)
    component.add_argument("--output", required=True)
    component.set_defaults(function=command_copy_component)

    meson = commands.add_parser("collect-meson")
    meson.add_argument("--kind", choices=("test", "sanitizer", "benchmark"), required=True)
    meson.add_argument("--name", required=True)
    meson.add_argument("--status", required=True)
    meson.add_argument("--log", required=True)
    meson.add_argument("--output", required=True)
    meson.set_defaults(function=command_collect_meson)

    environment = commands.add_parser("environment")
    environment.add_argument("--platform", required=True)
    environment.add_argument("--build-dir")
    environment.add_argument(
        "--provenance",
        choices=(
            "hosted-runner-version-recorded",
            "immutable-container-version-recorded",
            "hosted-runner-pinned-emscripten",
        ),
        required=True,
    )
    environment.add_argument("--output", required=True)
    environment.set_defaults(function=command_environment)

    status_parser = commands.add_parser("status")
    status_parser.add_argument("--name", required=True)
    status_parser.add_argument("--status", required=True)
    status_parser.add_argument("--detail", action="append", default=[])
    status_parser.add_argument("--output", required=True)
    status_parser.set_defaults(function=command_status)

    wasm_evidence = commands.add_parser("wasm-evidence")
    wasm_evidence.add_argument("--dist", required=True)
    wasm_evidence.add_argument("--embedded-tree", required=True)
    wasm_evidence.add_argument("--node-wasm-proof", required=True)
    wasm_evidence.add_argument("--output", required=True)
    wasm_evidence.set_defaults(function=command_wasm_evidence)

    normalize_vsix_parser = commands.add_parser("normalize-vsix")
    normalize_vsix_parser.add_argument("--input", required=True)
    normalize_vsix_parser.add_argument("--output", required=True)
    normalize_vsix_parser.set_defaults(function=command_normalize_vsix)

    vsix_evidence = commands.add_parser("vsix-evidence")
    vsix_evidence.add_argument("--vsix", required=True)
    vsix_evidence.add_argument("--publisher", required=True)
    vsix_evidence.add_argument("--node-js", required=True)
    vsix_evidence.add_argument("--wasm", required=True)
    vsix_evidence.add_argument("--output", required=True)
    vsix_evidence.set_defaults(function=command_vsix_evidence)

    gate = commands.add_parser("quality-gate")
    gate.add_argument("--event", required=True)
    gate.add_argument("--job", action="append", default=[], required=True)
    gate.add_argument("--output")
    gate.set_defaults(function=command_quality_gate)

    collect = commands.add_parser("collect-assets")
    collect.add_argument("--artifacts-root", required=True)
    collect.add_argument("--output", required=True)
    collect.set_defaults(function=command_collect_assets)

    finalize = commands.add_parser("finalize")
    finalize.add_argument("--assets", required=True)
    finalize.add_argument("--fragments", required=True)
    finalize.add_argument("--commit", required=True)
    finalize.add_argument("--event", required=True)
    finalize.set_defaults(function=command_finalize)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        args.function(args)
        return 0
    except ReleaseError as error:
        print(f"release error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
