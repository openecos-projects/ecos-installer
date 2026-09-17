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

Rules (metadata, version sources, templates) live in `nix/toolchain.toml`; the resolved version/url/sha256/size pins live in `nix/_sources/generated.json` (nvfetcher lock format, see `nix/patches/nvfetcher-lock-fields.md`). The installer source is `templates/ecc-installer.sh.in`.

```sh
nix fmt                          # format Nix, Python, TOML, YAML, and shell
nix build .#ecc-installer        # write ecc-installer.sh; does not fetch real archives
nix run .#update-ecc -- v<tag>   # prefetch the ECC GitHub asset and update the ecc lock entry
nix run .#publish-oss -- v<tag>  # PUT the immutable versioned object; advance latest by SemVer 2.0.0
```

`update-ecc` only rewrites the ecc lock entry. Until the nvfetcher bump driver lands, bump any other component by prefetching its new artifact (`nix-prefetch-url --print-path <url>`, then `nix hash convert` for the SRI/hex forms and `stat` for the size) and running `nix run .#lock-edit -- set nix/_sources/generated.json <id> <version> <url> <sri> <sha256_hex> <size>`. `cnb_sha256` belongs only to the PDK base, whose CNB mirror bytes differ from GitHub's.

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
| `update-ecc-locks` | `lock-edit` updates one lock entry atomically without touching decoy entries or the canonical formatting; missing entries fail without touching the file |
| `formatting` | `treefmt` dry-run: nixfmt, ruff, taplo, yamlfmt, shfmt |

`nix develop` provides `treefmt`, `dash`, and `shellcheck`. `nix fmt` runs the same formatters as the `formatting` check.

## Tool registry publishing

`nix/toolchain.toml` (rules) and `nix/_sources/generated.json` (locks) are the single source of truth for both the installer and the ECOS Studio registry. `nix build .#tool-registry` projects the merged model to `tool-registry.json` (`schema_version` 2; the PDK entry is a base lock plus a `packages` array; the sizer is installer-only and never appears).

Two URLs serve the same bytes during the transition:

- New: `https://emin017.github.io/ecos-release/tool-registry.json`
- Legacy: `https://emin017.github.io/ecos-registry/tool-registry.json` (still hardcoded in released Studio builds)

`publish-registry.yml` runs on every push to main that touches `nix/**`, `lib/**`, `flake.nix`, or the workflow itself: it builds the JSON, deploys it to GitHub Pages, polls the new URL until it serves the built sha256, then force-pushes the fixed branch `bot/tool-registry-sync` in `Emin017/ecos-registry` and opens or updates a pull request whose body carries the artifact sha256. Runs without changes do nothing. The workflow needs the repository secret `REGISTRY_SYNC_TOKEN`: a fine-grained PAT scoped to `Emin017/ecos-registry` only, with Contents: read and write plus Pull requests: read and write. GitHub Pages source must be set to GitHub Actions.

`verify-urls.yml` runs daily and fails when the two URLs stop serving identical bytes (for example while a sync PR waits for review). `check-urls.yml` probes every download URL on PRs and pushes to main.

Rollback: revert the offending commit on main and re-run `publish-registry.yml` — both URLs converge on the previous artifact. In an emergency, revert `tool-registry.json` directly in `ecos-registry` main; the next sync PR restores the generated version. If a sync PR sits unmerged, the legacy URL stays on the old bytes and `verify-urls` fails until it merges.

Bumps: `nix run .#update-ecc -- v<tag>` rewrites the ecc lock entry; update other components through their `nix/_sources/generated.json` entries (see "Generate and publish"). `mpc-frame` tracks its upstream branch only through manual bumps.
