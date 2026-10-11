# Shared helpers for the nightly build recipes (nix run .#nightly-build).
#
# nix/modules/nightly.nix concatenates this library, every
# nightly/scripts/<tool>.sh (each defining one nightly_recipe_<tool>
# function), nightly/scripts/release.sh (the publish stage), and
# nightly/dispatch.sh into the nightly-build app. Nothing here is executed
# standalone.
#
# The nightly product is one dated prerelease per day on THIS repository
# (oss-cad-suite-build style): per-tool tarballs for the installer/registry
# consumption shape, a combined ecos-nightly bundle tarball for humans, and
# the ecos-studio AppImage. Published tags are never overwritten.
#
# Required environment:
#   GH_TOKEN              the workflow's GITHUB_TOKEN (contents:write on this
#                         repository) or any token with the same reach
#   NIGHTLY_ASSETS_DIR    absolute path of the run's asset staging directory;
#                         recipes drop <asset>, <asset>.sha256,
#                         <tool>.commit and <tool>.version there
# Optional environment:
#   NIGHTLY_READ_TOKEN    read-only token (Actions:read on ecc-dreamplace and
#                         ecc-tools) for downloading native-wheel CI
#                         artifacts; the ecc recipe fails without it
#   NIGHTLY_RELEASE_REPO  publish target (default openecos-projects/ecos-installer)
#   NIGHTLY_RECIPE_TREE   `git rev-parse HEAD:nightly` of the ecos-installer
#                         checkout driving the build; recorded in the release
#                         body so a recipe change forces a rebuild even when
#                         no source commit moved. Defaults to the caller's
#                         working tree, else "unknown" (never skips).
#   NIGHTLY_DATE          YYYYMMDD override for the tag's date stamp
#   NIGHTLY_FORCE=1       build even when the latest nightly already covers a
#                         tool's HEAD with an unchanged recipe
#   NIGHTLY_SUFFIX=N      integer >= 2 overriding the same-day rerun suffix
#                         (default: auto-increment past any colliding tag)
#   NIGHTLY_KEEP=N        dated nightlies to keep (default 14)

# Repo-level release tags are strict SemVer 2.0: v<base>-nightly.<yyyymmdd>[.N]
# where <base> comes from this repository's own tags (0.1.0 until the first
# stable tag exists here). Per-tool versions keep the richer
# <toolbase>-nightly.<yyyymmdd>.g<sha> form and live in asset names and the
# release body (a single release tag cannot carry three shas).
NIGHTLY_TAG_BODY_RE='v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}(\.[1-9][0-9]*)?'
NIGHTLY_TAG_RE="^${NIGHTLY_TAG_BODY_RE}\$"
# Strict SemVer 2.0.0 (no leading zeros) for the tags eligible as a tool's
# nightly base; keeps the numeric comparisons below free of leading-zero
# ambiguity.
NIGHTLY_BASE_TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?$'

# Consumed by the recipes and the publish stage (concatenated into the same
# app; shellcheck sees this file in isolation).
# shellcheck disable=SC2034
NIGHTLY_TOOLS="ecc ecc-sizer ecos-studio"
NIGHTLY_RELEASE_REPO="${NIGHTLY_RELEASE_REPO:-openecos-projects/ecos-installer}"

nightly_log() {
  echo "nightly: $*" >&2
}

nightly_die() {
  echo "nightly: error: $*" >&2
  exit 1
}

# gh with the release token (this repository). dispatch.sh moves GH_TOKEN to
# NIGHTLY_GH_TOKEN and unsets it, so third-party build code (containers, make,
# pnpm) never inherits a token; only these explicit calls get one.
nightly_gh() {
  GH_TOKEN="$NIGHTLY_GH_TOKEN" gh "$@"
}

# gh for cross-repo dependency reads (CI artifacts of ecc-dreamplace /
# ecc-tools). Uses the read-only NIGHTLY_READ_TOKEN when present so the
# release token's scope stays minimal.
nightly_gh_deps() {
  local token="${NIGHTLY_DEPS_TOKEN:-}"
  if [ -z "$token" ]; then
    nightly_die "NIGHTLY_READ_TOKEN not set (needs Actions:read on ecc-dreamplace and ecc-tools for CI artifact downloads)"
  fi
  GH_TOKEN="$token" gh "$@"
}

