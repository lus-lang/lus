#!/usr/bin/env python3
"""Qualify Lus platform archives and the stable 1.6.2 C ABI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform as host_platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from typing import Optional
import zipfile


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "release" / "manifest.json"
PUBLIC_SYMBOL = re.compile(r"^(?:lua_|luaL_|luaopen_|lus_)[A-Za-z0-9_]*$")
BUILD_PATH_MARKERS = (
    b"/Users/",
    b"/home/runner/work/",
    b"/private/var/folders/",
    b"\\a\\lus\\lus",
    b"Development/lus",
)


class QualificationError(RuntimeError):
    pass


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise QualificationError(f"cannot read {path}: {error}") from error


def manifest() -> dict:
    value = read_json(MANIFEST_PATH)
    if value.get("schemaVersion") != 1:
        raise QualificationError("unsupported release manifest schema")
    return value


def canonical_version() -> str:
    text = (ROOT / manifest()["versionSource"]).read_text(encoding="utf-8")
    values = []
    for name in (
        "LUA_VERSION_MAJOR_N",
        "LUA_VERSION_MINOR_N",
        "LUA_VERSION_RELEASE_N",
    ):
        matches = re.findall(
            rf"^#define[ \t]+{name}[ \t]+([0-9]+)[ \t]*$",
            text,
            flags=re.MULTILINE,
        )
        if len(matches) != 1:
            raise QualificationError(f"lua.h must define {name} exactly once")
        values.append(str(int(matches[0])))
    return ".".join(values)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_name(name: str) -> PurePosixPath:
    value = PurePosixPath(name.replace("\\", "/"))
    if value.is_absolute() or not value.parts or any(part in {"", ".", ".."} for part in value.parts):
        raise QualificationError(f"unsafe archive member: {name}")
    return value


def extract_tar(path: Path, destination: Path) -> set[str]:
    files = set()
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            relative = safe_name(member.name)
            target = destination.joinpath(*relative.parts)
            if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                raise QualificationError(f"unsupported archive member: {member.name}")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise QualificationError(f"cannot read archive member: {member.name}")
            with target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
            files.add(relative.as_posix())
    return files


def extract_zip(path: Path, destination: Path) -> set[str]:
    files = set()
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            relative = safe_name(member.filename.rstrip("/"))
            target = destination.joinpath(*relative.parts)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise QualificationError(f"archive link is forbidden: {member.filename}")
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod((mode & 0o777) or 0o644)
            files.add(relative.as_posix())
    return files


def extract_archive(path: Path, destination: Path) -> tuple[Path, set[str]]:
    if path.name.endswith(".tar.gz"):
        files = extract_tar(path, destination)
    elif path.suffix == ".zip":
        files = extract_zip(path, destination)
    else:
        raise QualificationError(f"unsupported platform archive: {path.name}")
    roots = {PurePosixPath(name).parts[0] for name in files}
    if len(roots) != 1:
        raise QualificationError(f"archive must contain one root, found {sorted(roots)}")
    root_name = next(iter(roots))
    return destination / root_name, {
        PurePosixPath(name).relative_to(root_name).as_posix() for name in files
    }


def expected_inventory(platform_name: str) -> set[str]:
    data = manifest()
    sdk = data["sdk"]
    platform_data = data["platforms"][platform_name]
    files = set(sdk["headers"])
    files.update(platform_data["libraries"])
    files.update(f"bin/{name}" for name in platform_data["executables"].values())
    files.add(sdk["buildMetadata"])
    if platform_name == "windows-x64":
        files.add(sdk["cmakeConfig"])
    else:
        files.add(sdk["pkgConfig"])
    license_set = data["licenseSets"][platform_data["licenseSet"]]
    license_root = license_set["directory"]
    files.add(f"{license_root}/THIRD_PARTY_NOTICES.md")
    files.update(
        f"{license_root}/{Path(relative).name}"
        for relative in license_set["licenses"]
    )
    return files


def validate_metadata(prefix: Path, platform_name: str) -> dict:
    path = prefix / manifest()["sdk"]["buildMetadata"]
    value = read_json(path)
    required = {"schemaVersion", "version", "commit", "platform", "toolchain", "runtime", "sdk"}
    if set(value) != required or value["schemaVersion"] != 1:
        raise QualificationError("archive build metadata has an invalid shape")
    if value["version"] != canonical_version() or value["platform"] != platform_name:
        raise QualificationError("archive build metadata identifies another candidate")
    if not re.fullmatch(r"[0-9a-f]{40}", str(value["commit"])):
        raise QualificationError("archive build metadata needs a full commit id")
    if not isinstance(value["toolchain"], dict) or not value["toolchain"].get("compiler"):
        raise QualificationError("archive build metadata omits the compiler")
    runtime = value["runtime"]
    if not isinstance(runtime, dict) or not (
        runtime.get("lto") is True or runtime.get("pgo") == "qualified"
    ):
        raise QualificationError("runtime build is neither LTO nor qualified PGO")
    sdk = value["sdk"]
    if not isinstance(sdk, dict) or sdk.get("libraryType") != "static" or sdk.get("lto") is not False:
        raise QualificationError("SDK metadata must describe a non-LTO static library")
    dependencies = sdk.get("externalDependencies")
    if not isinstance(dependencies, list) or len(dependencies) != len(set(dependencies)):
        raise QualificationError("SDK external dependencies are missing or duplicated")
    if not {"c-ares", "openssl", "sqlite3", "zlib"} <= set(dependencies):
        raise QualificationError("SDK metadata omits required external dependencies")
    return value


def run(command: list[str], cwd: Path, environment=None, timeout=60) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise QualificationError(f"cannot run {command[0]}: {error}") from error
    if result.returncode != 0:
        detail = (result.stdout + "\n" + result.stderr).strip()
        raise QualificationError(
            f"command failed with {result.returncode}: {' '.join(command)}\n{detail}"
        )
    return result


def executable_paths(prefix: Path, platform_name: str) -> tuple[Path, Path]:
    suffix = ".exe" if platform_name == "windows-x64" else ""
    return prefix / "bin" / f"lus{suffix}", prefix / "bin" / f"lusc{suffix}"


def clean_runtime_environment() -> dict[str, str]:
    value = os.environ.copy()
    for name in ("LUA_PATH", "LUA_CPATH", "LUS_PATH", "LUS_CPATH"):
        value.pop(name, None)
    return value


def verify_runtime(prefix: Path, platform_name: str, workspace: Path) -> None:
    lus, lusc = executable_paths(prefix, platform_name)
    version_result = run([str(lus), "-v"], workspace)
    version = version_result.stdout + version_result.stderr
    if f"Lus {canonical_version()}" not in version:
        raise QualificationError(f"archive interpreter reported an unexpected version: {version.strip()}")
    source = workspace / "source.lus"
    source.write_text("print('archive-source-ok')\n", encoding="utf-8")
    if "archive-source-ok" not in run([str(lus), str(source)], workspace).stdout:
        raise QualificationError("archive interpreter did not execute source")
    bytecode = workspace / "source.lusc"
    run([str(lusc), "-o", str(bytecode), str(source)], workspace)
    if "archive-source-ok" not in run([str(lus), str(bytecode)], workspace).stdout:
        raise QualificationError("archive compiler round trip failed")

    lus_modules = prefix / "share" / "lus" / "1.7"
    lua_modules = prefix / "share" / "lua" / "1.7"
    lus_modules.mkdir(parents=True, exist_ok=True)
    lua_modules.mkdir(parents=True, exist_ok=True)
    lus_module = lus_modules / "release_probe.lus"
    lua_module = lua_modules / "release_probe.lus"
    lus_module.write_text("return 'lus-first'\n", encoding="utf-8")
    lua_module.write_text("return 'lua-fallback'\n", encoding="utf-8")
    probe = workspace / "module-probe.lus"
    probe.write_text(
        "local value = require('release_probe')\nprint(value)\n", encoding="utf-8"
    )
    environment = clean_runtime_environment()
    first = run([str(lus), "-Pall", str(probe)], workspace, environment).stdout.strip()
    if first != "lus-first":
        raise QualificationError(f"Lus module directory did not win: {first}")
    lus_module.unlink()
    fallback = run([str(lus), "-Pall", str(probe)], workspace, environment).stdout.strip()
    if fallback != "lua-fallback":
        raise QualificationError(f"Lua compatibility fallback failed: {fallback}")

    lus_module.write_text("return 'lus-first'\n", encoding="utf-8")
    worker_body = workspace / "worker-module-probe.lus"
    worker_body.write_text(
        "global require, worker\n"
        "local value = require('release_probe')\n"
        "worker.message(value)\n",
        encoding="utf-8",
    )
    worker_probe = workspace / "worker-probe.lus"
    worker_probe.write_text(
        "global arg, print, worker\n"
        "local handle = worker.create(arg[1])\n"
        "print(worker.receive(handle))\n",
        encoding="utf-8",
    )
    worker_value = run(
        [str(lus), "-Pall", str(worker_probe), str(worker_body)],
        workspace,
        environment,
    ).stdout.strip()
    if worker_value != "lus-first":
        raise QualificationError(
            f"archive worker did not inherit relocatable paths: {worker_value}"
        )

    unversioned_modules = workspace / "environment-unversioned"
    versioned_modules = workspace / "environment-versioned"
    unversioned_modules.mkdir()
    versioned_modules.mkdir()
    (unversioned_modules / "release_probe.lus").write_text(
        "return 'environment-unversioned'\n", encoding="utf-8"
    )
    (versioned_modules / "release_probe.lus").write_text(
        "return 'environment-versioned'\n", encoding="utf-8"
    )
    environment["LUA_PATH"] = str(unversioned_modules / "?.lus")
    environment["LUA_PATH_1_7"] = str(versioned_modules / "?.lus")
    override = run(
        [str(lus), "-Pall", str(probe)], workspace, environment
    ).stdout.strip()
    if override != "environment-versioned":
        raise QualificationError(
            f"versioned environment override did not win: {override}"
        )

    environment.pop("LUA_PATH_1_7")
    environment["LUA_PATH"] = str(workspace / "missing" / "?.lus") + ";;"
    expanded = run(
        [str(lus), "-Pall", str(probe)], workspace, environment
    ).stdout.strip()
    if expanded != "lus-first":
        raise QualificationError(
            f"environment default expansion lost the archive prefix: {expanded}"
        )


def pkg_config_environment(prefix: Path) -> dict[str, str]:
    value = os.environ.copy()
    directory = prefix / "lib" / "pkgconfig"
    inherited = value.get("PKG_CONFIG_PATH")
    value["PKG_CONFIG_PATH"] = str(directory) + (
        os.pathsep + inherited if inherited else ""
    )
    value.pop("PKG_CONFIG_SYSROOT_DIR", None)
    return value


def verify_unix_consumers(prefix: Path, workspace: Path, cc: str, cxx: str) -> None:
    environment = pkg_config_environment(prefix)
    directory = run(
        ["pkg-config", "--variable=pcfiledir", "lus"], workspace, environment
    ).stdout.strip()
    if Path(directory).resolve() != (prefix / "lib" / "pkgconfig").resolve():
        raise QualificationError("pkg-config selected metadata outside the archive")
    flags = shlex.split(
        run(
            ["pkg-config", "--cflags", "--libs", "--static", "lus"],
            workspace,
            environment,
        ).stdout
    )
    sources = (("consumer.c", cc), ("consumer.cpp", cxx))
    for source_name, compiler in sources:
        source = ROOT / "release" / "abi" / source_name
        output = workspace / (Path(source_name).stem + "-consumer")
        run([compiler, str(source), "-o", str(output)] + flags, workspace, environment, 120)
        result = run([str(output)], workspace, environment)
        if "consumer-ok" not in result.stdout:
            raise QualificationError(f"{source_name} consumer produced unexpected output")


def verify_windows_consumers(
    prefix: Path,
    workspace: Path,
    cmake: str,
    cmake_toolchain: Optional[str],
    vcpkg_triplet: Optional[str],
) -> None:
    project = workspace / "cmake-consumer"
    project.mkdir()
    shutil.copyfile(ROOT / "release" / "abi" / "consumer.c", project / "consumer.c")
    shutil.copyfile(ROOT / "release" / "abi" / "consumer.cpp", project / "consumer.cpp")
    (project / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.25)\n"
        "project(lus_abi_consumers C CXX)\n"
        "find_package(Lus CONFIG REQUIRED)\n"
        "add_executable(c_consumer consumer.c)\n"
        "target_link_libraries(c_consumer PRIVATE Lus::lus)\n"
        "add_executable(cpp_consumer consumer.cpp)\n"
        "target_link_libraries(cpp_consumer PRIVATE Lus::lus)\n",
        encoding="utf-8",
    )
    build = project / "build"
    configure = [
        cmake,
        "-S",
        str(project),
        "-B",
        str(build),
        f"-DCMAKE_PREFIX_PATH={prefix}",
    ]
    if cmake_toolchain:
        configure.append(f"-DCMAKE_TOOLCHAIN_FILE={cmake_toolchain}")
    if vcpkg_triplet:
        configure.append(f"-DVCPKG_TARGET_TRIPLET={vcpkg_triplet}")
    run(
        configure,
        workspace,
        timeout=180,
    )
    run([cmake, "--build", str(build), "--config", "Release"], workspace, timeout=300)
    for name in ("c_consumer.exe", "cpp_consumer.exe"):
        matches = list(build.rglob(name))
        if len(matches) != 1:
            raise QualificationError(f"CMake did not produce exactly one {name}")
        if "consumer-ok" not in run([str(matches[0])], workspace).stdout:
            raise QualificationError(f"{name} produced unexpected output")


def check_build_paths(prefix: Path, forbidden: list[str]) -> None:
    needles = list(BUILD_PATH_MARKERS)
    needles.extend(value.encode("utf-8") for value in forbidden if value)
    for path in sorted(prefix.rglob("*")):
        if not path.is_file():
            continue
        payload = path.read_bytes()
        for needle in needles:
            if needle in payload:
                raise QualificationError(
                    f"archive file contains a build-machine path: {path.relative_to(prefix)}"
                )


def host_supports(platform_name: str) -> bool:
    system = host_platform.system().lower()
    machine = host_platform.machine().lower()
    if platform_name.startswith("linux-"):
        return system == "linux" and machine in {"x86_64", "amd64"}
    if platform_name == "macos-arm64":
        return system == "darwin" and machine in {"arm64", "aarch64"}
    if platform_name == "windows-x64":
        return system == "windows" and machine in {"amd64", "x86_64"}
    return False


def nm_output(tool: str, library: Path) -> str:
    if Path(tool).name.lower() in {"dumpbin", "dumpbin.exe"}:
        result = run([tool, "/symbols", str(library)], Path.cwd())
        return "\n".join(
            line
            for line in result.stdout.splitlines()
            if "External" in line and "UNDEF" not in line
        )
    attempts = (
        [tool, "--defined-only", "--extern-only", str(library)],
        [tool, "-gU", str(library)],
        [tool, "-g", "--defined-only", str(library)],
    )
    errors = []
    for command in attempts:
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))
            continue
        if result.returncode == 0:
            return result.stdout
        errors.append(result.stderr.strip())
    raise QualificationError(f"cannot inspect {library} with {tool}: {' | '.join(errors)}")


def public_symbols(output: str) -> set[str]:
    symbols = set()
    for line in output.splitlines():
        fields = line.strip().split()
        if not fields:
            continue
        symbol = fields[-1]
        if symbol.startswith("_") and PUBLIC_SYMBOL.fullmatch(symbol[1:]):
            symbol = symbol[1:]
        if PUBLIC_SYMBOL.fullmatch(symbol):
            symbols.add(symbol)
    return symbols


def assert_sqlite_separate(tool: str, library: Path) -> None:
    output = nm_output(tool, library)
    defined = set()
    for line in output.splitlines():
        fields = line.strip().split()
        if fields:
            defined.add(fields[-1].lstrip("_"))
    bundled = sorted(symbol for symbol in defined if symbol.startswith("sqlite3_") and symbol != "sqlite3_api")
    if bundled:
        raise QualificationError("liblus contains SQLite implementation symbols")


def command_archive(args) -> None:
    if args.platform not in manifest()["platforms"]:
        raise QualificationError(f"unknown archive platform: {args.platform}")
    archive = Path(args.archive).resolve()
    if not archive.is_file():
        raise QualificationError(f"platform archive is missing: {archive}")
    if not host_supports(args.platform):
        raise QualificationError(
            f"{args.platform} archive qualification must run on its target platform"
        )
    with tempfile.TemporaryDirectory(prefix="lus-archive-qualification-") as directory:
        workspace = Path(directory)
        prefix, inventory = extract_archive(archive, workspace / "extract")
        expected = expected_inventory(args.platform)
        if inventory != expected:
            raise QualificationError(
                f"archive inventory mismatch, missing={sorted(expected - inventory)}, "
                f"unexpected={sorted(inventory - expected)}"
            )
        metadata = validate_metadata(prefix, args.platform)
        verify_runtime(prefix, args.platform, workspace)
        library_name = "lus.lib" if args.platform == "windows-x64" else "liblus.a"
        assert_sqlite_separate(args.nm, prefix / "lib" / library_name)
        if args.platform == "windows-x64":
            verify_windows_consumers(
                prefix,
                workspace,
                args.cmake,
                args.cmake_toolchain,
                args.vcpkg_triplet,
            )
        else:
            verify_unix_consumers(prefix, workspace, args.cc, args.cxx)
        check_build_paths(prefix, args.forbid_path)
        evidence = {
            "schemaVersion": 1,
            "kind": "archiveQualification",
            "archive": archive.name,
            "sha256": sha256(archive),
            "platform": args.platform,
            "version": canonical_version(),
            "commit": metadata["commit"],
            "inventory": sorted(inventory),
            "status": "passed",
        }
        if args.output:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(evidence, sort_keys=True))


def command_abi(args) -> None:
    baseline = Path(args.baseline_library).resolve()
    candidate = Path(args.candidate_library).resolve()
    if not baseline.is_file() or not candidate.is_file():
        raise QualificationError("ABI comparison requires both static libraries")
    baseline_symbols = public_symbols(nm_output(args.nm, baseline))
    candidate_symbols = public_symbols(nm_output(args.nm, candidate))
    if len(baseline_symbols) < 100:
        raise QualificationError(
            f"v1.6.2 baseline exposed only {len(baseline_symbols)} public symbols"
        )
    missing = sorted(baseline_symbols - candidate_symbols)
    if missing:
        raise QualificationError("1.7 removes stable symbols: " + ", ".join(missing))
    prefix = Path(args.candidate_prefix).resolve()
    if not prefix.is_dir():
        raise QualificationError("ABI consumer prefix is missing")
    with tempfile.TemporaryDirectory(prefix="lus-abi-consumers-") as directory:
        workspace = Path(directory)
        if args.platform == "windows-x64":
            verify_windows_consumers(
                prefix,
                workspace,
                args.cmake,
                args.cmake_toolchain,
                args.vcpkg_triplet,
            )
        else:
            verify_unix_consumers(prefix, workspace, args.cc, args.cxx)
    evidence = {
        "schemaVersion": 1,
        "kind": "abiCompatibility",
        "baseline": "1.6.2",
        "candidate": canonical_version(),
        "baselineLibrarySha256": sha256(baseline),
        "candidateLibrarySha256": sha256(candidate),
        "stableSymbolCount": len(baseline_symbols),
        "candidatePublicSymbolCount": len(candidate_symbols),
        "missing": [],
        "status": "passed",
    }
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(evidence, sort_keys=True))


def command_selftest(_args) -> None:
    sample = """
