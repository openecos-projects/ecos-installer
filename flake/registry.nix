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
      libs = import ../lib { inherit lib; };
      semver = libs.semver;
      loadModel = import ../nix/model.nix { inherit lib semver; };
      generateRegistry = import ../nix/generate-registry.nix { inherit lib; };

      checkRegistryUrls = pkgs.writeShellApplication {
        name = "check-registry-urls";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${../nix/registry-url-checker.py} "$@"
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
        registry-generate = import ../nix/tests/registry-generate.nix {
          inherit
            lib
            pkgs
            loadModel
            generateRegistry
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
              REGISTRY_URL_CHECKER=${../nix/registry-url-checker.py} \
                python3 ${../nix/tests/test-registry-url-checker.py}
              echo ok > "$out"
            '';
      };
    };
}
