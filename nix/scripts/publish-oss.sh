#!/usr/bin/env bash
set -euo pipefail

: "${OSS_ACCESS_KEY_ID:?}"
: "${OSS_ACCESS_KEY_SECRET:?}"
: "${PUBLISH_DECIDE:?}"
# Bucket coordinates are deployment configuration, not code: CI injects them
# from repository variables.
: "${OSS_BUCKET:?}"
: "${OSS_ENDPOINT:?}"
: "${OSS_PUBLIC_BASE:?}"

arg="${1:-}"
if [[ -n $arg && -f $arg ]]; then
  installer="$arg"
elif [[ -n ${ECC_INSTALLER:-} ]]; then
  installer="$ECC_INSTALLER"
else
  echo "usage: publish-oss [ecc-installer.sh|v<tag>]" >&2
  exit 1
fi
# decide-cli.nix reads the candidate through an absolute Nix path
# (/. + candidateFile), so the installer path must be absolute no matter how
# it was passed in (the workflow passes artifact/ecc-installer.sh).
installer="$(realpath "$installer")"

version="$(sed -n 's/^ECC_VERSION="\(.*\)"/\1/p' "$installer" | head -n1)"
tag="v${version}"
if [[ $arg == v* && $arg != "$tag" ]]; then
  echo "tag $arg does not match installer $tag" >&2
  exit 1
fi

versioned="installers/ecc/${tag}/ecc-installer.sh"
latest="installers/ecc/latest/ecc-installer.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Compare exact bytes: routing a body through a shell variable strips the
# trailing newline and would break every equality check below.
if ! put_object "$versioned" "$installer" "text/x-sh" "public, max-age=31536000, immutable" 1; then
  get_signed "$versioned" >"$workdir/existing" || true
  if ! cmp -s "$installer" "$workdir/existing"; then
    echo "refusing to overwrite $versioned with different bytes" >&2
    exit 1
  fi
fi

curl -fsS "${OSS_PUBLIC_BASE}/${versioned}" -o "$workdir/anon-versioned"
if ! cmp -s "$installer" "$workdir/anon-versioned"; then
  echo "anonymous read of $versioned did not match" >&2
  exit 1
fi

current_file="$workdir/current"
if curl -fsS "${OSS_PUBLIC_BASE}/${latest}" -o "$current_file"; then
  decision="$("$PUBLISH_DECIDE" "$current_file" "$installer")"
else
  decision="$("$PUBLISH_DECIDE" "" "$installer")"
fi

case "$decision" in
advance)
  put_object "$latest" "$installer" "text/x-sh" "no-cache" 0
  curl -fsS "${OSS_PUBLIC_BASE}/${latest}" -o "$workdir/anon-latest"
  if ! cmp -s "$installer" "$workdir/anon-latest"; then
    echo "anonymous read of latest did not match" >&2
    exit 1
  fi
  echo "published $versioned (latest advanced)"
  ;;
keep)
  echo "published $versioned (latest kept)"
  ;;
*)
  echo "publication rejected: ${decision:-empty}" >&2
  exit 1
  ;;
esac
