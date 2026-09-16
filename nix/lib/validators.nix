{ lib }:

# Generic validation helpers for the release manifest. Each require* either
# returns its input or throws a labelled error; they run at eval time so a
# malformed manifest fails before reaching a projection.

let
  inherit (import ./rules-locks.nix { inherit lib; }) hexSha;

  throwUn = msg: throw "invalid release model: ${msg}";
in
rec {
  inherit hexSha;

  categories = [
    "backend"
    "frontend"
    "synthesis"
    "simulation"
    "toolchain"
    "viewer"
    "pdk"
    "mpc"
  ];

  platformKeys = [
    "linux-x86_64"
    "all-platform"
  ];

  archiveSuffixes = [
    ".tar"
    ".tar.gz"
    ".tar.bz2"
    ".tar.xz"
    ".tgz"
    ".txz"
    ".zip"
  ];

  baseArchiveSuffixes = [
    ".tar"
    ".tar.gz"
    ".tgz"
    ".zip"
  ];

  hasControl = s: builtins.match ".*[[:cntrl:]].*" s != null;

  requireRelative =
    label: path:
    if path == "" || lib.hasPrefix "/" path || lib.hasPrefix "\\" path then
      throwUn "absolute or empty ${label} path: ${path}"
    else if builtins.any (p: p == "" || p == "." || p == "..") (lib.splitString "/" path) then
      throwUn "unsafe ${label} path: ${path}"
    else
      path;

  requireHex = label: s: if hexSha s then s else throwUn "invalid SHA-256 for ${label}: ${s}";

  requireCnb =
    label: url: if url == null || url == "" then throwUn "missing cnb_url on ${label}" else url;

  requireInt = label: v: if builtins.isInt v then v else throwUn "${label} must be an integer";

  requireSize =
    label: v:
    if !builtins.isInt v || v <= 0 then throwUn "${label} size must be a positive integer" else v;

  requireId =
    label: v:
    if builtins.isString v && builtins.match "[a-z0-9_-]+" v != null then
      v
    else
      throwUn "${label} must be a lowercase identifier matching ^[a-z0-9_-]+$: ${toString v}";

  requireCategory =
    label: v:
    if builtins.elem v categories then
      v
    else
      throwUn "${label} must be one of ${lib.concatStringsSep "|" categories}: ${toString v}";

  requirePlatformKey =
    label: v:
    if builtins.elem v platformKeys then
      v
    else
      throwUn "${label} must be one of ${lib.concatStringsSep "|" platformKeys}: ${toString v}";

  requireHttpsUrl =
    label: v:
    if builtins.isString v && lib.hasPrefix "https://" v && v != "https://" && !hasControl v then
      v
    else
      throwUn "${label} must be an https URL without control characters: ${toString v}";

  requireSuffix =
    label: suffixes: v:
    if builtins.any (sfx: lib.hasSuffix sfx v) suffixes then
      v
    else
      throwUn "${label} must end with ${lib.concatStringsSep "|" suffixes}: ${v}";

  requireNonEmpty =
    label: v: if builtins.isString v && v != "" then v else throwUn "missing ${label}";

  requireStringList =
    label: v:
    if builtins.isList v && builtins.all builtins.isString v then
      v
    else
      throwUn "${label} must be a list of strings";

  requireUnique =
    label: list:
    if lib.unique list == list then list else throwUn "${label} contains duplicate entries";

  githubRepo =
    homepage:
    let
      rest = lib.removePrefix "https://github.com/" homepage;
      parts = lib.splitString "/" rest;
    in
    if
      lib.hasPrefix "https://github.com/" homepage
      && builtins.length parts == 2
      && builtins.all (p: builtins.match "[A-Za-z0-9_.-]+" p != null) parts
    then
      rest
    else
      "";
}
