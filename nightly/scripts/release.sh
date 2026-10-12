# Publish stage: assemble and create the dated nightly prerelease on this
# repository. Freshly built assets come from $NIGHTLY_ASSETS_DIR; assets of
# tools that did not move are carried forward byte-identically from the
# previous nightly release. When nothing moved and the recipe is unchanged,
# no release is created at all.

nightly_recipe_release() (
  : "${NIGHTLY_ASSETS_DIR:?}"
  workdir="$(mktemp -d)"
  # Cleanup is best-effort: a leftover workdir must not fail a green run.
  trap 'rm -rf "$workdir" 2>/dev/null || nightly_log "warning: could not clean $workdir"' EXIT

  latest_tag="$(nightly_latest_release_tag)"
  recipe_tree="$(nightly_recipe_tree)"

  # Per tool: fresh assets built this run, or carry-forward from the latest
  # nightly. Carry is valid only when the tool's effective head (for ecc: the
  # latest commit with a green nightly check, not bare HEAD) is unchanged
  # since then. Fresh assets are trusted as-is: they were validated against
  # the effective head at build time, which may legitimately have advanced
  # during the run.
  declare -A tool_version=()
  declare -A tool_commit=()
  fresh_tools=()
  carry_tools=()
  for tool in $NIGHTLY_TOOLS; do
    repo="$(nightly_tool_repo "$tool")"
    head="$(nightly_effective_head "$tool" "$repo")"
    if [ -f "$NIGHTLY_ASSETS_DIR/${tool}.commit" ]; then
      built="$(cat "$NIGHTLY_ASSETS_DIR/${tool}.commit")"
      [ -f "$NIGHTLY_ASSETS_DIR/${tool}.version" ] || nightly_die "$tool: missing version file"
      tool_version[$tool]="$(cat "$NIGHTLY_ASSETS_DIR/${tool}.version")"
      tool_commit[$tool]="$built"
      fresh_tools+=("$tool")
    else
      [ -n "$latest_tag" ] || nightly_die "$tool: no fresh assets and no previous nightly to carry from"
      recorded="$(nightly_release_field "$latest_tag" "${tool}-commit")"
      if [ -n "$head" ]; then
        [ "$recorded" = "$head" ] ||
          nightly_die "$tool moved ($recorded -> $head) but was not rebuilt this run"
      else
        # No effective head (ecc without any green nightly check): carrying
        # the recorded build is the only option.
        [ -n "$recorded" ] || nightly_die "$tool: nothing recorded in $latest_tag and nothing built"
      fi
      tool_version[$tool]="$(nightly_release_field "$latest_tag" "${tool}-version")"
      tool_commit[$tool]="$recorded"
      carry_tools+=("$tool")
    fi
  done

  if [ ${#fresh_tools[@]} -eq 0 ]; then
    nightly_log "all tools unchanged since ${latest_tag}; no nightly today"
    exit 0
  fi

  nightly_log "release: fresh=[${fresh_tools[*]}] carry=[${carry_tools[*]}] latest=${latest_tag:-none}"

  for tool in "${carry_tools[@]}"; do
    nightly_carry_forward "$latest_tag" "$tool"
  done

  # The combined bundle (oss-cad-suite style, one tarball for the whole
  # toolchain): ecc/ holds the PyInstaller onedir contents, ecc-sizer/ and
  # kepler-formal/ the portable runtimes, pdk/ the assembled ICS55 PDK.
  bundle_name="ecos-nightly-linux-x86_64"
  bundle_root="$workdir/$bundle_name"
  nightly_assemble_bundle "$NIGHTLY_ASSETS_DIR" "$bundle_root"

  tag="$(nightly_repo_tag)"
  nightly_log "release: assembling bundle and notes for ${tag}"
  cat >"$bundle_root/README.md" <<EOF
# ECOS nightly toolchain bundle (Linux x86_64)

Release: ${tag}

| tool | version | source commit |
|---|---|---|
| ecc | ${tool_version[ecc]} | ${tool_commit[ecc]} |
| ecc-sizer | ${tool_version["ecc-sizer"]} | ${tool_commit["ecc-sizer"]} |
| kepler-formal | ${tool_version["kepler-formal"]} | ${tool_commit["kepler-formal"]} |
| pdk (ics55) | ${tool_version["pdk"]} | ${tool_commit["pdk"]} |

ecos-studio ships separately as its AppImage asset on the same release. OSS
CAD Suite stays out of the nightly channel — install it once with the
installer
(\`curl -fsSL https://release.openecos.com/installers/ecc/latest/ecc-installer.sh | sh -s -- --with-toolchain\`).

Layout: \`ecc/\` — ECC CLI (PyInstaller onedir, run \`ecc/ecc\`),
\`ecc-sizer/\` — portable Sizer runtime (run \`ecc-sizer/bin/Sizer\`),
\`kepler-formal/\` — Kepler formal verification (run \`kepler-formal/kepler-formal\`),
\`pdk/\` — the assembled ICS55 PDK (point PDK_ROOT here).

Unstable nightly build; use the stable releases of the individual tools for
production.
EOF
  tar -czf "$workdir/${bundle_name}.tar.gz" -C "$workdir" "$bundle_name"
  cp "$workdir/${bundle_name}.tar.gz" "$NIGHTLY_ASSETS_DIR/"
  nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/${bundle_name}.tar.gz"

  # Release notes: human table plus machine-readable fields (the skip check
  # and tomorrow's carry-forward read the <tool>-commit / <tool>-version /
  # nightly-recipe-tree lines back). The fields live in an HTML comment so
  # the rendered page stays clean; the API returns the raw body either way.
  notes="$workdir/notes.md"
  {
    echo "Nightly build of the ECOS toolchain (ecc, ecc-sizer, kepler-formal, ecos-studio) and the ICS55 PDK."
    echo
    echo "| tool | version | commit |"
    echo "|---|---|---|"
    for tool in $NIGHTLY_TOOLS; do
      repo="$(nightly_tool_repo "$tool")"
      echo "| ${tool} | ${tool_version[$tool]} | [${tool_commit[$tool]:0:7}](https://github.com/${repo}/commit/${tool_commit[$tool]}) |"
    done
    echo
    if [ -n "$latest_tag" ]; then
      echo "Changes since ${latest_tag}:"
      echo
      for tool in $NIGHTLY_TOOLS; do
        repo="$(nightly_tool_repo "$tool")"
        prev="$(nightly_release_field "$latest_tag" "${tool}-commit")"
        if [ -n "$prev" ] && [ "$prev" != "${tool_commit[$tool]}" ]; then
          echo "- ${tool}: https://github.com/${repo}/compare/${prev}...${tool_commit[$tool]}"
        else
          echo "- ${tool}: unchanged"
        fi
      done
      echo
    fi
    echo "## Downloads"
    echo
    # shellcheck disable=SC2016 # literal Markdown text, not a command substitution
    echo '- `ecos-nightly-linux-x86_64.tar.gz` — the whole toolchain in one bundle (run `ecc/ecc`, `ecc-sizer/bin/Sizer`, `kepler-formal/kepler-formal`; point PDK_ROOT at `pdk/`)'
    # shellcheck disable=SC2016 # literal Markdown text, not a command substitution
    echo '- `ECOS-Studio_*.AppImage` — the desktop app'
    # shellcheck disable=SC2016 # literal Markdown text, not a command substitution
    echo '- per-tool tarballs plus `.sha256` sidecars for individual or scripted consumption'
    echo
    echo "> [!WARNING]"
    echo "> Unstable nightly prerelease; use the tools' stable releases for production."
    echo
    echo "<!-- Machine-readable rebuild metadata, consumed by the nightly pipeline"
    echo "(skip check and carry-forward). Do not edit."
    for tool in $NIGHTLY_TOOLS; do
      echo "${tool}-commit: ${tool_commit[$tool]}"
      echo "${tool}-version: ${tool_version[$tool]}"
    done
    echo "nightly-recipe-tree: ${recipe_tree}"
    echo "-->"
  } >"$notes"

  self_head="$(git rev-parse HEAD 2>/dev/null || nightly_resolve_head "$NIGHTLY_RELEASE_REPO")"

  # gh release create uploads the assets; on failure nothing is published
  # (the release and its tag are created atomically with the upload). The
  # per-tool <tool>.commit / <tool>.version files are run metadata, not
  # release assets.
  assets=()
  for f in "$NIGHTLY_ASSETS_DIR"/*; do
    case "$f" in
    *.commit | *.version) continue ;;
    *) assets+=("$f") ;;
    esac
  done
  [ ${#assets[@]} -ge 1 ] || nightly_die "no assets to publish"

  nightly_log "release: creating ${tag} with ${#assets[@]} assets"
  local_rc=0
  nightly_gh release create "$tag" \
    --repo "$NIGHTLY_RELEASE_REPO" \
    --target "$self_head" \
    --prerelease \
    --title "ECOS nightly ${tag}" \
    --notes-file "$notes" \
    "${assets[@]}" || local_rc=$?
  [ "$local_rc" -eq 0 ] || nightly_die "gh release create ${tag} failed (exit ${local_rc})"
  nightly_log "release: published ${tag}"

  # Retention: keep the newest NIGHTLY_KEEP dated nightlies (by tag version,
  # not API creation order).
  keep="${NIGHTLY_KEEP:-14}"
  [[ $keep =~ ^[1-9][0-9]*$ ]] || nightly_die "NIGHTLY_KEEP must be a positive integer, got '${keep}'"
  nightly_gh api "repos/${NIGHTLY_RELEASE_REPO}/releases?per_page=100" --paginate \
    --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name' |
    { grep -E "$NIGHTLY_TAG_RE" || true; } |
    nightly_sort_tags_desc |
    tail -n "+$((keep + 1))" | while read -r old; do
    [ -n "$old" ] || continue
    nightly_log "deleting old nightly ${old}"
    nightly_gh release delete "$old" --repo "$NIGHTLY_RELEASE_REPO" --cleanup-tag --yes ||
      nightly_log "warning: failed to delete ${old}"
  done
)
