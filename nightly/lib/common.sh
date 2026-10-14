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
#
# NIGHTLY_TAG_BODY_RE is single-sourced in toolchain.toml ([nightly] tag_re)
# and injected by the nix wrapper (and the syntax check); the installer gets
# the same value as its NIGHTLY_TAG_RE placeholder.
: "${NIGHTLY_TAG_BODY_RE:?injected from toolchain.toml by the nix wrapper}"
NIGHTLY_TAG_RE="^${NIGHTLY_TAG_BODY_RE}\$"
# Strict SemVer 2.0.0 (no leading zeros) for the tags eligible as a tool's
# nightly base; keeps the numeric comparisons below free of leading-zero
# ambiguity.
NIGHTLY_BASE_TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?$'

# Consumed by the recipes and the publish stage (concatenated into the same
# app; shellcheck sees this file in isolation).
# shellcheck disable=SC2034
NIGHTLY_TOOLS="ecc ecc-sizer kepler-formal ecos-studio pdk"
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
# ecc-tools, the kepler-formal nightly release listing). Uses the read-only
# NIGHTLY_READ_TOKEN when present so the release token's scope stays minimal;
# falls back to the release token (works for public-repo release reads, but
# not for cross-repo Actions).
nightly_gh_deps() {
  local token="${NIGHTLY_DEPS_TOKEN:-$NIGHTLY_GH_TOKEN}"
  GH_TOKEN="$token" gh "$@"
}

nightly_tool_repo() {
  case "$1" in
  ecc) printf 'openecos-projects/ecc\n' ;;
  ecc-sizer) printf 'openecos-projects/ecc-sizer\n' ;;
  kepler-formal) printf 'openecos-projects/kepler-formal\n' ;;
  ecos-studio) printf 'openecos-projects/ecos-studio\n' ;;
  pdk) printf 'openecos-projects/icsprout55-pdk\n' ;;
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

# Print "<run_id> <head_sha>" of the newest successful run of <workflow> on
# <repo>'s main (optionally filtered to one event type). Empty when none
# exists. Success is filtered server-side (status=success), so a streak of
# failures can never push the last green run out of the page window.
# Needs the deps token (Actions:read).
nightly_latest_green_run() {
  local repo="$1" workflow="$2" event="${3:-}"
  local url="repos/${repo}/actions/workflows/${workflow}/runs?branch=main&status=success&per_page=5"
  if [ -n "$event" ]; then
    url="${url}&event=${event}"
  fi
  # Build the per-run string list first: first|join over an empty set would
  # otherwise print " " (a single space), which is not an empty result.
  nightly_gh_deps api "$url" \
    --jq '[.workflow_runs[] | [.id, .head_sha] | join(" ")][0] // empty'
}

# Print the newest commit on <repo>'s main with a successful scheduled run
# of <workflow> — the "nightly check" gate. A manually dispatched green run
# is the bootstrap/fallback. Empty when no green run exists yet. The event
# filter is server-side (per_page is ample for a daily schedule), so no
# pagination is needed. Needs the deps token (Actions:read).
nightly_checked_head() {
  local repo="$1" workflow="$2"
  local out
  out="$(nightly_latest_green_run "$repo" "$workflow" schedule)"
  if [ -z "$out" ]; then
    out="$(nightly_latest_green_run "$repo" "$workflow" workflow_dispatch)"
  fi
  printf '%s\n' "${out#* }"
}

# Print "<tag> <target_commitish>" of the newest kepler-formal nightly
# prerelease upstream (their pipeline skips days without changes, so this
# deliberately lags the default-branch HEAD).
nightly_kepler_upstream() {
  local repo tag commit
  repo="$(nightly_tool_repo kepler-formal)"
  tag="$(nightly_gh_deps api "repos/${repo}/releases?per_page=20" \
    --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name' |
    { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}(\.[1-9][0-9]*)?$' || true; } |
    nightly_sort_tags_desc |
    sed -n '1p')"
  [ -n "$tag" ] || nightly_die "no nightly prerelease found on ${repo}"
  commit="$(nightly_gh_deps api "repos/${repo}/releases/tags/${tag}" --jq '.target_commitish')" ||
    nightly_die "could not read release ${tag} on ${repo}"
  printf '%s %s\n' "$tag" "$commit"
}

