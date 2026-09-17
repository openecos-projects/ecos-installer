# Bump domain: the patched nvfetcher packaging, the ecos-bump driver, the
# update-ecc bridge, and their checks.
{ ... }:

{
  perSystem =
    { pkgs, lib, ... }:
    let
      nvfetcher = import ../tools/nvfetcher.nix { inherit pkgs; };

      # Haskell package set where nvfetcher is our patched library, for
      # linking the driver against it
      haskellPackages = pkgs.haskellPackages.override (old: {
        overrides = lib.composeExtensions (old.overrides or (_: _: { })) (
          hself: hsuper: {
            nvfetcher = nvfetcher.library;
          }
        );
      });

      ecosBump = haskellPackages.callCabal2nix "ecos-bump" ../../hs/ecos-bump { };

      bump = pkgs.writeShellApplication {
        name = "bump";
        runtimeInputs = [
          pkgs.nvchecker
          pkgs.nix
          pkgs.nix-prefetch-git
          pkgs.git
        ];
        text = ''
          exec ${ecosBump}/bin/ecos-bump "$@"
        '';
      };

      lockEdit = pkgs.writeShellApplication {
        name = "lock-edit";
        runtimeInputs = [
          pkgs.jq
          pkgs.coreutils
        ];
        text = builtins.readFile ../scripts/lock-edit.sh;
      };

      updateEcc = pkgs.writeShellApplication {
        name = "update-ecc";
        runtimeInputs = [
          pkgs.nix
          pkgs.git
          pkgs.gnused
          pkgs.coreutils
        ];
        text = ''
          LOCK_EDIT="${lockEdit}/bin/lock-edit"
          ${builtins.readFile ../scripts/update-ecc.sh}
        '';
      };
    in
    {
      packages = {
        nvfetcher = nvfetcher.package;
        ecos-bump = bump;
      };

      apps = {
        bump = {
          type = "app";
          program = "${bump}/bin/bump";
        };
        update-ecc = {
          type = "app";
          program = "${updateEcc}/bin/update-ecc";
        };
        lock-edit = {
          type = "app";
          program = "${lockEdit}/bin/lock-edit";
        };
      };

      checks = {
        update-ecc-locks = import ../tests/update-ecc.nix {
          inherit pkgs;
          lockEdit = "${lockEdit}/bin/lock-edit";
        };
        # The driver's offline check (rules schema + lock closure) must pass
        # on the repo files and fail on each mutated fixture
        toml-schema = pkgs.runCommand "ecos-release-toml-schema-check" { nativeBuildInputs = [ bump ]; } ''
          set -euo pipefail
          cd ${../..}
          bump check

          work="$TMPDIR/work"
          mkdir -p "$work"
          expect_fail() {
            name="$1"; msg="$2"
            if bump check --rules "$work/case.toml" --locks ${../..}/nix/_sources/generated.json >"$work/out" 2>&1; then
              echo "case $name should have failed" >&2
              exit 1
            fi
            if ! grep -q "$msg" "$work/out"; then
              echo "case $name: expected message containing '$msg':" >&2
              cat "$work/out" >&2
              exit 1
            fi
          }
          mutate() {
            cp ${../..}/nix/toolchain.toml "$work/case.toml"
            chmod u+w "$work/case.toml"
            sed -i "$1" "$work/case.toml"
          }

          mutate '0,/^\[slang\]/s//[slang]\npost_install = []/'
          expect_fail unknown-field "unknown field(s)"
          mutate 's/^version_map = { strip_prefix = "v" }$/version_map = "bogus"/'
          expect_fail bad-version-map "expected identity, strip_dashes"
          mutate 's|slang-linux-x86_64.tar.gz|{bogus}/slang-linux-x86_64.tar.gz|'
          expect_fail unknown-placeholder "unknown placeholder(s)"
          mutate 's|src = { github = "MikePopoloski/slang" }|src = { github = "MikePopoloski/slang", manual = "11.0" }|'
          expect_fail two-src-families "exactly one of github, github_tag, git, manual"
          mutate '0,/^kind = "liberty"/s//kind = "liberty"\nneeds_cnb_sha256 = true/'
          expect_fail nonbase-cnb "needs_cnb_sha256 is only valid on the base package"
          mutate 's|github = "openecos-projects/ecc"|github = "noslash"|'
          expect_fail bad-src-owner "must look like owner/repo"

          # a synthetic fixture repo drives discovery via --repo-root
          fixture="$TMPDIR/fixture-repo"
          mkdir -p "$fixture/nix/_sources"
          cp ${../..}/nix/toolchain.toml "$fixture/nix/toolchain.toml"
          cp ${../..}/nix/_sources/generated.json "$fixture/nix/_sources/generated.json"
          bump check --repo-root "$fixture" | grep -q "rules and locks: OK"

          echo ok > "$out"
        '';
      };
    };
}
