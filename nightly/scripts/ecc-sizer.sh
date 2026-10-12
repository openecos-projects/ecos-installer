# ecc-sizer nightly recipe: aggregation, not a rebuild. ecc-sizer's ci.yml
# publishes the portable runtime (bin/ wrapper + libexec/ + lddtree-bundled
# lib/, built and packaged by the repository's own scripts) as the
# ecc-sizer-linux-x64 artifact on green main runs; we download the newest,
# smoke-test startup from its bundled libs alone, and re-release it under a
# versioned asset name.
#
# Aggregation over rebuilding: the source build drags in the whole OpenROAD
# submodule tree (whose nested .gitmodules use SSH URLs that runners cannot
# clone anonymously) plus a long dependency install, for zero gain over the
# bytes the upstream CI already produced.

nightly_recipe_ecc_sizer() (
  tool=ecc-sizer
  repo="$(nightly_tool_repo ecc-sizer)"
  : "${NIGHTLY_ASSETS_DIR:?}"
  workdir="$(mktemp -d)"
  # Cleanup is best-effort: a leftover workdir must not fail a green run.
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT

  # Latest green CI build on main (any event; ecc-sizer CI is push-driven).
  run="$(nightly_latest_green_run "$repo" ci.yml)"
  if [ -z "$run" ]; then
    nightly_log "ecc-sizer: no green CI run on main yet; skipping"
    exit 0
  fi
  run_id="${run%% *}"
  head="${run#* }"

  if ! nightly_tool_should_build "$tool" "$head"; then
    exit 0
  fi
  version="$(nightly_tool_version "$repo" "$head")"
  nightly_log "aggregating ecc-sizer ${version} from ${repo} CI run ${run_id} (${head})"

  if [ -z "${NIGHTLY_DEPS_TOKEN:-}" ]; then
    nightly_die "NIGHTLY_READ_TOKEN not set (needs Actions:read on ecc-sizer for CI artifact downloads)"
  fi
  nightly_gh_deps run download "$run_id" --repo "$repo" \
    --name ecc-sizer-linux-x64 --dir "$workdir/artifact"

  tarball_ci="$(find "$workdir/artifact" -name 'ecc-sizer-linux-x64.tar.gz' -print -quit)"
  [ -n "$tarball_ci" ] || nightly_die "CI artifact has no ecc-sizer-linux-x64.tar.gz"

  # Smoke test (ecos-studio's validate_sizer_startup equivalent): the runtime
  # must start from its bundled libs alone.
  smoke="$workdir/smoke"
  mkdir -p "$smoke"
  tar -xzf "$tarball_ci" -C "$smoke"
  env -u LD_LIBRARY_PATH -u LD_PRELOAD timeout 10 \
    "$smoke/ecc-sizer/bin/Sizer" -env /dev/null -f /dev/null

  # Re-release byte-identical content under the versioned asset name.
  archive_name="ecc-sizer-${version}-linux-x64.tar.gz"
  cp "$tarball_ci" "$NIGHTLY_ASSETS_DIR/$archive_name"
  nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/$archive_name"
  nightly_record_built "$tool" "$head" "$version"
  nightly_log "$tool: staged"
)