# Print the commit a tag points at (peeled for annotated tags; an exact
# ref-pattern query alone returns only the tag object line).
nightly_tag_commit() {
  local repo="$1" tag="$2"
  local out plain peeled
  out="$(git ls-remote --tags "https://github.com/${repo}.git" "refs/tags/${tag}" "refs/tags/${tag}^{}")" ||
    nightly_die "could not resolve tag ${tag} on ${repo}"
  peeled="$(printf '%s\n' "$out" | sed -n "s#\\([0-9a-f]\\{40\\}\\)[[:space:]]refs/tags/${tag//./\\.}\\^{}\$#\\1#p")"
  plain="$(printf '%s\n' "$out" | sed -n "s#\\([0-9a-f]\\{40\\}\\)[[:space:]]refs/tags/${tag//./\\.}\$#\\1#p")"
  if [ -n "$peeled" ]; then
    printf '%s\n' "${peeled%%$'\n'*}"
  else
    [ -n "$plain" ] || nightly_die "tag ${tag} not found on ${repo}"
    printf '%s\n' "${plain%%$'\n'*}"
  fi
}

# Print "<tag> <target_commitish>" of the newest icsprout55-pdk release that
# carries the full package set (per $NIGHTLY_PDK_MANIFEST); older tags are
# tried in order when a newer one is incomplete.
nightly_pdk_upstream() {
  local repo expected releases
  repo="$(nightly_tool_repo pdk)"
  expected="$(jq -r '.assetNames[]' "$NIGHTLY_PDK_MANIFEST")"
  releases="$(nightly_gh api "repos/${repo}/releases?per_page=100" --paginate \
    --jq '.[] | select(.draft == false) | [.tag_name, .target_commitish, ([.assets[].name] | join(" "))] | @tsv')" ||
    nightly_die "could not list releases on ${repo}"
  # Candidates newest-version-first: the API order is not version order, and
  # a page window could otherwise hide the newest complete release.
  local tags tag line assets missing name commit
  tags="$(printf '%s\n' "$releases" | cut -f1 | nightly_sort_tags_desc)"
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    line="$(printf '%s\n' "$releases" | awk -F'\t' -v t="$tag" '$1 == t')"
    assets="$(printf '%s' "$line" | cut -f3)"
    missing=0
    while read -r name; do
      [ -n "$name" ] || continue
      case " $assets " in
      *" $name "*) ;;
      *) missing=1 ;;
      esac
    done <<<"$expected"
    if [ "$missing" -eq 0 ]; then
      # target_commitish is the branch name when the release was published
      # targeting a branch; resolve the tag to an exact commit instead.
      commit="$(nightly_tag_commit "$repo" "$tag")"
      printf '%s %s\n' "$tag" "$commit"
      return 0
    fi
    nightly_log "pdk: release $tag lacks some packages; trying an older one"
  done <<<"$tags"
  nightly_die "no complete PDK release found on ${repo}"
}

# The commit a tool's nightly is allowed to build. ecc is gated on its
# repository's nightly CI check (ci.yml on a schedule); kepler-formal follows
# its own repository's latest nightly build; the pdk follows its newest
# complete release tag; everything else tracks the default-branch HEAD.
nightly_effective_head() {
  local tool="$1" repo="$2"
  case "$tool" in
  ecc)
    nightly_checked_head "$repo" ci.yml
    ;;
  ecc-sizer)
    # Aggregation follows the newest green CI run on main, not bare HEAD.
    local run
    run="$(nightly_latest_green_run "$repo" ci.yml)"
    printf '%s\n' "${run#* }"
    ;;
  kepler-formal)
    local up
    up="$(nightly_kepler_upstream)"
    printf '%s\n' "${up#* }"
    ;;
  pdk)
    local up
    up="$(nightly_pdk_upstream)"
    printf '%s\n' "${up#* }"
    ;;
  *)
    nightly_resolve_head "$repo"
    ;;
  esac
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
  local raw
  if ! raw="$(git ls-remote --tags "https://github.com/${repo}.git")"; then
    nightly_die "could not list tags for ${repo}"
  fi
  # Filtering is local and may legitimately yield nothing (a repository with
  # no tags yet); keep it out of the network guard. The trailing || true
  # keeps a no-match grep from failing the pipeline under pipefail.
  tags="$(
    printf '%s\n' "$raw" |
      sed 's#.*refs/tags/##' |
      grep -v '\^{}$' |
      grep -E "$NIGHTLY_BASE_TAG_RE" |
      grep -v -- '-nightly' || true
  )"
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

