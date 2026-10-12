{ lib, semver }:

let
  inherit (semver) parse compare;

  versionedKey = tag: "installers/ecc/${tag}/ecc-installer.sh";
  latestKey = "installers/ecc/latest/ecc-installer.sh";

  versionedHeaders = {
    Content-Type = "text/x-sh";
    Content-Disposition = "inline";
    Cache-Control = "public, max-age=31536000, immutable";
  };

  latestHeaders = {
    Content-Type = "text/x-sh";
    Content-Disposition = "inline";
    Cache-Control = "no-cache";
  };

  extractVersion =
    text:
    let
      lines = lib.splitString "\n" text;
      matches = builtins.filter (l: lib.hasPrefix "ECC_VERSION=\"" l) lines;
      line =
        if matches == [ ] then
          throw "installer is missing ECC_VERSION assignment"
        else
          builtins.head matches;
      m = builtins.match "ECC_VERSION=\"([^\"]+)\"" line;
    in
    if m == null then throw "installer is missing ECC_VERSION assignment" else builtins.head m;
  decide =
    {
      currentLatest ? null,
      candidate,
    }:
    let
      # Parse the candidate first so a malformed version is rejected even on
      # the no-current branch instead of sailing straight to advance. seq
      # forces the parse under Nix's laziness.
      incoming = parse (extractVersion candidate);
    in
    if currentLatest == null then
      builtins.seq incoming "advance"
    else
      let
        currentVersion =
          let
            v = extractVersion currentLatest;
          in
          parse v;
        cmp = compare incoming currentVersion;
      in
      if cmp < 0 then
        "keep"
      else if cmp == 0 && currentLatest == candidate then
        "keep"
      else if cmp == 0 then
        throw "latest installer bytes do not match this version"
      else
        "advance";
in
{
  inherit
    versionedKey
    latestKey
    versionedHeaders
    latestHeaders
    extractVersion
    decide
    ;
}
