{ lib, semver }:

raw:

let
  inherit (semver) parse parseTag;

  throwUn = msg: throw "invalid release model: ${msg}";

  hasControl = s: builtins.match ".*[[:cntrl:]].*" s != null;

  requireRelative =
    label: path:
    if path == "" || lib.hasPrefix "/" path || lib.hasPrefix "\\" path then
      throwUn "absolute or empty ${label} path: ${path}"
    else if hasControl path then
      throwUn "control character in ${label} path: ${path}"
    else if builtins.any (p: p == "" || p == "." || p == "..") (lib.splitString "/" path) then
      throwUn "unsafe ${label} path: ${path}"
    else
      path;

  hexSha = s: builtins.match "[0-9a-f]{64}" s != null;

  requireHex = label: s: if hexSha s then s else throwUn "invalid SHA-256 for ${label}: ${s}";

  requireCnb =
    label: url: if url == null || url == "" then throwUn "missing cnb_url on ${label}" else url;

  parseMinGlibc =
    s:
    let
      m = builtins.match "([0-9]+)\\.([0-9]+)" s;
    in
    if m == null then
      throwUn "invalid min_glibc ${s}"
    else
      {
        major = lib.toInt (builtins.elemAt m 0);
        minor = lib.toInt (builtins.elemAt m 1);
      };

  ecc = raw.ecc or { };
  oss = raw.oss_cad_suite or { };
  sizer = raw.sizer or { };
  pdk = raw.pdk or { };
  platform = raw.platform or { };
  minGlibc = parseMinGlibc (platform.min_glibc or "");

  version = ecc.version or "";
  parsed = parse version;
  tag = "v${version}";
  _ = parseTag tag;

  libertyNames = [
    "ics55_LLSC_H7CH_liberty.tar.bz2"
    "ics55_LLSC_H7CL_liberty.tar.bz2"
    "ics55_LLSC_H7CR_liberty.tar.bz2"
  ];

  assets = pdk.assets or [ ];

  model = {
    ecc = {
      inherit version tag;
      name = ecc.asset_name or "";
      url = ecc.url or "";
      cnbUrl = ecc.cnb_url or "";
      sha256 = requireHex "ecc" (ecc.sha256 or "");
      size = ecc.size or null;
      githubRepo = ecc.github_repo or "";
    };
    ossCadSuite = {
      version = oss.version or "";
      name = oss.name or "";
      url = oss.url or "";
      cnbUrl = requireCnb "OSS CAD Suite" (oss.cnb_url or "");
      sha256 = requireHex "oss-cad-suite" (oss.sha256 or "");
      size = oss.size or null;
    };
    sizer = {
      version = sizer.version or "";
      name = sizer.asset_name or "";
      url = sizer.url or "";
      sha256 = requireHex "sizer" (sizer.sha256 or "");
      cnbUrl = sizer.cnb_url or "";
      cnbSha256 = sizer.cnb_sha256 or "";
      size = sizer.size or null;
      githubRepo = sizer.github_repo or "";
    };
    pdk = {
      name = pdk.name or "";
      version = pdk.version or "";
      base = {
        name = pdk.base_name or "";
        url = pdk.base_url or "";
        sha256 = requireHex "pdk-base" (pdk.base_sha256 or "");
        cnbUrl = pdk.base_cnb_url or "";
        cnbSha256 = pdk.base_cnb_sha256 or "";
      };
      techLef = requireRelative "tech lef" (pdk.tech_lef or "");
      cellLefs = map (requireRelative "cell lef") (pdk.cell_lefs or [ ]);
      libertyFiles = map (requireRelative "liberty") (pdk.liberty_files or [ ]);
      assets = map (a: {
        name = a.name or "";
        url = a.url or "";
        cnbUrl = requireCnb (a.name or "pdk-asset") (a.cnb_url or "");
        sha256 = requireHex (a.name or "pdk-asset") (a.sha256 or "");
        dest = requireRelative "dest" (a.dest or "");
        kind = a.kind or "archive";
        size = a.size or null;
      }) assets;
    };
    platform = {
      os = platform.os or "";
      cpu = platform.cpu or "";
      inherit minGlibc;
    };
  };
in
if platform.os or "" != "linux" || platform.cpu or "" != "x86_64" then
  throwUn "unsupported platform ${platform.os or "?"}/${platform.cpu or "?"}"
else if minGlibc.major != 2 || minGlibc.minor != 34 then
  throwUn "unsupported minimum glibc ${platform.min_glibc}"
else if model.ecc.name != "ecc-cli-linux-x86_64.tar.gz" then
  throwUn "ECC asset must be named ecc-cli-linux-x86_64.tar.gz"
else if model.ecc.url == "" then
  throwUn "missing ECC url"
else if (requireCnb "ECC" model.ecc.cnbUrl) == "" then
  throwUn "missing ECC cnb_url"
else if model.ossCadSuite.version == "" then
  throwUn "missing OSS CAD Suite version"
else if model.sizer.version == "" then
  throwUn "missing ecc-sizer version"
else if model.sizer.name != "ecc-sizer-${model.sizer.version}-linux-x64.tar.gz" then
  throwUn "ecc-sizer asset must be named ecc-sizer-${model.sizer.version}-linux-x64.tar.gz"
else if model.sizer.url == "" then
  throwUn "missing ecc-sizer url"
else if model.sizer.cnbSha256 != "" && !(hexSha model.sizer.cnbSha256) then
  throwUn "invalid SHA-256 for sizer cnb mirror: ${model.sizer.cnbSha256}"
else if model.sizer.cnbUrl == "" && model.sizer.cnbSha256 != "" then
  throwUn "sizer cnb_sha256 set without cnb_url"
else if model.pdk.version == "" then
  throwUn "missing ICS55 PDK version"
else if builtins.length model.pdk.assets != 7 then
  throwUn "ICS55 PDK requires 7 supplemental assets"
else if model.pdk.libertyFiles == [ ] then
  throwUn "PDK liberty_files is empty"
else if
  model.pdk.base.cnbUrl != "" && (builtins.match "[0-9a-f]{64}" model.pdk.base.cnbSha256 == null)
then
  throwUn "PDK base cnb_url requires base_cnb_sha256"
else if model.pdk.base.cnbUrl == "" && model.pdk.base.cnbSha256 != "" then
  throwUn "PDK base_cnb_sha256 set without base_cnb_url"
else if !(builtins.all (n: builtins.any (a: a.name == n) model.pdk.assets) libertyNames) then
  throwUn "missing Liberty archive"
else if builtins.length model.pdk.cellLefs < 2 then
  throwUn "PDK standard-cell LEF list is incomplete"
else
  model
