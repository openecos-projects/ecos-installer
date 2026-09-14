{ lib }:

# Project the validated release model into the tool-registry.json attrset.
# The mapping from manifest sections to registry entities is an explicit
# whitelist: [ecc] becomes the "ecc" tool, [oss_cad_suite] becomes the
# "yosys" tool, [sizer] and [platform] are installer-only, the plain tool
# sections map one-to-one, the PDK collection folds its base package into
# the platform lock and the remaining pdk_pkg entries into a packages
# array, and [mpc-frame] projects verbatim including its update_source.
# JSON key order is decided by builtins.toJSON (sorted); entity order is
# normalised here by sorting on id.

{
  model,
}:

let
  optionalStringField = value: name: lib.optionalAttrs (value != "") { ${name} = value; };

  platformEntry =
    tool:
    {
      url = tool.url;
      sha256 = tool.sha256;
      size = tool.size;
    }
    // optionalStringField tool.metadataUrl "metadata_url"
    // optionalStringField tool.stripPrefix "strip_prefix";

  toolEntity = tool: {
    name = tool.name;
    display_name = tool.displayName;
    description = tool.description;
    category = tool.category;
    homepage = tool.homepage;
    versions = [
      {
        version = tool.version;
        platforms.${tool.platform} = platformEntry tool;
        requires = tool.requires;
      }
    ];
  };

  # The installer model keeps the PDK version's leading "v" (it is part of
  # the on-disk install path); the registry publishes the bare number so
  # client version comparisons stay unchanged.
  pdkEntity =
    let
      pdk = model.pdk;
    in
    {
      id = pdk.id;
      display_name = pdk.displayName;
      description = pdk.description;
      category = pdk.category;
      homepage = pdk.homepage;
      versions = [
        {
          version = lib.removePrefix "v" pdk.version;
          platforms.all-platform = {
            url = pdk.base.url;
            sha256 = pdk.base.sha256;
            size = pdk.base.size;
            strip_prefix = pdk.base.stripPrefix;
            packages = map (pkg: {
              path = pkg.name;
              url = pkg.url;
              cnb_url = pkg.cnbUrl;
              sha256 = pkg.sha256;
              size = pkg.size;
              dest = pkg.dest;
            }) pdk.assets;
          };
        }
      ];
    };

  mpcEntity =
    let
      mpc = model.mpc;
    in
    {
      id = mpc.id;
      display_name = mpc.displayName;
      description = mpc.description;
      category = mpc.category;
      homepage = mpc.homepage;
      versions = [
        {
          version = mpc.version;
          platforms.${mpc.platform} = {
            url = mpc.url;
            sha256 = mpc.sha256;
            size = mpc.size;
            strip_prefix = mpc.stripPrefix;
            update_source = {
              type = mpc.updateSource.type;
              branch = mpc.updateSource.branch;
            };
          };
        }
      ];
    };

  tools = builtins.sort (a: b: a.name < b.name) (
    map toolEntity (
      [
        {
          name = model.ecc.tool.name;
          displayName = model.ecc.tool.displayName;
          description = model.ecc.tool.description;
          category = model.ecc.tool.category;
          homepage = model.ecc.tool.homepage;
          requires = model.ecc.tool.requires;
          version = model.ecc.version;
          platform = "linux-x86_64";
          url = model.ecc.url;
          sha256 = model.ecc.sha256;
          size = model.ecc.size;
          metadataUrl = "";
          stripPrefix = "";
        }
        {
          name = model.ossCadSuite.tool.name;
          displayName = model.ossCadSuite.tool.displayName;
          description = model.ossCadSuite.tool.description;
          category = model.ossCadSuite.tool.category;
          homepage = model.ossCadSuite.tool.homepage;
          requires = model.ossCadSuite.tool.requires;
          version = model.ossCadSuite.version;
          platform = "linux-x86_64";
          url = model.ossCadSuite.url;
          sha256 = model.ossCadSuite.sha256;
          size = model.ossCadSuite.size;
          metadataUrl = "";
          stripPrefix = model.ossCadSuite.stripPrefix;
        }
      ]
      ++ model.tools
    )
  );
in
{
  schema_version = 2;
  tools = tools;
  pdks = [ pdkEntity ];
  mpcs = [ mpcEntity ];
}
