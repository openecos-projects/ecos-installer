#!/usr/bin/env bash
# Read and edit the [ecc] section of metadata/toolchain.toml.
#
#   ecc-toml-edit.sh get  <toml> <key>
#   ecc-toml-edit.sh set  <toml> <version> <url> <cnb_url> <sha256> <size>
#
# `get` reads a key from inside the [ecc] section only; other sections may
# repeat the same key names. `set` rewrites version/url/cnb_url/sha256/size
# in place and fails without modifying the file if any of them is missing
# from [ecc].
set -euo pipefail

usage() {
  echo "usage: ecc-toml-edit.sh get <toml> <key>" >&2
  echo "       ecc-toml-edit.sh set <toml> <version> <url> <cnb_url> <sha256> <size>" >&2
  exit 1
}

# Print every line from [ecc] up to (not including) the next section header.
ecc_section() {
  sed -n '/^\[ecc\]/,/^\[/{ /^\[ecc\]/d; /^\[/d; p }' "$1"
}

cmd="${1:-}"
case "$cmd" in
get)
  [[ $# == 3 ]] || usage
  toml="$2"
  key="$3"
  ecc_section "$toml" | sed -n "s/^$key = \"\\(.*\\)\"/\\1/p" | head -n1
  ;;
set)
  [[ $# == 7 ]] || usage
  toml="$2"
  ver="$3"
  url="$4"
  cnb="$5"
  sha="$6"
  size="$7"

  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  awk -v ver="$ver" -v url="$url" -v cnb="$cnb" -v sha="$sha" -v size="$size" '
    function key_of(line,   k) {
      k = line
      sub(/[ \t]*=.*/, "", k)
      gsub(/^[ \t]+|[ \t]+$/, "", k)
      return k
    }
    $0 == "[ecc]" { in_ecc = 1; print; next }
    in_ecc && /^\[/ { in_ecc = 0 }
    in_ecc && $0 ~ /^[ \t]*[A-Za-z0-9_]+[ \t]*=/ && $0 !~ /^[ \t]*#/ {
      k = key_of($0)
      if (k == "version") { print "version = \"" ver "\""; seen[k] = 1; next }
      if (k == "url") { print "url = \"" url "\""; seen[k] = 1; next }
      if (k == "cnb_url") { print "cnb_url = \"" cnb "\""; seen[k] = 1; next }
      if (k == "sha256") { print "sha256 = \"" sha "\""; seen[k] = 1; next }
      if (k == "size") { print "size = " size; seen[k] = 1; next }
    }
    { print }
    END {
      n = split("version url cnb_url sha256 size", keys, " ")
      for (i = 1; i <= n; i++) {
        if (!seen[keys[i]]) {
          printf "missing [ecc] key %s\n", keys[i] > "/dev/stderr"
          err = 1
        }
      }
      exit err
    }
  ' "$toml" >"$tmp"
  mv "$tmp" "$toml"
  trap - EXIT
  ;;
*)
  usage
  ;;
esac
