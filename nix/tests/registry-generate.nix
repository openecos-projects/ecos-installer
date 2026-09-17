{
  lib,
  pkgs,
  loadModel,
  registry,
  registryJson,
  toolchain,
  locks,
}:

let
  sources = {
    rules = toolchain;
    inherit locks;
  };
  model = loadModel sources;

  inherit (import ../../lib/testing.nix { inherit lib; })
    withRules
    withLocks
    withSection
    withLock
    withPkgs
    mapPkg
    ;

  tryModel = f: builtins.tryEval (loadModel (f sources));

  mustFail = name: outcome: {
    inherit name;
    ok = !outcome.success;
  };

  negativeCases = [
    (mustFail "unknown-section" (tryModel (withRules (t: t // { not_a_component = { }; }))))
    (mustFail "unknown-field" (tryModel (withSection "slang" (s: s // { post_install = [ ]; }))))
    (mustFail "retired-sha256-url" (
      tryModel (withSection "slang" (s: s // { sha256_url = "https://example.com/x.sha256"; }))
    ))
    (mustFail "retired-supplemental-assets" (
      tryModel (withSection "slang" (s: s // { supplemental_assets = [ ]; }))
    ))
    (mustFail "retired-version-field" (tryModel (withSection "slang" (s: s // { version = "11.0"; }))))
    (mustFail "missing-url" (
      tryModel (withLock "slang" (l: l // { src = builtins.removeAttrs l.src [ "url" ]; }))
    ))
    (mustFail "missing-sha256" (
      tryModel (withLock "slang" (l: builtins.removeAttrs l [ "sha256_hex" ]))
    ))
    (mustFail "missing-src-sha256" (
      tryModel (withLock "slang" (l: l // { src = builtins.removeAttrs l.src [ "sha256" ]; }))
    ))
    (mustFail "bad-sha256-format" (tryModel (withLock "slang" (l: l // { sha256_hex = "NOTHEX"; }))))
    (mustFail "non-positive-size" (tryModel (withLock "slang" (l: l // { size = 0; }))))
    (mustFail "orphan-lock" (tryModel (withLocks (l: l // { ghost = l.slang; }))))
    (mustFail "missing-lock" (tryModel (withLocks (l: builtins.removeAttrs l [ "slang" ]))))
    (mustFail "url-template-mismatch" (
      tryModel (
        withLock "slang" (
          l:
          l
          // {
            src = l.src // {
              url = "https://example.com/slang.tar.gz";
            };
          }
        )
      )
    ))
    (mustFail "unknown-version-map" (
      tryModel (withSection "slang" (s: s // { version_map = "bogus"; }))
    ))
    (mustFail "unknown-placeholder" (
      tryModel (withSection "slang" (s: s // { url_template = "https://example.com/{bogus}/s.tar.gz"; }))
    ))
    (mustFail "unknown-src-field" (
      tryModel (
        withSection "slang" (
          s:
          s
          // {
            src = s.src // {
              gitlab = "x/y";
            };
          }
        )
      )
    ))
    (mustFail "two-src-families" (
      tryModel (
        withSection "slang" (
          s:
          s
          // {
            src = s.src // {
              manual = "11.0";
            };
          }
        )
      )
    ))
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
      tryModel (withLock "slang" (l: l // { version = "latest"; }))
    ))
    (mustFail "latest-url-on-pinned-tool" (
      tryModel (
        withLock "verilator" (
          l:
          l
          // {
            src = l.src // {
              url = "https://example.com/verilator-latest.tar.gz";
            };
          }
        )
      )
    ))
    (mustFail "non-versioned-sidecar" (
      tryModel (withSection "slang" (s: s // { metadata_url = "https://example.com/slang-11.0.json"; }))
    ))
    (mustFail "oss-registry-name" (tryModel (withSection "oss_cad_suite" (s: s // { name = "oss"; }))))
    (mustFail "pkg-unknown-kind" (
      tryModel (withPkgs (pkgs: [ (builtins.head pkgs // { kind = "archive"; }) ] ++ builtins.tail pkgs))
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
    (mustFail "two-base-packages" (tryModel (withPkgs (pkgs: [ (builtins.head pkgs) ] ++ pkgs))))
    (mustFail "zero-base-packages" (
      tryModel (
        withRules (
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
      )
    ))
    (mustFail "base-with-dest" (
      tryModel (
        withPkgs (pkgs: [ (builtins.head pkgs // { dest = " somewhere"; }) ] ++ builtins.tail pkgs)
      )
    ))
    (mustFail "absolute-dest" (
      tryModel (withPkgs (mapPkg "ics55_LLSC_H7CH_liberty" (pkg: pkg // { dest = "/absolute"; })))
    ))
    (mustFail "traversal-dest" (
      tryModel (withPkgs (mapPkg "ics55_LLSC_H7CH_liberty" (pkg: pkg // { dest = "../evil"; })))
    ))
    (mustFail "same-dest-same-kind" (
      tryModel (
        withPkgs (
          mapPkg "ics55_LLSC_H7CL_liberty" (
            pkg: pkg // { dest = "IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CH"; }
          )
        )
      )
    ))
    (mustFail "liberty-outside-dests" (
      tryModel (withSection "pdk" (p: p // { liberty_files = [ "somewhere_else/not_covered.lib" ]; }))
    ))
    (mustFail "pdk-version-disagree" (
      tryModel (withLock "icsprout55-base" (l: l // { version = "v9.9.9"; }))
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
    allEntitiesPresent =
      builtins.sort builtins.lessThan (map (t: t.name) registry.tools) == [
        "ecc"
        "ecc-fe"
        "ecc-fe-cpu-rtl"
        "ecc-fe-difftest-ref"
        "ecc-fe-examples"
        "ecc-fe-soc-ysyx-am"
        "riscv-toolchain"
        "slang"
        "surfer"
        "verilator"
        "yosys"
      ]
      && map (p: p.id) registry.pdks == [ "ics55" ]
      && map (m: m.id) registry.mpcs == [ "mpc-frame" ];
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
    packagesFollowRequires =
      map (pkg: pkg.path) pdkPlatform.packages == map (pkg: pkg.name) model.pdk.assets;
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
    jq -e '[.tools[].name] | sort == ["ecc", "ecc-fe", "ecc-fe-cpu-rtl", "ecc-fe-difftest-ref", "ecc-fe-examples", "ecc-fe-soc-ysyx-am", "riscv-toolchain", "slang", "surfer", "verilator", "yosys"]' "$json"
    jq -e '[.pdks[].id] == ["ics55"] and [.mpcs[].id] == ["mpc-frame"]' "$json"
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
