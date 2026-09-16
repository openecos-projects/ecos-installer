{
  pkgs,
  lib,
  publish,
  generate,
  loadModel,
  template,
  toolchain,
  locks,
}:

let
  model = loadModel {
    rules = toolchain;
    inherit locks;
  };
  text = generate { inherit template model; };
  older = builtins.replaceStrings [ "0.1.0-alpha.11" ] [ "0.1.0-alpha.10" ] text;
  sameVerDiff = builtins.replaceStrings [ "MIN_GLIBC_MAJOR=\"2\"" ] [ "MIN_GLIBC_MAJOR=\"9\"" ] text;
  malformed = "not an installer\n";
  rejectDiff = builtins.tryEval (
    publish.decide {
      currentLatest = text;
      candidate = sameVerDiff;
    }
  );
  rejectMalformed = builtins.tryEval (
    publish.decide {
      currentLatest = malformed;
      candidate = text;
    }
  );
in
assert
  publish.decide {
    currentLatest = null;
    candidate = text;
  } == "advance";
assert
  publish.decide {
    currentLatest = text;
    candidate = older;
  } == "keep";
assert
  publish.decide {
    currentLatest = text;
    candidate = text;
  } == "keep";
assert !rejectDiff.success;
assert !rejectMalformed.success;
assert publish.versionedKey "v0.1.0-alpha.11" == "installers/ecc/v0.1.0-alpha.11/ecc-installer.sh";
assert publish.latestKey == "installers/ecc/latest/ecc-installer.sh";
pkgs.runCommand "ecos-release-publish-check" { } ''
  echo ok > "$out"
''
