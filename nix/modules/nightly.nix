# Nightly build domain: the nightly-build app (nix run .#nightly-build --
# <tool>) and its static checks.
#
# nix only provides the orchestration tools (git/gh/jq/curl); the builds run
# each tool's native recipe (container or runner toolchain) so published
# artifacts never reference /nix/store. The recipes live in
# ../../nightly/scripts/ and share nightly/lib/common.sh; dispatch.sh is the
# entry point.
{ ... }:

{
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # The PDK package set (base git archive + release packages with dest
      # paths, plus the installer's validation file list) is single-sourced
      # in toolchain.toml; the pdk recipe consumes this projection.
      toolchain = config.ecos.toolchain;
      # Validated model view of the [nightly] section (regex self-checked at
      # eval time in model.nix); injecting the raw toolchain.nightly values
      # would bypass that check.
      nightlyModel = config.ecos.model.nightly;
      pdkPkgs = toolchain.pdk_pkg;
      basePkg = lib.findFirst (p: p.kind == "base") null pdkPkgs;
      pdkManifest = pkgs.writeText "nightly-pdk-manifest.json" (
        builtins.toJSON {
          repo = "openecos-projects/icsprout55-pdk";
          base = {
            urlTemplate = basePkg.url_template;
            stripPrefix = basePkg.strip_prefix;
          };
          packages = map (p: {
            id = p.id;
            urlTemplate = p.url_template;
            dest = p.dest or "";
          }) (builtins.filter (p: p.kind != "base") pdkPkgs);
          assetNames = map (p: builtins.baseNameOf p.url_template) (
            builtins.filter (p: p.kind != "base") pdkPkgs
          );
          verifyPaths = [ toolchain.pdk.tech_lef ] ++ toolchain.pdk.cell_lefs ++ toolchain.pdk.liberty_files;
        }
      );

      # Bundle manifest template (ecos-manifest.toml) shipped inside the
      # nightly bundle: the installer's --nightly mode validates the
      # extracted trees against this file, so the validation data travels
      # with the artifacts and cannot drift from the nightly assembly the
      # way the installer's stable pins could. The PDK lists are the same
      # toolchain.toml projection the pdk recipe consumes; the runtime
      # values (tag, per-tool version/commit) stay as @NIGHTLY_*@
      # placeholders for release.sh to substitute. Arrays stay on one line
      # and placeholders sit inside TOML strings, so the template itself is
      # valid TOML -- verified by the fromTOML deepSeq below.
      bundleManifestText =
        let
          # The installer's awk parser accepts only [^"\] inside strings and
          # so does this template: a PDK path with a quote or backslash fails
          # the build here instead of producing a manifest the installer
          # would reject as malformed. (requireRelative allows both, and the
          # fromTOML deepSeq below would catch an unescaped quote anyway, but
          # with an opaque parse error.)
          quote =
            s:
            if builtins.match ''[^"\\]*'' s == null then
              throw "nightly bundle manifest: PDK path is not TOML-safe: ${s}"
            else
              ''"${s}"'';
          list = xs: "[ ${lib.concatStringsSep ", " (map quote xs)} ]";
          toolPlaceholder = tool: lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] tool);
          toolSection = tool: ''
            [tools.${tool}]
            version = "@NIGHTLY_${toolPlaceholder tool}_VERSION@"
            commit = "@NIGHTLY_${toolPlaceholder tool}_COMMIT@"
          '';
        in
        ''
          # Machine-readable manifest of this ECOS nightly bundle, consumed by
          # ecc-installer.sh --nightly. Generated at publish time; do not edit.
          tag = "@NIGHTLY_TAG@"
        ''
        + lib.concatMapStringsSep "\n" toolSection [
          "ecc"
          "ecc-sizer"
          "kepler-formal"
          "ecos-studio"
          "pdk"
        ]
        + ''
          [pdk]
          tech_lef = ${quote toolchain.pdk.tech_lef}
          cell_lefs = ${list toolchain.pdk.cell_lefs}
          liberty_files = ${list toolchain.pdk.liberty_files}
        '';

      bundleManifestParsed = builtins.fromTOML bundleManifestText;

      bundleManifestTemplate = pkgs.writeText "ecos-manifest.toml.in" (
        builtins.deepSeq bundleManifestParsed bundleManifestText
      );

      nightlyBuild = pkgs.writeShellApplication {
        name = "nightly-build";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.findutils
          pkgs.gawk
          pkgs.gh
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          # Build tooling for the ecos-studio recipe. These never leak into
          # the artifact: the AppImage embeds Electron's own runtime, and the
          # agent bundle is built with uv's managed Python. (ecos-studio
          # pins Node 23.11.0 in its .nvmrc; 23 is EOL, so the recipe uses
          # the closest supported LTS.)
          pkgs.nodejs_24
          pkgs.pnpm_11
          pkgs.uv
        ];
        text = ''
          # Single source of truth for the nightly tag shape (toolchain.toml
          # [nightly] tag_re); the installer gets the same value as its
          # NIGHTLY_TAG_RE placeholder, and common.sh refuses to run without
          # it. Must precede the readFile of common.sh.
          NIGHTLY_TAG_BODY_RE=${lib.escapeShellArg nightlyModel.tagRe}
          ${builtins.readFile ../../nightly/lib/common.sh}
          # The PDK manifest projected from toolchain.toml (single source of
          # truth for the package set and validation paths).
          NIGHTLY_PDK_MANIFEST=${pdkManifest}
          # The bundle manifest template; release.sh substitutes the
          # @NIGHTLY_*@ placeholders and ships it as ecos-manifest.toml.
          NIGHTLY_BUNDLE_MANIFEST_TEMPLATE=${bundleManifestTemplate}
          ${builtins.readFile ../../nightly/scripts/ecc.sh}
          ${builtins.readFile ../../nightly/scripts/ecc-sizer.sh}
          ${builtins.readFile ../../nightly/scripts/kepler-formal.sh}
          ${builtins.readFile ../../nightly/scripts/pdk.sh}
          ${builtins.readFile ../../nightly/scripts/ecos-studio.sh}
          ${builtins.readFile ../../nightly/scripts/release.sh}
          ${builtins.readFile ../../nightly/dispatch.sh}
        '';
      };
    in
    {
      apps.nightly-build = {
        type = "app";
        program = "${nightlyBuild}/bin/nightly-build";
      };

      # writeShellApplication shellchecks the concatenated app; this check
      # lints each source file in isolation so failures point at a file.
      checks.nightly-syntax =
        pkgs.runCommand "ecos-release-nightly-syntax-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.shellcheck
            ];
          }
          ''
            set -euo pipefail
            for f in ${../../nightly}/lib/*.sh ${../../nightly}/scripts/*.sh ${../../nightly}/dispatch.sh; do
              bash -n "$f"
              # The files are fragments concatenated into the app, so they have
              # no shebang; tell shellcheck the dialect explicitly.
              shellcheck -s bash "$f"
            done

            # Unit-test the bash SemVer comparison used to pick the nightly
            # base version (lib/semver.nix has its own nix-side tests).
            # common.sh requires the tag regex to be injected (single-sourced
            # from toolchain.toml).
            export NIGHTLY_TAG_BODY_RE=${lib.escapeShellArg nightlyModel.tagRe}
            source ${../../nightly}/lib/common.sh
            # The pipeline's default publish repo is the installer's [nightly]
            # repo: both name the same GitHub repository.
            test "$NIGHTLY_RELEASE_REPO" = ${lib.escapeShellArg nightlyModel.repo}
            t() { test "$(nightly_semver_compare "$1" "$2")" = "$3"; }
            t 0.1.0-alpha.12 0.1.0-alpha.13 -1
            t 0.1.0-alpha.9 0.1.0-alpha.10 -1
            t 0.1.0-alpha 0.1.0-alpha.1 -1
            t 0.1.0 0.1.0-alpha.13 1
            t 0.1.0-alpha.13 0.1.0 -1
            t 1.0.0 1.0.0 0
            t 1.0.0-alpha 1.0.0-alpha.1 -1
            t 1.0.0-alpha.1 1.0.0-alpha.beta -1
            t 1.0.0-alpha.beta 1.0.0-beta -1
            # Nightlies sort above their prerelease base and below a plain
            # core base's stable release.
            t 0.1.0-alpha.13-nightly.20261010.g3c23c6d 0.1.0-alpha.13 1
            t 0.5.1-nightly.20261010.g3c23c6d 0.5.1 -1
            t 0.1.0-alpha.13-nightly.20261010.g3c23c6d 0.1.0-alpha.13-nightly.20261010.g3c23c6d.2 -1
            # Numeric identifiers beyond int64 compare by length+lexical, not
            # arithmetic (2^64 is a legal SemVer numeric identifier).
            t 1.0.0-18446744073709551616 1.0.0-1 1
            t 1.0.0-1 1.0.0-18446744073709551616 -1
            # Arbitrary-precision increment, including carry and single
            # numeric prerelease identifiers.
            test "$(nightly_increment_decimal 9)" = 10
            test "$(nightly_increment_decimal 99)" = 100
            test "$(nightly_increment_decimal 18446744073709551615)" = 18446744073709551616
            # Tag ordering follows the tag's own SemVer, not API creation
            # order (backfills with NIGHTLY_DATE must not become "latest").
            sorted="$(
              printf '%s\n' \
                v0.1.0-nightly.20261010 \
                v0.1.0-nightly.20261011 \
                v0.1.0-nightly.20261010.2 | nightly_sort_tags_desc
            )"
            test "$sorted" = "$(printf '%s\n' v0.1.0-nightly.20261011 v0.1.0-nightly.20261010.2 v0.1.0-nightly.20261010)"

            # Wiring: every tool in NIGHTLY_TOOLS must have its recipe
            # function defined in nightly/scripts/ and reachable from the
            # dispatcher's all path (a missing call publishes a release
            # without that tool's assets and fails the publish stage).
            for tool in $NIGHTLY_TOOLS; do
              fn="nightly_recipe_$(printf '%s' "$tool" | tr '-' '_')"
              grep -q "^$fn() (" ${../../nightly}/scripts/*.sh
              grep -q "^  $fn\$" ${../../nightly}/dispatch.sh
            done
            # First-ever nightly on a tag-less repository: the base falls back
            # to 0.1.0 instead of dying silently (nightly_die's exit inside
            # $() defeats a trailing || true; the catch must be if/!).
            stubbin="$(mktemp -d)"
            # printf instead of a heredoc: nixfmt reindents the string,
            # which would move a heredoc terminator off column zero.
            printf '#!${pkgs.bash}/bin/bash\n# Emulates git ls-remote for a repository with no tags at all.\nif [ "$1" = "ls-remote" ]; then exit 0; fi\nexit 1\n' >"$stubbin/git"
            chmod +x "$stubbin/git"
            test "$(PATH="$stubbin:$PATH" NIGHTLY_DATE=20261011 NIGHTLY_RELEASE_REPO=x/y nightly_repo_tag)" = "v0.1.0-nightly.20261011"

            # A hard network failure still fails loudly, with the message.
            # (nightly_die's exit only aborts a $() subshell, so the negative
            # case must call through one for the if guard to see it.)
            printf '#!${pkgs.bash}/bin/bash\nexit 1\n' >"$stubbin/git"
            if got="$(PATH="$stubbin:$PATH" NIGHTLY_DATE=20261011 NIGHTLY_RELEASE_REPO=x/y nightly_repo_tag 2>&1)"; then
              echo "nightly_repo_tag survived a total ls-remote failure" >&2
              exit 1
            fi
            case "$got" in
            *"could not query tags"*) ;;
            *)
              echo "expected the query-failure message, got: $got" >&2
              exit 1
              ;;
            esac

            # Bundle assembly: every per-tool tarball lands in its
            # subdirectory with the top directory stripped (the PDK is
            # inside the bundle too), and the studio AppImage in studio/.
            tmpd="$(mktemp -d)"
            mkdir -p "$tmpd/assets" "$tmpd/src/eccroot" "$tmpd/src/sizer-top/bin" "$tmpd/src/kepler-top" "$tmpd/src/icsprout55-pdk-1.0.0/prtech"
            echo x >"$tmpd/src/eccroot/ecc"
            echo x >"$tmpd/src/sizer-top/bin/Sizer"
            echo x >"$tmpd/src/kepler-top/kepler-formal"
            echo x >"$tmpd/src/icsprout55-pdk-1.0.0/prtech/tech.lef"
            tar -czf "$tmpd/assets/ecc-cli-linux-x86_64.tar.gz" -C "$tmpd/src/eccroot" .
            tar -czf "$tmpd/assets/ecc-sizer-1.0.0-nightly.20261012.gabcdef0-linux-x64.tar.gz" -C "$tmpd/src" sizer-top
            tar -czf "$tmpd/assets/kepler-formal-0.5.0-nightly.20261012.gabcdef0-linux-x86_64.tar.gz" -C "$tmpd/src" kepler-top
            tar -czf "$tmpd/assets/icsprout55-pdk-1.0.0.tar.gz" -C "$tmpd/src" icsprout55-pdk-1.0.0
            echo x >"$tmpd/assets/ECOS-Studio_1.0.0-nightly.20261012.gabcdef0_x86_64.AppImage"
            nightly_assemble_bundle "$tmpd/assets" "$tmpd/out"
            test -f "$tmpd/out/ecc/ecc"
            test -f "$tmpd/out/ecc-sizer/bin/Sizer"
            test -f "$tmpd/out/kepler-formal/kepler-formal"
            test -f "$tmpd/out/pdk/prtech/tech.lef"
            test -x "$tmpd/out/studio/ECOS-Studio_1.0.0-nightly.20261012.gabcdef0_x86_64.AppImage"

            # Bundle manifest: fixture substitution fills every @NIGHTLY_*@
            # placeholder and the PDK lists come through from toolchain.toml.
            export NIGHTLY_BUNDLE_MANIFEST_TEMPLATE=${bundleManifestTemplate}
            declare -A tool_version=() tool_commit=()
            for tool in $NIGHTLY_TOOLS; do
              tool_version[$tool]="1.0.0-nightly.20261012.gabcdef0"
              tool_commit[$tool]="0123456789abcdef0123456789abcdef01234567"
            done
            nightly_write_bundle_manifest "$tmpd/out" "v0.1.0-nightly.20261012"
            m="$tmpd/out/ecos-manifest.toml"
            test -f "$m"
            grep -q '^tag = "v0.1.0-nightly.20261012"$' "$m"
            grep -q '^version = "1.0.0-nightly.20261012.gabcdef0"$' "$m"
            # `! grep` cannot fail the build: set -e exempts negated commands.
            if grep -q '@NIGHTLY_' "$m"; then
              echo "unsubstituted placeholder survived in $m" >&2
              exit 1
            fi
            grep -q '^cell_lefs = \[ "' "$m"
            # Unsafe values are rejected instead of breaking the TOML quoting.
            # nightly_die exits, so the negative cases run in a subshell.
            mkdir -p "$tmpd/out2"
            tool_commit[ecc]='bad"value'
            if ( nightly_write_bundle_manifest "$tmpd/out2" "v0.1.0-nightly.20261013" ) 2>/dev/null; then
              echo "nightly_write_bundle_manifest accepted a quote in a value" >&2
              exit 1
            fi
            tool_commit[ecc]='bad\value'
            if ( nightly_write_bundle_manifest "$tmpd/out2" "v0.1.0-nightly.20261013" ) 2>/dev/null; then
              echo "nightly_write_bundle_manifest accepted a backslash in a value" >&2
              exit 1
            fi
            echo ok > "$out"
          '';
    };
}
