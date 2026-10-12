# ecos-studio nightly recipe: the Linux AppImage from the repository's own
# Makefile flow (install-apt-deps + setup + build) on an Ubuntu 22.04 runner.
# The AppImage does not embed ECC by design (it is fetched from the registry
# on first run), so a studio nightly rebuilds when studio itself moves.
# Builds land in $NIGHTLY_ASSETS_DIR; publishing happens in
# nightly_recipe_release.

nightly_recipe_ecos_studio() (
  tool=ecos-studio
  repo="$(nightly_tool_repo ecos-studio)"
  head="$(nightly_resolve_head "$repo")"
  if ! nightly_tool_should_build "$tool" "$head"; then
    exit 0
  fi
  version="$(nightly_tool_version "$repo" "$head")"
  nightly_log "building ecos-studio ${version} from ${head}"

  : "${NIGHTLY_ASSETS_DIR:?}"
  workdir="$(mktemp -d)"
  # Cleanup is best-effort: a leftover workdir must not fail a green run.
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT

  nightly_clone "$repo" "$workdir/src"
  cd "$workdir/src" || exit 1

  # uv, pnpm, and Node come from the nix wrapper (pinned in
  # nix/modules/nightly.nix), so `make setup` skips its install-deps step and
  # dependency installation stays split between install-apt-deps (system) and
  # the wrapper (toolchains). Rust is pinned by the workflow
  # (dtolnay/rust-toolchain); the runner's preinstalled toolchain is not
  # trusted because its version drifts.
  sudo make install-apt-deps

  # Stamp the nightly version so the AppImage filename and About dialog
  # self-identify; the upstream tag-release consistency check does not run
  # here.
  jq --arg v "$version" '.version = $v' \
    ecos/gui/apps/desktop-electron/package.json >package.json.tmp
  mv package.json.tmp ecos/gui/apps/desktop-electron/package.json

  # Pre-init the submodules shallowly (the PDK submodule carries large binary
  # assets); make setup's plain `git submodule update` then finds every pin
  # already satisfied and adds nothing.
  git submodule update --init --recursive --depth 1
  make setup

  # Stage the portable sizer runtime for build-binaries.sh: prefer this run's
  # fresh ecc-sizer build, otherwise carry forward the tarball from the
  # latest nightly release. Either way the build needs no token (the upstream
  # fallback would gh-download from ecc-sizer CI mid-build).
  shopt -s nullglob
  sizer_tarballs=("$NIGHTLY_ASSETS_DIR"/ecc-sizer-*-linux-x64.tar.gz)
  if [ ${#sizer_tarballs[@]} -eq 0 ]; then
    latest_tag="$(nightly_latest_release_tag)"
    [ -n "$latest_tag" ] ||
      nightly_die "no sizer runtime available: no fresh build and no previous nightly"
    nightly_carry_forward "$latest_tag" ecc-sizer
    sizer_tarballs=("$NIGHTLY_ASSETS_DIR"/ecc-sizer-*-linux-x64.tar.gz)
  fi
  [ ${#sizer_tarballs[@]} -ge 1 ] || nightly_die "no sizer tarball in $NIGHTLY_ASSETS_DIR"
  mkdir -p "$workdir/sizer"
  tar -xzf "${sizer_tarballs[0]}" -C "$workdir/sizer"
  # Parameter expansion keeps the first match so nothing downstream closes
  # the pipe early under pipefail.
  sizer_root="$(find "$workdir/sizer" -type f -path '*/src/sizer_os.tcl' -printf '%h\n')"
  sizer_root="${sizer_root%%$'\n'*}"
  sizer_root="${sizer_root%/src}"
  [ -n "$sizer_root" ] || nightly_die "could not locate the sizer runtime root"
  # Match build-binaries.sh is_portable_sizer_runtime exactly: an incomplete
  # runtime must fail here, not fall back to a mid-build download.
  for f in bin/Sizer libexec/Sizer lib/ld-linux-x86-64.so.2 src/sizer_os.tcl; do
    [ -e "$sizer_root/$f" ] || nightly_die "incomplete sizer runtime: missing $f in $sizer_root"
  done
  export CHIPCOMPILER_ECC_SIZER_ROOT="$sizer_root"

  (cd ecos/gui && pnpm install --frozen-lockfile)
  make build

  mapfile -t appimages < <(find -L build -type f -name '*.AppImage' | sort)
  [ "${#appimages[@]}" -ge 1 ] || nightly_die "no AppImage produced under build/"

  # FUSE-free integrity smoke: extraction must succeed on any host.
  first_appimage="$(readlink -f "${appimages[0]}")"
  chmod +x "$first_appimage"
  (cd "$workdir" && "$first_appimage" --appimage-extract >/dev/null)

  for appimage in "${appimages[@]}"; do
    name="$(basename "$appimage")"
    cp "$appimage" "$NIGHTLY_ASSETS_DIR/$name"
    nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/$name"
  done
  nightly_record_built "$tool" "$head" "$version"
  nightly_log "$tool: staged"
)
