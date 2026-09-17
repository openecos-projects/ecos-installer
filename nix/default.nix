# Every file in ./modules is a flake-parts module (imported automatically);
# drop a new <name>.nix there to add a module.
{
  imports = builtins.readDir ./modules |> builtins.attrNames |> map (name: ./modules/${name});
}
