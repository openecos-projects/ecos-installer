{ lib }:

# Parse and precedence follow SemVer 2.0.0.
# Structure adapted from https://gist.github.com/acuteaangle/4d2820d31bc76b8925e1f97b415a40b1
# (CC0-1.0 OR 0BSD OR MIT-0). Numeric identifier "0" is accepted; the gist
# regex `^[1-9]+[0-9]*$` rejected it.

let
  # builtins.match already matches the whole string; no ^/$.
  semverRegex = "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\\+([0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*))?";

  isNumericIdent = s: builtins.match "0|[1-9][0-9]*" s != null;

  parseIdentifiers =
    string:
    map (identifier: if isNumericIdent identifier then lib.toInt identifier else identifier) (
      lib.splitString "." string
    );

  parse =
    version:
    let
      matches = builtins.match semverRegex version;
    in
    if matches == null then
      throw "invalid SemVer 2.0.0 version: ${version}"
    else
      let
        prerelease = builtins.elemAt matches 4;
        build = builtins.elemAt matches 9;
      in
      {
        major = lib.toInt (builtins.elemAt matches 0);
        minor = lib.toInt (builtins.elemAt matches 1);
        patch = lib.toInt (builtins.elemAt matches 2);
        prerelease = if prerelease == null then [ ] else parseIdentifiers prerelease;
        build = if build == null then "" else build;
      };

  parseTag =
    tag:
    if lib.hasPrefix "v" tag then
      parse (lib.removePrefix "v" tag)
    else
      throw "ECC tag must be v<version>, got ${tag}";

  compareIdentifier =
    left: right:
    if builtins.typeOf left == builtins.typeOf right then
      lib.compare left right
    else if builtins.typeOf left == "int" then
      -1
    else
      1;

  comparePrerelease =
    left: right:
    if left == [ ] then
      if right == [ ] then 0 else 1
    else if right == [ ] then
      -1
    else
      lib.compareLists compareIdentifier left right;

  compare =
    left: right:
    if left.major != right.major then
      lib.compare left.major right.major
    else if left.minor != right.minor then
      lib.compare left.minor right.minor
    else if left.patch != right.patch then
      lib.compare left.patch right.patch
    else
      comparePrerelease left.prerelease right.prerelease;

  lessThan = a: b: compare a b < 0;
  equal = a: b: compare a b == 0;
in
{
  inherit
    parse
    parseTag
    compare
    lessThan
    equal
    ;
}
