# Every .nix file under ./modules (recursively) is a flake-parts module;
# drop a new file there to add one. Data files (e.g. core/placeholders.toml)
# are excluded by the suffix filter.
{ lib, ... }:

let
  walk =
    dir:
    lib.concatMap (
      name:
      let
        path = dir + "/${name}";
      in
      if lib.hasSuffix ".nix" name then
        [ path ]
      else if (builtins.readDir dir).${name} == "directory" then
        walk path
      else
        [ ]
    ) (builtins.attrNames (builtins.readDir dir));
in
{
  imports = walk ./modules;
}
