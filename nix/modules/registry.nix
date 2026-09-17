# Registry domain: the tool-registry.json package, URL reachability, and
# the registry projection checks.
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
      libs = import ../../lib { inherit lib; };
      semver = libs.semver;
      loadModel = import ../model/model.nix { inherit lib semver; };

      checkRegistryUrls = pkgs.writeShellApplication {
        name = "check-registry-urls";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${../tools/registry-url-checker.py} "$@"
        '';
      };
    in
    {
      packages.tool-registry = ecos.toolRegistry;

      apps.check-registry-urls = {
        type = "app";
        program = "${checkRegistryUrls}/bin/check-registry-urls";
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
