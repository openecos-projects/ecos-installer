# pdk nightly recipe: assembles the ICS55 PDK into a single installable
# tarball. Upstream ships the PDK split (git-archive base plus seven release
# packages); this recipe repackages the newest release that carries the full
# package set into icsprout55-pdk-<version>.tar.gz, using the exact layout
# the installer produces (base stripped to the root, packages extracted into
# their dest paths) and validating the same tech/cell/liberty file list.
#
# The package set and validation paths come from $NIGHTLY_PDK_MANIFEST, a
# projection of toolchain.toml rendered by nix/modules/nightly.nix, so the
# recipe never drifts from the lock-driven installer layout. All downloads
# are public and anonymous.

nightly_recipe_pdk() (
  tool=pdk
  : "${NIGHTLY_ASSETS_DIR:?}"
  : "${NIGHTLY_PDK_MANIFEST:?}"
  workdir="$(mktemp -d)"
  # Cleanup is best-effort: a leftover workdir must not fail a green run.
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT

  up="$(nightly_pdk_upstream)"
  tag="${up%% *}"
  commit="${up#* }"
  version="${tag#v}"

  if ! nightly_tool_should_build "$tool" "$commit"; then
    exit 0
  fi
  nightly_log "assembling ICS55 PDK ${version} (${commit})"

  # Interpolate the toolchain.toml templates: {version} keeps the leading v,
  # {version^} drops it.
  nightly_pdk_interp() {
    local t="$1"
    t="${t//"{version^}"/"$version"}"
    t="${t//"{version}"/"$tag"}"
    printf '%s\n' "$t"
  }

  # Base: git archive of the release tag, stripped to the root.
  base_url="$(nightly_pdk_interp "$(jq -r '.base.urlTemplate' "$NIGHTLY_PDK_MANIFEST")")"
  top_expected="$(nightly_pdk_interp "$(jq -r '.base.stripPrefix' "$NIGHTLY_PDK_MANIFEST")")"
  curl -fsSL --retry 3 --retry-delay 5 "$base_url" -o "$workdir/base.tar.gz"
  mkdir -p "$workdir/base-x"
  tar -xzf "$workdir/base.tar.gz" -C "$workdir/base-x"
  [ -d "$workdir/base-x/$top_expected" ] ||
    nightly_die "base archive top directory is not ${top_expected} (GitHub archive layout changed?)"
  stage="$workdir/icsprout55-pdk-${version}"
  mv "$workdir/base-x/$top_expected" "$stage"

  # Packages: extract each release asset as-is into its dest path (the
  # installer's extract_archive semantics).
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    id="$(printf '%s' "$pkg" | jq -r '.id')"
    url="$(nightly_pdk_interp "$(printf '%s' "$pkg" | jq -r '.urlTemplate')")"
    dest="$(printf '%s' "$pkg" | jq -r '.dest')"
    [ -n "$dest" ] || nightly_die "pdk package ${id} has no dest"
    nightly_log "pdk package ${id} -> ${dest}"
    mkdir -p "$stage/$dest"
    curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$workdir/pkg.tar.bz2" || nightly_die "download failed: ${url}"
    tar --no-same-owner --no-same-permissions -xjf "$workdir/pkg.tar.bz2" -C "$stage/$dest" ||
      nightly_die "extract failed: ${id}"
  done <<<"$(jq -c '.packages[]' "$NIGHTLY_PDK_MANIFEST")"

  # Validate the assembled tree against the installer's file list.
  while read -r rel; do
    [ -n "$rel" ] || continue
    [ -s "$stage/$rel" ] || nightly_die "assembled PDK is missing ${rel}"
  done <<<"$(jq -r '.verifyPaths[]' "$NIGHTLY_PDK_MANIFEST")"

  tarball="icsprout55-pdk-${version}.tar.gz"
  tar -czf "$workdir/$tarball" -C "$workdir" "icsprout55-pdk-${version}"
  cp "$workdir/$tarball" "$NIGHTLY_ASSETS_DIR/"
  nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/$tarball"
  nightly_record_built "$tool" "$commit" "$version"
)
