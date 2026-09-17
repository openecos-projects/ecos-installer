#!/usr/bin/env bash
# Compare a pinned baseline tool-registry.json against a candidate build.
set -euo pipefail
exec python3 "$(dirname "$(readlink -f "$0")")/diff-registry.py" "$@"
