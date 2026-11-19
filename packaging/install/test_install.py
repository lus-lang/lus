#!/usr/bin/env python3
"""Exercise install.sh against a deterministic local HTTPS release."""

from __future__ import annotations

import argparse
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import platform
import shutil
import ssl
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]


def canonical_version() -> str:
    result = subprocess.run(
        ["python3", "scripts/release.py", "version"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: list[str], cwd: Path, environment: dict[str, str]) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        output = (result.stdout + "\n" + result.stderr).strip()
        raise RuntimeError(
            f"command failed with {result.returncode}: {' '.join(command)}\n{output}"
        )
    return result.stdout + result.stderr


class ReleaseServer(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.errors: list[str] = []

    def handle_error(self, request, client_address):
        self.errors.append(f"request from {client_address} failed")
        super().handle_error(request, client_address)


class ReleaseHandler(SimpleHTTPRequestHandler):
    requests: list[str] = []

    def do_GET(self):
        self.requests.append(self.path)
        super().do_GET()

    def log_message(self, format, *args):
        return


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--installer", required=True)
    value.add_argument("--lus", required=True)
    value.add_argument("--lusc", required=True)
    value.add_argument(
        "--certificate",
        default="legacy/lus-tests/h3/fixtures/localhost-cert.pem",
    )
    value.add_argument(
        "--private-key",
        default="legacy/lus-tests/h3/fixtures/localhost-key.pem",
    )
    return value


def qualify(args) -> None:
    version = canonical_version()
    certificate = (ROOT / args.certificate).resolve()
    private_key = (ROOT / args.private_key).resolve()
    installer = Path(args.installer).resolve()
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin" and machine in {"arm64", "aarch64"}:
        asset_names = ("lus-macos", "lusc-macos")
    elif system == "Linux" and machine in {"x86_64", "amd64"}:
        libc_name, _libc_version = platform.libc_ver()
        if libc_name.lower() == "musl":
            asset_names = ("lus-linux-musl", "lusc-linux-musl")
        else:
            asset_names = ("lus-linux", "lusc-linux")
    else:
        raise RuntimeError(f"installer qualification host is unsupported: {system} {machine}")
    sources = {
        asset_names[0]: Path(args.lus).resolve(),
        asset_names[1]: Path(args.lusc).resolve(),
    }
    for path in [installer, certificate, private_key, *sources.values()]:
        if not path.is_file():
            raise RuntimeError(f"installer qualification input is missing: {path}")

    with tempfile.TemporaryDirectory(prefix="lus-install-qualification-") as temporary:
        workspace = Path(temporary).resolve()
        release_root = workspace / "release" / f"v{version}"
        release_root.mkdir(parents=True)
        for name, source in sources.items():
            target = release_root / name
            shutil.copyfile(source, target)
            target.chmod(0o755)
        checksums = "".join(
            f"{digest(release_root / name)}  {name}\n" for name in sorted(sources)
        )
        (release_root / "SHA256SUMS").write_text(checksums, encoding="utf-8")

        handler = functools.partial(ReleaseHandler, directory=str(workspace / "release"))
        ReleaseHandler.requests = []
        server = ReleaseServer(("127.0.0.1", 0), handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, private_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, name="installer-https")
        thread.start()
        try:
            install_dir = workspace / "prefix" / "bin"
            environment = os.environ.copy()
            environment["LUS_RELEASE_BASE_URL"] = (
                f"https://localhost:{server.server_address[1]}/v{version}"
            )
            environment["SSL_CERT_FILE"] = str(certificate)
            environment["CURL_CA_BUNDLE"] = str(certificate)
            run(
                [
                    "sh",
                    str(installer),
                    "--version",
                    f"v{version}",
                    "--dir",
                    str(install_dir),
                ],
                workspace,
                environment,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        if thread.is_alive():
            raise RuntimeError("installer HTTPS fixture did not stop")
        if server.errors:
            raise RuntimeError("installer HTTPS fixture reported request errors")

        expected_requests = {
            f"/v{version}/SHA256SUMS",
            f"/v{version}/{asset_names[0]}",
            f"/v{version}/{asset_names[1]}",
        }
        if sorted(ReleaseHandler.requests) != sorted(expected_requests):
            raise RuntimeError(
                "installer fetched an unexpected release inventory: "
                f"{ReleaseHandler.requests}"
            )

        lus = install_dir / "lus"
        lusc = install_dir / "lusc"
        run(
            [
                "python3",
                str(ROOT / "scripts" / "release.py"),
                "binary-versions",
                "--lus",
                str(lus),
                "--lusc",
                str(lusc),
            ],
            workspace,
            environment,
        )
        source = workspace / "source.lus"
        source.write_text("print('installer-source-ok')\n", encoding="utf-8")
        if "installer-source-ok" not in run([str(lus), str(source)], workspace, environment):
            raise RuntimeError("installed interpreter did not execute source")
        bytecode = workspace / "source.lusc"
        run([str(lusc), "-o", str(bytecode), str(source)], workspace, environment)
        if "installer-source-ok" not in run(
            [str(lus), str(bytecode)], workspace, environment
        ):
            raise RuntimeError("installed compiler round trip failed")

        module_dir = workspace / "prefix" / "share" / "lus" / "1.7"
        module_dir.mkdir(parents=True)
        (module_dir / "installer_module.lus").write_text(
            "return 'installer-module-ok'\n", encoding="utf-8"
        )
        module_probe = workspace / "module-probe.lus"
        module_probe.write_text(
            "print(require('installer_module'))\n", encoding="utf-8"
        )
        module_environment = environment.copy()
        for name in ("LUS_PATH", "LUS_PATH_1_7", "LUA_PATH", "LUA_PATH_1_7"):
            module_environment.pop(name, None)
        if "installer-module-ok" not in run(
            [str(lus), "-Pall", str(module_probe)], workspace, module_environment
        ):
            raise RuntimeError("installed interpreter did not use its relocatable modules")


def main() -> int:
    qualify(parser().parse_args())
    print("Unix installer qualification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
