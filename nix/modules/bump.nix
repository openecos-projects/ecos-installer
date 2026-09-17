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
        lock-edit = import ../tests/lock-edit.nix {
          inherit pkgs;
          lockEdit = "${lockEdit}/bin/lock-edit";
        };
        # The driver's offline check (rules schema + lock closure) must pass
        # on the repo files and fail on each mutated fixture; the cases live
        # in the script so they are greppable outside a nix string.
        toml-schema = pkgs.runCommand "ecos-release-toml-schema-check" { nativeBuildInputs = [ bump ]; } ''
          bash ${../tests/toml-schema.sh} ${../..}
          echo ok > "$out"
        '';
      };
    };
}
