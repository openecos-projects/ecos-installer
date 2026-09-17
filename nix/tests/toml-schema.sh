#!/usr/bin/env bash
# Offline schema check for the ecos-bump driver: the real rules + locks must
# pass `bump check`, and each mutated fixture must fail with the expected
# message. Runs inside a nix build sandbox with `bump` on PATH.
#
# usage: toml-schema.sh REPO_ROOT
set -euo pipefail

repo="$1"

cd "$repo"
bump check

work="$TMPDIR/work"
mkdir -p "$work"

expect_fail() {
  name="$1"
  msg="$2"
  if bump check --rules "$work/case.toml" --locks "$repo/nix/_sources/generated.json" >"$work/out" 2>&1; then
    echo "case $name should have failed" >&2
    exit 1
  fi
  if ! grep -q "$msg" "$work/out"; then
    echo "case $name: expected message containing '$msg':" >&2
    cat "$work/out" >&2
    exit 1
  fi
}

mutate() {
  cp "$repo/nix/toolchain.toml" "$work/case.toml"
  chmod u+w "$work/case.toml"
  sed -i "$1" "$work/case.toml"
}

mutate '0,/^\[slang\]/s//[slang]\npost_install = []/'
expect_fail unknown-field "unknown field(s)"
mutate 's/^version_map = { strip_prefix = "v" }$/version_map = "bogus"/'
expect_fail bad-version-map "expected identity, strip_dashes"
mutate 's|slang-linux-x86_64.tar.gz|{bogus}/slang-linux-x86_64.tar.gz|'
expect_fail unknown-placeholder "unknown placeholder(s)"
mutate 's|src = { github = "MikePopoloski/slang" }|src = { github = "MikePopoloski/slang", manual = "11.0" }|'
expect_fail two-src-families "exactly one of github, github_tag, git, manual"
mutate '0,/^kind = "liberty"/s//kind = "liberty"\nneeds_cnb_sha256 = true/'
expect_fail nonbase-cnb "needs_cnb_sha256 is only valid on the base package"
mutate 's|github = "openecos-projects/ecc"|github = "noslash"|'
expect_fail bad-src-owner "must look like owner/repo"

# a synthetic fixture repo drives discovery via --repo-root
fixture="$TMPDIR/fixture-repo"
mkdir -p "$fixture/nix/_sources"
cp "$repo/nix/toolchain.toml" "$fixture/nix/toolchain.toml"
cp "$repo/nix/_sources/generated.json" "$fixture/nix/_sources/generated.json"
bump check --repo-root "$fixture" | grep -q "rules and locks: OK"
