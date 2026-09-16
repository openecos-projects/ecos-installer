{ lib }:

# Shared helpers for the rules/locks world: template and version_map
# algebra, lock entry shape validation, the rules src-rule schema, and the
# rules+lock merge. Everything here is stateless; callers curry in the data
# (`requireLock locks`, `mergeLock { inherit locks; ... }`).

rec {
  throwUn = msg: throw "invalid rules/locks: ${msg}";

  hexSha = s: builtins.isString s && builtins.match "[0-9a-f]{64}" s != null;

  # Closed field sets: unknown fields fail with a readable error.
  checkFields =
    label: allowed: section:
    let
      unknown = builtins.filter (k: !builtins.elem k allowed) (builtins.attrNames section);
    in
    if unknown == [ ] then
      section
    else
      throwUn "unknown field(s) in [${label}]: ${lib.concatStringsSep ", " unknown}";

  stripV = s: lib.removePrefix "v" s;

  # version_map: null/"identity" | "strip_dashes" | { strip_prefix = "..." }
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

  # Lock entry shape validation, curried over the lock attrset. These
  # assertions are also the format-drift guard: an nvfetcher upgrade that
  # changes the generated.json serialization fails here with a readable
  # error at eval time.
  requireLock =
    locks: id:
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

  # Merge one rules section with its lock entry into the lock-driven fields.
  # urlAssertExempt lists sections whose url_template interpolation may
  # disagree with the locked src.url (mpc-frame: the 0.1.0 seed version
  # predates the commit-form versions the url_template produces).
  mergeLock =
    {
      locks,
      urlAssertExempt ? [ ],
    }:
    label: section:
    let
      lock = requireLock locks label;
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
}
