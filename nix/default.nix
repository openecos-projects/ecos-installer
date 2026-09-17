# Every .nix file in ./modules is a flake-parts module (imported
# automatically); drop a new <name>.nix there to add a module. Non-module
# files (like placeholders.toml) are excluded by the suffix filter.
{ lib, ... }:

{
  imports =
    builtins.readDir ./modules
    |> builtins.attrNames
    |> builtins.filter (lib.hasSuffix ".nix")
    |> map (name: ./modules/${name});
}