# Substitute one @placeholder@ in the bundle manifest. Values land inside
# TOML strings, so reject anything that could break the quoting (or the sed
# replacement); the template's structure is fixed at eval time (see
# nix/modules/nightly.nix).
nightly_manifest_substitute() {
  local file="$1" placeholder="$2" value="$3"
  case "$value" in
  "" | *'"'* | *\\* | *'&'* | *'|'* | *$'\n'* | *$'\r'*)
    nightly_die "manifest value for ${placeholder} is empty or not TOML-safe"
    ;;
  esac
  sed -i "s|${placeholder}|${value}|g" "$file"
}

# Write ecos-manifest.toml into the bundle root from the eval-time template.
# Reads the caller-scoped tool_version/tool_commit associative arrays of
# nightly_recipe_release (keyed by $NIGHTLY_TOOLS names).
nightly_write_bundle_manifest() {
  local bundle_root="$1" tag="$2"
  local template="${NIGHTLY_BUNDLE_MANIFEST_TEMPLATE:?}"
  local out="${bundle_root}/ecos-manifest.toml"
  local tool uc
  cp "$template" "$out"
  nightly_manifest_substitute "$out" "@NIGHTLY_TAG@" "$tag"
  for tool in $NIGHTLY_TOOLS; do
    uc="$(printf '%s' "$tool" | tr 'a-z-' 'A-Z_')"
    nightly_manifest_substitute "$out" "@NIGHTLY_${uc}_VERSION@" "${tool_version[$tool]:?}"
    nightly_manifest_substitute "$out" "@NIGHTLY_${uc}_COMMIT@" "${tool_commit[$tool]:?}"
  done
  if grep -q '@NIGHTLY_[A-Z_]*@' "$out"; then
    nightly_die "bundle manifest still carries unsubstituted placeholders"
  fi
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
  # NOTE: a `|| true` after a command substitution cannot rescue a helper
  # that dies with `exit`: the exit terminates the substitution subshell
  # before the || handler ever runs. Catch the failure with if/! instead.
  if ! base="$(nightly_base_version "$NIGHTLY_RELEASE_REPO" 2>/dev/null)"; then
    # No tags on this repository yet (first nightly ever): the series starts
    # at 0.1.0 until a stable tag exists here.
    base="0.1.0"
    nightly_log "no tags on ${NIGHTLY_RELEASE_REPO} yet; using base 0.1.0"
  fi
  date="${NIGHTLY_DATE:-$(date -u +%Y%m%d)}"
  [[ $date =~ ^[0-9]{8}$ ]] || nightly_die "NIGHTLY_DATE must be YYYYMMDD, got '${date}'"
  tag="v${base}-nightly.${date}"
  if [ -n "${NIGHTLY_SUFFIX:-}" ]; then
    if ! [[ $NIGHTLY_SUFFIX =~ ^[1-9][0-9]*$ ]] || [ "$NIGHTLY_SUFFIX" -lt 2 ]; then
      nightly_die "NIGHTLY_SUFFIX must be an integer >= 2, got '${NIGHTLY_SUFFIX}'"
    fi
    tag="${tag}.${NIGHTLY_SUFFIX}"
  else
    if ! existing="$(git ls-remote --tags "https://github.com/${NIGHTLY_RELEASE_REPO}.git" "refs/tags/${tag}" "refs/tags/${tag}.[0-9]*" |
      sed 's#.*refs/tags/##')"; then
      nightly_die "could not query tags on ${NIGHTLY_RELEASE_REPO}"
    fi
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

