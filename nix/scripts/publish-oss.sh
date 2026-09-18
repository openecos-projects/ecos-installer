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

version="$(sed -n 's/^ECC_VERSION="\(.*\)"/\1/p' "$installer" | head -n1)"
tag="v${version}"
if [[ $arg == v* && $arg != "$tag" ]]; then
  echo "tag $arg does not match installer $tag" >&2
  exit 1
fi

versioned="installers/ecc/${tag}/ecc-installer.sh"
latest="installers/ecc/latest/ecc-installer.sh"

if ! put_object "$versioned" "$installer" "text/x-sh" "public, max-age=31536000, immutable" 1; then
  existing="$(get_signed "$versioned" || true)"
  if ! cmp -s "$installer" <(printf '%s' "$existing"); then
    echo "refusing to overwrite $versioned with different bytes" >&2
    exit 1
  fi
fi

anon_versioned="$(curl -fsS "${OSS_PUBLIC_BASE}/${versioned}")"
if ! cmp -s "$installer" <(printf '%s' "$anon_versioned"); then
  echo "anonymous read of $versioned did not match" >&2
  exit 1
fi

current_file=""
if current="$(curl -fsS "${OSS_PUBLIC_BASE}/${latest}")"; then
  current_file="$(mktemp)"
  printf '%s' "$current" >"$current_file"
fi
decision="$("$PUBLISH_DECIDE" "${current_file:-}" "$installer")"
rm -f "$current_file"

case "$decision" in
advance)
  put_object "$latest" "$installer" "text/x-sh" "no-cache" 0
  anon_latest="$(curl -fsS "${OSS_PUBLIC_BASE}/${latest}")"
  if ! cmp -s "$installer" <(printf '%s' "$anon_latest"); then
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
