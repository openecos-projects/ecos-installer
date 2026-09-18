# Shared Aliyun OSS REST helpers. Not executed directly: nix/modules/*.nix
# inlines this file into the publish-* shell apps via builtins.readFile.
# Requires OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET / OSS_BUCKET /
# OSS_ENDPOINT in the environment; each caller guards them with : "${VAR:?}".

sign() {
  local method="$1" key="$2" content_type="${3:-}" oss_header="${4:-}"
  local date
  date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
  local canonical
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
