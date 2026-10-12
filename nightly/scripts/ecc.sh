# ecc nightly recipe: aggregation, not a rebuild. ecc's ci.yml already builds
# the release-grade PyInstaller onedir bundle in the manylinux_2_34 container
# on every green run (the composite action smoke-tests it), so we download the
# artifact of the newest main commit with a green nightly check, repack it
# (gzip -n for reproducibility), and re-verify it ourselves — on the host and
# in a clean ubuntu:24.04 container — before it enters the release.
#
# Aggregation over rebuilding: the source build is slow, needs a docker
# container plus native-wheel CI downloads, and any deviation from upstream's
# pipeline is a drift risk. The artifact's existence implies a green CI run.

nightly_recipe_ecc() (
  tool=ecc
  repo="$(nightly_tool_repo ecc)"
  : "${NIGHTLY_ASSETS_DIR:?}"
  workdir="$(mktemp -d)"
  # Cleanup is best-effort: a leftover workdir must not fail a green run.
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT

  # The ecc nightly ships the newest main commit with a green nightly CI
  # check (ci.yml on a schedule), never bare HEAD.
  run="$(nightly_latest_green_run "$repo" ci.yml schedule)"
  [ -n "$run" ] || run="$(nightly_latest_green_run "$repo" ci.yml workflow_dispatch)"
  if [ -z "$run" ]; then
    nightly_log "ecc: no green scheduled CI run on main yet; skipping tonight's ecc build"
    exit 0
  fi
  run_id="${run%% *}"
  head="${run#* }"

  if ! nightly_tool_should_build "$tool" "$head"; then
    exit 0
  fi
  version="$(nightly_tool_version "$repo" "$head")"
  nightly_log "aggregating ecc ${version} from ${repo} CI run ${run_id} (${head})"

  if [ -z "${NIGHTLY_DEPS_TOKEN:-}" ]; then
    nightly_die "NIGHTLY_READ_TOKEN not set (needs Actions:read on ecc for the nightly CI gate and CI artifact downloads)"
  fi
  nightly_gh_deps run download "$run_id" --repo "$repo" \
    --name ecc-cli-linux-x86_64 --dir "$workdir/artifact"
  [ -f "$workdir/artifact/ecc.tar" ] || nightly_die "CI artifact has no ecc.tar"

  # Repack exactly like the upstream release does (gzip -n keeps the bytes
  # reproducible), then verify the result ourselves.
  mkdir -p "$workdir/dist"
  gzip -n -9 -c "$workdir/artifact/ecc.tar" >"$workdir/dist/ecc-cli-linux-x86_64.tar.gz"
  tarball="$workdir/dist/ecc-cli-linux-x86_64.tar.gz"

  # Smoke test on the host (subset of upstream's build-pyinstaller-bundle
  # smoke): the bundle must run on a plain glibc system.
  smoke="$workdir/smoke"
  mkdir -p "$smoke"
  tar -xzf "$tarball" -C "$smoke"
  "$smoke/ecc" --help >/dev/null
  "$smoke/ecc" --version
  "$smoke/ecc" version --json >/dev/null
  test -x "$smoke/ecc-agent-rpc"
  "$smoke/ecc" doc config --plain >/dev/null

  # Clean-distro check: newer glibc than the build image, no development
  # packages — the tarball must carry every non-system dependency itself.
  nightly_clean_distro_smoke "$smoke" ecc --version

  cp "$tarball" "$NIGHTLY_ASSETS_DIR/"
  nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/ecc-cli-linux-x86_64.tar.gz"
  nightly_record_built "$tool" "$head" "$version"
  nightly_log "$tool: staged"
)
