#!/usr/bin/env python3
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Installer behaviour checks. Stdlib only; does not import ecos_release."""

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path, PurePosixPath
from typing import Any

CELL_LEFS = (
    "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/lef/ics55_LLSC_H7CR_ecos.lef",
    "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CL/lef/ics55_LLSC_H7CL_ecos.lef",
)
TECH_LEF = "prtech/techLEF/N551P6M_ecos.lef"
SIZER_VERSION = "0.1.0-alpha"
SIZER_ASSET = f"ecc-sizer-{SIZER_VERSION}-linux-x64.tar.gz"
LIBERTY_SPECS = (
    (
        "ics55_LLSC_H7CH_liberty.tar.bz2",
        "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CH",
        "h7ch.lib",
    ),
    (
        "ics55_LLSC_H7CL_liberty.tar.bz2",
        "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CL",
        "h7cl.lib",
    ),
    (
        "ics55_LLSC_H7CR_liberty.tar.bz2",
        "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR",
        "h7cr.lib",
    ),
)
GDS_SPECS = (
    (
        "ics55_LLSC_H7CH_gds.tar.bz2",
        "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CH",
        "h7ch.gds",
    ),
    (
        "ics55_LLSC_H7CL_gds.tar.bz2",
        "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CL",
        "h7cl.gds",
    ),
    (
        "ics55_LLSC_H7CR_gds.tar.bz2",
        "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR",
        "h7cr.gds",
    ),
    (
        "ICsprout_55LLULP1233_IO_251013_gds.tar.bz2",
        "IP/IO/ICsprout_55LLULP1233_IO_251013",
        "io.gds",
    ),
)
PLACEHOLDERS = (
    "ECC_VERSION",
    "ECC_TAG",
    "ECC_ASSET_NAME",
    "ECC_SHA256",
    "ECC_SIZE",
    "ECC_GITHUB_URL",
    "ECC_CNB_URL",
    "MIN_GLIBC_MAJOR",
    "MIN_GLIBC_MINOR",
    "OSS_CAD_VERSION",
    "OSS_CAD_ASSET_NAME",
    "OSS_CAD_SHA256",
    "OSS_CAD_URL",
    "OSS_CAD_CNB_URL",
    "SIZER_VERSION",
    "SIZER_ASSET_NAME",
    "SIZER_SHA256",
    "SIZER_SIZE",
    "SIZER_URL",
    "SIZER_CNB_URL",
    "SIZER_CNB_SHA256",
    "PDK_NAME",
    "PDK_VERSION",
    "PDK_BASE_ASSET_NAME",
    "PDK_BASE_SHA256",
    "PDK_BASE_URL",
    "PDK_BASE_CNB_URL",
    "PDK_BASE_CNB_SHA256",
    "PDK_TECH_LEF",
    "PDK_CELL_LEFS",
    "PDK_ASSET_TABLE",
    "PDK_LIBERTY_FILES",
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pack_tar(members: dict[str, bytes | None], *, compression: str) -> bytes:
    buffer = BytesIO()
    mode = {"gz": "w:gz", "bz2": "w:bz2"}[compression]
    with tarfile.open(fileobj=buffer, mode=mode) as tar:
        for name, content in members.items():
            info = tarfile.TarInfo(name)
            if content is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
                continue
            info.size = len(content)
            base = PurePosixPath(name).name
            info.mode = (
                0o755
                if content.startswith(b"#!")
                or base in {"ecc", "yosys", "torch_shm_manager", "Sizer"}
                else 0o644
            )
            tar.addfile(info, BytesIO(content))
    return buffer.getvalue()


def ecc_script(version: str, *, fail: bool = False) -> bytes:
    status = "1" if fail else "0"
    return f"""#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "ecc {version}"
  exit {status}
fi
if [ "$1" = "version" ] && [ "${{2:-}}" = "--json" ]; then
  echo '{{"schema_version":1,"runtime":"ECC CLI","ecc":"{version}"}}'
  exit {status}
fi
if [ "$1" = "dump-env" ]; then
  printf 'OSS=%s\\n' "${{CHIPCOMPILER_OSS_CAD_DIR-}}"
  printf 'PDK=%s\\n' "${{CHIPCOMPILER_ICS55_PDK_ROOT-}}"
  printf 'PATH=%s\\n' "$PATH"
  printf 'YOSYS_PLUGINPATH=%s\\n' "${{YOSYS_PLUGINPATH-}}"
  printf 'YOSYS_DATDIR=%s\\n' "${{YOSYS_DATDIR-}}"
  exit 0
fi
exit {status}
""".encode()


def yosys_script(*, slang: bool = True) -> bytes:
    if slang:
        body = """
case "$cmd" in
  "help read_slang") echo "read_slang -- read SystemVerilog"; exit 0 ;;
  "plugin -i slang") exit 0 ;;
esac
exit 1
"""
    else:
        body = """
case "$cmd" in
  "help read_slang") echo "No such command: read_slang"; exit 0 ;;
  "plugin -i slang") exit 1 ;;
esac
exit 1
"""
    return f"""#!/bin/sh
cmd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) echo "Yosys 0.67 (test)"; exit 0 ;;
    -Q|-T) ;;
    -p) cmd="$2"; shift ;;
  esac
  shift
done
{body}
""".encode()


@dataclass
class PackedAsset:
    name: str
    data: bytes
    sha256: str
    dest: str | None = None
    kind: str = "archive"


def build_ecc_archive(version: str = "0.1.0-alpha.11", *, fail: bool = False) -> bytes:
    return pack_tar(
        {"ecc": ecc_script(version, fail=fail), "_internal/torch/bin/torch_shm_manager": b"shm\n"},
        compression="gz",
    )


def build_oss_archive(*, slang: bool = True) -> bytes:
    return pack_tar(
        {
            "oss-cad-suite/bin/yosys": yosys_script(slang=slang),
            "oss-cad-suite/share/yosys/plugins/.keep": b"",
        },
        compression="gz",
    )


def sizer_script(version: str = SIZER_VERSION) -> bytes:
    return f"""#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "OpenROAD v{version}"
  echo "Usage : sizer -env <env_file> -f <cmd_file>"
  exit 1
