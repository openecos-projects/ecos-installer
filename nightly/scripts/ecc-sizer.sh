# ecc-sizer nightly recipe: drives the repository's own CI scripts
# (install-build-deps.sh, build-sizer.sh, package-sizer.sh) on an Ubuntu
# 22.04 runner. package-sizer.sh already produces a portable layout
# (bin/ wrapper + libexec/ + lddtree-bundled lib/), so nothing nix-provided
# leaks into the artifact. Builds land in $NIGHTLY_ASSETS_DIR; publishing
# happens in nightly_recipe_release.

nightly_recipe_ecc_sizer() (
  tool=ecc-sizer
  repo="$(nightly_tool_repo ecc-sizer)"
  head="$(nightly_resolve_head "$repo")"
  if ! nightly_tool_should_build "$tool" "$head"; then
    exit 0
  fi
  version="$(nightly_tool_version "$repo" "$head")"
  nightly_log "building ecc-sizer ${version} from ${head}"

  : "${NIGHTLY_ASSETS_DIR:?}"
  workdir="$(mktemp -d)"
  # Cleanup is best-effort: a leftover workdir must not fail a green run.
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT

  # The build needs thirdparty/OpenROAD (DependencyInstaller and the cmake
  # dependency prefixes), so submodules are required.
  nightly_clone "$repo" "$workdir/src" --recurse-submodules --shallow-submodules
  cd "$workdir/src" || exit 1

  # Long step: OpenROAD's DependencyInstaller plus pax-utils (lddtree).
  sudo bash .github/scripts/install-build-deps.sh

  SIZER_VERSION="$version" bash .github/scripts/build-sizer.sh

  package_name="ecc-sizer-${version}"
  archive_name="${package_name}-linux-x64.tar.gz"
  PACKAGE_NAME="$package_name" ARCHIVE_NAME="$archive_name" \
    bash .github/scripts/package-sizer.sh

  tarball="$workdir/src/dist/${archive_name}"
  [ -f "$tarball" ] || nightly_die "build produced no tarball at ${tarball}"

  # Smoke test (ecos-studio's validate_sizer_startup equivalent): the runtime
  # must start from its bundled libs alone.
  smoke="$workdir/smoke"
  mkdir -p "$smoke"
  tar -xzf "$tarball" -C "$smoke"
  env -u LD_LIBRARY_PATH -u LD_PRELOAD timeout 10 \
    "$smoke/${package_name}/bin/Sizer" -env /dev/null -f /dev/null

  cp "$tarball" "$NIGHTLY_ASSETS_DIR/"
  nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/${archive_name}"
  nightly_record_built "$tool" "$head" "$version"
)
