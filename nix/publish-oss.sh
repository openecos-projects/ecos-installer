#!/usr/bin/env bash
set -euo pipefail

: "${OSS_ACCESS_KEY_ID:?}"
: "${OSS_ACCESS_KEY_SECRET:?}"
: "${PUBLISH_DECIDE:?}"
OSS_BUCKET="${OSS_BUCKET:-ecc-install-script}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-beijing.aliyuncs.com}"
OSS_PUBLIC_BASE="${OSS_PUBLIC_BASE:-https://ecc-install-script.oss-cn-beijing.aliyuncs.com}"

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

sign() {
  local method="$1" key="$2" content_type="${3:-}" oss_header="${4:-}"
  local date
  date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
  local canonical
  # OSS StringToSign is VERB, Content-MD5, Content-Type, Date (one \n each,
  # empty values included), then CanonicalizedOSSHeaders and the resource.
  canonical="${method}

${content_type}
${date}
${oss_header:+${oss_header}
}/${OSS_BUCKET}/${key}"
  local sig
  sig="$(printf '%s' "$canonical" | openssl dgst -sha1 -hmac "$OSS_ACCESS_KEY_SECRET" -binary | base64)"
  printf '%s\n%s\n' "$date" "OSS ${OSS_ACCESS_KEY_ID}:${sig}"
}

put_object() {
  local key="$1" file="$2" content_type="$3" cache="$4" forbid="$5"
  local extra="" header_args=()
  if [[ $forbid == "1" ]]; then
    extra="x-oss-forbid-overwrite:true"
    header_args+=(-H "x-oss-forbid-overwrite: true")
  fi
  local signed date auth
  signed="$(sign PUT "$key" "$content_type" "$extra")"
  date="$(printf '%s\n' "$signed" | sed -n '1p')"
  auth="$(printf '%s\n' "$signed" | sed -n '2p')"
  curl -fsS -X PUT \
    -H "Date: $date" \
    -H "Authorization: $auth" \
    -H "Content-Type: $content_type" \
    -H "Content-Disposition: inline" \
    -H "Cache-Control: $cache" \
    "${header_args[@]}" \
    --data-binary @"$file" \
    "https://${OSS_BUCKET}.${OSS_ENDPOINT}/${key}"
}

get_signed() {
  local key="$1"
  local signed date auth
  signed="$(sign GET "$key" "" "")"
  date="$(printf '%s\n' "$signed" | sed -n '1p')"
  auth="$(printf '%s\n' "$signed" | sed -n '2p')"
  curl -fsS -H "Date: $date" -H "Authorization: $auth" \
    "https://${OSS_BUCKET}.${OSS_ENDPOINT}/${key}"
}

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
