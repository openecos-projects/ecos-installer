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

      # Haskell package set where nvfetcher is our patched library, for
      # linking the driver against it
      haskellPackages = pkgs.haskellPackages.override (old: {
        overrides = lib.composeExtensions (old.overrides or (_: _: { })) (
          hself: hsuper: {
            nvfetcher = nvfetcher.library;
          }
        );
      });

      ecosBump = haskellPackages.callCabal2nix "ecos-bump" ./hs/ecos-bump { };

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
            ${self}/nix/decide-cli.nix | tr -d '"\n '
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
        nvfetcher = nvfetcher.package;
        ecos-bump = bump;
      };

      apps.${system} = {
        update-ecc = {
          type = "app";
          program = "${updateEcc}/bin/update-ecc";
        };
        bump = {
          type = "app";
          program = "${bump}/bin/bump";
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
            publishDecide
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
        # The driver's offline check (rules schema + lock closure) must pass
        # on the repo files and fail on each mutated fixture
        toml-schema = pkgs.runCommand "ecos-release-toml-schema-check" { nativeBuildInputs = [ bump ]; } ''
          set -euo pipefail
          cd ${self}
          bump check

          work="$TMPDIR/work"
          mkdir -p "$work"
          expect_fail() {
            name="$1"; msg="$2"
            if bump check --rules "$work/case.toml" --locks ${self}/nix/_sources/generated.json >"$work/out" 2>&1; then
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
            cp ${self}/nix/toolchain.toml "$work/case.toml"
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

          echo ok > "$out"
        '';
        formatting = treefmtEval.config.build.check self;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          treefmtEval.config.build.wrapper
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
