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
    if currentLatest == null then
      "advance"
    else
      let
        currentVersion =
          let
            v = extractVersion currentLatest;
          in
          parse v;
        incoming = parse (extractVersion candidate);
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
