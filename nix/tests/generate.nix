{
  lib,
  pkgs,
  semver,
  loadModel,
  generate,
  publish,
  template,
  toolchain,
  locks,
}:

let
  sources = {
    rules = toolchain;
    inherit locks;
  };
  model = loadModel sources;
  text = generate { inherit template model; };
  v10 = semver.parse "0.1.0-alpha.10";
  v11 = semver.parse "0.1.0-alpha.11";
  vRelease = semver.parse "0.1.0";

  inherit (import ../lib/testing.nix { inherit lib; })
    withRules
    withLocks
    withSection
    withLock
    withPkgs
    mapPkg
    ;

  tryModel = f: builtins.tryEval (loadModel (f sources));
  withPkg = id: f: withPkgs (mapPkg id f);

  badPlatform = tryModel (
    withRules (
      t:
      t
      // {
        platform = t.platform // {
          os = "darwin";
        };
      }
    )
  );
  badLiberty = tryModel (withSection "pdk" (p: p // { liberty_files = [ ]; }));
  badSizerName = tryModel (
    withLock "sizer" (
      l:
      l
      // {
        src = l.src // {
          name = "ecc-sizer-linux-x64.tar.gz";
        };
      }
    )
  );
  badSizerSha = tryModel (withLock "sizer" (l: l // { sha256_hex = "not-hex"; }));
  badSizerVersion = tryModel (withLock "sizer" (l: l // { version = "../evil"; }));
  badEccVersion = tryModel (withLock "ecc" (l: l // { version = "1..0"; }));
  straySizerCnbSha = tryModel (
    withLock "sizer" (
      l: l // { cnb_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; }
    )
  );
  nonBaseCnbSha = tryModel (
    withPkg "ics55_LLSC_H7CH_liberty" (pkg: pkg // { needs_cnb_sha256 = true; })
  );
  missingCnbSha = tryModel (withLock "icsprout55-base" (l: builtins.removeAttrs l [ "cnb_sha256" ]));

  older = builtins.replaceStrings [ model.ecc.version ] [ "0.1.0-alpha.10" ] text;
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
  ${lib.optionalString straySizerCnbSha.success "echo 'sizer cnb_sha256 without needs_cnb_sha256 should fail' >&2; exit 1"}
  ${lib.optionalString nonBaseCnbSha.success "echo 'needs_cnb_sha256 on a non-base pdk_pkg should fail' >&2; exit 1"}
  ${lib.optionalString missingCnbSha.success "echo 'base lock without cnb_sha256 should fail' >&2; exit 1"}
  ${lib.optionalString (!(lib.hasPrefix "#!/bin/sh\n" text)) "echo 'missing shebang' >&2; exit 1"}
  ${lib.optionalString (lib.hasInfix "@ECC_VERSION@" text) "echo 'unsubstituted placeholder' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix ''ECC_VERSION="${model.ecc.version}"'' text)
  ) "echo 'missing version' >&2; exit 1"}
  ${lib.optionalString (
    !(lib.hasInfix ''PDK_VERSION="${model.pdk.version}"'' text)
  ) "echo 'missing PDK version' >&2; exit 1"}
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
