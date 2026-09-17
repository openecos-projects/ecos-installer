{ lib }:

# Render the installer by substituting the @NAME@ placeholders declared in
# ./placeholders.toml (the single source for the token -> model-field
# mapping; adding a placeholder is a template edit plus one TOML line, no
# other Nix change).

{
  template,
  model,
}:

let
  declared = builtins.fromTOML (builtins.readFile ./placeholders.toml);

  assetRow =
    a:
    lib.concatStringsSep "\t" [
      a.name
      a.sha256
      a.url
      (if a.cnbUrl == "" then "-" else a.cnbUrl)
      a.dest
    ];

  formats = {
    raw = v: v;
    int = toString;
    lines = lib.concatStringsSep "\n";
    assetTable = assets: lib.concatMapStringsSep "\n" assetRow assets;
  };

  renderValue =
    name: spec:
    let
      format = spec.format or "raw";
    in
    if builtins.hasAttr format formats then
      formats.${format} (lib.getAttrFromPath (lib.splitString "." spec.path) model)
    else
      throw "unknown format for placeholder ${name}: ${format}";

  mapping = lib.mapAttrs' (
    name: spec: lib.nameValuePair "@${name}@" (renderValue name spec)
  ) declared;

  from = builtins.attrNames mapping;
  to = builtins.attrValues mapping;
  rendered = builtins.replaceStrings from to template;
  leftover = builtins.filter (k: lib.hasInfix k rendered) from;
  leftoverAny = builtins.any (line: builtins.match ".*@[A-Z][A-Z0-9_]*@.*" line != null) (
    lib.splitString "\n" rendered
  );
  unix = builtins.replaceStrings [ "\r\n" ] [ "\n" ] rendered;
  final = if lib.hasSuffix "\n" unix then unix else unix + "\n";
in
if leftover != [ ] then
  throw "unsubstituted installer placeholders: ${lib.concatStringsSep ", " leftover}"
else if leftoverAny then
  throw "unsubstituted installer placeholder remains"
else
  final
