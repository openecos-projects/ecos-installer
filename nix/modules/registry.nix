# Registry domain: the tool-registry.json package, URL reachability, and
# the registry projection checks.
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

      checkRegistryUrls = pkgs.writeShellApplication {
        name = "check-registry-urls";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${../tools/registry-url-checker.py} "$@"
        '';
      };

      publishRegistryOss = pkgs.writeShellApplication {
        name = "publish-registry-oss";
        runtimeInputs = [
          pkgs.curl
          pkgs.openssl
          pkgs.coreutils
          pkgs.diffutils
          pkgs.gnused
        ];
        text = ''
          export TOOL_REGISTRY=${lib.escapeShellArg (toString ecos.toolRegistry)}
          ${builtins.readFile ../scripts/oss-lib.sh}
          ${builtins.readFile ../scripts/publish-registry-oss.sh}
        '';
      };
    in
    {
      packages.tool-registry = ecos.toolRegistry;

      apps = {
        check-registry-urls = {
          type = "app";
          program = "${checkRegistryUrls}/bin/check-registry-urls";
        };
        publish-registry-oss = {
          type = "app";
          program = "${publishRegistryOss}/bin/publish-registry-oss";
        };
      };

      checks = {
        registry-render = import ../tests/registry-render.nix {
          inherit
            lib
            pkgs
            loadModel
            ;
          inherit (ecos) toolchain locks;
          registry = ecos.registry;
          registryJson = ecos.toolRegistry;
        };
        registry-url-tests =
          pkgs.runCommand "ecos-release-registry-url-tests"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              REGISTRY_URL_CHECKER=${../tools/registry-url-checker.py} \
                python3 ${../tests/test-registry-url-checker.py}
              echo ok > "$out"
            '';
      };
    };
}
