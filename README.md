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

`--download-source auto|github|cnb` selects the mirror (`auto` tries GitHub, then CNB). The PDK base's CNB mirror is a distinct git archive with its own SHA-256.

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

`update-ecc` only rewrites ECC pins. Bump OSS CAD Suite, ecc-sizer, or the PDK by editing the TOML; for ecc-sizer keep `asset_name` and both URLs in sync with `version` (`ecc-sizer-<version>-linux-x64.tar.gz` embeds it in the basename and the tag), and set `cnb_sha256` only if the mirror bytes differ from GitHub's.

Publishing needs `OSS_ACCESS_KEY_ID` and `OSS_ACCESS_KEY_SECRET`. A versioned object cannot be overwritten with different bytes. `latest` never moves to an older SemVer.


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
| `registry-generate` | Build `tool-registry.json` from the manifest: entity counts, single version per entity, PDK package shape, dependency closure, retired-field rejection, plus negative eval cases for the closed field sets |
| `registry-url-tests` | Offline unit tests for the URL checker (HEAD with ranged GET fallback, redirect handling, traversal and empty-URL coverage) |
| `update-ecc-toml` | `[ecc]`-section-scoped TOML reads and edits survive decoy sections; missing keys fail without touching the file |
| `formatting` | `treefmt` dry-run: nixfmt, ruff, taplo, yamlfmt, shfmt |

`nix develop` provides `treefmt`, `dash`, and `shellcheck`. `nix fmt` runs the same formatters as the `formatting` check.

## Tool registry publishing

`metadata/toolchain.toml` is the single source of truth for both the installer and the ECOS Studio registry. `nix build .#tool-registry` projects the manifest to `tool-registry.json` (`schema_version` 2; the PDK entry is a base lock plus a `packages` array; the sizer is installer-only and never appears).

Two URLs serve the same bytes during the transition:

- New: `https://emin017.github.io/ecos-release/tool-registry.json`
- Legacy: `https://emin017.github.io/ecos-registry/tool-registry.json` (still hardcoded in released Studio builds)

`publish-registry.yml` runs on every push to main that touches `metadata/**`, `nix/**`, or the workflow itself: it builds the JSON, deploys it to GitHub Pages, polls the new URL until it serves the built sha256, then force-pushes the fixed branch `bot/tool-registry-sync` in `Emin017/ecos-registry` and opens or updates a pull request whose body carries the artifact sha256. Runs without changes do nothing. The workflow needs the repository secret `REGISTRY_SYNC_TOKEN`: a fine-grained PAT scoped to `Emin017/ecos-registry` only, with Contents: read and write plus Pull requests: read and write. GitHub Pages source must be set to GitHub Actions.

`verify-urls.yml` runs daily and fails when the two URLs stop serving identical bytes (for example while a sync PR waits for review). `check-urls.yml` probes every download URL on PRs and pushes to main.

Rollback: revert the offending commit on main and re-run `publish-registry.yml` — both URLs converge on the previous artifact. In an emergency, revert `tool-registry.json` directly in `ecos-registry` main; the next sync PR restores the generated version. If a sync PR sits unmerged, the legacy URL stays on the old bytes and `verify-urls` fails until it merges.

Bumps: `nix run .#update-ecc -- v<tag>` rewrites the `[ecc]` pins; edit every other component in the TOML by hand. `mpc-frame` tracks its upstream branch only through manual bumps.
