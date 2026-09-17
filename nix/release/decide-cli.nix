{
  pkgsPath,
  currentFile ? "",
  candidateFile,
}:

let
  lib = import (pkgsPath + "/lib");
  semver = import ../../lib/semver.nix { inherit lib; };
  publish = import ./publish.nix { inherit lib semver; };
  current = if currentFile == "" then null else builtins.readFile (/. + currentFile);
  candidate = builtins.readFile (/. + candidateFile);
in
publish.decide {
  currentLatest = current;
  inherit candidate;
}
