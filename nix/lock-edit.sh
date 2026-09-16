#!/usr/bin/env bash
# Atomically update one entry of nix/_sources/generated.json.
#
#   lock-edit.sh set <locks.json> <key> <version> <url> <sri> <sha256_hex> <size>
#
# The file is rewritten through jq -S --indent 4 (the lock file's canonical
# format) via a temp file + rename, so the entry set is updated atomically
# and no other entry changes. Fails without touching the file if the entry
# does not exist.
set -euo pipefail

usage() {
  echo "usage: lock-edit.sh set <locks.json> <key> <version> <url> <sri> <sha256_hex> <size>" >&2
  exit 1
}

cmd="${1:-}"
[[ $cmd == set ]] || usage
[[ $# == 8 ]] || usage

locks="$2"
key="$3"
version="$4"
url="$5"
sri="$6"
hex="$7"
size="$8"

if ! jq -e --arg key "$key" 'has($key)' "$locks" >/dev/null; then
  echo "missing lock entry: $key" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
jq -S --indent 4 \
  --arg key "$key" \
  --arg version "$version" \
  --arg url "$url" \
  --arg sri "$sri" \
  --arg hex "$hex" \
  --argjson size "$size" \
  '.[$key].version = $version
   | .[$key].src.url = $url
   | .[$key].src.sha256 = $sri
   | .[$key].sha256_hex = $hex
   | .[$key].size = $size' \
  "$locks" >"$tmp"
mv "$tmp" "$locks"
trap - EXIT
