# Installer domain: the ecc-installer package and OSS publishing, plus the
# installer/semver/archive/publish checks.
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
      ecos = config.ecos;
      libs = import ../lib { inherit lib; };
      semver = libs.semver;
      loadModel = import ../nix/model.nix { inherit lib semver; };
      generate = import ../nix/generate.nix { inherit lib; };
      publish = import ../nix/publish.nix { inherit lib semver; };

      publishDecide = pkgs.writeShellApplication {
        name = "publish-decide";
        runtimeInputs = [ pkgs.nix ];
        text = ''
          current="''${1:-}"
          candidate="''${2:?candidate installer required}"
          ${pkgs.nix}/bin/nix-instantiate --eval --strict \
            --arg pkgsPath ${pkgs.path} \
            --argstr currentFile "$current" \
            --argstr candidateFile "$candidate" \
            ${../.}/nix/decide-cli.nix | tr -d '"\n '
        '';
      };

      publishOss = pkgs.writeShellApplication {
        name = "publish-oss";
        runtimeInputs = [
          pkgs.curl
          pkgs.openssl
          pkgs.coreutils
          pkgs.gnused
          pkgs.nix
        ];
        text = ''
          export ECC_INSTALLER=${lib.escapeShellArg (toString ecos.eccInstaller)}
          export PUBLISH_DECIDE=${lib.escapeShellArg "${publishDecide}/bin/publish-decide"}
          ${builtins.readFile ../nix/scripts/publish-oss.sh}
        '';
      };

      installerChecks = import ../nix/tests/installer.nix {
        inherit pkgs;
        installer = ecos.eccInstaller;
        template = ecos.templatePath;
      };
    in
    {
      packages = {
        ecc-installer = ecos.eccInstaller;
        default = ecos.eccInstaller;
      };

      apps.publish-oss = {
        type = "app";
        program = "${publishOss}/bin/publish-oss";
      };

      checks = {
        generate = import ../nix/tests/generate.nix {
          inherit
            lib
            pkgs
            semver
            loadModel
            generate
            publish
            ;
          inherit (ecos) template toolchain locks;
        };
        semver = import ../nix/tests/semver.nix { inherit pkgs semver; };
        archive = import ../nix/tests/archive.nix { inherit pkgs; };
        publish = import ../nix/tests/publish.nix {
          inherit
            pkgs
            lib
            publish
            generate
            loadModel
            publishDecide
            ;
          inherit (ecos) template toolchain locks;
        };
        installer-syntax = installerChecks.syntax;
        installer-e2e = installerChecks.e2e;
      };
    };
}