fi
exit 0
""".encode()


def build_sizer_archive(*, version: str = SIZER_VERSION) -> bytes:
    return pack_tar(
        {
            f"ecc-sizer-{version}/bin/Sizer": sizer_script(version),
            f"ecc-sizer-{version}/libexec/Sizer": b"ELF-sizer-payload\n",
            f"ecc-sizer-{version}/lib/ld-linux-x86-64.so.2": b"ELF-loader\n",
        },
        compression="gz",
    )


def build_sizer_symlink_archive() -> bytes:
    # bin/Sizer symlinks to an executable that emits the correct banner, so
    # only the symlink rejection (not the version smoke test) can fail it.
    top = f"ecc-sizer-{SIZER_VERSION}"
    script = sizer_script()
    buffer = BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name in (f"{top}/bin", f"{top}/lib", f"{top}/libexec"):
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tar.addfile(info)
        info = tarfile.TarInfo(f"{top}/libexec/Sizer")
        info.size = len(script)
        info.mode = 0o755
        tar.addfile(info, BytesIO(script))
        loader = b"ELF-loader\n"
        info = tarfile.TarInfo(f"{top}/lib/ld-linux-x86-64.so.2")
        info.size = len(loader)
        info.mode = 0o644
        tar.addfile(info, BytesIO(loader))
        link = tarfile.TarInfo(f"{top}/bin/Sizer")
        link.type = tarfile.SYMTYPE
        link.linkname = "../libexec/Sizer"
        link.mode = 0o755
        tar.addfile(link)
    return buffer.getvalue()


def build_sizer_root_symlink_archive() -> bytes:
    # The top-level ecc-sizer-<version> entry is a symlink to payload/, so a
    # root found by following it validates but promote_dir would move only
    # the link and leave a dangling destination behind.
    top = f"ecc-sizer-{SIZER_VERSION}"
    script = sizer_script()
    buffer = BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name in ("payload/bin", "payload/lib", "payload/libexec"):
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tar.addfile(info)
        info = tarfile.TarInfo("payload/bin/Sizer")
        info.size = len(script)
        info.mode = 0o755
        tar.addfile(info, BytesIO(script))
        payload = b"ELF-sizer-payload\n"
        info = tarfile.TarInfo("payload/libexec/Sizer")
        info.size = len(payload)
        info.mode = 0o755
        tar.addfile(info, BytesIO(payload))
        loader = b"ELF-loader\n"
        info = tarfile.TarInfo("payload/lib/ld-linux-x86-64.so.2")
        info.size = len(loader)
        info.mode = 0o644
        tar.addfile(info, BytesIO(loader))
        root = tarfile.TarInfo(top)
        root.type = tarfile.SYMTYPE
        root.linkname = "payload"
        root.mode = 0o755
        tar.addfile(root)
    return buffer.getvalue()


def build_pdk_base_archive() -> bytes:
    members: dict[str, bytes | None] = {f"icsprout55-pdk/{TECH_LEF}": b"VERSION 5.8 ;\n"}
    for path in CELL_LEFS:
        members[f"icsprout55-pdk/{path}"] = b"MACRO TEST ;\nEND TEST\n"
    return pack_tar(members, compression="gz")


def build_named_bz2(kind: str, filename: str) -> bytes:
    # Real supplemental archives carry a top-level liberty/ or gds/ directory,
    # so the installer extracts them beside the cell or IO parent directory.
    member = f"{kind}/{filename}"
    return pack_tar({member: b"contents of %s\n" % member.encode()}, compression="bz2")


def build_release_assets(*, version: str = "0.1.0-alpha.11") -> dict[str, PackedAsset]:
    assets: dict[str, PackedAsset] = {}
    ecc = build_ecc_archive(version)
    assets["ecc-cli-linux-x86_64.tar.gz"] = PackedAsset(
        "ecc-cli-linux-x86_64.tar.gz", ecc, sha256_bytes(ecc)
    )
    oss = build_oss_archive()
    assets["oss-cad-suite-linux-x64-20260827.tgz"] = PackedAsset(
        "oss-cad-suite-linux-x64-20260827.tgz", oss, sha256_bytes(oss)
    )
    sizer = build_sizer_archive()
    assets[SIZER_ASSET] = PackedAsset(SIZER_ASSET, sizer, sha256_bytes(sizer))
    pdk_base = build_pdk_base_archive()
    assets["icsprout55-pdk-v1.10.102.tar.gz"] = PackedAsset(
        "icsprout55-pdk-v1.10.102.tar.gz", pdk_base, sha256_bytes(pdk_base)
    )
    for name, dest, filename in LIBERTY_SPECS:
        data = build_named_bz2("liberty", filename)
        assets[name] = PackedAsset(name, data, sha256_bytes(data), dest=dest, kind="liberty")
    for name, dest, filename in GDS_SPECS:
        data = build_named_bz2("gds", filename)
        assets[name] = PackedAsset(name, data, sha256_bytes(data), dest=dest, kind="gds")
    return assets


def liberty_paths() -> tuple[str, ...]:
    return tuple(f"{dest}/liberty/{filename}" for _, dest, filename in LIBERTY_SPECS)


class AssetServer(ThreadingHTTPServer):
    def __init__(self, routes: dict[str, dict[str, Any]]) -> None:
        super().__init__(("127.0.0.1", 0), _AssetHandler)
        self.routes = routes


class _AssetHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:
        route = self.server.routes.get(self.path)  # type: ignore[attr-defined]
        if route is None:
            self.send_error(404)
            return
        if "redirect" in route:
            self.send_response(302)
            self.send_header("Location", route["redirect"])
            self.end_headers()
            return
        status = int(route.get("status", 200))
        if status != 200:
            self.send_error(status)
            return
        data: bytes = route.get("data", b"")
        stall = float(route.get("stall", 0))
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if stall:
            self.wfile.write(data[:64] if data else b"x")
            self.wfile.flush()
            time.sleep(stall)
            return
        self.wfile.write(data)


def start_server(routes: dict[str, dict[str, Any]]) -> AssetServer:
    server = AssetServer(routes)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def server_base(server: AssetServer) -> str:
    host, port = server.server_address[:2]
    return f"http://{host}:{port}"


def default_routes(assets: dict[str, PackedAsset]) -> dict[str, dict[str, Any]]:
    routes: dict[str, dict[str, Any]] = {}
    for asset in assets.values():
        payload = {"data": asset.data}
        routes[f"/github/{asset.name}"] = payload
        routes[f"/cnb/{asset.name}"] = payload
    return routes


def render_installer(
    template: str,
    assets: dict[str, PackedAsset],
    base: str,
    *,
    version: str = "0.1.0-alpha.11",
    ecc_github: str | None = None,
    ecc_cnb: str | None = None,
) -> str:
    ecc = assets["ecc-cli-linux-x86_64.tar.gz"]
    oss = assets["oss-cad-suite-linux-x64-20260827.tgz"]
    sizer = assets[SIZER_ASSET]
    pdk_base = assets["icsprout55-pdk-v1.10.102.tar.gz"]
    rows = []
    for spec in (*LIBERTY_SPECS, *GDS_SPECS):
        packed = assets[spec[0]]
        rows.append(
            "\t".join(
                (
                    packed.name,
                    packed.sha256,
                    f"{base}/github/{packed.name}",
                    f"{base}/cnb/{packed.name}",
                    packed.dest or "",
                )
            )
        )
    mapping = {
        "ECC_VERSION": version,
        "ECC_TAG": f"v{version}",
        "ECC_ASSET_NAME": ecc.name,
        "ECC_SHA256": ecc.sha256,
        "ECC_SIZE": str(len(ecc.data)),
        "ECC_GITHUB_URL": ecc_github or f"{base}/github/{ecc.name}",
        "ECC_CNB_URL": ecc_cnb or f"{base}/cnb/{ecc.name}",
        "MIN_GLIBC_MAJOR": "2",
        "MIN_GLIBC_MINOR": "34",
        "OSS_CAD_VERSION": "20260827",
        "OSS_CAD_ASSET_NAME": oss.name,
        "OSS_CAD_SHA256": oss.sha256,
        "OSS_CAD_URL": f"{base}/github/{oss.name}",
        "OSS_CAD_CNB_URL": f"{base}/cnb/{oss.name}",
        "SIZER_VERSION": SIZER_VERSION,
        "SIZER_ASSET_NAME": sizer.name,
        "SIZER_SHA256": sizer.sha256,
        "SIZER_SIZE": str(len(sizer.data)),
        "SIZER_URL": f"{base}/github/{sizer.name}",
        "SIZER_CNB_URL": f"{base}/cnb/{sizer.name}",
        "SIZER_CNB_SHA256": "",
        "PDK_NAME": "icsprout55",
        "PDK_VERSION": "v1.10.102",
        "PDK_BASE_ASSET_NAME": pdk_base.name,
        "PDK_BASE_SHA256": pdk_base.sha256,
        "PDK_BASE_URL": f"{base}/github/{pdk_base.name}",
        "PDK_BASE_CNB_URL": f"{base}/cnb/{pdk_base.name}",
        "PDK_BASE_CNB_SHA256": pdk_base.sha256,
        "PDK_TECH_LEF": TECH_LEF,
        "PDK_CELL_LEFS": "\n".join(CELL_LEFS),
        "PDK_ASSET_TABLE": "\n".join(rows),
        "PDK_LIBERTY_FILES": "\n".join(liberty_paths()),
    }
    rendered = template
    for key in PLACEHOLDERS:
        rendered = rendered.replace(f"@{key}@", mapping[key])
    leftover = [key for key in PLACEHOLDERS if f"@{key}@" in rendered]
    if leftover:
        raise RuntimeError(f"unsubstituted installer placeholders: {leftover}")
    if not rendered.endswith("\n"):
        rendered += "\n"
    return rendered.replace("\r\n", "\n")


def write_installer(text: str, path: Path) -> Path:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def xdg_env(root: Path, *, extra_path: str = "") -> dict[str, str]:
    home = root / "home"
    data = root / "data"
    bindir = root / "bin"
    cache = root / "cache"
    config = root / "config"
    for path in (home, data, bindir, cache, config):
        path.mkdir(parents=True, exist_ok=True)
    path_value = os.environ.get("PATH", "/usr/bin:/bin")
    if extra_path:
        path_value = f"{extra_path}:{path_value}"
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "XDG_DATA_HOME": str(data),
            "XDG_BIN_HOME": str(bindir),
            "XDG_CACHE_HOME": str(cache),
            "XDG_CONFIG_HOME": str(config),
            "PATH": path_value,
            "SHELL": env.get("SHELL", "/bin/sh"),
        }
    )
    env.pop("ECC_WITH_TOOLCHAIN", None)
    env.pop("ECC_DOWNLOAD_SOURCE", None)
    env.pop("ECC_INSTALL_DIR", None)
    return env


def write_fake_cmd(directory: Path, name: str, body: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def run_installer(
    installer: Path,
    env: dict[str, str],
    *args: str,
    timeout: int = 120,
    shell: str = "dash",
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [shell, str(installer), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def roots(env: dict[str, str]) -> tuple[Path, Path, Path, Path]:
    return (
        Path(env["XDG_DATA_HOME"]) / "ecc",
        Path(env["XDG_BIN_HOME"]),
        Path(env["XDG_CACHE_HOME"]) / "ecc",
        Path(env["XDG_CONFIG_HOME"]) / "ecc",
    )


def read_wrapper_env(wrapper: Path, env: dict[str, str]) -> dict[str, str]:
    result = subprocess.run(
        [str(wrapper), "dump-env"],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    parsed: dict[str, str] = {}
    for line in result.stdout.splitlines():
        key, _, value = line.partition("=")
        parsed[key] = value
    return parsed


def fail(message: str) -> None:
    raise AssertionError(message)


class Harness:
    def __init__(self, template: str, work: Path) -> None:
        self.template = template
        self.work = work
        self.assets = build_release_assets()
        self.routes = default_routes(self.assets)
        self.server = start_server(self.routes)
        self.base = server_base(self.server)
        self._n = 0

    def close(self) -> None:
        self.server.shutdown()

    def tmp(self) -> Path:
        self._n += 1
        path = self.work / f"case-{self._n}"
        path.mkdir()
        return path

    def installer(
        self,
        dest: Path,
        *,
        assets: dict[str, PackedAsset] | None = None,
        version: str = "0.1.0-alpha.11",
        ecc_github: str | None = None,
        ecc_cnb: str | None = None,
    ) -> Path:
        text = render_installer(
            self.template,
            assets or self.assets,
            self.base,
            version=version,
            ecc_github=ecc_github,
            ecc_cnb=ecc_cnb,
        )
        return write_installer(text, dest)


def test_syntax(h: Harness) -> None:
    path = h.tmp() / "installer.sh"
    h.installer(path)
    for shell in ("dash", "bash"):
        result = subprocess.run([shell, "-n", str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"{shell} -n failed: {result.stderr}")


def test_github_success(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    installer = h.installer(root / "installer.sh")
    result = run_installer(installer, env)
    if result.returncode != 0:
        fail(result.stderr)
    data, bindir, _cache, config = roots(env)
    wrapper = bindir / "ecc"
    if wrapper.read_text().splitlines()[:2] != ["#!/bin/sh", "# ecos-release-wrapper-v1"]:
        fail("wrapper marker missing")
    dumped = read_wrapper_env(wrapper, env)
    if dumped["OSS"] or dumped["PDK"] or dumped["YOSYS_PLUGINPATH"] or dumped["YOSYS_DATDIR"]:
        fail(f"ecc-only install leaked toolchain env: {dumped}")
    receipt = json.loads((config / "ecc-receipt.json").read_text())
    if receipt["binaries"] != ["ecc"] or receipt["version"] != "0.1.0-alpha.11":
        fail(receipt)
    if not (data / "v0.1.0-alpha.11" / "ecc").is_file():
        fail("payload missing")


def test_github_failure_falls_back_to_cnb(h: Harness) -> None:
    h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {"status": 500}
    try:
        root = h.tmp()
        result = run_installer(h.installer(root / "installer.sh"), xdg_env(root))
        if result.returncode != 0:
            fail(result.stderr)
        if "failed to download" not in result.stderr:
            fail(result.stderr)
    finally:
        h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }


def test_forced_source_modes(h: Harness) -> None:
    root = h.tmp()
    installer = h.installer(root / "installer.sh")
    ok = run_installer(installer, xdg_env(root / "gh"), "--download-source", "github")
    if ok.returncode != 0:
        fail(ok.stderr)
    h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {"status": 404}
    try:
        cnb = run_installer(installer, xdg_env(root / "cnb"), "--download-source", "cnb")
        if cnb.returncode != 0:
            fail(cnb.stderr)
        h.routes["/cnb/ecc-cli-linux-x86_64.tar.gz"] = {"status": 404}
        failed = run_installer(installer, xdg_env(root / "none"))
        if failed.returncode == 0:
            fail("expected both sources to fail")
    finally:
        h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }
        h.routes["/cnb/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }


def test_checksum_mismatch(h: Harness) -> None:
    h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {"data": b"not-the-archive"}
    h.routes["/cnb/ecc-cli-linux-x86_64.tar.gz"] = {"data": b"also-wrong"}
    try:
        root = h.tmp()
        env = xdg_env(root)
        result = run_installer(h.installer(root / "installer.sh"), env)
        if result.returncode == 0 or "checksum mismatch" not in result.stderr:
            fail(result.stderr)
        _data, bindir, _cache, config = roots(env)
        if (bindir / "ecc").exists() or (config / "ecc-receipt.json").exists():
            fail("partial install after checksum mismatch")
    finally:
        h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }
        h.routes["/cnb/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }


def test_unsupported_platform(h: Harness) -> None:
    root = h.tmp()
    installer = h.installer(root / "installer.sh")
    fake = root / "fakebin"
    write_fake_cmd(fake, "uname", '#!/bin/sh\n[ "$1" = -s ] && echo Darwin || echo x86_64\n')
    result = run_installer(installer, xdg_env(root / "os", extra_path=str(fake)))
    if result.returncode == 0 or "os=Darwin" not in result.stderr:
        fail(result.stderr)
    write_fake_cmd(fake, "uname", '#!/bin/sh\n[ "$1" = -s ] && echo Linux || echo aarch64\n')
    result = run_installer(installer, xdg_env(root / "cpu", extra_path=str(fake)))
    if result.returncode == 0 or "cpu=aarch64" not in result.stderr:
        fail(result.stderr)
    write_fake_cmd(fake, "ldd", "#!/bin/sh\necho 'musl libc (aarch64) 1.2.4'\n")
    write_fake_cmd(fake, "uname", '#!/bin/sh\n[ "$1" = -s ] && echo Linux || echo x86_64\n')
    result = run_installer(installer, xdg_env(root / "musl", extra_path=str(fake)))
    if result.returncode == 0 or "libc=musl" not in result.stderr:
        fail(result.stderr)
    write_fake_cmd(fake, "ldd", "#!/bin/sh\necho 'ldd (GNU libc) 2.31'\n")
    result = run_installer(installer, xdg_env(root / "old", extra_path=str(fake)))
    if result.returncode == 0 or "libc_version=2.31" not in result.stderr:
        fail(result.stderr)


def test_unsupported_bitness(h: Harness) -> None:
    root = h.tmp()
    installer = h.installer(root / "installer.sh")
    fake = root / "fakebin"
    real_head = shutil.which("head")
    if real_head is None:
        fail("head not found")
    write_fake_cmd(
        fake,
        "head",
        f"""#!/bin/sh