nightly_tool_repo() {
  case "$1" in
  ecc) printf 'openecos-projects/ecc\n' ;;
  ecc-sizer) printf 'openecos-projects/ecc-sizer\n' ;;
  ecos-studio) printf 'openecos-projects/ecos-studio\n' ;;
  *) nightly_die "unknown tool: $1" ;;
  esac
}

# Print the default-branch HEAD sha of a GitHub repository (unauthenticated).
nightly_resolve_head() {
  local repo="$1"
  local sha
  if ! sha="$(git ls-remote "https://github.com/${repo}.git" HEAD)"; then
    nightly_die "git ls-remote HEAD failed for ${repo}"
  fi
  sha="${sha%%[!0-9a-f]*}"
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || nightly_die "unexpected HEAD for ${repo}: ${sha}"
  printf '%s\n' "$sha"
}

# Print the newest commit on <repo>'s main with a successful scheduled run
# of <workflow> — the "nightly check" gate. A manually dispatched green run
# is the bootstrap/fallback. Empty when no green run exists yet. The event
# filter is server-side (per_page=5 is ample for a daily schedule), so no
# pagination is needed. Needs the deps token (Actions:read).
nightly_checked_head() {
  local repo="$1" workflow="$2"
  local sha
  sha="$(nightly_gh_deps api \
    "repos/${repo}/actions/workflows/${workflow}/runs?event=schedule&branch=main&status=completed&per_page=5" \
    --jq '[.workflow_runs[] | select(.conclusion == "success") | .head_sha][0] // empty')"
  if [ -z "$sha" ]; then
    sha="$(nightly_gh_deps api \
      "repos/${repo}/actions/workflows/${workflow}/runs?event=workflow_dispatch&branch=main&status=completed&per_page=5" \
      --jq '[.workflow_runs[] | select(.conclusion == "success") | .head_sha][0] // empty')"
  fi
  printf '%s\n' "$sha"
}

# The commit a tool's nightly is allowed to build. ecc is gated on its
# repository's nightly CI check (ci.yml on a schedule); everything else
# tracks the default-branch HEAD directly.
nightly_effective_head() {
  local tool="$1" repo="$2"
  if [ "$tool" = "ecc" ]; then
    nightly_checked_head "$repo" ci.yml
  else
    nightly_resolve_head "$repo"
  fi
}