00000000 T lua_absindex
00000010 T _luaL_newstate
00000020 T luaopen_base
00000030 T lus_worker_status
00000040 T luaC_step
"""
    expected = {"lua_absindex", "luaL_newstate", "luaopen_base", "lus_worker_status"}
    if public_symbols(sample) != expected:
        raise QualificationError("public symbol parser self-test failed")
    with tempfile.TemporaryDirectory(prefix="lus-release-selftest-") as directory:
        root = Path(directory)
        bad_tar = root / "bad.tar.gz"
        payload = root / "payload"
        payload.write_text("bad", encoding="utf-8")
        with tarfile.open(bad_tar, "w:gz") as archive:
            archive.add(payload, arcname="../escape")
        try:
            extract_archive(bad_tar, root / "extract")
        except QualificationError:
            pass
        else:
            raise QualificationError("archive traversal self-test was accepted")
        bad_result = {
            "schemaVersion": 1,
            "version": canonical_version(),
            "commit": "0" * 40,
            "platform": "macos-arm64",
            "toolchain": {"compiler": "fixture"},
            "runtime": {"lto": True},
            "sdk": {
                "libraryType": "static",
                "lto": True,
                "externalDependencies": ["c-ares", "openssl", "sqlite3", "zlib"],
            },
        }
        prefix = root / "prefix"
        metadata_path = prefix / manifest()["sdk"]["buildMetadata"]
        metadata_path.parent.mkdir(parents=True)
        metadata_path.write_text(json.dumps(bad_result), encoding="utf-8")
        try:
            validate_metadata(prefix, "macos-arm64")
        except QualificationError:
            pass
        else:
            raise QualificationError("LTO SDK metadata self-test was accepted")
    print("release qualification self-test passed")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    commands = value.add_subparsers(dest="command", required=True)
    archive = commands.add_parser("archive")
    archive.add_argument("--archive", required=True)
    archive.add_argument("--platform", required=True)
    archive.add_argument("--cc", default=os.environ.get("CC", "cc"))
    archive.add_argument("--cxx", default=os.environ.get("CXX", "c++"))
    archive.add_argument("--cmake", default="cmake")
    archive.add_argument("--cmake-toolchain")
    archive.add_argument("--vcpkg-triplet")
    archive.add_argument("--nm", default=os.environ.get("NM", "nm"))
    archive.add_argument("--forbid-path", action="append", default=[])
    archive.add_argument("--output")
    archive.set_defaults(function=command_archive)
    abi = commands.add_parser("abi")
    abi.add_argument("--baseline-library", required=True)
    abi.add_argument("--candidate-library", required=True)
    abi.add_argument("--candidate-prefix", required=True)
    abi.add_argument("--platform", choices=tuple(manifest()["platforms"]), required=True)
    abi.add_argument("--cc", default=os.environ.get("CC", "cc"))
    abi.add_argument("--cxx", default=os.environ.get("CXX", "c++"))
    abi.add_argument("--cmake", default="cmake")
    abi.add_argument("--cmake-toolchain")
    abi.add_argument("--vcpkg-triplet")
    abi.add_argument("--nm", default=os.environ.get("NM", "nm"))
    abi.add_argument("--output")
    abi.set_defaults(function=command_abi)
    selftest = commands.add_parser("self-test")
    selftest.set_defaults(function=command_selftest)
    return value


def main() -> int:
    try:
        args = parser().parse_args()
        args.function(args)
        return 0
    except QualificationError as error:
        print(f"release qualification error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