if [ "$1" = "-c" ] && [ "$2" = "5" ]; then
  printf '\\177ELF\\001'
  exit 0
fi
exec {real_head} "$@"
""",
    )
    result = run_installer(installer, xdg_env(root, extra_path=str(fake)))
    if result.returncode == 0 or "bitness=32" not in result.stderr:
        fail(result.stderr)


def test_path_guidance(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    profile = Path(env["HOME"]) / ".profile"
    profile.write_text("# keep\n")
    result = run_installer(h.installer(root / "installer.sh"), env)
    if result.returncode != 0:
        fail(result.stderr)
    if "which is not in PATH" not in result.stderr or "export PATH=" not in result.stderr:
        fail(result.stderr)
    if profile.read_text() != "# keep\n":
        fail("profile mutated")


def test_toolchain_wrapper(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    env["PATH"] = f"{env['XDG_BIN_HOME']}:{env['PATH']}"
    result = run_installer(h.installer(root / "installer.sh"), env, "--with-toolchain")
    if result.returncode != 0:
        fail(result.stderr)
    data, bindir, _cache, _config = roots(env)
    dumped = read_wrapper_env(bindir / "ecc", env)
    oss = data / "tools" / "oss-cad-suite" / "20260827"
    pdk = data / "pdks" / "icsprout55" / "v1.10.102"
    sizer = data / "tools" / "ecc-sizer" / SIZER_VERSION
    if dumped["OSS"] != str(oss) or dumped["PDK"] != str(pdk):
        fail(dumped)
    if str(oss / "bin") in dumped["PATH"].split(":"):
        fail("oss bin leaked onto PATH")
    if dumped["YOSYS_PLUGINPATH"] or dumped["YOSYS_DATDIR"]:
        fail(dumped)
    if not (oss / "bin" / "yosys").is_file():
        fail("yosys missing")
    if not (sizer / "bin" / "Sizer").is_file() or not os.access(sizer / "bin" / "Sizer", os.X_OK):
        fail("sizer missing or not executable")
    if not (sizer / "libexec" / "Sizer").is_file():
        fail("sizer libexec payload missing")
    for liberty in liberty_paths():
        if (pdk / liberty).stat().st_size <= 0:
            fail(liberty)


def test_ecc_only_upgrade_preserves_toolchain(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    first = h.installer(root / "first.sh")
    if run_installer(first, env, "--with-toolchain").returncode != 0:
        fail("first toolchain install failed")
    second = h.installer(root / "second.sh", version="0.1.0-alpha.12")
    result = run_installer(second, env)
    if result.returncode != 0:
        fail(result.stderr)
    data, bindir, _cache, _config = roots(env)
    dumped = read_wrapper_env(bindir / "ecc", env)
    if not dumped["OSS"].endswith("/tools/oss-cad-suite/20260827"):
        fail(dumped)
    if not (data / "v0.1.0-alpha.11").is_dir() or not (data / "v0.1.0-alpha.12").is_dir():
        fail("version dirs missing")
    if not (data / "tools" / "ecc-sizer" / SIZER_VERSION / "bin" / "Sizer").is_file():
        fail("sizer missing after ecc-only upgrade")


def test_failed_first_install(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    env["ECC_DOWNLOAD_SOURCE"] = "nope"
    result = run_installer(h.installer(root / "installer.sh"), env)
    if result.returncode == 0:
        fail("invalid source succeeded")
    _data, bindir, _cache, config = roots(env)
    if (bindir / "ecc").exists() or (config / "ecc-receipt.json").exists():
        fail("failed first install left artifacts")


def test_failed_upgrade_preserves_wrapper(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    first = h.installer(root / "first.sh")
    if run_installer(first, env).returncode != 0:
        fail("first install failed")
    _data, bindir, _cache, config = roots(env)
    wrapper_before = (bindir / "ecc").read_text()
    receipt_before = (config / "ecc-receipt.json").read_text()
    bad = build_ecc_archive("0.1.0-alpha.12", fail=True)
    packed = PackedAsset("ecc-cli-linux-x86_64.tar.gz", bad, sha256_bytes(bad))
    h.routes["/github/ecc-next.tar.gz"] = {"data": bad}
    h.routes["/cnb/ecc-next.tar.gz"] = {"data": bad}
    mutated = dict(h.assets)
    mutated["ecc-cli-linux-x86_64.tar.gz"] = packed
    second = h.installer(
        root / "second.sh",
        assets=mutated,
        version="0.1.0-alpha.12",
        ecc_github=f"{h.base}/github/ecc-next.tar.gz",
        ecc_cnb=f"{h.base}/cnb/ecc-next.tar.gz",
    )
    result = run_installer(second, env)
    if result.returncode == 0:
        fail("failing payload succeeded")
    if (bindir / "ecc").read_text() != wrapper_before or (
        config / "ecc-receipt.json"
    ).read_text() != receipt_before:
        fail("failed upgrade mutated wrapper/receipt")


def test_corrupted_same_version(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    installer = h.installer(root / "installer.sh")
    if run_installer(installer, env).returncode != 0:
        fail("first install failed")
    data, bindir, _cache, _config = roots(env)
    wrapper_before = (bindir / "ecc").read_text()
    target = data / "v0.1.0-alpha.11" / "ecc"
    target.write_text("#!/bin/sh\nexit 1\n")
    target.chmod(target.stat().st_mode | stat.S_IXUSR)
    result = run_installer(installer, env)
    if result.returncode == 0 or "move it aside" not in result.stderr:
        fail(result.stderr)
    if (bindir / "ecc").read_text() != wrapper_before:
        fail("wrapper changed")


def test_three_versions(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    for version in ("0.1.0-alpha.9", "0.1.0-alpha.10", "0.1.0-alpha.11"):
        result = run_installer(h.installer(root / f"{version}.sh", version=version), env)
        if result.returncode != 0:
            fail(result.stderr)
    data, bindir, _cache, _config = roots(env)
    for version in ("v0.1.0-alpha.9", "v0.1.0-alpha.10", "v0.1.0-alpha.11"):
        if not (data / version).is_dir():
            fail(version)
    if "ECC_VERSION='v0.1.0-alpha.11'" not in (bindir / "ecc").read_text():
        fail("wrapper not pointing at latest")


def test_idempotent_reinstall(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    old = h.installer(root / "old.sh", version="0.1.0-alpha.10")
    current = h.installer(root / "cur.sh")
    if run_installer(old, env).returncode != 0 or run_installer(current, env).returncode != 0:
        fail("install failed")
    again = run_installer(current, env)
    if again.returncode != 0:
        fail(again.stderr)
    data, _bindir, _cache, _config = roots(env)
    if not (data / "v0.1.0-alpha.10").is_dir() or not (data / "v0.1.0-alpha.11").is_dir():
        fail("version dirs missing after reinstall")


def test_live_lock(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    data, _bindir, _cache, _config = roots(env)
    data.mkdir(parents=True, exist_ok=True)
    lock = data / ".ecc-install-lock"
    lock.mkdir()
    installer = h.installer(root / "installer.sh")
    blocked = run_installer(installer, env)
    if blocked.returncode == 0 or str(lock) not in blocked.stderr:
        fail(blocked.stderr)
    if (roots(env)[1] / "ecc").exists():
        fail("lock did not block wrapper")
    lock.rmdir()
    retry = run_installer(installer, env)
    if retry.returncode != 0:
        fail(retry.stderr)


def test_receipt_write_failure(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    fake = root / "fakebin"
    real_mv = shutil.which("mv")
    if real_mv is None:
        fail("mv not found")
    write_fake_cmd(
        fake,
        "mv",
        f"""#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *ecc-receipt.json) exit 1 ;;
  esac
