{
  pkgsPath,
  currentFile ? "",
  candidateFile,
}:

let
  lib = import (pkgsPath + "/lib");
  # our SemVer helpers and the publish policy live in the repo library
  libs = import ../../lib { inherit lib; };
  publish = libs.publish;
  current = if currentFile == "" then null else builtins.readFile (/. + currentFile);
  candidate = builtins.readFile (/. + candidateFile);
in
publish.decide {
  currentLatest = current;
  inherit candidate;
}
