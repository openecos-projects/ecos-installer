# Installer domain: the ecc-installer package and OSS publishing, plus the
# installer/semver/archive/publish checks.
{ ... }:

{
  perSystem =
    {
      config,
      pkgs,
      lib,
      libs,
      ...
    }:
    let
      ecos = config.ecos;
      semver = libs.semver;
      loadModel = import ../model/model.nix { inherit lib semver; };
      publish = libs.publish;

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
            ${../..}/nix/tools/decide-cli.nix | tr -d '"\n '
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
          ${builtins.readFile ../scripts/oss-lib.sh}
          ${builtins.readFile ../scripts/publish-oss.sh}
        '';
      };

      installerChecks = import ../tests/installer.nix {
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
        installer-render = import ../tests/installer-render.nix {
          inherit
            lib
            pkgs
            semver
            loadModel
            publish
            ;
          inherit (ecos) toolchain locks;
          text = ecos.generated;
        };
        semver = import ../tests/semver.nix { inherit pkgs semver; };
        archive = import ../tests/archive.nix { inherit pkgs; };
        publish = import ../tests/publish.nix {
          inherit
            pkgs
            lib
            publish
            loadModel
            publishDecide
            ;
          inherit (ecos) toolchain locks;
          text = ecos.generated;
        };
        installer-syntax = installerChecks.syntax;
        installer-e2e = installerChecks.e2e;
      };
    };
}
