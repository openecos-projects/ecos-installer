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
    { pkgs, ... }:
    let
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
          ${builtins.readFile ../../nightly/scripts/ecc.sh}
          ${builtins.readFile ../../nightly/scripts/ecc-sizer.sh}
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
            echo ok > "$out"
          '';
    };
}
