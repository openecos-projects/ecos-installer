#!/usr/bin/env python3
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Structured tar validation for installer publication. Nix derivation tool."""

import argparse
import json
import posixpath
import sys
import tarfile
from pathlib import Path, PurePosixPath

ALLOWED_TYPES = {
    tarfile.REGTYPE,
    tarfile.AREGTYPE,
    tarfile.DIRTYPE,
    tarfile.SYMTYPE,
    tarfile.LNKTYPE,
}


class UnsafeArchive(ValueError):
    pass


def _has_control(value: str) -> bool:
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in value)


def _normalized_member_path(name: str) -> str:
    stripped = name.lstrip("./")
    if stripped == "":
        raise UnsafeArchive(f"empty member path: {name!r}")
    return posixpath.normpath(stripped)


def _is_within(root: str, candidate: str) -> bool:
    root_n = posixpath.normpath(root)
    cand_n = posixpath.normpath(candidate)
    return cand_n == root_n or cand_n.startswith(root_n + "/")


def _validate_member(info: tarfile.TarInfo) -> None:
    name = info.name
    if name is None or name == "":
        raise UnsafeArchive("empty member path")
    if _has_control(name):
        raise UnsafeArchive(f"control character in member path: {name!r}")
    normalized = _normalized_member_path(name)
    if normalized.startswith("/") or PurePosixPath(name).is_absolute():
        raise UnsafeArchive(f"absolute member path: {name!r}")
    if any(part == ".." for part in PurePosixPath(normalized).parts):
        raise UnsafeArchive(f"parent traversal in member path: {name!r}")
    if info.type not in ALLOWED_TYPES:
        raise UnsafeArchive(f"unsupported member type {info.type!r} for {name}")
    if info.issym() or info.islnk():
        target = info.linkname or ""
        if not target:
            raise UnsafeArchive(f"empty link target for {name}")
        if _has_control(target):
            raise UnsafeArchive(f"control character in link target: {target!r}")
        if PurePosixPath(target).is_absolute() or target.startswith("/"):
            raise UnsafeArchive(f"absolute link target for {name}: {target!r}")
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(normalized), target))
        if any(part == ".." for part in PurePosixPath(resolved).parts) or resolved.startswith("/"):
            raise UnsafeArchive(f"link target for {name} escapes staging root: {target!r}")


def validate_archive(path: Path, *, require_liberty: bool) -> dict:
    members: list[str] = []
    liberty: list[str] = []
    with tarfile.open(path, mode="r:*") as tar:
        for info in tar.getmembers():
            _validate_member(info)
            members.append(info.name)
            if info.isfile() and _normalized_member_path(info.name).endswith(".lib"):
                liberty.append(_normalized_member_path(info.name))
    if require_liberty and not liberty:
        raise UnsafeArchive(f"{path.name} contains no .lib members")
    return {"members": members, "liberty_files": sorted(liberty)}


def liberty_destinations(dest: str, liberty_members: list[str]) -> list[str]:
    dest_root = _normalized_member_path(dest)
    destinations = []
    for member in liberty_members:
        joined = posixpath.normpath(posixpath.join(dest_root, member))
        if joined == dest_root or not _is_within(dest_root, joined):
            raise UnsafeArchive(f"Liberty member {member!r} escapes destination {dest!r}")
        destinations.append(joined)
    return sorted(destinations)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--require-liberty", action="store_true")
    parser.add_argument("--dest")
    parser.add_argument("--expect-liberty", action="append", default=[])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        inventory = validate_archive(Path(args.archive), require_liberty=args.require_liberty)
        if args.dest:
            inventory["destinations"] = liberty_destinations(args.dest, inventory["liberty_files"])
            for expected in args.expect_liberty:
                if expected not in inventory["destinations"]:
                    raise UnsafeArchive(f"missing expected Liberty path {expected}")
        if args.json:
            json.dump(inventory, sys.stdout)
            sys.stdout.write("\n")
        return 0
    except UnsafeArchive as exc:
        print(f"unsafe archive: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
