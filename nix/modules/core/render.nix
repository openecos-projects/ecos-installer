# Render layer: turn the merged model into the two published artifacts
# (the installer text and the registry attrset). Absorbs the former
# nix/release/{installer,registry}.nix functions; with everything inside
# the module system, lib comes from the module arguments.
{ ... }:

{
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      ecos = config.ecos;
      model = ecos.model;

      # ---- installer render (formerly nix/release/installer.nix) ----
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
      rendered = builtins.replaceStrings from to ecos.template;
      leftover = builtins.filter (k: lib.hasInfix k rendered) from;
      leftoverAny = builtins.any (line: builtins.match ".*@[A-Z][A-Z0-9_]*@.*" line != null) (
        lib.splitString "\n" rendered
      );
      unix = builtins.replaceStrings [ "\r\n" ] [ "\n" ] rendered;

      generated =
        if leftover != [ ] then
          throw "unsubstituted installer placeholders: ${lib.concatStringsSep ", " leftover}"
        else if leftoverAny then
          throw "unsubstituted installer placeholder remains"
        else if lib.hasSuffix "\n" unix then
          unix
        else
          unix + "\n";

      # ---- registry projection (formerly nix/release/registry.nix) ----
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

      registry = {
        schema_version = 2;
        tools = tools;
        pdks = [ pdkEntity ];
        mpcs = [ mpcEntity ];
      };
    in
    {
      ecos = {
        inherit generated registry;
        eccInstaller = pkgs.writeTextFile {
          name = "ecc-installer.sh";
          executable = true;
          text = generated;
          checkPhase = ''
            ${pkgs.dash}/bin/dash -n "$target"
            ${pkgs.bash}/bin/bash -n "$target"
          '';
        };
        toolRegistry = pkgs.writeText "tool-registry.json" (builtins.toJSON registry);
      };
    };
}
