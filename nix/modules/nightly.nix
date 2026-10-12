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
          ${builtins.readFile ../../nightly/lib/common.sh}
          # The PDK manifest projected from toolchain.toml (single source of
          # truth for the package set and validation paths).
          NIGHTLY_PDK_MANIFEST=${pdkManifest}
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
            source ${../../nightly}/lib/common.sh
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
            # inside the bundle too).
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
            nightly_assemble_bundle "$tmpd/assets" "$tmpd/out"
            test -f "$tmpd/out/ecc/ecc"
            test -f "$tmpd/out/ecc-sizer/bin/Sizer"
            test -f "$tmpd/out/kepler-formal/kepler-formal"
            test -f "$tmpd/out/pdk/prtech/tech.lef"
            echo ok > "$out"
          '';
    };
}
