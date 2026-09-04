# ecos-release

Generates and publishes the POSIX ECC installer. End users still install with `curl | sh`; they do not need Nix.

Supported platform: Linux x86_64, glibc ≥ 2.34.

## Install ECC

```sh
curl -fsSL https://release.openecos.com/installers/ecc/latest/ecc-installer.sh | sh
```

With OSS CAD Suite, the ICS55 PDK, and ecc-sizer:

```sh
curl -fsSL https://release.openecos.com/installers/ecc/latest/ecc-installer.sh | sh -s -- --with-toolchain
```

`--download-source auto|github|cnb` selects the mirror (`auto` tries GitHub, then CNB). The PDK base archive is GitHub-only, and ecc-sizer has no CNB mirror yet, so it always downloads from GitHub.

If GitHub is unreachable, set a prefix that replaces `https://github.com`:

```sh
export ECC_GITHUB_BASE_URL=https://ghfast.top/https://github.com
curl -fsSL https://release.openecos.com/installers/ecc/latest/ecc-installer.sh | sh
```

CNB URLs are not rewritten. Direct OSS URLs skip Cloudflare and are not counted in Google Analytics.

Data lands in `$XDG_DATA_HOME/ecc` (or `~/.local/share/ecc`). The wrapper goes to `$XDG_BIN_HOME` or `~/.local/bin`. `ECC_INSTALL_DIR` overrides the data root and must be an absolute path.

## Generate and publish

Pins live in `metadata/toolchain.toml`. The installer source is `templates/ecc-installer.sh.in`.

```sh
nix fmt                          # format Nix, Python, TOML, YAML, and shell
nix build .#ecc-installer        # write ecc-installer.sh; does not fetch real archives
nix run .#update-ecc -- v<tag>   # prefetch the ECC GitHub asset and update the [ecc] pin
nix run .#publish-oss -- v<tag>  # PUT the immutable versioned object; advance latest by SemVer 2.0.0
```

`update-ecc` only rewrites ECC pins. Bump OSS CAD Suite, ecc-sizer, or the PDK by editing the TOML; for ecc-sizer keep `asset_name` in sync with `version` (`ecc-sizer-<version>-linux-x64.tar.gz`) and fill `cnb_url` plus `cnb_sha256` once a CNB mirror exists.

Publishing needs `OSS_ACCESS_KEY_ID` and `OSS_ACCESS_KEY_SECRET`. A versioned object cannot be overwritten with different bytes. `latest` never moves to an older SemVer.

## Google Analytics

`curl | sh` does not run JavaScript, so a page tag cannot see downloads. `release.openecos.com/installers/*` is a Cloudflare Worker that proxies OSS and sends a GA4 Measurement Protocol `file_download` event.

Create a GA4 property, enable Measurement Protocol, then:

```sh
# put the G- id in cloudflare/wrangler.toml [vars].GA_MEASUREMENT_ID
nix shell nixpkgs#wrangler -c wrangler secret put GA_API_SECRET --config cloudflare/wrangler.toml
nix shell nixpkgs#wrangler -c wrangler deploy --config cloudflare/wrangler.toml
```

The worker hashes `CF-Connecting-IP` + `User-Agent` into `client_id`. It does not send the raw IP to Google. Look at event count, not Active Users.

## `nix flake check`

Default checks do not download the real ECC, OSS CAD Suite, or PDK archives.

| check | What it covers |
|---|---|
| `semver` | SemVer 2.0.0 order: `0.1.0-alpha.10` < `alpha.11` < `0.1.0`; numeric ident `0`; build metadata ignored |
| `generate` | Render the installer from the current TOML; reject darwin / empty Liberty lists; no leftover placeholders |
| `publish` | `latest` policy: missing → advance, older → keep, same version + same bytes → keep, same version + different bytes → reject, malformed `ECC_VERSION` → reject |
| `archive` | `tarfile` safety on synthetic tars: traversal, absolute paths, control characters, escaping links, FIFOs, empty Liberty inventories |
| `installer-syntax` | `dash -n`, `bash -n`, and `shellcheck -s dash -S error` on the generated script |
| `installer-e2e` | Fake archives over local HTTP: GitHub success, GitHub failure then CNB, checksum mismatch, unsupported platform, wrapper env, lock, receipt, toolchain fallback |
| `formatting` | `treefmt` dry-run: nixfmt, ruff, taplo, yamlfmt, shfmt |

`nix develop` provides `treefmt`, `dash`, and `shellcheck`. `nix fmt` runs the same formatters as the `formatting` check.
