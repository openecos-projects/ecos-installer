{
  lib,
  rules,
  locks,
}:

# Merge metadata/toolchain.toml (rules) with nix/_sources/generated.json (locks)
# into the manifest attrset that nix/model.nix validates and projects.
#
# Rules carry metadata, version-source rules (src), and interpolation
# templates; locks carry the resolved version/url/sha256/size data. Every
# lock-driven value is derived here and every consistency assertion between
# the two sources fires here, so model.nix keeps validating a single
# manifest exactly as before.

let
  throwUn = msg: throw "invalid rules/locks: ${msg}";

  stripV = s: lib.removePrefix "v" s;

  # version_map: absent/"identity" | "strip_dashes" | { strip_prefix = "..." }
  applyVersionMap =
    label: vm: version:
    if vm == null || vm == "identity" then
      version
    else if vm == "strip_dashes" then
      lib.replaceStrings [ "-" ] [ "" ] version
    else if builtins.isAttrs vm && builtins.attrNames vm == [ "strip_prefix" ] then
      if builtins.isString vm.strip_prefix && vm.strip_prefix != "" then
        if lib.hasPrefix vm.strip_prefix version then
          lib.removePrefix vm.strip_prefix version
        else
          throwUn "${label}: version_map strip_prefix \"${vm.strip_prefix}\" does not prefix version ${version}"
      else
        throwUn "${label}: version_map strip_prefix must be a non-empty string"
    else
      throwUn "${label}: unknown version_map (expected identity, strip_dashes, or { strip_prefix = ... })";

  # Template interpolation. {version^}/{registry^} replace first: at any
  # position they must win over the {version}/{registry} prefixes.
  interpolate =
    label: tmpl: version: registryVersion:
    if !builtins.isString tmpl then
      throwUn "${label}: template must be a string, got ${builtins.typeOf tmpl}"
    else
      let
        replaced =
          lib.replaceStrings
            [ "{version^}" "{version}" "{registry^}" "{registry}" ]
            [
              (stripV version)
              version
              (stripV registryVersion)
              registryVersion
            ]
            tmpl;
      in
      if lib.hasInfix "{" replaced || lib.hasInfix "}" replaced then
        throwUn "${label}: template has unknown placeholder(s): ${tmpl}"
      else
        replaced;

  hexSha = s: builtins.isString s && builtins.match "[0-9a-f]{64}" s != null;

  # Lock entry shape validation. These assertions are also the format-drift
  # guard: an nvfetcher upgrade that changes the generated.json serialization
  # fails here with a readable error at eval time.
  requireLock =
    id:
    let
      e = locks.${id} or (throwUn "missing lock entry: ${id}");
      version =
        if !(e ? version) || !builtins.isString e.version || e.version == "" then
          throwUn "lock ${id}: missing version field"
        else
          e.version;
      src = e.src or (throwUn "lock ${id}: missing src field");
      url =
        if !(src ? url) || !builtins.isString src.url || src.url == "" then
          throwUn "lock ${id}: missing src.url"
        else
          src.url;
      sri =
        if !(src ? sha256) || !builtins.isString src.sha256 || !(lib.hasPrefix "sha256-" src.sha256) then
          throwUn "lock ${id}: src.sha256 must be in SRI form sha256-<base64>"
        else
          src.sha256;
      hex =
        if !(e ? sha256_hex) || !hexSha e.sha256_hex then
          throwUn "lock ${id}: sha256_hex must be 64 lowercase hex chars"
        else
          e.sha256_hex;
      size =
        if !(e ? size) || !builtins.isInt e.size || e.size <= 0 then
          throwUn "lock ${id}: size must be a positive integer"
        else
          e.size;
      name =
        if !(src ? name) || (src.name != null && !builtins.isString src.name) then
          throwUn "lock ${id}: src.name must be null or a string"
        else
          src.name;
      cnbSha256 =
        if !(e ? cnb_sha256) || e.cnb_sha256 == null then
          null
        else if !hexSha e.cnb_sha256 then
          throwUn "lock ${id}: cnb_sha256 must be 64 lowercase hex chars"
        else
          e.cnb_sha256;
    in
    # Force the shape validations: consumers only use some of these fields,
    # so a lazily-bound field (e.g. the SRI drift guard) would otherwise
    # never report its error.
    builtins.deepSeq [ version url sri hex size name ] {
      inherit
        version
        url
        sri
        hex
        size
        name
        cnbSha256
        ;
    };

  # Sections whose url_template interpolation is allowed to disagree with the
  # locked src.url. mpc-frame only: the 0.1.0 seed version predates the
  # commit-form versions the url_template produces; the exemption goes away
  # with the first bump that advances the version to commit form.
  urlAssertExempt = [ "mpc-frame" ];

  # Merge one rules section with its lock entry into the lock-driven fields.
  mergeLock =
    label: section:
    let
      lock = requireLock label;
      regVersion = applyVersionMap "${label}.version_map" (section.version_map or null) lock.version;
      interpolate' = field: interpolate "${label}.${field}" section.${field} lock.version regVersion;
      urlCheck =
        if
          section ? url_template
          && interpolate' "url_template" != lock.url
          && !(builtins.elem label urlAssertExempt)
        then
          throwUn "${label}: url_template resolves to ${interpolate' "url_template"} but the lock carries ${lock.url}"
        else
          null;
      nameCheck =
        if section ? name_template && lock.name != interpolate' "name_template" then
          throwUn "${label}: name_template resolves to ${interpolate' "name_template"} but the lock carries ${
            if lock.name == null then "null" else lock.name
          }"
        else
          null;
      cnbCheck =
        if (section.needs_cnb_sha256 or false) && lock.cnbSha256 == null then
          throwUn "${label}: needs_cnb_sha256 is set but the lock has no cnb_sha256"
        else if !(section.needs_cnb_sha256 or false) && lock.cnbSha256 != null then
          throwUn "${label}: the lock carries cnb_sha256 but needs_cnb_sha256 is not set"
        else
          null;
    in
    builtins.deepSeq [ urlCheck nameCheck cnbCheck ] {
      version = regVersion;
      url = lock.url;
      sha256 = lock.hex;
      size = lock.size;
      assetName = if lock.name != null then lock.name else builtins.baseNameOf lock.url;
      cnbUrl = if section ? cnb_url_template then interpolate' "cnb_url_template" else null;
      stripPrefix = if section ? strip_prefix then interpolate' "strip_prefix" else null;
      inherit (lock) cnbSha256;
    };

  # Closed field sets for the rules schema (same role as model.nix's
  # checkFields on the merged manifest).
  checkFields =
    label: allowed: section:
    let
      unknown = builtins.filter (k: !builtins.elem k allowed) (builtins.attrNames section);
    in
    if unknown == [ ] then
      section
    else
      throwUn "unknown field(s) in [${label}]: ${lib.concatStringsSep ", " unknown}";

  srcRuleKeys = [
    "github"
    "prerelease"
    "github_tag"
    "include_regex"
    "git"
    "branch"
    "manual"
  ];

  ownerRepoPattern = "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";

  checkSrc =
    label: section:
    let
      src = section.src or (throwUn "${label}: missing src rule");
      unknown = builtins.filter (k: !(builtins.elem k srcRuleKeys)) (builtins.attrNames src);
      families = builtins.filter (k: builtins.hasAttr k src) [
        "github"
        "github_tag"
        "git"
        "manual"
      ];
    in
    if !builtins.isAttrs src then
      throwUn "${label}: src must be a table"
    else if unknown != [ ] then
      throwUn "${label}: unknown src field(s): ${lib.concatStringsSep ", " unknown}"
    else if builtins.length families != 1 then
      throwUn "${label}: src must set exactly one of github, github_tag, git, manual"
    else if (src ? prerelease) && !(src ? github) then
      throwUn "${label}: src.prerelease requires src.github"
    else if (src ? include_regex) && !(src ? github_tag) then
      throwUn "${label}: src.include_regex requires src.github_tag"
    else if (src ? branch) && !(src ? git) then
      throwUn "${label}: src.branch requires src.git"
    else if (src ? github) && builtins.match ownerRepoPattern src.github == null then
      throwUn "${label}: src.github must look like owner/repo: ${src.github}"
    else if (src ? github_tag) && builtins.match ownerRepoPattern src.github_tag == null then
      throwUn "${label}: src.github_tag must look like owner/repo: ${src.github_tag}"
    else if (src ? manual) && !(builtins.isString src.manual && src.manual != "") then
      throwUn "${label}: src.manual must be a non-empty string"
    else
      src;

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
