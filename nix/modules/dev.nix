# Development environment and formatting (treefmt via its flake module).
{ ... }:

{
  perSystem =
    { config, pkgs, ... }:
    {
      treefmt = {
        projectRootFile = "flake.nix";

        programs.nixfmt.enable = true;
        programs.ruff-format = {
          enable = true;
          lineLength = 100;
        };
        programs.taplo.enable = true;
        programs.yamlfmt.enable = true;
        programs.shfmt.enable = true;
        programs.ormolu.enable = true;

        # POSIX installer template uses @PLACEHOLDER@ tokens; leave it alone.
        settings.formatter.shfmt.excludes = [ "templates/*" ];
      };

      devShells.default = pkgs.mkShell {
        packages = [
          config.treefmt.build.wrapper
          pkgs.dash
          pkgs.shellcheck
          pkgs.python3
          pkgs.curl
          # for working on the hs/ecos-bump driver (not needed to run bump)
          pkgs.haskellPackages.ghc
          pkgs.cabal-install
        ];
      };
    };
}
