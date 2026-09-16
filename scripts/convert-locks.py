#!/usr/bin/env python3
"""One-shot converter: legacy toolchain.toml lock fields -> nix/_sources/generated.json.

Reads the pre-migration metadata/toolchain.toml (inline version/url/sha256/size
lock fields) and writes the initial nvfetcher-style lock file. Lock values are
the current production pins; this script exists to seed the lock file without
querying upstream (a first real bump must not pollute the regression gate).

Usage: scripts/convert-locks.py [toolchain.toml] [nix/_sources/generated.json]
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
import sys
import tomllib

# Lock entries whose upstream version is the release-tag path segment of their
# url (…/releases/download/<segment>/…).
TAG_FROM_URL = [
    "ecc",
    "oss_cad_suite",
    "sizer",
    "slang",
    "verilator",
    "riscv-toolchain",
]

# Lock entries pinned by hand: upstream version is the legacy `version` field
# verbatim (mutable -latest assets, the mpc-frame seed, and every pdk_pkg,
# which takes the [pdk] collection version).
MANUAL = [
    "ecc-fe",
    "ecc-fe-cpu-rtl",
    "ecc-fe-soc-ysyx-am",
    "ecc-fe-difftest-ref",
    "ecc-fe-examples",
    "surfer",
    "mpc-frame",
]

HEX64 = frozenset("0123456789abcdef")


def die(msg: str) -> None:
    sys.exit(f"convert-locks: {msg}")


def require_hex(label: str, value: str) -> str:
    if len(value) != 64 or any(c not in HEX64 for c in value):
        die(f"{label}: sha256 must be 64 lowercase hex chars, got {value!r}")
    return value


def require_size(label: str, value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        die(f"{label}: size must be a positive integer, got {value!r}")
    return value


def require_str(label: str, value: object) -> str:
    if not isinstance(value, str) or value == "":
        die(f"{label}: missing or empty value")
    return value


def sri(hex_sha: str) -> str:
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_sha)).decode("ascii")


def tag_from_url(label: str, url: str) -> str:
    marker = "/releases/download/"
    if marker not in url:
        die(f"{label}: url has no {marker} segment: {url}")
    rest = url.split(marker, 1)[1]
    tag = rest.split("/", 1)[0]
    if tag == "":
        die(f"{label}: empty tag segment in url: {url}")
    return tag


def entry(
    label: str,
    *,
    name: str | None,
    version: str,
    url: object,
    sha256: object,
    size: object,
    cnb_sha256: str | None = None,
    pinned: bool = False,
) -> dict:
    url_s = require_str(f"{label}.url", url)
    hex_sha = require_hex(f"{label}.sha256", require_str(f"{label}.sha256", sha256))
    # Entry shape mirrors nvfetcher's own generated.json entries (including
    # our patched-in size/sha256_hex/cnb_sha256 fields), so the first real
    # bump produces no structural churn.
    result = {
        "cargoLock": None,
        "cnb_sha256": None,
        "date": None,
        "extract": None,
        "name": label,
        "passthru": None,
        "pinned": pinned,
        "sha256_hex": hex_sha,
        "size": require_size(label, size),
        "src": {
            "name": name,
            "sha256": sri(hex_sha),
            "type": "url",
            "url": url_s,
        },
        "version": require_str(f"{label}.version", version),
    }
    if cnb_sha256 is not None:
        result["cnb_sha256"] = require_hex(f"{label}.cnb_sha256", cnb_sha256)
    return result


def main() -> None:
    toml_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("metadata/toolchain.toml")
    out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("nix/_sources/generated.json")

    doc = tomllib.loads(toml_path.read_text())
    locks: dict[str, dict] = {}

    for key in TAG_FROM_URL:
        section = doc.get(key)
        if not isinstance(section, dict):
            die(f"missing [{key}] section")
        url = require_str(f"{key}.url", section.get("url"))
        locks[key] = entry(
            key,
            name=None,
            version=tag_from_url(key, url),
            url=url,
            sha256=section.get("sha256"),
            size=section.get("size"),
        )

    for key in MANUAL:
        section = doc.get(key)
        if not isinstance(section, dict):
            die(f"missing [{key}] section")
        locks[key] = entry(
            key,
            name=None,
            version=require_str(f"{key}.version", section.get("version")),
            url=section.get("url"),
            sha256=section.get("sha256"),
            size=section.get("size"),
        )

    pdk = doc.get("pdk")
    if not isinstance(pdk, dict):
        die("missing [pdk] section")
    pdk_version = require_str("pdk.version", pdk.get("version"))

    pkgs = doc.get("pdk_pkg")
    if not isinstance(pkgs, list) or not pkgs:
        die("missing [[pdk_pkg]] tables")
    for pkg in pkgs:
        pkg_id = require_str("pdk_pkg.id", pkg.get("id"))
        if pkg_id in locks:
            die(f"duplicate lock entry: {pkg_id}")
        name = require_str(f"pdk_pkg:{pkg_id}.name", pkg.get("name"))
        url = require_str(f"pdk_pkg:{pkg_id}.url", pkg.get("url"))
        # src.name stays null when the asset name is the url basename
        # (nvfetcher's default); only the PDK base renames its archive.
        src_name = name if name != url.rsplit("/", 1)[-1] else None
        locks[pkg_id] = entry(
            pkg_id,
            name=src_name,
            version=pdk_version,
            url=url,
            sha256=pkg.get("sha256"),
            size=pkg.get("size"),
            cnb_sha256=pkg.get("cnb_sha256"),
            # the pdk_pkg entries stay pinned to the single [pdk].src.manual
            # version rule; nvfetcher marks them pinned on its runs too
            pinned=True,
        )

    expected = len(TAG_FROM_URL) + len(MANUAL) + len(pkgs)
    if len(locks) != expected or len(locks) != 21:
        die(f"expected 21 lock entries, produced {len(locks)}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(locks, indent=4, sort_keys=True) + "\n"
    out_path.write_text(text)
    print(f"wrote {out_path} with {len(locks)} entries")


if __name__ == "__main__":
    main()
