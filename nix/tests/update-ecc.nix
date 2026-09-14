{
  pkgs,
  eccTomlEdit,
}:

let
  fixture = pkgs.writeText "toolchain-fixture.toml" ''
    [platform]
    os = "linux"
    cpu = "x86_64"
    min_glibc = "2.34"

    [oss_cad_suite]
    version = "20260827"
    asset_name = "oss-cad-suite-linux-x64-20260827.tgz"
    url = "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-08-27/oss-cad-suite-linux-x64-20260827.tgz"
    cnb_url = "https://cnb.cool/ecoslab/oss-cad-suite-build/-/releases/download/2026-08-27/oss-cad-suite-linux-x64-20260827.tgz"
    sha256 = "c3ffafe1549d5bf321b85e6ac30b3bc6af0af72093d5f45117380bcc0645a8e2"
    size = 740836017
    strip_prefix = "oss-cad-suite"

    [ecc]
    name = "ecc"
    github_repo = "openecos-projects/ecc"
    asset_name = "ecc-cli-linux-x86_64.tar.gz"
    cnb_url_template = "https://cnb.cool/ecoslab/ecc/-/releases/download/{tag}/{name}"
    version = "0.1.0-alpha.11"
    url = "https://github.com/openecos-projects/ecc/releases/download/v0.1.0-alpha.11/ecc-cli-linux-x86_64.tar.gz"
    cnb_url = "https://cnb.cool/ecoslab/ecc/-/releases/download/v0.1.0-alpha.11/ecc-cli-linux-x86_64.tar.gz"
    sha256 = "ef34c53631c902bc6f4a99ec08fcaf2a5815e2d59acb68849ce6895c69e08dba"
    size = 513992667

    [sizer]
    # decoys: same key names as [ecc], must stay untouched by the editor
    github_repo = "decoy/sizer-repo"
    asset_name = "decoy-sizer.tar.gz"
    cnb_url_template = "https://cnb.cool/decoy/-/releases/download/{tag}/{name}"
    version = "0.1.0-alpha"
    url = "https://github.com/decoy/sizer/releases/download/v0.1.0-alpha/decoy.tar.gz"
    cnb_url = "https://cnb.cool/decoy/-/releases/download/v0.1.0-alpha/decoy.tar.gz"
    sha256 = "d33a2167600711f35fb1dcef55983b0d669176988d8722ed8b22c03471dafee7"
    size = 85803792
  '';

  # [ecc] is not the first component section; reads must still come from it.
  decoyFirst = pkgs.writeText "toolchain-decoy-first.toml" ''
    [slang]
    name = "slang"
    display_name = "Slang"
    description = "decoy"
    category = "frontend"
    homepage = "https://github.com/MikePopoloski/slang"
    requires = []
    version = "99.0"
    url = "https://github.com/MikePopoloski/slang/releases/download/v99.0/slang-linux-x86_64.tar.gz"
    sha256 = "951a170e10e25e54c91565030acfdfc11c3226714ebf225a18ad4166a898d8a4"
    size = 3514870

    [ecc]
    name = "ecc"
    github_repo = "openecos-projects/ecc"
    asset_name = "ecc-cli-linux-x86_64.tar.gz"
    cnb_url_template = "https://cnb.cool/ecoslab/ecc/-/releases/download/{tag}/{name}"
    version = "0.1.0-alpha.11"
    url = "https://github.com/openecos-projects/ecc/releases/download/v0.1.0-alpha.11/ecc-cli-linux-x86_64.tar.gz"
    cnb_url = "https://cnb.cool/ecoslab/ecc/-/releases/download/v0.1.0-alpha.11/ecc-cli-linux-x86_64.tar.gz"
    sha256 = "ef34c53631c902bc6f4a99ec08fcaf2a5815e2d59acb68849ce6895c69e08dba"
    size = 513992667

    [sizer]
    version = "0.1.0-alpha"
    url = "https://github.com/decoy/sizer/releases/download/v0.1.0-alpha/decoy.tar.gz"
    cnb_url = "https://cnb.cool/decoy/-/releases/download/v0.1.0-alpha/decoy.tar.gz"
    sha256 = "d33a2167600711f35fb1dcef55983b0d669176988d8722ed8b22c03471dafee7"
    size = 85803792
  '';

  missingKey = pkgs.writeText "toolchain-missing-key.toml" ''
    [ecc]
    version = "0.1.0-alpha.11"
    url = "https://github.com/openecos-projects/ecc/releases/download/v0.1.0-alpha.11/ecc-cli-linux-x86_64.tar.gz"
    cnb_url = "https://cnb.cool/ecoslab/ecc/-/releases/download/v0.1.0-alpha.11/ecc-cli-linux-x86_64.tar.gz"
    sha256 = "ef34c53631c902bc6f4a99ec08fcaf2a5815e2d59acb68849ce6895c69e08dba"

    [sizer]
    version = "0.1.0-alpha"
  '';

  script = ''
    set -euo pipefail
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    cp ${fixture} "$work/case1.toml"

    # Section-scoped reads.
    got_repo="$(${eccTomlEdit} get "$work/case1.toml" github_repo)"
    got_name="$(${eccTomlEdit} get "$work/case1.toml" asset_name)"
    got_template="$(${eccTomlEdit} get "$work/case1.toml" cnb_url_template)"
    test "$got_repo" = "openecos-projects/ecc"
    test "$got_name" = "ecc-cli-linux-x86_64.tar.gz"
    test "$got_template" = "https://cnb.cool/ecoslab/ecc/-/releases/download/{tag}/{name}"

    # Only the [ecc] section is rewritten.
    ${eccTomlEdit} set "$work/case1.toml" 9.9.9 \
      "https://github.com/openecos-projects/ecc/releases/download/v9.9.9/ecc-cli-linux-x86_64.tar.gz" \
      "https://cnb.cool/ecoslab/ecc/-/releases/download/v9.9.9/ecc-cli-linux-x86_64.tar.gz" \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
      42

    grep -q '^version = "9.9.9"$' "$work/case1.toml"
    grep -q '^size = 42$' "$work/case1.toml"
    grep -q 'v9.9.9/ecc-cli-linux-x86_64.tar.gz' "$work/case1.toml"
    grep -q 'decoy/sizer-repo' "$work/case1.toml"
    grep -q 'decoy-sizer.tar.gz' "$work/case1.toml"
    grep -q '^version = "0.1.0-alpha"$' "$work/case1.toml"
    # The sizer section keeps its old url/cnb_url bytes.
    grep -q 'download/v0.1.0-alpha/decoy.tar.gz' "$work/case1.toml"

    # Reads survive a decoy section placed before [ecc].
    cp ${decoyFirst} "$work/case2.toml"
    got_ver="$(${eccTomlEdit} get "$work/case2.toml" version)"
    test "$got_ver" = "0.1.0-alpha.11"
    ${eccTomlEdit} set "$work/case2.toml" 8.8.8 \
      "https://github.com/openecos-projects/ecc/releases/download/v8.8.8/ecc-cli-linux-x86_64.tar.gz" \
      "https://cnb.cool/ecoslab/ecc/-/releases/download/v8.8.8/ecc-cli-linux-x86_64.tar.gz" \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
      7
    grep -q '^version = "99.0"$' "$work/case2.toml"
    grep -q '^version = "8.8.8"$' "$work/case2.toml"
    grep -q '^version = "0.1.0-alpha"$' "$work/case2.toml"

    # A missing required key fails without touching the file.
    cp ${missingKey} "$work/case3.toml"
    before="$(sha256sum "$work/case3.toml" | cut -d' ' -f1)"
    if ${eccTomlEdit} set "$work/case3.toml" 7.7.7 \
      "https://github.com/openecos-projects/ecc/releases/download/v7.7.7/ecc-cli-linux-x86_64.tar.gz" \
      "https://cnb.cool/ecoslab/ecc/-/releases/download/v7.7.7/ecc-cli-linux-x86_64.tar.gz" \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
      5 >"$work/err.log" 2>&1; then
      echo 'edit with missing key should fail' >&2
      exit 1
    fi
    grep -q 'missing .ecc. key size' "$work/err.log"
    after="$(sha256sum "$work/case3.toml" | cut -d' ' -f1)"
    test "$before" = "$after"

    echo ok > "$out"
  '';

in
pkgs.runCommand "ecos-release-update-ecc-toml-check" {
  nativeBuildInputs = [
    pkgs.gawk
    pkgs.gnused
    pkgs.coreutils
  ];
} script
