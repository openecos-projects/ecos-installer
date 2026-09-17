{
  pkgs,
  lib,
  publish,
  generate,
  loadModel,
  template,
  toolchain,
  locks,
  publishDecide,
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
  set -euo pipefail
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  # nix-instantiate wants a writable state dir; the sandbox's /nix/var is
  # read-only.
  export NIX_STATE_DIR="$work/nixstate"
  mkdir -p "$NIX_STATE_DIR"
  # The publish-decide CLI evaluates nix/decide-cli.nix at run time; this
  # covers its import graph (lib/semver.nix, nix/publish.nix), which the
  # pure-eval tests above cannot reach.
  printf 'ECC_VERSION="0.1.0-alpha.11"\n' >"$work/cur.sh"
  printf 'ECC_VERSION="0.1.0-alpha.12"\n' >"$work/cand.sh"
  test "$(${publishDecide}/bin/publish-decide "$work/cur.sh" "$work/cand.sh")" = "advance"
  test "$(${publishDecide}/bin/publish-decide "$work/cand.sh" "$work/cur.sh")" = "keep"
  test "$(${publishDecide}/bin/publish-decide "" "$work/cand.sh")" = "advance"
  echo ok > "$out"
''
