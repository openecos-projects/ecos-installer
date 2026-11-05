# Keep a rolling prerelease at /releases/download/latest/<asset>. GitHub's
# /releases/latest/download redirect excludes prereleases. The dated release
# remains the source of truth; only the latest tag and its assets are mutable.
nightly_recipe_latest() (
  cached_tag="${1:-}"
  cached_dir="${2:-}"
  releases="$(nightly_gh api "repos/${NIGHTLY_RELEASE_REPO}/releases?per_page=100" --paginate | jq -s add)"
  tag="$(jq -r '.[] | select(.prerelease == true and .draft == false) | .tag_name' <<<"$releases" |
    { grep -E "$NIGHTLY_TAG_RE" || true; } | nightly_sort_tags_desc | sed -n '1p')"
  [ -n "$tag" ] || nightly_die "no dated nightly to publish as latest"
  source_release="$(jq -c --arg tag "$tag" '.[] | select(.tag_name == $tag)' <<<"$releases")"
  rolling="$(jq -c '.[] | select(.tag_name == "latest")' <<<"$releases")"

  full="ecos-nightly-linux-x86_64.tar.gz"
  cli="${NIGHTLY_CLI_BUNDLE_NAME:?}.tar.gz"
  names=("$full" "${full}.sha256")
  # Older dated releases have only the full bundle; bootstrap those too.
  if jq -e --arg cli "$cli" 'any(.assets[]; .name == $cli or .name == ($cli + ".sha256"))' <<<"$source_release" >/dev/null; then
    names+=("$cli" "${cli}.sha256")
  fi
  for name in "${names[@]}"; do
    jq -e --arg name "$name" 'any(.assets[]; .name == $name and .state == "uploaded")' <<<"$source_release" >/dev/null ||
      nightly_die "${tag}: missing uploaded asset ${name}"
  done

  # Compare asset digests as well as the source tag so a partially completed
  # upload is repaired on retry. Listing errors must not look like absence.
  asset_filter='[.assets[] | {name, size, digest, state}] | sort_by(.name)'
  source_assets="$(jq -c --arg full "$full" --arg cli "$cli" \
    '.assets |= map(select(.name == $full or .name == ($full + ".sha256") or .name == $cli or .name == ($cli + ".sha256")))' <<<"$source_release" |
    jq -c "$asset_filter")"
  commit="$(nightly_tag_commit "$NIGHTLY_RELEASE_REPO" "$tag")"
  ref="$(nightly_gh api "repos/${NIGHTLY_RELEASE_REPO}/git/matching-refs/tags/latest" \
    --jq '.[] | select(.ref == "refs/tags/latest") | .object.sha')"
  marker="<!-- nightly-source: ${tag} -->"
  if [ -n "$rolling" ] && [ "$ref" = "$commit" ] &&
    jq -e --arg marker "$marker" '.draft == false and .prerelease == true and ((.body // "") | contains($marker))' <<<"$rolling" >/dev/null &&
    [ "$(jq -c "$asset_filter" <<<"$rolling")" = "$source_assets" ]; then
    nightly_log "latest already matches ${tag}"
    exit 0
  fi

  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT
  assets_dir="$workdir"
  if [ "$cached_tag" = "$tag" ] && [ -d "$cached_dir" ]; then
    assets_dir="$cached_dir"
  else
    patterns=()
    for name in "${names[@]}"; do
      patterns+=(--pattern "$name")
    done
    nightly_gh release download "$tag" --repo "$NIGHTLY_RELEASE_REPO" \
      "${patterns[@]}" --dir "$assets_dir"
  fi
  assets=()
  for name in "${names[@]}"; do
    [ -s "$assets_dir/$name" ] || nightly_die "missing latest asset ${name}"
    assets+=("$assets_dir/$name")
    case "$name" in
    *.tar.gz) (cd "$assets_dir" && sha256sum -c "${name}.sha256") ;;
    esac
  done

  notes="$workdir/notes.md"
  {
    echo "Rolling nightly download. Assets are identical to [${tag}](https://github.com/${NIGHTLY_RELEASE_REPO}/releases/tag/${tag}) and are replaced when a newer nightly is published."
    echo
    echo "$marker"
    echo
    jq -r '.body // ""' <<<"$source_release"
  } >"$notes"

  # Move only the rolling ref. Resolving the dated tag above also handles
  # releases whose target_commitish is a branch rather than an exact SHA.
  if [ -n "$ref" ]; then
    nightly_gh api --method PATCH "repos/${NIGHTLY_RELEASE_REPO}/git/refs/tags/latest" \
      -f sha="$commit" -F force=true >/dev/null
  else
    nightly_gh api --method POST "repos/${NIGHTLY_RELEASE_REPO}/git/refs" \
      -f ref=refs/tags/latest -f sha="$commit" >/dev/null
  fi
  if [ -z "$rolling" ]; then
    nightly_gh release create latest --repo "$NIGHTLY_RELEASE_REPO" \
      --verify-tag --prerelease --latest=false --title "ECOS nightly latest" \
      --notes-file "$notes" "${assets[@]}"
  else
    nightly_gh release upload latest --repo "$NIGHTLY_RELEASE_REPO" --clobber "${assets[@]}"
    # Remove assets no longer present in the source release, if any.
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if ! jq -e --arg name "$name" 'any(.[]; .name == $name)' <<<"$source_assets" >/dev/null; then
        nightly_gh release delete-asset latest "$name" --repo "$NIGHTLY_RELEASE_REPO" --yes
      fi
    done <<<"$(jq -r '.assets[].name' <<<"$rolling")"
    # Update the source marker last: a failed upload leaves the old marker
    # so the next run retries, including on days without new tool builds.
    nightly_gh release edit latest --repo "$NIGHTLY_RELEASE_REPO" \
      --draft=false --prerelease --latest=false --target "$commit" \
      --title "ECOS nightly latest" --notes-file "$notes"
  fi
  nightly_log "latest now mirrors ${tag}"
)
