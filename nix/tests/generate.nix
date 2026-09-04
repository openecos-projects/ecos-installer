{
  lib,
  pkgs,
  semver,
  loadModel,
  generate,
  publish,
  template,
  toolchain,
}:

let
  model = loadModel toolchain;
  text = generate { inherit template model; };
  v10 = semver.parse "0.1.0-alpha.10";
  v11 = semver.parse "0.1.0-alpha.11";
  vRelease = semver.parse "0.1.0";

  badPlatform = builtins.tryEval (
    loadModel (
      toolchain
      // {
        platform = toolchain.platform // {
          os = "darwin";
        };
      }
    )
  );
  badLiberty = builtins.tryEval (
    loadModel (
      toolchain
      // {
        pdk = toolchain.pdk // {
          liberty_files = [ ];
        };
      }
    )
  );
  badSizerName = builtins.tryEval (
    loadModel (
      toolchain
      // {
        sizer = toolchain.sizer // {
          asset_name = "ecc-sizer-linux-x64.tar.gz";
        };
      }
    )
  );
  badSizerSha = builtins.tryEval (generate {
    inherit template;
    model = loadModel (
      toolchain
      // {
        sizer = toolchain.sizer // {
          sha256 = "not-hex";
        };
      }
    );
  });
  badSizerVersion = builtins.tryEval (
    loadModel (
      toolchain
      // {
        sizer = toolchain.sizer // {
          version = "../evil";
          asset_name = "ecc-sizer-../evil-linux-x64.tar.gz";
        };
      }
    )
  );
  badEccVersion = builtins.tryEval (
    loadModel (
      toolchain
      // {
        ecc = toolchain.ecc // {
          version = "1..0";
        };
      }
    )
  );
  badSizerCnbSha = builtins.tryEval (
    loadModel (
      toolchain
      // {
        sizer = toolchain.sizer // {
          cnb_sha256 = "not-hex";
        };
      }
    )
  );
  orphanSizerCnbSha = builtins.tryEval (
    loadModel (
      toolchain
      // {
        sizer = toolchain.sizer // {
          cnb_url = "";
          cnb_sha256 = toolchain.sizer.sha256;
        };
      }
    )
  );

  older = builtins.replaceStrings [ "0.1.0-alpha.11" ] [ "0.1.0-alpha.10" ] text;
  malformed = "not an installer\n";
  sameVerDiff = builtins.replaceStrings [ "MIN_GLIBC_MAJOR=\"2\"" ] [ "MIN_GLIBC_MAJOR=\"9\"" ] text;
  rejectDiff = builtins.tryEval (
    publish.decide {
      currentLatest = text;
      candidate = sameVerDiff;
    }
  );
in
pkgs.runCommand "ecos-release-generate-check" { } ''
  set -euo pipefail
  ${lib.optionalString (semver.compare v10 v11 >= 0) "echo 'semver alpha.10 !< alpha.11' >&2; exit 1"}
  ${lib.optionalString (
    semver.compare v11 vRelease >= 0
  ) "echo 'semver prerelease !< release' >&2; exit 1"}
  ${lib.optionalString badPlatform.success "echo 'darwin platform should fail' >&2; exit 1"}
  ${lib.optionalString badLiberty.success "echo 'empty liberty_files should fail' >&2; exit 1"}
  ${lib.optionalString badSizerName.success "echo 'sizer asset name mismatch should fail' >&2; exit 1"}
  ${lib.optionalString badSizerSha.success "echo 'bad sizer sha256 should fail' >&2; exit 1"}
  ${lib.optionalString badSizerVersion.success "echo 'non-SemVer sizer version should fail' >&2; exit 1"}
  ${lib.optionalString badEccVersion.success "echo 'non-SemVer ecc version should fail' >&2; exit 1"}
  ${lib.optionalString badSizerCnbSha.success "echo 'bad sizer cnb sha256 should fail' >&2; exit 1"}
  ${lib.optionalString orphanSizerCnbSha.success "echo 'sizer cnb_sha256 without cnb_url should fail' >&2; exit 1"}
  ${lib.optionalString (!(lib.hasPrefix "#!/bin/sh\n" text)) "echo 'missing shebang' >&2; exit 1"}
  ${lib.optionalString (lib.hasInfix "@ECC_VERSION@" text) "echo 'unsubstituted placeholder' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix ''ECC_VERSION="0.1.0-alpha.11"'' text)
  ) "echo 'missing version' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix model.ecc.cnbUrl text)
  ) "echo 'missing ECC cnb_url' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix model.ossCadSuite.cnbUrl text)
  ) "echo 'missing OSS cnb_url' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix ''SIZER_VERSION="0.1.0-alpha"'' text)
  ) "echo 'missing sizer version' >&2; exit 1"}
  ${lib.optionalString (!(lib.hasInfix model.sizer.url text)) "echo 'missing sizer url' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix model.sizer.cnbUrl text)
  ) "echo 'missing sizer cnb_url' >&2; exit 1"}
  ${lib.optionalString (
    (publish.decide {
      currentLatest = null;
      candidate = text;
    }) != "advance"
  ) "echo 'null latest should advance' >&2; exit 1"}
  ${lib.optionalString (
    (publish.decide {
      currentLatest = text;
      candidate = older;
    }) != "keep"
  ) "echo 'older should keep latest' >&2; exit 1"}
  ${lib.optionalString (
    (publish.decide {
      currentLatest = text;
      candidate = text;
    }) != "keep"
  ) "echo 'identical should keep' >&2; exit 1"}
  ${lib.optionalString rejectDiff.success "echo 'different bytes at same version should reject' >&2; exit 1"}
  ${lib.optionalString
    (builtins.tryEval (
      publish.decide {
        currentLatest = malformed;
        candidate = text;
      }
    )).success
    "echo 'malformed latest should reject' >&2; exit 1"
  }
  echo ok > "$out"
''
