# Patched nvfetcher packaging: pinned upstream + the lock-fields patch.
#
# Upstream pin: berberman/nvfetcher master (includes #147, the prerelease
# option for the github version source). nix/patches/nvfetcher-lock-fields.patch
# makes generated.json natively carry the `size`/`sha256_hex`/`cnb_sha256`
# lock fields and adds the `fetchCnb` DSL combinator; see
# nix/patches/nvfetcher-lock-fields.md for the full documentation of the patch.
#
# When bumping `rev`, update `hash` and check the patch still applies
# (otherwise this build fails at the patch step).

{ pkgs }:

let
  inherit (pkgs) lib;

  rev = "e41af9779ea14adf1d8c3edb075713c2668d45b9";

  src = pkgs.fetchFromGitHub {
    owner = "berberman";
    repo = "nvfetcher";
    inherit rev;
    hash = "sha256-Bj1ZaZVKTGyTOwwkp7TvAG0wxK9AAn717G/C8HnKFQM=";
  };

  patchedSrc = pkgs.applyPatches {
    name = "nvfetcher-${rev}-patched";
    inherit src;
    patches = [ ./patches/nvfetcher-lock-fields.patch ];
    # new test files are kept as plain files next to the patch for
    # readability (nix/patches/nvfetcher/ mirrors the source tree layout)
    postPatch = ''
      cp ${./patches/nvfetcher/test/SriSpec.hs} test/SriSpec.hs
      cp ${./patches/nvfetcher/test/PackageResultSpec.hs} test/PackageResultSpec.hs
    '';
  };
in
pkgs.haskell.lib.overrideCabal (pkgs.haskellPackages.callCabal2nix "nvfetcher" patchedSrc { })
  (drv: {
    # build the test suite (it also validates the added test files) but don't
    # run it: the tests need network access
    checkPhase = "";
    buildTools = (drv.buildTools or [ ]) ++ [ pkgs.makeWrapper ];
    # Runtime tools the CLI shells out to, mirroring upstream's wrapper.
    # `nix` itself (nix hash, nix-prefetch-url, nix-build) is expected to be
    # present on the system, like upstream assumes.
    postInstall = (drv.postInstall or "") + ''
      wrapProgram $out/bin/nvfetcher \
        --prefix PATH ":" ${
          lib.makeBinPath [
            pkgs.nvchecker
            pkgs.nix-prefetch-git
            pkgs.nix-prefetch-docker
            pkgs.python313Packages.awesomeversion
            pkgs.git
          ]
        }
    '';
  })
