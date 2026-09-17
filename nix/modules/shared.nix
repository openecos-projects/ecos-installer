# Shared computed layer: the single-source-of-truth values every domain
# module consumes (rules/locks merged model, rendered installer text,
# registry attrset, and the two published artifacts).
#
# Everything is an option so domain modules compose through config.ecos.*
# instead of sharing a flake-wide let.
{ flake-parts-lib, lib, ... }:

let
  inherit (flake-parts-lib) mkPerSystemOption;
in
{
  options.perSystem = mkPerSystemOption {
    _file = ./shared.nix;
    options.ecos = {
      templatePath = lib.mkOption { type = lib.types.path; };
      template = lib.mkOption { type = lib.types.str; };
      toolchain = lib.mkOption { type = lib.types.raw; };
      locks = lib.mkOption { type = lib.types.raw; };
      model = lib.mkOption { type = lib.types.raw; };
      generated = lib.mkOption { type = lib.types.str; };
      registry = lib.mkOption { type = lib.types.raw; };
      eccInstaller = lib.mkOption { type = lib.types.package; };
      toolRegistry = lib.mkOption { type = lib.types.package; };
    };
  };

  config.perSystem =
    { pkgs, lib, ... }:
    let
      libs = import ../../lib { inherit lib; };
      semver = libs.semver;
      loadModel = import ../model/model.nix { inherit lib semver; };
      renderInstaller = import ../release/installer.nix { inherit lib; };
      renderRegistry = import ../release/registry.nix { inherit lib; };

      templatePath = ../../templates/ecc-installer.sh.in;
      toolchain = builtins.fromTOML (builtins.readFile ../toolchain.toml);
      locks = builtins.fromJSON (builtins.readFile ../_sources/generated.json);
      model = loadModel {
        rules = toolchain;
        inherit locks;
      };
      generated = renderInstaller {
        template = builtins.readFile templatePath;
        inherit model;
      };
      registry = renderRegistry { inherit model; };
    in
    {
      ecos = {
        inherit
          templatePath
          toolchain
          locks
          model
          generated
          registry
          ;
        template = builtins.readFile templatePath;
        eccInstaller = pkgs.writeTextFile {
          name = "ecc-installer.sh";
          executable = true;
          text = generated;
          checkPhase = ''
            ${pkgs.dash}/bin/dash -n "$target"
            ${pkgs.bash}/bin/bash -n "$target"
          '';
        };
        toolRegistry = pkgs.writeText "tool-registry.json" (builtins.toJSON registry);
      };
    };
}
