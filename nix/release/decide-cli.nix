{
  pkgsPath,
  currentFile ? "",
  candidateFile,
}:

let
  lib = import (pkgsPath + "/lib");
  # our SemVer helpers live in the repo library (lib/), not in nixpkgs lib
  semver = (import ../../lib { inherit lib; }).semver;
  publish = import ./publish.nix { inherit lib semver; };
  current = if currentFile == "" then null else builtins.readFile (/. + currentFile);
  candidate = builtins.readFile (/. + candidateFile);
in
publish.decide {
  currentLatest = current;
  inherit candidate;
}
