#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: update-ecc <github-tag>}"

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
toml="$root/nix/toolchain.toml"
locks="$root/nix/_sources/generated.json"
if [[ ! -f $toml || ! -f $locks ]]; then
  echo "nix/toolchain.toml or nix/_sources/generated.json not found (run from the ecos-release checkout)" >&2
  exit 1
fi

rule="$(nix-instantiate --eval --strict --expr "let t = (builtins.fromTOML (builtins.readFile $toml)).ecc; in t.src.github + \" \" + t.url_template" | tr -d '\"')"
repo="${rule%% *}"
name="$(basename "${rule#* }")"
url="https://github.com/${repo}/releases/download/${tag}/${name}"

prefetch="$(nix-prefetch-url --print-path --type sha256 --name "$name" "$url")"
nix32="$(printf '%s\n' "$prefetch" | sed -n '1p')"
store_path="$(printf '%s\n' "$prefetch" | sed -n '2p')"
sri="$(nix hash convert --from nix32 --to sri --hash-algo sha256 "$nix32")"
hex="$(nix hash convert --from nix32 --to base16 --hash-algo sha256 "$nix32" | tr 'A-F' 'a-f')"
size="$(stat -c '%s' "$store_path")"

"$LOCK_EDIT" set "$locks" ecc "$tag" "$url" "$sri" "$hex" "$size"
echo "updated $locks for $tag"
