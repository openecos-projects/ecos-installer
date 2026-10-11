# kepler-formal nightly recipe: aggregation, not a rebuild. kepler-formal
# already runs a mature nightly pipeline in its own repository (bazel build,
# bundled runtime, clean-distro verification); we consume its latest nightly
# prerelease — verified against its .sha256 sidecar — into our dated release
# and the combined bundle.

nightly_recipe_kepler_formal() (
  tool=kepler-formal
  repo="$(nightly_tool_repo kepler-formal)"
  : "${NIGHTLY_ASSETS_DIR:?}"
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT

  up="$(nightly_kepler_upstream)"
  upstream_tag="${up%% *}"
  upstream_commit="${up#* }"
  version="${upstream_tag#v}"

  if ! nightly_tool_should_build "$tool" "$upstream_commit"; then
    exit 0
  fi
  nightly_log "aggregating kepler-formal ${version} (${upstream_commit}) from ${repo}"

  tarball="kepler-formal-${version}-linux-x86_64.tar.gz"
  nightly_gh_deps release download "$upstream_tag" --repo "$repo" \
    --pattern "$tarball" --pattern "${tarball}.sha256" \
    --dir "$workdir" --clobber

  # Verify against the upstream sidecar before the bytes enter our release.
  (cd "$workdir" && sha256sum -c "${tarball}.sha256")

  cp "$workdir/$tarball" "$workdir/${tarball}.sha256" "$NIGHTLY_ASSETS_DIR/"
  nightly_record_built "$tool" "$upstream_commit" "$version"
)
