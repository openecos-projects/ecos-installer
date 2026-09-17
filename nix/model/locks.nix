{
  lib,
  rules,
  locks,
}:

# Merge nix/toolchain.toml (rules) with nix/_sources/generated.json
# (locks) into the manifest attrset that nix/model.nix validates and
# projects.
#
# Rules carry metadata, version-source rules (src), and interpolation
# templates; locks carry the resolved version/url/sha256/size data. The
# shared helpers (shape validation, template algebra, src schema, merge)
# live in lib/; this file is only the domain wiring: which sections
# exist, which fields they carry, and how the two sources join.

let
  helpers = import ../../lib { inherit lib; };
  inherit (helpers) throwUn checkFields checkSrc;

  requireLock = helpers.requireLock locks;
  mergeLock = helpers.mergeLock {
    inherit locks;
    # mpc-frame only: the 0.1.0 seed version predates the commit-form
    # versions the url_template produces; the exemption goes away with the
    # first bump that advances the version to commit form.
    urlAssertExempt = [ "mpc-frame" ];
  };

  requireSection = name: rules.${name} or (throwUn "missing [${name}] section");

  metadataFields = [
    "name"
    "display_name"
    "description"
    "category"
    "homepage"
    "requires"
  ];

  ruleFields = [
    "src"
    "version_map"
    "url_template"
    "cnb_url_template"
    "name_template"
    "strip_prefix"
    "needs_cnb_sha256"
  ];

  eccRuleFields = metadataFields ++ ruleFields;
  sizerRuleFields = ruleFields;
  toolRuleFields =
    metadataFields
    ++ ruleFields
    ++ [
      "metadata_url"
      "platform"
    ];
  pdkRuleFields = [
    "id"
    "name"
    "display_name"
    "description"
    "category"
    "homepage"
    "src"
    "requires"
    "tech_lef"
    "cell_lefs"
    "liberty_files"
  ];
  pkgRuleFields = [
    "id"
    "kind"
    "url_template"
    "cnb_url_template"
    "name_template"
    "strip_prefix"
    "needs_cnb_sha256"
    "dest"
  ];
  mpcRuleFields = [
    "id"
    "display_name"
    "description"
    "category"
    "homepage"
    "platform"
    "src"
    "version_map"
    "url_template"
    "strip_prefix"
    "update_source"
  ];
  platformRuleFields = [
    "os"
    "cpu"
    "min_glibc"
  ];

  metadataOf = section: {
    name = section.name or "";
    display_name = section.display_name or "";
    description = section.description or "";
    category = section.category or "";
    homepage = section.homepage or "";
    requires = section.requires or [ ];
  };

  platformSection = checkFields "platform" platformRuleFields (requireSection "platform");

  eccSection =
    let
      section = checkFields "ecc" eccRuleFields (requireSection "ecc");
      src = checkSrc "ecc" section;
      lock = builtins.deepSeq src (mergeLock "ecc" section);
    in
    metadataOf section
    // {
      github_repo = src.github or "";
      asset_name = lock.assetName;
      inherit (lock)
        version
        url
        sha256
        size
        ;
      cnb_url = lock.cnbUrl;
    };

  ossSection =
    let
      section = checkFields "oss_cad_suite" eccRuleFields (requireSection "oss_cad_suite");
      src = checkSrc "oss_cad_suite" section;
      lock = builtins.deepSeq src (mergeLock "oss_cad_suite" section);
    in
    metadataOf section
    // {
      asset_name = lock.assetName;
      inherit (lock)
        version
        url
        sha256
        size
        ;
      cnb_url = lock.cnbUrl;
      strip_prefix = lock.stripPrefix;
    };

  sizerSection =
    let
      section = checkFields "sizer" sizerRuleFields (requireSection "sizer");
      src = checkSrc "sizer" section;
      lock = builtins.deepSeq src (mergeLock "sizer" section);
    in
    {
      github_repo = src.github or "";
      asset_name = lock.assetName;
      inherit (lock)
        version
        url
        sha256
        size
        ;
      cnb_url = lock.cnbUrl;
    };

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

  toolSection =
    key:
    let
      section = checkFields key toolRuleFields (requireSection key);
      src = checkSrc key section;
      lock = builtins.deepSeq src (mergeLock key section);
    in
    metadataOf section
    // {
      inherit (lock)
        version
        url
        sha256
        size
        ;
    }
    // lib.optionalAttrs (section ? metadata_url) { metadata_url = section.metadata_url; }
    // lib.optionalAttrs (section ? platform) { platform = section.platform; }
    // lib.optionalAttrs (lock.stripPrefix != null) { strip_prefix = lock.stripPrefix; };

  pkgSections =
    let
      list = rules.pdk_pkg or null;
    in
    if !builtins.isList list then
      throwUn "missing [[pdk_pkg]] tables"
    else
      map (
        pkg:
        let
          checked = checkFields "pdk_pkg" pkgRuleFields pkg;
          id = checked.id or "";
          label = "pdk_pkg:${id}";
          kind = checked.kind or "";
          cnbKindCheck =
            if (checked.needs_cnb_sha256 or false) && kind != "base" then
              throwUn "${label}: needs_cnb_sha256 is only valid on the base package"
            else if kind == "base" && checked ? dest then
              throwUn "${label}: the base package must not carry dest"
            else
              null;
          lock = builtins.deepSeq cnbKindCheck (mergeLock id checked);
        in
        {
          inherit id kind;
          name = lock.assetName;
          inherit (lock) url sha256 size;
          cnb_url = lock.cnbUrl;
        }
        // lib.optionalAttrs (kind == "base") {
          cnb_sha256 = lock.cnbSha256;
          strip_prefix = lock.stripPrefix;
        }
        // lib.optionalAttrs (kind != "base") { dest = checked.dest or ""; }
      ) list;

  # The PDK collection version comes from the base package's lock entry;
  # every pdk_pkg lock must agree on it.
  pdkVersion =
    let
      versions = lib.unique (map (pkg: (requireLock pkg.id).version) pkgSections);
    in
    if builtins.length versions == 1 then
      builtins.head versions
    else
      throwUn "pdk_pkg lock versions disagree: ${lib.concatStringsSep ", " versions}";

  pdkSection =
    let
      section = checkFields "pdk" pdkRuleFields (requireSection "pdk");
      src = checkSrc "pdk" section;
    in
    builtins.deepSeq src {
      id = section.id or "";
      name = section.name or "";
      display_name = section.display_name or "";
      description = section.description or "";
      category = section.category or "";
      homepage = section.homepage or "";
      version = pdkVersion;
      requires = section.requires or [ ];
      tech_lef = section.tech_lef or "";
      cell_lefs = section.cell_lefs or [ ];
      liberty_files = section.liberty_files or [ ];
    };

  mpcSection =
    let
      section = checkFields "mpc-frame" mpcRuleFields (requireSection "mpc-frame");
      src = checkSrc "mpc-frame" section;
      lock = builtins.deepSeq src (mergeLock "mpc-frame" section);
    in
    {
      id = section.id or "";
      display_name = section.display_name or "";
      description = section.description or "";
      category = section.category or "";
      homepage = section.homepage or "";
      inherit (lock)
        version
        url
        sha256
        size
        ;
      platform = section.platform or "all-platform";
      strip_prefix = lock.stripPrefix;
      update_source = section.update_source or { };
    };

  # Lock-set closure: the lock file must contain exactly the 13 components
  # plus the [[pdk_pkg]] ids, no orphans and no gaps. [platform] and [pdk]
  # are not lock entries.
  componentIds = [
    "ecc"
    "oss_cad_suite"
    "sizer"
    "mpc-frame"
  ]
  ++ toolSections;

  expectedLockIds = componentIds ++ map (pkg: pkg.id) pkgSections;

  closureCheck =
    let
      extra = builtins.filter (k: !(builtins.elem k expectedLockIds)) (builtins.attrNames locks);
      missing = builtins.filter (k: !(builtins.hasAttr k locks)) expectedLockIds;
    in
    if extra != [ ] then
      throwUn "orphan lock entries (no matching rules): ${lib.concatStringsSep ", " extra}"
    else if missing != [ ] then
      throwUn "missing lock entries for: ${lib.concatStringsSep ", " missing}"
    else
      null;

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
        builtins.attrNames (builtins.removeAttrs rules [ "pdk_pkg" ])
      );
    in
    if extra == [ ] then
      null
    else
      throwUn "unknown top-level section(s): ${lib.concatStringsSep ", " extra}";
in
builtins.deepSeq [ topCheck closureCheck pdkVersion ] (
  {
    platform = platformSection;
    ecc = eccSection;
    oss_cad_suite = ossSection;
    sizer = sizerSection;
    pdk = pdkSection;
    pdk_pkg = pkgSections;
    mpc-frame = mpcSection;
  }
  // builtins.listToAttrs (
    map (key: {
      name = key;
      value = toolSection key;
    }) toolSections
  )
)
