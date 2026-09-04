{ lib }:

{
  template,
  model,
}:

let
  placeholders = [
    "ECC_VERSION"
    "ECC_TAG"
    "ECC_ASSET_NAME"
    "ECC_SHA256"
    "ECC_SIZE"
    "ECC_GITHUB_URL"
    "ECC_CNB_URL"
    "MIN_GLIBC_MAJOR"
    "MIN_GLIBC_MINOR"
    "OSS_CAD_VERSION"
    "OSS_CAD_ASSET_NAME"
    "OSS_CAD_SHA256"
    "OSS_CAD_URL"
    "OSS_CAD_CNB_URL"
    "SIZER_VERSION"
    "SIZER_ASSET_NAME"
    "SIZER_SHA256"
    "SIZER_URL"
    "SIZER_CNB_URL"
    "SIZER_CNB_SHA256"
    "PDK_NAME"
    "PDK_VERSION"
    "PDK_BASE_ASSET_NAME"
    "PDK_BASE_SHA256"
    "PDK_BASE_URL"
    "PDK_BASE_CNB_URL"
    "PDK_BASE_CNB_SHA256"
    "PDK_TECH_LEF"
    "PDK_CELL_LEFS"
    "PDK_ASSET_TABLE"
    "PDK_LIBERTY_FILES"
  ];

  joinLines = values: lib.concatStringsSep "\n" values;

  assetRow =
    a:
    lib.concatStringsSep "\t" [
      a.name
      a.sha256
      a.url
      (if a.cnbUrl == "" then "-" else a.cnbUrl)
      a.dest
    ];

  mapping = {
    ECC_VERSION = model.ecc.version;
    ECC_TAG = model.ecc.tag;
    ECC_ASSET_NAME = model.ecc.name;
    ECC_SHA256 = model.ecc.sha256;
    ECC_SIZE = if model.ecc.size == null then "" else toString model.ecc.size;
    ECC_GITHUB_URL = model.ecc.url;
    ECC_CNB_URL = model.ecc.cnbUrl;
    MIN_GLIBC_MAJOR = toString model.platform.minGlibc.major;
    MIN_GLIBC_MINOR = toString model.platform.minGlibc.minor;
    OSS_CAD_VERSION = model.ossCadSuite.version;
    OSS_CAD_ASSET_NAME = model.ossCadSuite.name;
    OSS_CAD_SHA256 = model.ossCadSuite.sha256;
    OSS_CAD_URL = model.ossCadSuite.url;
    OSS_CAD_CNB_URL = model.ossCadSuite.cnbUrl;
    SIZER_VERSION = model.sizer.version;
    SIZER_ASSET_NAME = model.sizer.name;
    SIZER_SHA256 = model.sizer.sha256;
    SIZER_URL = model.sizer.url;
    SIZER_CNB_URL = model.sizer.cnbUrl;
    SIZER_CNB_SHA256 = model.sizer.cnbSha256;
    PDK_NAME = model.pdk.name;
    PDK_VERSION = model.pdk.version;
    PDK_BASE_ASSET_NAME = model.pdk.base.name;
    PDK_BASE_SHA256 = model.pdk.base.sha256;
    PDK_BASE_URL = model.pdk.base.url;
    PDK_BASE_CNB_URL = model.pdk.base.cnbUrl;
    PDK_BASE_CNB_SHA256 = model.pdk.base.cnbSha256;
    PDK_TECH_LEF = model.pdk.techLef;
    PDK_CELL_LEFS = joinLines model.pdk.cellLefs;
    PDK_ASSET_TABLE = joinLines (map assetRow model.pdk.assets);
    PDK_LIBERTY_FILES = joinLines model.pdk.libertyFiles;
  };

  from = map (k: "@${k}@") placeholders;
  to = map (k: mapping.${k}) placeholders;
  rendered = builtins.replaceStrings from to template;
  leftover = builtins.filter (k: lib.hasInfix "@${k}@" rendered) placeholders;
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
