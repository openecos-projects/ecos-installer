"""One-time migration gate for the unified toolchain manifest.

Compares a pinned baseline tool-registry.json (curl of the legacy URL)
against a freshly built one and exits 0 only when every difference falls
into the accepted classes:

1. yosys version bump: version/url/sha256/size may change, nothing else.
2. PDK entry reshaping: base lock fields (url/sha256/size/strip_prefix)
   stay equal, the supplemental_assets array becomes a packages array
   with the same url/sha256/size per file plus cnb_url and dest, and
   post_install/supplemental_assets/requires disappear.
3. Resources moving off mutable -latest pins: only version/url/
   metadata_url may change.
4. Key order: normalized away before comparing.

Anything else (new or missing entities, unexpected field changes,
silent value drift inside an allowlisted object) is a violation and
fails the comparison.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

MUTABLE_LATEST_RESOURCES = frozenset(
    {
        "ecc-fe",
        "ecc-fe-cpu-rtl",
        "ecc-fe-soc-ysyx-am",
        "ecc-fe-difftest-ref",
        "ecc-fe-examples",
        "surfer",
    }
)

YOSYS_VERSION_FIELDS = frozenset({"version"})
YOSYS_PLATFORM_FIELDS = frozenset({"url", "sha256", "size"})
MUTABLE_VERSION_FIELDS = frozenset({"version"})
MUTABLE_PLATFORM_FIELDS = frozenset({"url", "metadata_url"})

TOOL_META_FIELDS = ("name", "display_name", "description", "category", "homepage")

PDK_BASE_FIELDS = ("url", "sha256", "size", "strip_prefix")
PDK_PACKAGE_FIELDS = frozenset({"path", "url", "cnb_url", "sha256", "size", "dest"})


def differing_fields(baseline: dict, candidate: dict) -> list[str]:
    return sorted(
        field
        for field in set(baseline) | set(candidate)
        if baseline.get(field) != candidate.get(field)
    )


def compare_tools(
    baseline: dict, candidate: dict, report: list[str], violations: list[str]
) -> None:
    baseline_tools = index_by(baseline["tools"], "name")
    candidate_tools = index_by(candidate["tools"], "name")
    if len(baseline_tools) != len(baseline["tools"]):
        violations.append("the baseline tools array has duplicate names")
    if len(candidate_tools) != len(candidate["tools"]):
        violations.append("the candidate tools array has duplicate names")
    if len(baseline_tools) != len(candidate_tools):
        violations.append("the tools array changed length")
    for name in sorted(set(baseline_tools) - set(candidate_tools)):
        violations.append(f"tool {name} is missing from the candidate")
    for name in sorted(set(candidate_tools) - set(baseline_tools)):
        violations.append(f"tool {name} is new in the candidate")

    for name in sorted(set(baseline_tools) & set(candidate_tools)):
        b, c = baseline_tools[name], candidate_tools[name]
        if name == "yosys":
            version_allowed, platform_allowed = YOSYS_VERSION_FIELDS, YOSYS_PLATFORM_FIELDS
        elif name in MUTABLE_LATEST_RESOURCES:
            version_allowed, platform_allowed = MUTABLE_VERSION_FIELDS, MUTABLE_PLATFORM_FIELDS
        else:
            version_allowed, platform_allowed = frozenset(), frozenset()

        meta_diff = [field for field in TOOL_META_FIELDS if b.get(field) != c.get(field)]
        if meta_diff:
            violations.append(f"tool {name}: {', '.join(meta_diff)} changed")
        if len(b["versions"]) != 1 or len(c["versions"]) != 1:
            violations.append(f"tool {name}: version count changed")
            continue
        bv, cv = b["versions"][0], c["versions"][0]
        version_diff = differing_fields(
            {k: v for k, v in bv.items() if k != "platforms"},
            {k: v for k, v in cv.items() if k != "platforms"},
        )
        unexpected = [field for field in version_diff if field not in version_allowed]
        if unexpected:
            violations.append(f"tool {name}: unexpected changes in {', '.join(unexpected)}")

        if set(bv.get("platforms", {})) != set(cv.get("platforms", {})):
            violations.append(f"tool {name}: platform keys changed")
            continue
        platform_diff: list[str] = []
        for platform_key in bv.get("platforms", {}):
            platform_diff.extend(
                differing_fields(bv["platforms"][platform_key], cv["platforms"][platform_key])
            )
        unexpected = [field for field in platform_diff if field not in platform_allowed]
        if unexpected:
            violations.append(
                f"tool {name}: unexpected platform changes in {', '.join(unexpected)}"
            )

        changed = sorted(set(version_diff) | set(platform_diff))
        if changed and not unexpected:
            report.append(f"{name}: changed {', '.join(changed)}")


def load(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def index_by(entries: list, key: str) -> dict[str, dict]:
    return {entry[key]: entry for entry in entries if isinstance(entry, dict) and key in entry}


def unchanged_outside(baseline: dict, candidate: dict, allowed: frozenset[str]) -> list[str]:
    violations = []
    for field in sorted(set(baseline) | set(candidate)):
        if field in allowed:
            continue
        if baseline.get(field) != candidate.get(field):
            violations.append(field)
    return violations


def compare_pdks(baseline: dict, candidate: dict, report: list[str], violations: list[str]) -> None:
    baseline_pdks, candidate_pdks = baseline["pdks"], candidate["pdks"]
    if len(baseline_pdks) != len(candidate_pdks):
        violations.append("the pdks array changed length")
        return
    for b, c in zip(baseline_pdks, candidate_pdks, strict=True):
        pdk_id = c.get("id", "?")
        for field in ("id", "display_name", "description", "category", "homepage"):
            if b.get(field) != c.get(field):
                violations.append(f"pdk {pdk_id}: {field} changed")
        b_versions = b["versions"]
        c_versions = c["versions"]
        if len(b_versions) != 1 or len(c_versions) != 1:
            violations.append(f"pdk {pdk_id}: version count changed")
            continue
        bv, cv = b_versions[0], c_versions[0]
        if bv.get("version") != cv.get("version"):
            violations.append(f"pdk {pdk_id}: published version changed")
        if "requires" in cv:
            violations.append(f"pdk {pdk_id}: candidate version carries requires")
        b_platforms, c_platforms = bv["platforms"], cv["platforms"]
        if set(b_platforms) != set(c_platforms):
            violations.append(f"pdk {pdk_id}: platform keys changed")
            continue
        for platform_key in b_platforms:
            bp, cp = b_platforms[platform_key], c_platforms[platform_key]
            for field in PDK_BASE_FIELDS:
                if bp.get(field) != cp.get(field):
                    violations.append(f"pdk {pdk_id}: base {field} changed")
            for field in ("post_install", "supplemental_assets"):
                if field in cp:
                    violations.append(f"pdk {pdk_id}: candidate keeps {field}")
            supplemental = bp.get("supplemental_assets", [])
            packages = cp.get("packages")
            if not isinstance(packages, list):
                violations.append(f"pdk {pdk_id}: candidate has no packages array")
                continue
            report.append(
                f"pdk {pdk_id}: {len(supplemental)} supplemental assets became "
                f"{len(packages)} packages"
            )
            if len(packages) != len(supplemental):
                violations.append(f"pdk {pdk_id}: package count does not match the baseline")
                continue
            by_path = {pkg.get("path"): pkg for pkg in packages if isinstance(pkg, dict)}
            for asset in supplemental:
                pkg = by_path.get(asset.get("path"))
                if pkg is None:
                    violations.append(f"pdk {pdk_id}: package for {asset.get('path')} is missing")
                    continue
                if frozenset(pkg) != PDK_PACKAGE_FIELDS:
                    violations.append(
                        f"pdk {pdk_id}: package {pkg.get('path')} has unexpected fields"
                    )
                for field in ("url", "sha256", "size"):
                    if pkg.get(field) != asset.get(field):
                        violations.append(
                            f"pdk {pdk_id}: package {pkg.get('path')} {field} drifted"
                        )
                for field in ("cnb_url", "dest"):
                    value = pkg.get(field)
                    if not isinstance(value, str) or not value:
                        violations.append(f"pdk {pdk_id}: package {pkg.get('path')} lacks {field}")


def compare_mpcs(baseline: dict, candidate: dict, violations: list[str]) -> None:
    baseline_mpcs, candidate_mpcs = baseline["mpcs"], candidate["mpcs"]
    if len(baseline_mpcs) != len(candidate_mpcs):
        violations.append("the mpcs array changed length")
        return
    for b, c in zip(baseline_mpcs, candidate_mpcs, strict=True):
        mpc_id = b.get("id", "?")
        if b != c:
            violations.append(f"mpc {mpc_id}: entry changed")


def compare(baseline: dict, candidate: dict) -> tuple[list[str], list[str]]:
    report: list[str] = []
    violations: list[str] = []
    if set(baseline) != set(candidate):
        violations.append("top-level keys changed")
        return report, violations
    if baseline["schema_version"] != candidate["schema_version"]:
        violations.append("schema_version changed")
    compare_tools(baseline, candidate, report, violations)
    compare_pdks(baseline, candidate, report, violations)
    compare_mpcs(baseline, candidate, violations)
    return report, violations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("baseline", help="pinned legacy tool-registry.json")
    parser.add_argument("candidate", help="freshly built tool-registry.json")
    args = parser.parse_args()

    report, violations = compare(load(args.baseline), load(args.candidate))

    print("Accepted differences observed:")
    for line in report or ["(none)"]:
        print(f"  - {line}")
    if violations:
        print("\nViolations:")
        for line in violations:
            print(f"  - {line}", file=sys.stderr)
        print("diff-registry: FAILED", file=sys.stderr)
        return 1
    print("\ndiff-registry: OK (entities matched by id, key order normalized)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
