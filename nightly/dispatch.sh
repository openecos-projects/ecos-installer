# Entry point of the nightly-build app (nix run .#nightly-build -- <target>).
# Concatenated after nightly/lib/common.sh and the recipe files, so every
# nightly_* function is already defined.
set -euo pipefail
# Locale-independent ordering for the SemVer string comparisons.
export LC_ALL=C

nightly_usage() {
  cat >&2 <<'EOF'
usage: nightly-build <all|ecc|ecc-sizer|ecos-studio|release>

Build the given tools from their default-branch HEAD and publish one dated
nightly prerelease (v<base>-nightly.<yyyymmdd>[.N]) on this repository with
the per-tool tarballs, the combined ecos-nightly bundle, and the ecos-studio
AppImage as assets. A tool is skipped when the latest nightly already covers
its HEAD with an unchanged recipe; when nothing moved, no release is
created. `release` alone re-runs only the publish stage.

environment:
  GH_TOKEN              required; the workflow's GITHUB_TOKEN (contents:write
                        on this repository)
  NIGHTLY_ASSETS_DIR    required; absolute path of the run's asset staging
                        directory
  NIGHTLY_READ_TOKEN    required by the ecc recipe; read-only token with
                        Actions:read on ecc-dreamplace and ecc-tools
  NIGHTLY_RECIPE_TREE   recipe tree hash for the skip check (default: the
                        caller's HEAD:nightly, else "unknown" = never skip)
  NIGHTLY_FORCE=1       build even when a nightly already covers HEAD
  NIGHTLY_SUFFIX=N      integer >= 2 overriding the same-day rerun suffix
                        (default: auto-increment past any colliding tag)
  NIGHTLY_DATE=YYYYMMDD override the tag's date stamp
  NIGHTLY_KEEP=N        dated nightlies to keep per repository (default 14)
  NIGHTLY_RELEASE_REPO  publish target (default openecos-projects/
                        ecos-installer)
EOF
}

nightly_target="${1:-}"
case "$nightly_target" in
-h | --help | help)
  nightly_usage
  exit 0
  ;;
all | ecc | ecc-sizer | ecos-studio | release) ;;
*)
  nightly_usage
  exit 1
  ;;
esac

# Move the tokens out of the environment: third-party build code (containers,
# make, pnpm) must not inherit them. Kept as unexported shell variables
# (subshells still see them); gh calls go through the nightly_gh* wrappers,
# which receive a token per invocation. The export attribute must be stripped
# explicitly: plain assignment preserves it when the caller exported the
# variable beforehand.
: "${GH_TOKEN:?nightly builds need GH_TOKEN with contents:write on the release repository}"
# Used by nightly_gh (lib/common.sh) in this same concatenated script.
# shellcheck disable=SC2034
NIGHTLY_GH_TOKEN="$GH_TOKEN"
export -n NIGHTLY_GH_TOKEN
unset GH_TOKEN
if [ -n "${NIGHTLY_READ_TOKEN:-}" ]; then
  # shellcheck disable=SC2034
  NIGHTLY_DEPS_TOKEN="$NIGHTLY_READ_TOKEN"
  export -n NIGHTLY_DEPS_TOKEN
  unset NIGHTLY_READ_TOKEN
fi

case "$nightly_target" in
# ecc-sizer builds before ecos-studio: the studio AppImage bundles the sizer
# runtime, preferably from this run's fresh build.
all)
  nightly_recipe_ecc
  nightly_recipe_ecc_sizer
  nightly_recipe_ecos_studio
  nightly_recipe_release
  ;;
ecc)
  nightly_recipe_ecc
  nightly_recipe_release
  ;;
ecc-sizer)
  nightly_recipe_ecc_sizer
  nightly_recipe_release
  ;;
ecos-studio)
  nightly_recipe_ecos_studio
  nightly_recipe_release
  ;;
release)
  nightly_recipe_release
  ;;
esac