# Carry an unchanged tool forward from the previous nightly's bundle into
# $NIGHTLY_ASSETS_DIR: the published release only carries the combined
# bundle, so the tool's subtree is extracted from it and repacked under the
# recorded version's asset name (byte-identical file content).
nightly_carry_forward() {
  local tag="$1" tool="$2"
  local subdir
  case "$tool" in
  ecc) subdir=ecc ;;
  ecc-sizer) subdir=ecc-sizer ;;
  kepler-formal) subdir=kepler-formal ;;
  ecos-studio) subdir=studio ;;
  pdk) subdir=pdk ;;
  *) nightly_die "unknown tool: $tool" ;;
  esac
  nightly_log "carrying forward ${tool} from ${tag}'s bundle"
  local work version
  work="$(mktemp -d)"
  nightly_gh release download "$tag" \
    --repo "$NIGHTLY_RELEASE_REPO" \
    --pattern 'ecos-nightly-linux-x86_64.tar.gz' \
    --dir "$work" \
    --clobber
  # Extract only this tool's subtree from the previous bundle.
  if ! tar -xzf "$work/ecos-nightly-linux-x86_64.tar.gz" -C "$work" \
    "ecos-nightly-linux-x86_64/${subdir}" 2>/dev/null; then
    nightly_die "previous bundle ${tag} has no ${subdir}/ subtree; force a full rebuild instead of carrying"
  fi
  case "$tool" in
  ecos-studio)
    cp "$work/ecos-nightly-linux-x86_64/studio/"*.AppImage "$NIGHTLY_ASSETS_DIR/"
    ;;
  ecc)
    # Static asset name; no version lookup needed.
    tar -czf "$NIGHTLY_ASSETS_DIR/ecc-cli-linux-x86_64.tar.gz" -C "$work/ecos-nightly-linux-x86_64/ecc" .
    ;;
  *)
    local version
    version="$(nightly_release_field "$tag" "${tool}-version")"
    [ -n "$version" ] || nightly_die "no ${tool}-version recorded in ${tag}"
    tar -czf "$NIGHTLY_ASSETS_DIR/$(nightly_tool_asset_name "$tool" "$version")" \
      -C "$work/ecos-nightly-linux-x86_64" "$subdir"
    ;;
  esac
  rm -rf "$work"
}

# The per-tool asset file name for a given recorded version.
nightly_tool_asset_name() {
  case "$1" in
  ecc-sizer) printf 'ecc-sizer-%s-linux-x64.tar.gz\n' "$2" ;;
  kepler-formal) printf 'kepler-formal-%s-linux-x86_64.tar.gz\n' "$2" ;;
  pdk) printf 'icsprout55-pdk-%s.tar.gz\n' "$2" ;;
  *) nightly_die "no versioned asset name for tool: $1" ;;
  esac
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

# Assemble the combined bundle tree from the staged per-tool assets —
# oss-cad-suite style, one tarball for the whole toolchain: ecc/ holds the
# PyInstaller onedir contents, ecc-sizer/ and kepler-formal/ the portable
# runtimes, pdk/ the assembled ICS55 PDK, and studio/ the AppImage.
nightly_assemble_bundle() {
  local assets="$1" bundle_root="$2"
  mkdir -p "$bundle_root/ecc" "$bundle_root/ecc-sizer" "$bundle_root/kepler-formal" "$bundle_root/pdk" "$bundle_root/studio"
  tar -xzf "$assets/ecc-cli-linux-x86_64.tar.gz" -C "$bundle_root/ecc" ||
    nightly_die "bundle: could not unpack the ecc tarball"
  shopt -s nullglob
  local tarballs
  tarballs=("$assets"/ecc-sizer-*-linux-x64.tar.gz)
  [ ${#tarballs[@]} -ge 1 ] || nightly_die "bundle: no ecc-sizer tarball available"
  tar -xzf "${tarballs[0]}" --strip-components 1 -C "$bundle_root/ecc-sizer" ||
    nightly_die "bundle: could not unpack the ecc-sizer tarball"
  tarballs=("$assets"/kepler-formal-*-linux-x86_64.tar.gz)
  [ ${#tarballs[@]} -ge 1 ] || nightly_die "bundle: no kepler-formal tarball available"
  tar -xzf "${tarballs[0]}" --strip-components 1 -C "$bundle_root/kepler-formal" ||
    nightly_die "bundle: could not unpack the kepler-formal tarball"
  tarballs=("$assets"/icsprout55-pdk-*.tar.gz)
  [ ${#tarballs[@]} -ge 1 ] || nightly_die "bundle: no ICS55 PDK tarball available"
  tar -xzf "${tarballs[0]}" --strip-components 1 -C "$bundle_root/pdk" ||
    nightly_die "bundle: could not unpack the ICS55 PDK tarball"
  tarballs=("$assets"/ECOS-Studio_*.AppImage)
  [ ${#tarballs[@]} -ge 1 ] || nightly_die "bundle: no ecos-studio AppImage available"
  cp "${tarballs[@]}" "$bundle_root/studio/"
  chmod +x "$bundle_root"/studio/*.AppImage
}
