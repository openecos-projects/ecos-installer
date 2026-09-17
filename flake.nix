{
  description = "ECC installer generator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

      semver = (import ./lib { inherit lib; }).semver;
      loadModel = import ./nix/model.nix { inherit lib semver; };
      generate = import ./nix/generate.nix { inherit lib; };
      generateRegistry = import ./nix/generate-registry.nix { inherit lib; };
      publish = import ./nix/publish.nix { inherit lib semver; };
      nvfetcher = import ./nix/nvfetcher.nix { inherit pkgs; };

      templatePath = ./templates/ecc-installer.sh.in;
      template = builtins.readFile templatePath;
      toolchain = builtins.fromTOML (builtins.readFile ./nix/toolchain.toml);
      locks = builtins.fromJSON (builtins.readFile ./nix/_sources/generated.json);
      model = loadModel {
        rules = toolchain;
        inherit locks;
      };
      generated = generate { inherit template model; };
      registry = generateRegistry { inherit model; };

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
            ${./nix/decide-cli.nix} | tr -d '"\n '
        '';
      };

      lockEdit = pkgs.writeShellApplication {
        name = "lock-edit";
        runtimeInputs = [
          pkgs.jq
          pkgs.coreutils
        ];
        text = builtins.readFile ./nix/scripts/lock-edit.sh;
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
          ${builtins.readFile ./nix/scripts/update-ecc.sh}
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
          export ECC_INSTALLER=${lib.escapeShellArg (toString eccInstaller)}
          export PUBLISH_DECIDE=${lib.escapeShellArg "${publishDecide}/bin/publish-decide"}
          ${builtins.readFile ./nix/scripts/publish-oss.sh}
        '';
      };

      checkRegistryUrls = pkgs.writeShellApplication {
        name = "check-registry-urls";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${./nix/registry-url-checker.py} "$@"
        '';
      };

      installerChecks = import ./nix/tests/installer.nix {
        inherit pkgs;
        installer = eccInstaller;
        template = templatePath;
      };
    in
    {
      formatter.${system} = treefmtEval.config.build.wrapper;

      packages.${system} = {
        ecc-installer = eccInstaller;
        default = eccInstaller;
        tool-registry = toolRegistry;
        nvfetcher = nvfetcher;
      };

      apps.${system} = {
        update-ecc = {
          type = "app";
          program = "${updateEcc}/bin/update-ecc";
        };
        lock-edit = {
          type = "app";
          program = "${lockEdit}/bin/lock-edit";
        };
        publish-oss = {
          type = "app";
          program = "${publishOss}/bin/publish-oss";
        };
        check-registry-urls = {
          type = "app";
          program = "${checkRegistryUrls}/bin/check-registry-urls";
        };
      };

      checks.${system} = {
        generate = import ./nix/tests/generate.nix {
          inherit
            lib
            pkgs
            semver
            loadModel
            generate
            publish
            template
            toolchain
            locks
            ;
        };
        semver = import ./nix/tests/semver.nix { inherit pkgs semver; };
        archive = import ./nix/tests/archive.nix { inherit pkgs; };
        publish = import ./nix/tests/publish.nix {
          inherit
            pkgs
            lib
            publish
            generate
            loadModel
            template
            toolchain
            locks
            ;
        };
        installer-syntax = installerChecks.syntax;
        installer-e2e = installerChecks.e2e;
        update-ecc-locks = import ./nix/tests/update-ecc.nix {
          inherit pkgs;
          lockEdit = "${lockEdit}/bin/lock-edit";
        };
        registry-url-tests =
          pkgs.runCommand "ecos-release-registry-url-tests"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              REGISTRY_URL_CHECKER=${./nix/registry-url-checker.py} \
                python3 ${./nix/tests/test-registry-url-checker.py}
              echo ok > "$out"
            '';
        registry-generate = import ./nix/tests/registry-generate.nix {
          inherit
            lib
            pkgs
            loadModel
            generateRegistry
            registry
            toolchain
            locks
            ;
          registryJson = toolRegistry;
        };
        formatting = treefmtEval.config.build.check self;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          treefmtEval.config.build.wrapper
          pkgs.dash
          pkgs.shellcheck
          pkgs.python3
          pkgs.curl
        ];
      };
    };
}