# Compare two numeric SemVer identifiers without arithmetic (no overflow on
# huge-but-legal identifiers): strict SemVer forbids leading zeros, so a
# longer digit string is the larger number, and equal-length strings compare
# lexically.
nightly_numeric_compare() {
  local x="$1" y="$2"
  if ((${#x} != ${#y})); then
    ((${#x} < ${#y})) && printf -- '-1\n' || printf '1\n'
  elif [[ $x != "$y" ]]; then
    [[ $x < $y ]] && printf -- '-1\n' || printf '1\n'
  else
    printf '0\n'
  fi
}

# Increment a decimal string of any size (single-digit carry only, so no bash
# arithmetic can overflow).
nightly_increment_decimal() {
  local digits="$1" carry=1 out="" i d
  for ((i = ${#digits} - 1; i >= 0; i--)); do
    d="${digits:i:1}"
    if ((carry)); then
      if [ "$d" = 9 ]; then
        d=0
      else
        d=$((d + 1))
        carry=0
      fi
    fi
    out="${d}${out}"
  done
  ((carry)) && out="1${out}"
  printf '%s\n' "$out"
}

# Compare two SemVer versions (no leading v) per SemVer 2.0.0 precedence;
# prints -1, 0, or 1. The tag lists here are small, so a correct bash
# comparison beats a clever sort (sort -V is not SemVer-aware: it orders a
# stable tag before its own prereleases).
nightly_semver_compare() {
  local a="$1" b="$2"
  local a_core="${a%%-*}" b_core="${b%%-*}"
  local a_pre="" b_pre=""
  [[ $a == *-* ]] && a_pre="${a#*-}"
  [[ $b == *-* ]] && b_pre="${b#*-}"
  local i x y
  local ac bc
  IFS=. read -ra ac <<<"$a_core"
  IFS=. read -ra bc <<<"$b_core"
  for i in 0 1 2; do
    x="${ac[i]:-0}"
    y="${bc[i]:-0}"
    if [ "$x" != "$y" ]; then
      nightly_numeric_compare "$x" "$y"
      return
    fi
  done
  # No prerelease outranks any prerelease at the same core.
  if [ -z "$a_pre" ] || [ -z "$b_pre" ]; then
    if [ -z "$a_pre" ] && [ -z "$b_pre" ]; then
      printf '0\n'
    elif [ -z "$a_pre" ]; then
      printf '1\n'
    else
      printf -- '-1\n'
    fi
    return
  fi
  local ap bp
  IFS=. read -ra ap <<<"$a_pre"
  IFS=. read -ra bp <<<"$b_pre"
  local n
  n=$((${#ap[@]} > ${#bp[@]} ? ${#ap[@]} : ${#bp[@]}))
  for ((i = 0; i < n; i++)); do
    # A longer prerelease list wins once all shared identifiers are equal.
    if [ $i -ge ${#ap[@]} ]; then
      printf -- '-1\n'
      return
    fi
    if [ $i -ge ${#bp[@]} ]; then
      printf '1\n'
      return
    fi
    x="${ap[i]}"
    y="${bp[i]}"
    if [[ $x =~ ^[0-9]+$ ]] && [[ $y =~ ^[0-9]+$ ]]; then
      if [[ $x != "$y" ]]; then
        nightly_numeric_compare "$x" "$y"
        return
      fi
    elif [[ $x =~ ^[0-9]+$ ]]; then
      # Numeric identifiers rank below alphanumeric ones.
      printf -- '-1\n'
      return
    elif [[ $y =~ ^[0-9]+$ ]]; then
      printf '1\n'
      return
    elif [[ $x != "$y" ]]; then
      [[ $x < $y ]] && printf -- '-1\n' || printf '1\n'
      return
    fi
  done
  printf '0\n'
}

# Print the base version (no leading v) that a tool's nightlies sort just
# below: the next planned release. Derived from the tool repository's highest
# non-nightly semver tag: a trailing numeric prerelease identifier is
# incremented (0.1.0-alpha.12 -> 0.1.0-alpha.13), a non-numeric one gains one
# (0.1.0-alpha -> 0.1.0-alpha.1), and a stable tag bumps the patch component
# (0.5.0 -> 0.5.1).
nightly_base_version() {
  local repo="$1"
  local tags tag base core pre last bumped
  if ! tags="$(
    git ls-remote --tags "https://github.com/${repo}.git" |
      sed 's#.*refs/tags/##' |
      grep -v '\^{}$' |
      grep -E "$NIGHTLY_BASE_TAG_RE" |
      grep -v -- '-nightly'
  )"; then
    nightly_die "could not list tags for ${repo}"
  fi
  [ -n "$tags" ] || nightly_die "no non-nightly semver tag found on ${repo}"
  tag=""
  local candidate
  while read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -z "$tag" ] || [ "$(nightly_semver_compare "${candidate#v}" "${tag#v}")" = "1" ]; then
      tag="$candidate"
    fi
  done <<<"$tags"
  base="${tag#v}"
  case "$base" in
  *-*)
    core="${base%%-*}"
    pre="${base#*-}"
    last="${pre##*.}"
    if [[ $last =~ ^[0-9]+$ ]]; then
      if [[ $pre == *.* ]]; then
        bumped="${pre%.*}.$(nightly_increment_decimal "$last")"
      else
        # Single-identifier prerelease (v1.2.3-1 -> 1.2.3-2, not 1.2.3-1.2).
        bumped="$(nightly_increment_decimal "$last")"
      fi
    else
      bumped="${pre}.1"
    fi
    printf '%s-%s\n' "$core" "$bumped"
    ;;
  *)
    core="$base"
    printf '%s.%s\n' "${core%.*}" "$(nightly_increment_decimal "${core##*.}")"
    ;;
  esac
}

# Print a tool's nightly version: <toolbase>-nightly.<yyyymmdd>.g<shortsha>.
nightly_tool_version() {
  local repo="$1" sha="$2"
  local base date short
  base="$(nightly_base_version "$repo")"
  date="${NIGHTLY_DATE:-$(date -u +%Y%m%d)}"
  [[ $date =~ ^[0-9]{8}$ ]] || nightly_die "NIGHTLY_DATE must be YYYYMMDD, got '${date}'"
  short="${sha:0:7}"
  printf '%s-nightly.%s.g%s\n' "$base" "$date" "$short"
}

# The recipe tree hash feeding the skip check.
nightly_recipe_tree() {
  if [ -n "${NIGHTLY_RECIPE_TREE:-}" ]; then
    printf '%s\n' "$NIGHTLY_RECIPE_TREE"
  else
    git rev-parse HEAD:nightly 2>/dev/null || echo unknown
  fi
}

# Sort nightly tags newest-first (stdin, one per line) by the tag's own
# SemVer semantics: the releases API returns creation order, which a backfill
# with NIGHTLY_DATE would falsify. Selection sort; nightly tag counts are
# tiny (bounded by NIGHTLY_KEEP).
nightly_sort_tags_desc() {
  local -a tags=()
  mapfile -t tags
  local i j best tmp
  for ((i = 0; i < ${#tags[@]}; i++)); do
    best=$i
    for ((j = i + 1; j < ${#tags[@]}; j++)); do
      if [ "$(nightly_semver_compare "${tags[j]#v}" "${tags[best]#v}")" = "1" ]; then
        best=$j
      fi
    done
    if [ "$best" != "$i" ]; then
      tmp="${tags[i]}"
      tags[i]="${tags[best]}"
      tags[best]="$tmp"
    fi
  done
  if [ ${#tags[@]} -gt 0 ]; then
    printf '%s\n' "${tags[@]}"
  fi
}

# Print the newest dated nightly release tag on the publish repository
# (empty when none exists).
nightly_latest_release_tag() {
  nightly_gh api "repos/${NIGHTLY_RELEASE_REPO}/releases?per_page=20" \
    --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name' |
    { grep -E "$NIGHTLY_TAG_BODY_RE" || true; } |
    nightly_sort_tags_desc |
    sed -n '1p'
}

# Print one "<field>: <value>" line's value from a release body (first match
# only; parameter expansion avoids closing any pipe early under pipefail).
nightly_release_field() {
  local tag="$1" field="$2"
  local body value
  body="$(nightly_gh api "repos/${NIGHTLY_RELEASE_REPO}/releases/tags/${tag}" --jq '.body // ""')"
  value="$(printf '%s\n' "$body" | sed -n "s/^${field}: \\(.*\\)\$/\\1/p")"
  value="${value%%$'\n'*}"
  printf '%s\n' "$value"
}

# Decide whether <tool> needs a fresh build for <head sha>: build when the
# newest nightly recorded a different commit for the tool, when the recipe
# changed, or when forced. Returns 0 to build, 1 to skip.
nightly_tool_should_build() {
  local tool="$1" head="$2"
  if [ "${NIGHTLY_FORCE:-0}" = "1" ]; then
    nightly_log "${tool}: NIGHTLY_FORCE=1; building"
    return 0
  fi
  local tag recorded stored_tree recipe_tree
  tag="$(nightly_latest_release_tag)"
  if [ -z "$tag" ]; then
    nightly_log "${tool}: no previous nightly; building"
    return 0
  fi
  recorded="$(nightly_release_field "$tag" "${tool}-commit")"
  stored_tree="$(nightly_release_field "$tag" "nightly-recipe-tree")"
  recipe_tree="$(nightly_recipe_tree)"
  if [ "$recorded" = "$head" ] && [ "$stored_tree" = "$recipe_tree" ] && [ "$recipe_tree" != "unknown" ]; then
    nightly_log "${tool}: ${tag} already covers ${head} with an unchanged recipe; skipping"
    return 1
  fi
  nightly_log "${tool}: building (recorded ${recorded:-none}, HEAD ${head}, recipe ${stored_tree:-none} -> ${recipe_tree})"
  return 0
}

# Clone <repo> (default branch, shallow) into <dest>; extra args are passed to
# git clone (e.g. --recurse-submodules --shallow-submodules).
nightly_clone() {
  local repo="$1" dest="$2"
  shift 2
  git clone --depth 1 "$@" "https://github.com/${repo}.git" "$dest"
}

# Write <file>.sha256 next to <file> (basename form, as consumers expect).
nightly_sha256_sidecar() {
  local file="$1"
  (cd "$(dirname "$file")" && sha256sum "$(basename "$file")" >"$(basename "$file").sha256")
}

# Record a built tool's provenance for the publish stage and the next run's
# skip check.
nightly_record_built() {
  local tool="$1" head="$2" version="$3"
  : "${NIGHTLY_ASSETS_DIR:?}"
  printf '%s\n' "$head" >"${NIGHTLY_ASSETS_DIR}/${tool}.commit"
  printf '%s\n' "$version" >"${NIGHTLY_ASSETS_DIR}/${tool}.version"
}

# Compute the repository-level nightly tag: v<base>-nightly.<yyyymmdd>[.N].
# The base comes from this repository's own non-nightly tags and stays 0.1.0
# until a stable tag exists here. A colliding same-day tag (forced rerun,
# recipe change) moves to the next free .N suffix; NIGHTLY_SUFFIX overrides.
nightly_repo_tag() {
  local base date tag existing max_n
  base="$(nightly_base_version "$NIGHTLY_RELEASE_REPO" 2>/dev/null || true)"
  [ -n "$base" ] || base="0.1.0"
  date="${NIGHTLY_DATE:-$(date -u +%Y%m%d)}"
  [[ $date =~ ^[0-9]{8}$ ]] || nightly_die "NIGHTLY_DATE must be YYYYMMDD, got '${date}'"
  tag="v${base}-nightly.${date}"
  if [ -n "${NIGHTLY_SUFFIX:-}" ]; then
    if ! [[ $NIGHTLY_SUFFIX =~ ^[1-9][0-9]*$ ]] || [ "$NIGHTLY_SUFFIX" -lt 2 ]; then
      nightly_die "NIGHTLY_SUFFIX must be an integer >= 2, got '${NIGHTLY_SUFFIX}'"
    fi
    tag="${tag}.${NIGHTLY_SUFFIX}"
  else
    existing="$(git ls-remote --tags "https://github.com/${NIGHTLY_RELEASE_REPO}.git" "refs/tags/${tag}" "refs/tags/${tag}.[0-9]*" |
      sed 's#.*refs/tags/##')"
    if printf '%s\n' "$existing" | grep -Fqx "$tag"; then
      max_n="$(printf '%s\n' "$existing" | sed -n "s/^${tag//./\\.}\.\([0-9][0-9]*\)\$/\1/p" | sort -n | tail -n 1)"
      # The plain tag counts as .1, so the next free suffix is max+1.
      tag="${tag}.$(nightly_increment_decimal "${max_n:-1}")"
      nightly_log "same-day tag collision; using ${tag}"
    fi
  fi
  [[ $tag =~ $NIGHTLY_TAG_RE ]] ||
    nightly_die "internal error: computed tag '${tag}' does not match the nightly scheme"
  printf '%s\n' "$tag"
}

# Download one tool's assets from an earlier nightly release into
# $NIGHTLY_ASSETS_DIR (byte-identical carry-forward of an unchanged tool).
nightly_carry_forward() {
  local tag="$1" tool="$2"
  local pattern
  case "$tool" in
  ecc) pattern='ecc-cli-linux-x86_64.tar.gz*' ;;
  ecc-sizer) pattern='ecc-sizer-*.tar.gz*' ;;
  ecos-studio) pattern='ECOS-Studio*.AppImage*' ;;
  *) nightly_die "unknown tool: $tool" ;;
  esac
  nightly_log "carrying forward ${tool} assets from ${tag}"
  nightly_gh release download "$tag" \
    --repo "$NIGHTLY_RELEASE_REPO" \
    --pattern "$pattern" \
    --dir "$NIGHTLY_ASSETS_DIR" \
    --clobber
}

# Run the smoke-test binary <path> with <args...> inside a clean ubuntu:24.04
# container (newer glibc than the build images, no development packages): the
# artifact can only start if it carries every non-system dependency itself.
nightly_clean_distro_smoke() {
  local root_on_host="$1" entrypoint="$2"
  shift 2
  command -v docker >/dev/null 2>&1 || nightly_die "clean-distro smoke test needs docker"
  docker run --rm -v "${root_on_host}:/pkg:ro" ubuntu:24.04 "/pkg/${entrypoint}" "$@"
}
