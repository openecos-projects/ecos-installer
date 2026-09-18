#!/usr/bin/env bash
# Publish the tool registry as a mutable OSS object, mirroring the
# installers/ecc/latest pattern: overwrite the key, then verify the
# anonymous read serves the same bytes.
set -euo pipefail

: "${OSS_ACCESS_KEY_ID:?}"
: "${OSS_ACCESS_KEY_SECRET:?}"
# Bucket coordinates are deployment configuration, not code: CI injects them
# from repository secrets.
: "${OSS_BUCKET:?}"
: "${OSS_ENDPOINT:?}"
: "${OSS_PUBLIC_BASE:?}"

arg="${1:-}"
if [[ -n $arg && -f $arg ]]; then
  registry="$arg"
elif [[ -n ${TOOL_REGISTRY:-} ]]; then
  registry="$TOOL_REGISTRY"
else
  echo "usage: publish-registry-oss [tool-registry.json]" >&2
  exit 1
fi

key="tools/registry.json"

put_object "$key" "$registry" "application/json" "no-cache" 0

anon="$(curl -fsS "${OSS_PUBLIC_BASE}/${key}")"
if ! cmp -s "$registry" <(printf '%s' "$anon"); then
  echo "anonymous read of $key did not match" >&2
  exit 1
fi
echo "published ${OSS_PUBLIC_BASE}/${key}"
