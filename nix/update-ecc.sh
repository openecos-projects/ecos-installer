#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: update-ecc <github-tag>}"
version="${tag#v}"

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
toml="$root/metadata/toolchain.toml"
if [[ ! -f $toml ]]; then
  echo "metadata/toolchain.toml not found (run from the ecos-release checkout)" >&2
  exit 1
fi

toml_get() {
  "$ECC_TOML_EDIT" get "$toml" "$1"
}

repo="$(toml_get github_repo)"
name="$(toml_get asset_name)"
template="$(toml_get cnb_url_template)"
url="https://github.com/${repo}/releases/download/${tag}/${name}"
cnb="${template//\{tag\}/$tag}"
cnb="${cnb//\{name\}/$name}"

prefetch="$(nix-prefetch-url --print-path --type sha256 --name "$name" "$url")"
nix32="$(printf '%s\n' "$prefetch" | sed -n '1p')"
store_path="$(printf '%s\n' "$prefetch" | sed -n '2p')"
sha="$(nix hash convert --from nix32 --to base16 --hash-algo sha256 "$nix32" | tr 'A-F' 'a-f')"
size="$(stat -c '%s' "$store_path")"

"$ECC_TOML_EDIT" set "$toml" "$version" "$url" "$cnb" "$sha" "$size"
echo "updated $toml for $tag"
