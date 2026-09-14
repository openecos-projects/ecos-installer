{
  lib,
  pkgs,
  loadModel,
  generateRegistry,
  registry,
  registryJson,
  toolchain,
}:

let
  model = loadModel toolchain;

  tryModel = f: builtins.tryEval (loadModel (f toolchain));

  mustFail = name: outcome: {
    inherit name;
    ok = !outcome.success;
  };

  # Returns a manifest mutator function for tryModel.
  withSection =
    name: f: t:
    t // { ${name} = f t.${name}; };

  mapPkg = id: f: map (pkg: if pkg.id == id then f pkg else pkg);

  negativeCases = [
    (mustFail "unknown-section" (tryModel (t: t // { not_a_component = { }; })))
    (mustFail "unknown-field" (tryModel (withSection "slang" (s: s // { post_install = [ ]; }))))
    (mustFail "retired-sha256-url" (
      tryModel (withSection "slang" (s: s // { sha256_url = "https://example.com/x.sha256"; }))
    ))
    (mustFail "retired-supplemental-assets" (
      tryModel (withSection "slang" (s: s // { supplemental_assets = [ ]; }))
    ))
    (mustFail "missing-url" (tryModel (withSection "slang" (s: builtins.removeAttrs s [ "url" ]))))
    (mustFail "missing-sha256" (
      tryModel (withSection "slang" (s: builtins.removeAttrs s [ "sha256" ]))
    ))
    (mustFail "bad-sha256-format" (tryModel (withSection "slang" (s: s // { sha256 = "NOTHEX"; }))))
    (mustFail "non-positive-size" (tryModel (withSection "slang" (s: s // { size = 0; }))))
    (mustFail "unknown-category" (tryModel (withSection "slang" (s: s // { category = "compiler"; }))))
    (mustFail "all-platform-tool" (
      tryModel (withSection "slang" (s: s // { platform = "all-platform"; }))
    ))
    (mustFail "dangling-requires" (
      tryModel (withSection "slang" (s: s // { requires = [ "tool:nope" ]; }))
    ))
    (mustFail "malformed-requires" (
      tryModel (withSection "slang" (s: s // { requires = [ "yosys" ]; }))
    ))
    (mustFail "mutable-latest-on-pinned-tool" (
      tryModel (withSection "slang" (s: s // { version = "latest"; }))
    ))
    (mustFail "oss-registry-name" (tryModel (withSection "oss_cad_suite" (s: s // { name = "oss"; }))))
    (mustFail "pkg-unknown-kind" (
      tryModel (
        t:
        t
        // {
          pdk_pkg = [ (builtins.head t.pdk_pkg // { kind = "archive"; }) ] ++ builtins.tail t.pdk_pkg;
        }
      )
    ))
    (mustFail "dangling-pkg-reference" (
      tryModel (
        withSection "pdk" (
          p:
          p
          // {
            requires = [
              "pdk_pkg:icsprout55-base"
              "pdk_pkg:does_not_exist"
            ];
          }
        )
      )
    ))
    (mustFail "orphan-pkg" (
      tryModel (
        withSection "pdk" (
          p: p // { requires = builtins.filter (dep: dep != "pdk_pkg:ics55_LLSC_H7CR_gds") p.requires; }
        )
      )
    ))
    (mustFail "two-base-packages" (
      tryModel (t: t // { pdk_pkg = [ (builtins.head t.pdk_pkg) ] ++ t.pdk_pkg; })
    ))
    (mustFail "zero-base-packages" (
      tryModel (
        t:
        let
          noBase = builtins.filter (pkg: pkg.kind != "base") t.pdk_pkg;
        in
        t
        // {
          pdk_pkg = noBase;
          pdk = t.pdk // {
            requires = map (pkg: "pdk_pkg:${pkg.id}") noBase;
          };
        }
      )
    ))
    (mustFail "base-with-dest" (
      tryModel (
        t:
        t
        // {
          pdk_pkg = [ (builtins.head t.pdk_pkg // { dest = " somewhere"; }) ] ++ builtins.tail t.pdk_pkg;
        }
      )
    ))
    (mustFail "absolute-dest" (
      tryModel (
        t:
        t
        // {
          pdk_pkg = mapPkg "ics55_LLSC_H7CH_liberty" (pkg: pkg // { dest = "/absolute"; }) t.pdk_pkg;
        }
      )
    ))
    (mustFail "traversal-dest" (
      tryModel (
        t:
        t
        // {
          pdk_pkg = mapPkg "ics55_LLSC_H7CH_liberty" (pkg: pkg // { dest = "../evil"; }) t.pdk_pkg;
        }
      )
    ))
    (mustFail "same-dest-same-kind" (
      tryModel (
        t:
        t
        // {
          pdk_pkg = mapPkg "ics55_LLSC_H7CL_liberty" (
            pkg: pkg // { dest = "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CH"; }
          ) t.pdk_pkg;
        }
      )
    ))
    (mustFail "liberty-outside-dests" (
      tryModel (withSection "pdk" (p: p // { liberty_files = [ "somewhere_else/not_covered.lib" ]; }))
    ))
    (mustFail "bad-update-source-type" (
      tryModel (
        withSection "mpc-frame" (
          m:
          m
          // {
            update_source = {
              type = "gitlab_branch";
              branch = "main";
            };
          }
        )
      )
    ))
    (mustFail "bad-update-source-field" (
      tryModel (
        withSection "mpc-frame" (
          m:
          m
          // {
            update_source = {
              type = "github_branch";
              branch = "main";
              commit = "x";
            };
          }
        )
      )
    ))
  ];

  pdkVersion = builtins.head ((builtins.head registry.pdks).versions);
  pdkPlatform = pdkVersion.platforms.all-platform;
  mpcVersion = builtins.head ((builtins.head registry.mpcs).versions);

  # Positive shape assertions on the projected attrset (the jq block below
  # re-checks the rendered JSON file).
  registryChecks = {
    schemaVersion = registry.schema_version == 2;
    counts =
      builtins.length registry.tools == 11
      && builtins.length registry.pdks == 1
      && builtins.length registry.mpcs == 1;
    singleVersion = builtins.all (entity: builtins.length entity.versions == 1) (
      registry.tools ++ registry.pdks ++ registry.mpcs
    );
    noSizerEntity = builtins.all (t: t.name != "ecc-sizer") registry.tools;
    yosysProjectsFromOss = builtins.any (
      t: t.name == "yosys" && (builtins.head t.versions).version == model.ossCadSuite.version
    ) registry.tools;
    pdkVersionStripsV = pdkVersion.version == "1.10.102" && model.pdk.version == "v1.10.102";
    pdkPackagesShape =
      let
        expectedKeys = [
          "cnb_url"
          "dest"
          "path"
          "sha256"
          "size"
          "url"
        ];
      in
      builtins.length pdkPlatform.packages == 7
      && builtins.all (pkg: builtins.attrNames pkg == expectedKeys) pdkPlatform.packages
      && pdkPlatform ? url
      && pdkPlatform ? sha256
      && pdkPlatform ? size
      && pdkPlatform ? strip_prefix;
    mpcUpdateSource =
      mpcVersion.platforms.all-platform.update_source == {
        type = "github_branch";
        branch = "main";
      };
    requiresClosed =
      let
        ids = map (t: t.name) registry.tools ++ map (p: p.id) registry.pdks;
        deps = builtins.concatMap (t: (builtins.head t.versions).requires) registry.tools;
      in
      builtins.all (dep: builtins.elem (lib.removePrefix "tool:" (lib.removePrefix "pdk:" dep)) ids) deps;
  };

  failedNegatives = builtins.filter (c: !c.ok) negativeCases;
  failedPositives = lib.filterAttrs (_: ok: !ok) registryChecks;

  negativeScript = lib.concatMapStrings (
    c:
    lib.optionalString (!c.ok) ''
      echo 'negative case should have failed: ${c.name}' >&2
      exit 1
    ''
  ) negativeCases;

  positiveScript = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: _: ''
      echo 'registry projection check failed: ${name}' >&2
      exit 1
    '') failedPositives
  );

  jqScript = ''
    json="${registryJson}"
    test -s "$json"
    jq -e '.schema_version == 2' "$json"
    jq -e '(.tools | length) == 11 and (.pdks | length) == 1 and (.mpcs | length) == 1' "$json"
    jq -e 'all(.tools[], .pdks[], .mpcs[]; (.versions | length) == 1)' "$json"
    jq -e '[.tools[].name] | (index("ecc") and index("yosys") and (index("ecc-sizer") | not))' "$json"
    jq -e '.pdks[0].versions[0].version == "1.10.102"' "$json"
    jq -e '.pdks[0].versions[0] | (has("requires") | not)' "$json"
    jq -e '.pdks[0].versions[0].platforms["all-platform"] | (has("post_install") or has("supplemental_assets") | not)' "$json"
    jq -e '(.pdks[0].versions[0].platforms["all-platform"].packages | length) == 7' "$json"
    jq -e 'all(.pdks[0].versions[0].platforms["all-platform"].packages[]; has("path") and has("url") and has("cnb_url") and has("sha256") and has("size") and has("dest"))' "$json"
    jq -e '.mpcs[0].versions[0].platforms["all-platform"].update_source == {"type": "github_branch", "branch": "main"}' "$json"
    jq -e '([.tools[] | select(.name == "yosys") | .versions[0].version] | length) == 1' "$json"
    jq -e '([.tools[].name] + [.pdks[].id]) as $ids
      | [.tools[].versions[].requires[]] as $deps
      | all($deps[]; . as $d | $ids | index($d | ltrimstr("tool:") | ltrimstr("pdk:")))' "$json"
    if grep -qE '"(post_install|supplemental_assets|sha256_url)"' "$json"; then
      echo 'retired registry field present' >&2
      exit 1
    fi
  '';
in
pkgs.runCommand "ecos-release-registry-generate-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
  set -euo pipefail
  ${negativeScript}
  ${positiveScript}
  ${jqScript}
  echo ok > "$out"
''
