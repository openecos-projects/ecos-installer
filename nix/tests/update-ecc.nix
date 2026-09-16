{
  pkgs,
  lockEdit,
}:

let
  fixture = pkgs.writeText "generated-fixture.json" (
    builtins.toJSON {
      ecc = {
        name = "ecc";
        version = "v0.1.0-alpha.12";
        src = {
          name = null;
          sha256 = "sha256-+2PZa/g+mZrOBMHSHC4HZ6tUUodWUbfMxd25YQyBgKo=";
          type = "url";
          url = "https://github.com/openecos-projects/ecc/releases/download/v0.1.0-alpha.12/ecc-cli-linux-x86_64.tar.gz";
        };
        size = 513976534;
        sha256_hex = "fb63d96bf83e999ace04c1d21c2e0767ab5452875651b7ccc5ddb9610c8180aa";
      };
      slang = {
        name = "slang";
        version = "v11.0";
        src = {
          name = null;
          sha256 = "sha256-lRaXDpCiVVTJFllQCs/NfRsjImNU6yIlGK0VhqaJjYo=";
          type = "url";
          url = "https://github.com/MikePopoloski/slang/releases/download/v11.0/slang-linux-x86_64.tar.gz";
        };
        size = 3514870;
        sha256_hex = "951a170e10e25e54c91565030acfdfc11c3226714ebf225a18ad4166a898d8a4";
      };
    }
  );

  script = ''
    set -euo pipefail
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    canon() {
      jq -j -S --indent 4 . "$1"
    }

    # Update the ecc entry; the decoy entry must stay untouched and the
    # canonical jq formatting must be preserved.
    cp ${fixture} "$work/case1.json"
    before_slang="$(jq -S .slang "$work/case1.json")"
    ${lockEdit} set "$work/case1.json" ecc v9.9.9 \
      "https://github.com/openecos-projects/ecc/releases/download/v9.9.9/ecc-cli-linux-x86_64.tar.gz" \
      "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
      42

    jq -e '.ecc.version == "v9.9.9"' "$work/case1.json" >/dev/null
    jq -e '.ecc.size == 42' "$work/case1.json" >/dev/null
    jq -e '.ecc.src.url | endswith("v9.9.9/ecc-cli-linux-x86_64.tar.gz")' "$work/case1.json" >/dev/null
    jq -e '.ecc.src.sha256 == "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' "$work/case1.json" >/dev/null
    jq -e '.ecc.sha256_hex == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"' "$work/case1.json" >/dev/null
    test "$(jq -S .slang "$work/case1.json")" = "$before_slang"
    canon "$work/case1.json" | cmp - "$work/case1.json"

    # A missing entry fails without touching the file.
    cp ${fixture} "$work/case2.json"
    before="$(sha256sum "$work/case2.json" | cut -d' ' -f1)"
    if ${lockEdit} set "$work/case2.json" nosuch v1.0 "https://example.com/x.tar.gz" \
      "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
      0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
      5 >"$work/err.log" 2>&1; then
      echo 'edit of a missing entry should fail' >&2
      exit 1
    fi
    grep -q 'missing lock entry: nosuch' "$work/err.log"
    after="$(sha256sum "$work/case2.json" | cut -d' ' -f1)"
    test "$before" = "$after"

    echo ok > "$out"
  '';

in
pkgs.runCommand "ecos-release-update-ecc-locks-check" {
  nativeBuildInputs = [
    pkgs.jq
    pkgs.coreutils
  ];
} script
