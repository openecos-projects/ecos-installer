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

  requireCategory =
    label: v:
    if builtins.elem v categories then
      v
    else
      throwUn "${label} must be one of ${lib.concatStringsSep "|" categories}: ${toString v}";

  platformKeys = [
    "linux-x86_64"
    "all-platform"
  ];

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

  # Closed field sets per section: unknown sections and unknown fields fail
  # here, so typos and retired keys (sha256_url, post_install,
  # supplemental_assets) cannot re-enter the manifest.
  checkFields =
    label: allowed: section:
    let
      unknown = builtins.filter (k: !builtins.elem k allowed) (builtins.attrNames section);
    in
    if unknown == [ ] then
      section
    else
      throwUn "unknown field(s) in [${label}]: ${lib.concatStringsSep ", " unknown}";

  requireSection =
    name:
    let
      section = raw.${name} or null;
    in
    if section == null || !builtins.isAttrs section || builtins.isList section then
      throwUn "missing [${name}] section"
    else
      section;

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

  # Tool sections whose lock data is still pinned to the mutable -latest
  # tags of ecos-resource-assets. These are the only sections allowed to
  # carry version = "latest"; replace each entry's version/url/metadata_url
  # with immutable versioned release data and drop it from this list.
  mutableLatest = [
    "ecc-fe"
    "ecc-fe-cpu-rtl"
    "ecc-fe-soc-ysyx-am"
    "ecc-fe-difftest-ref"
    "ecc-fe-examples"
    "surfer"
  ];

  toolSections = [
    "ecc-fe"
    "ecc-fe-cpu-rtl"
    "ecc-fe-soc-ysyx-am"
    "ecc-fe-difftest-ref"
    "ecc-fe-examples"
    "slang"
    "verilator"
    "riscv-toolchain"
    "surfer"
  ];

  knownSections = [
    "platform"
    "ecc"
    "oss_cad_suite"
    "sizer"
    "pdk"
    "mpc-frame"
  ]
  ++ toolSections;

  topCheck =
    let
      extra = builtins.filter (k: !builtins.elem k knownSections) (
        builtins.attrNames (builtins.removeAttrs raw [ "pdk_pkg" ])
      );
    in
    if extra == [ ] then
      null
    else
      throwUn "unknown top-level section(s): ${lib.concatStringsSep ", " extra}";

  platformRaw = requireSection "platform";
  ecc = requireSection "ecc";
  oss = requireSection "oss_cad_suite";
  sizer = requireSection "sizer";
  pdkRaw = requireSection "pdk";
  mpcRaw = requireSection "mpc-frame";

  pdkPkgsRaw =
    let
      list = raw.pdk_pkg or null;
    in
    if !builtins.isList list then throwUn "missing [[pdk_pkg]] tables" else list;

  platformCheck =
    let
      allowed = [
        "os"
        "cpu"
        "min_glibc"
      ];
    in
    checkFields "platform" allowed platformRaw;

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

  minGlibc = parseMinGlibc (platformRaw.min_glibc or "");

  platform = {
    os = platformRaw.os or "";
    cpu = platformRaw.cpu or "";
    inherit minGlibc;
  };

  version = ecc.version or "";
  parsed = parse version;
  tag = "v${version}";
  tagCheck = parseTag tag;
  sizerParsed = parse (sizer.version or "");

  eccFields = [
    "name"
    "display_name"
    "description"
    "category"
    "homepage"
    "requires"
    "github_repo"
    "asset_name"
    "cnb_url_template"
    "version"
    "url"
    "cnb_url"
    "sha256"
    "size"
  ];

  ossFields = [
    "name"
    "display_name"
    "description"
    "category"
    "homepage"
    "requires"
    "version"
    "asset_name"
    "url"
    "cnb_url"
    "sha256"
    "size"
    "strip_prefix"
  ];

  sizerFields = [
    "github_repo"
    "asset_name"
    "version"
    "url"
    "cnb_url"
    "cnb_sha256"
    "sha256"
    "size"
  ];

  toolFields = [
    "name"
    "display_name"
    "description"
    "category"
    "homepage"
    "requires"
    "version"
    "url"
    "sha256"
    "size"
    "metadata_url"
    "strip_prefix"
    "platform"
  ];

  pdkFields = [
    "id"
    "name"
    "display_name"
    "description"
    "category"
    "homepage"
    "version"
    "requires"
    "tech_lef"
    "cell_lefs"
    "liberty_files"
  ];

  pkgFields = [
    "id"
    "kind"
    "name"
    "url"
    "cnb_url"
    "sha256"
    "size"
    "cnb_sha256"
    "strip_prefix"
    "dest"
  ];

  mpcFields = [
    "id"
    "display_name"
    "description"
    "category"
    "homepage"
    "version"
    "platform"
    "url"
    "sha256"
    "size"
    "strip_prefix"
    "update_source"
  ];

  sizerCheck = checkFields "sizer" sizerFields sizer;

  sizerModel = {
    version = sizer.version or "";
    name = sizer.asset_name or "";
    url = requireHttpsUrl "sizer.url" (sizer.url or "");
    sha256 = requireHex "sizer" (sizer.sha256 or "");
    cnbUrl =
      let
        u = sizer.cnb_url or "";
      in
      if u == "" then "" else requireHttpsUrl "sizer.cnb_url" u;
    cnbSha256 = sizer.cnb_sha256 or "";
    size = requireSize "sizer" (requireInt "sizer.size" (sizer.size or 0));
    githubRepo = sizer.github_repo or "";
  };

  parsePkg =
    section:
    let
      checked = checkFields "pdk_pkg" pkgFields section;
      id = requireNonEmpty "pdk_pkg.id" (checked.id or "");
      label = "pdk_pkg:${id}";
      kind = checked.kind or "";
      common = {
        inherit id kind;
        name = requireNonEmpty "${label}.name" (checked.name or "");
        url = requireHttpsUrl "${label}.url" (checked.url or "");
        cnbUrl = requireCnb id (checked.cnb_url or "");
        sha256 = requireHex id (checked.sha256 or "");
        size = requireSize label (requireInt "${label}.size" (checked.size or 0));
      };
    in
    if kind == "base" then
      if checked ? dest then
        throwUn "${label} is the base package and must not carry dest"
      else
        common
        // {
          cnbSha256 = requireHex "${label} cnb mirror" (
            requireNonEmpty "${label}.cnb_sha256" (checked.cnb_sha256 or "")
          );
          stripPrefix = requireNonEmpty "${label}.strip_prefix" (checked.strip_prefix or "");
        }
        // {
          url = requireSuffix "${label}.url" baseArchiveSuffixes common.url;
        }
    else if
      builtins.elem kind [
        "liberty"
        "gds"
      ]
    then
      if checked ? cnb_sha256 || checked ? strip_prefix then
        throwUn "${label} must not carry cnb_sha256 or strip_prefix; only the base package does"
      else
        common
        // {
          url = requireSuffix "${label}.url" archiveSuffixes common.url;
          dest = requireRelative "${label} dest" (checked.dest or "");
        }
    else
      throwUn "${label} kind must be base, liberty, or gds: ${kind}";

  pdkPkgs = map parsePkg pdkPkgsRaw;

  pdkPkgIds = map (p: p.id) pdkPkgs;
  pkgIdCheck = requireUnique "pdk_pkg ids" pdkPkgIds;

  pdkSection = checkFields "pdk" pdkFields pdkRaw;
  pdkId = requireId "pdk.id" (pdkSection.id or "");

  pdkRequires = map (
    dep:
    if builtins.match "pdk_pkg:[A-Za-z0-9_.-]+" dep == null then
      throwUn "pdk.requires entries must look like pdk_pkg:<id>: ${dep}"
    else if !(builtins.elem (lib.removePrefix "pdk_pkg:" dep) pdkPkgIds) then
      throwUn "pdk.requires references unknown pdk_pkg: ${dep}"
    else
      dep
  ) (requireUnique "pdk.requires" (requireStringList "pdk.requires" (pdkSection.requires or [ ])));

  basePkgs = builtins.filter (p: p.kind == "base") pdkPkgs;
  nonBasePkgs = builtins.filter (p: p.kind != "base") pdkPkgs;

  baseCountCheck =
    if builtins.length basePkgs == 1 then
      null
    else
      throwUn "exactly one kind = \"base\" pdk_pkg is required, found ${toString (builtins.length basePkgs)}";

  nonBaseCountCheck =
    if builtins.length nonBasePkgs == 7 then
      null
    else
      throwUn "ICS55 PDK requires 7 supplemental packages, found ${toString (builtins.length nonBasePkgs)}";

  orphanCheck =
    let
      referenced = map (lib.removePrefix "pdk_pkg:") pdkRequires;
      orphans = builtins.filter (id: !(builtins.elem id referenced)) pdkPkgIds;
    in
    if orphans == [ ] then
      null
    else
      throwUn "pdk_pkg entries not referenced by pdk.requires: ${lib.concatStringsSep ", " orphans}";

  # Installer order (and registry packages order) follows pdk.requires.
  orderedPkgsCheck = map (
    dep:
    let
      matches = builtins.filter (p: p.id == lib.removePrefix "pdk_pkg:" dep) pdkPkgs;
    in
    if builtins.length matches == 1 then
      null
    else
      throwUn "pdk.requires must reference each pdk_pkg exactly once: ${dep}"
  ) pdkRequires;
  orderedAllPkgs = map (
    dep: builtins.head (builtins.filter (p: p.id == lib.removePrefix "pdk_pkg:" dep) pdkPkgs)
  ) pdkRequires;
  assets = builtins.filter (p: p.kind != "base") orderedAllPkgs;

  destKindCheck = map (
    p:
    if p.kind == "base" then
      null
    else
      map (
        q:
        if p.id != q.id && q.kind != "base" && p.dest == q.dest && p.kind == q.kind then
          throwUn "pdk_pkg:${p.id} and pdk_pkg:${q.id} share dest ${p.dest} with the same kind"
        else
          null
      ) pdkPkgs
  ) pdkPkgs;

  libertyDests = map (p: p.dest) (builtins.filter (p: p.kind == "liberty") pdkPkgs);

  cellLefs = map (requireRelative "cell lef") (
    requireStringList "pdk.cell_lefs" (pdkSection.cell_lefs or [ ])
  );
  libertyFiles = map (
    lf:
    let
      path = requireRelative "liberty" lf;
      covered = builtins.any (dest: lib.hasPrefix "${dest}/" path) libertyDests;
    in
    if covered then
      path
    else
      throwUn "pdk.liberty_files entry ${path} is not under any liberty pdk_pkg dest"
  ) (requireStringList "pdk.liberty_files" (pdkSection.liberty_files or [ ]));

  pdkModel = {
    id = pdkId;
    name = requireNonEmpty "pdk.name" (pdkSection.name or "");
    version = requireNonEmpty "pdk.version" (pdkSection.version or "");
    displayName = requireNonEmpty "pdk.display_name" (pdkSection.display_name or "");
    description = requireNonEmpty "pdk.description" (pdkSection.description or "");
    category = requireCategory "pdk.category" (pdkSection.category or "");
    homepage = requireHttpsUrl "pdk.homepage" (pdkSection.homepage or "");
    base = builtins.head basePkgs;
    techLef = requireRelative "tech lef" (pdkSection.tech_lef or "");
    cellLefs = cellLefs;
    libertyFiles = libertyFiles;
    assets = assets;
  };

  parseTool =
    key:
    let
      section = checkFields key toolFields (requireSection key);
      toolVersion = requireNonEmpty "${key}.version" (section.version or "");
      entityId = requireId "${key}.name" (section.name or "");
      platformKey =
        let
          pk = requirePlatformKey "${key}.platform" (section.platform or "linux-x86_64");
        in
        if pk == "all-platform" then throwUn "${key}: all-platform is not allowed for tools" else pk;
      metadataUrl =
        let
          u = section.metadata_url or "";
        in
        if u == "" then
          ""
        else if lib.hasSuffix ".metadata.json" u then
          requireHttpsUrl "${key}.metadata_url" u
        else
          throwUn "${key}.metadata_url must point at a .metadata.json sidecar: ${u}";
      latestCheck =
        if toolVersion != "latest" then
          null
        else if builtins.elem key mutableLatest then
          if section.metadata_url or "" == "" then
            throwUn "${key} pins a -latest release and requires metadata_url"
          else
            null
        else
          throwUn "${key} still pins a mutable -latest release; publish an immutable versioned release and update the pin";
      versionedCheck =
        let
          mutableUrl = builtins.match ".*-latest.*" (section.url or "") != null;
          mutableMetadata = builtins.match ".*-latest.*" (section.metadata_url or "") != null;
        in
        if toolVersion == "latest" then
          null
        else if mutableUrl || mutableMetadata then
          throwUn "${key} pins an immutable version but its url or metadata_url still references a -latest release"
        else
          null;
    in
    {
      name =
        if entityId == key then
          entityId
        else
          throwUn "${key}.name must match the section name, got ${entityId}";
      displayName = requireNonEmpty "${key}.display_name" (section.display_name or "");
      description = requireNonEmpty "${key}.description" (section.description or "");
      category = requireCategory "${key}.category" (section.category or "");
      homepage = requireHttpsUrl "${key}.homepage" (section.homepage or "");
      version = toolVersion;
      platform = platformKey;
      url = requireSuffix "${key}.url" archiveSuffixes (requireHttpsUrl "${key}.url" (section.url or ""));
      sha256 = requireHex key (section.sha256 or "");
      size = requireSize key (requireInt "${key}.size" (section.size or 0));
      metadataUrl = metadataUrl;
      stripPrefix =
        let
          sp = section.strip_prefix or "";
        in
        if section ? strip_prefix then requireNonEmpty "${key}.strip_prefix" sp else "";
      rawRequires = requireStringList "${key}.requires" (section.requires or [ ]);
    }
    // {
      inherit latestCheck versionedCheck;
    };

  toolModels = map parseTool toolSections;

  mpcSection = checkFields "mpc-frame" mpcFields mpcRaw;

  updateSource =
    let
      src = checkFields "mpc-frame.update_source" [
        "type"
        "branch"
      ] (mpcSection.update_source or { });
      branch =
        let
          b = src.branch or "";
        in
        if b != "" && !hasControl b && builtins.match ".*[[:space:]].*" b == null then
          b
        else
          throwUn "mpc-frame.update_source.branch must be a non-empty branch name without whitespace";
    in
    if (src.type or "") == "github_branch" then
      {
        type = "github_branch";
        inherit branch;
      }
    else
      throwUn "mpc-frame.update_source.type must be github_branch: ${src.type or ""}";

  mpcHomepageCheck =
    if githubRepo (requireHttpsUrl "mpc-frame.homepage" (mpcSection.homepage or "")) == "" then
      throwUn "mpc-frame.update_source requires the homepage to be a canonical https://github.com/<owner>/<repo> URL"
    else
      null;

  mpcModel = {
    id = requireId "mpc-frame.id" (mpcSection.id or "");
    displayName = requireNonEmpty "mpc-frame.display_name" (mpcSection.display_name or "");
    description = requireNonEmpty "mpc-frame.description" (mpcSection.description or "");
    category = requireCategory "mpc-frame.category" (mpcSection.category or "");
    homepage = requireHttpsUrl "mpc-frame.homepage" (mpcSection.homepage or "");
    version = requireNonEmpty "mpc-frame.version" (mpcSection.version or "");
    platform = requirePlatformKey "mpc-frame.platform" (mpcSection.platform or "all-platform");
    url = requireSuffix "mpc-frame.url" archiveSuffixes (
      requireHttpsUrl "mpc-frame.url" (mpcSection.url or "")
    );
    sha256 = requireHex "mpc-frame" (mpcSection.sha256 or "");
    size = requireSize "mpc-frame" (requireInt "mpc-frame.size" (mpcSection.size or 0));
    stripPrefix = requireNonEmpty "mpc-frame.strip_prefix" (mpcSection.strip_prefix or "");
    updateSource = updateSource;
  };

  # Registry dependency targets: tool entity names plus the PDK entity id.
  toolNames = map (t: t.name) toolModels;
  resourceIds =
    map (n: "tool:${n}") (
      toolNames
      ++ [
        "ecc"
        "yosys"
      ]
    )
    ++ [ "pdk:${pdkId}" ];

  parseDeps =
    label: deps: ids:
    map (
      dep:
      if builtins.match "(tool|pdk):[a-z0-9_-]+" dep == null then
        throwUn "${label} entries must look like tool:<id> or pdk:<id>: ${dep}"
      else if !(builtins.elem dep ids) then
        throwUn "${label} references unknown resource: ${dep}"
      else
        dep
    ) (requireUnique label deps);

  parseEcc =
    let
      section = checkFields "ecc" eccFields ecc;
    in
    {
      inherit version tag;
      name = requireNonEmpty "ecc.asset_name" (ecc.asset_name or "");
      url = requireSuffix "ecc.url" archiveSuffixes (requireHttpsUrl "ecc.url" (ecc.url or ""));
      cnbUrl = requireCnb "ECC" (ecc.cnb_url or "");
      sha256 = requireHex "ecc" (ecc.sha256 or "");
      size = requireSize "ecc" (requireInt "ecc.size" (ecc.size or 0));
      githubRepo = requireNonEmpty "ecc.github_repo" (ecc.github_repo or "");
      tool = {
        name =
          let
            n = requireId "ecc.name" (ecc.name or "");
          in
          if n == "ecc" then n else throwUn "ecc.name must be \"ecc\", got ${n}";
        displayName = requireNonEmpty "ecc.display_name" (ecc.display_name or "");
        description = requireNonEmpty "ecc.description" (ecc.description or "");
        category = requireCategory "ecc.category" (ecc.category or "");
        homepage = requireHttpsUrl "ecc.homepage" (ecc.homepage or "");
        requires = parseDeps "ecc.requires" (requireStringList "ecc.requires" (
          ecc.requires or [ ]
        )) resourceIds;
      };
    };

  parseOss =
    let
      section = checkFields "oss_cad_suite" ossFields oss;
      ossVersion = requireNonEmpty "oss_cad_suite.version" (oss.version or "");
      assetName = requireNonEmpty "oss_cad_suite.asset_name" (oss.asset_name or "");
      entityName = requireId "oss_cad_suite.name" (oss.name or "");
    in
    {
      version = ossVersion;
      name = assetName;
      url = requireSuffix "oss_cad_suite.url" archiveSuffixes (
        requireHttpsUrl "oss_cad_suite.url" (oss.url or "")
      );
      cnbUrl = requireCnb "OSS CAD Suite" (oss.cnb_url or "");
      sha256 = requireHex "oss-cad-suite" (oss.sha256 or "");
      size = requireSize "oss_cad_suite" (requireInt "oss_cad_suite.size" (oss.size or 0));
      stripPrefix = requireNonEmpty "oss_cad_suite.strip_prefix" (oss.strip_prefix or "");
      tool = {
        name =
          if entityName == "yosys" then
            entityName
          else
            throwUn "oss_cad_suite.name must be \"yosys\", got ${entityName}";
        displayName = requireNonEmpty "oss_cad_suite.display_name" (oss.display_name or "");
        description = requireNonEmpty "oss_cad_suite.description" (oss.description or "");
        category = requireCategory "oss_cad_suite.category" (oss.category or "");
        homepage = requireHttpsUrl "oss_cad_suite.homepage" (oss.homepage or "");
        requires = parseDeps "oss_cad_suite.requires" (requireStringList "oss_cad_suite.requires" (
          oss.requires or [ ]
        )) resourceIds;
      };
    };

  ossAssetNameCheck =
    let
      expected = "oss-cad-suite-linux-x64-${ossModel.version}.tgz";
    in
    if ossModel.name == expected then
      null
    else
      throwUn "oss_cad_suite.asset_name must be ${expected}, got ${ossModel.name}";

  eccModel = parseEcc;
  ossModel = parseOss;

  tools = map (
    t:
    t
    // {
      requires = parseDeps "${t.name}.requires" t.rawRequires resourceIds;
    }
  ) toolModels;

  libertyNames = [
    "ics55_LLSC_H7CH_liberty.tar.bz2"
    "ics55_LLSC_H7CL_liberty.tar.bz2"
    "ics55_LLSC_H7CR_liberty.tar.bz2"
  ];

  model = {
    ecc = eccModel;
    ossCadSuite = ossModel;
    sizer = sizerModel;
    pdk = pdkModel;
    tools = tools;
    mpc = mpcModel;
    platform = platform;
  };

  forcedChecks = [
    topCheck
    platformCheck
    tagCheck
    sizerCheck
    pkgIdCheck
    baseCountCheck
    nonBaseCountCheck
    orphanCheck
    ossAssetNameCheck
    mpcHomepageCheck
  ]
  ++ orderedPkgsCheck
  ++ destKindCheck
  ++ map (t: t.latestCheck) toolModels
  ++ map (t: t.versionedCheck) toolModels;
in
if platform.os != "linux" || platform.cpu != "x86_64" then
  throwUn "unsupported platform ${platform.os}/${platform.cpu}"
else if minGlibc.major != 2 || minGlibc.minor != 34 then
  throwUn "unsupported minimum glibc ${platformRaw.min_glibc}"
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
else if model.pdk.libertyFiles == [ ] then
  throwUn "PDK liberty_files is empty"
else if !(builtins.all (n: builtins.any (a: a.name == n) model.pdk.assets) libertyNames) then
  throwUn "missing Liberty archive"
else if builtins.length model.pdk.cellLefs < 2 then
  throwUn "PDK standard-cell LEF list is incomplete"
else
  # Force the SemVer parses and the whole model so a malformed manifest
  # fails at nix build / flake check time instead of reaching a projection.
  builtins.deepSeq (
    forcedChecks
    ++ [
      parsed
      sizerParsed
      model
    ]
  ) model