done
exec {real_mv} "$@"
""",
    )
    env["PATH"] = f"{fake}:{env['PATH']}"
    result = run_installer(h.installer(root / "installer.sh"), env)
    if result.returncode != 0:
        fail(result.stderr)
    if "failed to write install receipt" not in result.stderr:
        fail(result.stderr)
    if not (roots(env)[1] / "ecc").is_file():
        fail("wrapper missing after receipt failure")


def test_stale_receipt_and_unowned_binary(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    _data, bindir, _cache, config = roots(env)
    config.mkdir(parents=True, exist_ok=True)
    (config / "ecc-receipt.json").write_text("{not json")
    result = run_installer(h.installer(root / "installer.sh"), env)
    if result.returncode != 0:
        fail(result.stderr)
    json.loads((config / "ecc-receipt.json").read_text())
    env2 = xdg_env(root / "owned")
    bindir2 = Path(env2["XDG_BIN_HOME"])
    bindir2.mkdir(parents=True, exist_ok=True)
    (bindir2 / "ecc").write_text("#!/bin/sh\necho stolen\n")
    blocked = run_installer(h.installer(root / "owned.sh"), env2)
    if blocked.returncode == 0 or "unowned binary" not in blocked.stderr:
        fail(blocked.stderr)


def test_shadowed_ecc(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    shadow = root / "shadow"
    write_fake_cmd(shadow, "ecc", "#!/bin/sh\necho other\n")
    env["PATH"] = f"{shadow}:{env['XDG_BIN_HOME']}:{env['PATH']}"
    result = run_installer(h.installer(root / "installer.sh"), env)
    if result.returncode != 0:
        fail(result.stderr)
    if "shadowed by" not in result.stderr:
        fail(result.stderr)
    if not (Path(env["XDG_CONFIG_HOME"]) / "ecc" / "ecc-receipt.json").is_file():
        fail("receipt missing")


def test_unexpected_member_type(h: Harness) -> None:
    buffer = BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        info = tarfile.TarInfo("ecc")
        payload = b"#!/bin/sh\nexit 0\n"
        info.size = len(payload)
        info.mode = 0o755
        tar.addfile(info, BytesIO(payload))
        fifo = tarfile.TarInfo("fifo")
        fifo.type = tarfile.FIFOTYPE
        tar.addfile(fifo)
        internal = tarfile.TarInfo("_internal/torch/bin/torch_shm_manager")
        blob = b"x"
        internal.size = len(blob)
        internal.mode = 0o755
        tar.addfile(internal, BytesIO(blob))
    data = buffer.getvalue()
    packed = PackedAsset("ecc-cli-linux-x86_64.tar.gz", data, sha256_bytes(data))
    h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {"data": data}
    h.routes["/cnb/ecc-cli-linux-x86_64.tar.gz"] = {"data": data}
    try:
        mutated = dict(h.assets)
        mutated["ecc-cli-linux-x86_64.tar.gz"] = packed
        root = h.tmp()
        result = run_installer(h.installer(root / "bad.sh", assets=mutated), xdg_env(root))
        if result.returncode == 0:
            fail("fifo archive accepted")
        if (
            "unexpected filesystem object types" not in result.stderr
            and "smoke tests failed" not in result.stderr
        ):
            fail(result.stderr)
    finally:
        h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }
        h.routes["/cnb/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }


def test_toolchain_failure_keeps_wrapper(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    first = h.installer(root / "first.sh")
    if run_installer(first, env).returncode != 0:
        fail("first install failed")
    wrapper_before = (Path(env["XDG_BIN_HOME"]) / "ecc").read_text()
    bad_oss = build_oss_archive(slang=False)
    packed = PackedAsset("oss-cad-suite-linux-x64-20260827.tgz", bad_oss, sha256_bytes(bad_oss))
    h.routes["/github/oss-cad-suite-linux-x64-20260827.tgz"] = {"data": bad_oss}
    h.routes["/cnb/oss-cad-suite-linux-x64-20260827.tgz"] = {"data": bad_oss}
    try:
        mutated = dict(h.assets)
        mutated["oss-cad-suite-linux-x64-20260827.tgz"] = packed
        result = run_installer(
            h.installer(root / "second.sh", assets=mutated), env, "--with-toolchain"
        )
        if result.returncode == 0:
            fail("bad yosys succeeded")
        if (Path(env["XDG_BIN_HOME"]) / "ecc").read_text() != wrapper_before:
            fail("wrapper mutated")
        data = Path(env["XDG_DATA_HOME"]) / "ecc"
        if not (data / "v0.1.0-alpha.11").is_dir():
            fail("ecc payload missing")
    finally:
        h.routes["/github/oss-cad-suite-linux-x64-20260827.tgz"] = {
            "data": h.assets["oss-cad-suite-linux-x64-20260827.tgz"].data
        }
        h.routes["/cnb/oss-cad-suite-linux-x64-20260827.tgz"] = {
            "data": h.assets["oss-cad-suite-linux-x64-20260827.tgz"].data
        }


def test_sizer_bad_layout(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    bad = pack_tar({"ecc-sizer-0.1.0-alpha/README": b"no binaries here\n"}, compression="gz")
    saved_github = h.routes[f"/github/{SIZER_ASSET}"]
    try:
        h.routes[f"/github/{SIZER_ASSET}"] = {"data": bad}
        mutated = dict(h.assets)
        mutated[SIZER_ASSET] = PackedAsset(SIZER_ASSET, bad, sha256_bytes(bad))
        result = run_installer(
            h.installer(root / "installer.sh", assets=mutated), env, "--with-toolchain"
        )
        if result.returncode == 0 or "missing the expected bin/Sizer layout" not in result.stderr:
            fail(result.stderr)
        data = Path(env["XDG_DATA_HOME"]) / "ecc"
        if (data / "tools" / "ecc-sizer" / SIZER_VERSION).exists():
            fail("partial sizer install survived layout failure")
    finally:
        h.routes[f"/github/{SIZER_ASSET}"] = saved_github


def test_sizer_wrong_version_banner(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    # 0.1.0-alpha.1 satisfies an unanchored "v0.1.0-alpha" substring match,
    # so this pins the exact-token comparison.
    bad = build_sizer_archive(version="0.1.0-alpha.1")
    saved_github = h.routes[f"/github/{SIZER_ASSET}"]
    try:
        h.routes[f"/github/{SIZER_ASSET}"] = {"data": bad}
        mutated = dict(h.assets)
        mutated[SIZER_ASSET] = PackedAsset(SIZER_ASSET, bad, sha256_bytes(bad))
        result = run_installer(
            h.installer(root / "installer.sh", assets=mutated), env, "--with-toolchain"
        )
        if result.returncode == 0 or "ecc-sizer validation failed" not in result.stderr:
            fail(result.stderr)
        data = Path(env["XDG_DATA_HOME"]) / "ecc"
        if (data / "tools" / "ecc-sizer" / SIZER_VERSION).exists():
            fail("partial sizer install survived banner mismatch")
    finally:
        h.routes[f"/github/{SIZER_ASSET}"] = saved_github


def test_sizer_symlink_rejected(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    bad = build_sizer_symlink_archive()
    saved_github = h.routes[f"/github/{SIZER_ASSET}"]
    try:
        h.routes[f"/github/{SIZER_ASSET}"] = {"data": bad}
        mutated = dict(h.assets)
        mutated[SIZER_ASSET] = PackedAsset(SIZER_ASSET, bad, sha256_bytes(bad))
        result = run_installer(
            h.installer(root / "installer.sh", assets=mutated), env, "--with-toolchain"
        )
        if result.returncode == 0 or "ecc-sizer validation failed" not in result.stderr:
            fail(result.stderr)
        data = Path(env["XDG_DATA_HOME"]) / "ecc"
        if (data / "tools" / "ecc-sizer" / SIZER_VERSION).exists():
            fail("partial sizer install survived symlink rejection")
    finally:
        h.routes[f"/github/{SIZER_ASSET}"] = saved_github


def test_sizer_root_symlink_rejected(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    bad = build_sizer_root_symlink_archive()
    saved_github = h.routes[f"/github/{SIZER_ASSET}"]
    try:
        h.routes[f"/github/{SIZER_ASSET}"] = {"data": bad}
        mutated = dict(h.assets)
        mutated[SIZER_ASSET] = PackedAsset(SIZER_ASSET, bad, sha256_bytes(bad))
        result = run_installer(
            h.installer(root / "installer.sh", assets=mutated), env, "--with-toolchain"
        )
        if result.returncode == 0 or "ecc-sizer validation failed" not in result.stderr:
            fail(result.stderr)
        dest = Path(env["XDG_DATA_HOME"]) / "ecc" / "tools" / "ecc-sizer" / SIZER_VERSION
        if dest.exists() or dest.is_symlink():
            fail("dangling sizer destination survived root symlink rejection")
    finally:
        h.routes[f"/github/{SIZER_ASSET}"] = saved_github


def test_missing_sizer_blocks_toolchain_export(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    first = h.installer(root / "first.sh")
    if run_installer(first, env, "--with-toolchain").returncode != 0:
        fail("first toolchain install failed")
    data, bindir, _cache, _config = roots(env)
    shutil.rmtree(data / "tools" / "ecc-sizer" / SIZER_VERSION)
    second = h.installer(root / "second.sh", version="0.1.0-alpha.12")
    result = run_installer(second, env)
    if result.returncode != 0:
        fail(result.stderr)
    if "without the managed toolchain" not in result.stderr:
        fail(result.stderr)
    dumped = read_wrapper_env(bindir / "ecc", env)
    if dumped["OSS"] or dumped["PDK"]:
        fail(f"incomplete toolchain exported: {dumped}")


def test_conflicting_flags(h: Harness) -> None:
    root = h.tmp()
    installer = h.installer(root / "installer.sh")
    env = xdg_env(root)
    conflict = run_installer(installer, env, "-q", "-v")
    if conflict.returncode == 0 or "conflicting" not in conflict.stderr:
        fail(conflict.stderr)
    env["ECC_INSTALL_DIR"] = "relative/path"
    relative = run_installer(installer, env)
    if relative.returncode == 0 or "absolute path" not in relative.stderr:
        fail(relative.stderr)


def test_cnb_mode_toolchain(h: Harness) -> None:
    saved = dict(h.routes)
    try:
        for name in h.assets:
            h.routes[f"/github/{name}"] = {"status": 404}
        root = h.tmp()
        env = xdg_env(root)
        result = run_installer(
            h.installer(root / "installer.sh"),
            env,
            "--download-source",
            "cnb",
            "--with-toolchain",
        )
        if result.returncode != 0:
            fail(result.stderr)
        if "no CNB URL" in result.stderr:
            fail(result.stderr)
        data = Path(env["XDG_DATA_HOME"]) / "ecc"
        if not (data / "tools" / "oss-cad-suite" / "20260827" / "bin" / "yosys").is_file():
            fail("cnb toolchain missing yosys")
        if not (data / "tools" / "ecc-sizer" / SIZER_VERSION / "bin" / "Sizer").is_file():
            fail("cnb toolchain missing sizer")
    finally:
        h.routes.clear()
        h.routes.update(saved)


def test_toolchain_github_fallback(h: Harness) -> None:
    saved = dict(h.routes)
    try:
        h.routes["/github/oss-cad-suite-linux-x64-20260827.tgz"] = {"status": 500}
        h.routes["/github/icsprout55-pdk-v1.10.102.tar.gz"] = {"status": 500}
        h.routes[f"/github/{SIZER_ASSET}"] = {"status": 500}
        for spec in (*LIBERTY_SPECS, *GDS_SPECS):
            h.routes[f"/github/{spec[0]}"] = {"status": 500}
        root = h.tmp()
        result = run_installer(
            h.installer(root / "installer.sh"), xdg_env(root), "--with-toolchain"
        )
        if result.returncode != 0:
            fail(result.stderr)
        if "failed to download" not in result.stderr:
            fail(result.stderr)
    finally:
        h.routes.clear()
        h.routes.update(saved)


def test_redirect_stall_falls_back(h: Harness) -> None:
    h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {"redirect": f"{h.base}/stall/ecc"}
    h.routes["/stall/ecc"] = {"data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data, "stall": 35}
    try:
        root = h.tmp()
        result = run_installer(h.installer(root / "stall.sh"), xdg_env(root), timeout=90)
        if result.returncode != 0:
            fail(result.stderr)
    finally:
        h.routes.pop("/stall/ecc", None)
        h.routes["/github/ecc-cli-linux-x86_64.tar.gz"] = {
            "data": h.assets["ecc-cli-linux-x86_64.tar.gz"].data
        }


def test_bash_install(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    result = run_installer(h.installer(root / "installer.sh"), env, shell="bash")
    if result.returncode != 0:
        fail(result.stderr)
    if not (roots(env)[1] / "ecc").is_file():
        fail("bash install missing wrapper")


def test_github_base_url(h: Harness) -> None:
    root = h.tmp()
    env = xdg_env(root)
    env["ECC_GITHUB_BASE_URL"] = h.base
    installer = h.installer(
        root / "installer.sh",
        ecc_github="https://github.com/github/ecc-cli-linux-x86_64.tar.gz",
    )
    result = run_installer(installer, env, "--download-source", "github")
    if result.returncode != 0:
        fail(result.stderr)
    if not (roots(env)[1] / "ecc").is_file():
        fail("proxied GitHub download did not install")


CASES = [
    test_syntax,
    test_github_success,
    test_github_failure_falls_back_to_cnb,
    test_forced_source_modes,
    test_checksum_mismatch,
    test_unsupported_platform,
    test_unsupported_bitness,
    test_path_guidance,
    test_toolchain_wrapper,
    test_ecc_only_upgrade_preserves_toolchain,
    test_failed_first_install,
    test_failed_upgrade_preserves_wrapper,
    test_corrupted_same_version,
    test_three_versions,
    test_idempotent_reinstall,
    test_live_lock,
    test_receipt_write_failure,
    test_stale_receipt_and_unowned_binary,
    test_shadowed_ecc,
    test_unexpected_member_type,
    test_toolchain_failure_keeps_wrapper,
    test_sizer_bad_layout,
    test_sizer_wrong_version_banner,
    test_sizer_symlink_rejected,
    test_sizer_root_symlink_rejected,
    test_missing_sizer_blocks_toolchain_export,
    test_conflicting_flags,
    test_cnb_mode_toolchain,
    test_toolchain_github_fallback,
    test_redirect_stall_falls_back,
    test_bash_install,
    test_github_base_url,
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    args = parser.parse_args()
    template = Path(args.template).read_text()
    work = Path(tempfile.mkdtemp(prefix="ecc-e2e-"))
    harness = Harness(template, work)
    failed = 0
    try:
        for case in CASES:
            try:
                case(harness)
                print(f"ok {case.__name__}", flush=True)
            except Exception as exc:  # noqa: BLE001
                failed += 1
                print(f"FAIL {case.__name__}: {exc}", file=sys.stderr, flush=True)
    finally:
        harness.close()
    if failed:
        print(f"{failed} failed", file=sys.stderr)
        return 1
    print(f"{len(CASES)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
