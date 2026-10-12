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
nix run .#bump                   # check upstream for all 21 components and refresh the lock file
nix run .#bump -- --only slang   # bump one component exactly (others stay untouched)
nix run .#bump -- --dry-run      # report drift without writing
nix run .#bump -- pin ecc v<tag> # lock ecc to an exact tag for this run
nix run .#publish-oss -- v<tag>  # PUT the immutable versioned object; advance latest by SemVer 2.0.0
nix run .#publish-registry-oss   # PUT the registry as the mutable tools/registry.json object; verify the anonymous read
```

`bump` rewrites only `nix/_sources/generated.json`; rules and metadata stay hand-edited in `nix/toolchain.toml`. The 6 mutable `-latest` entries are re-prefetched whenever they are inside the selection; entries outside it are carried over untouched. `pin` overrides one component's version source for the run (the publish-installer workflow still uses the older `nix run .#update-ecc` bridge for now). A full bump of the prerelease components (ecc, sizer) needs `GITHUB_TOKEN` (or `GH_TOKEN`) in the environment for nvchecker's GitHub API calls. A scheduled workflow (`auto-bump.yml`) runs a full bump daily and opens or updates the `bot/lock-bump` PR when locks drift; the bump run itself gates on `nix flake check` and registry URL checks.

Publishing needs `OSS_ACCESS_KEY_ID` and `OSS_ACCESS_KEY_SECRET` plus the bucket coordinates `OSS_BUCKET`, `OSS_ENDPOINT`, and `OSS_PUBLIC_BASE`; CI reads all five from repository secrets. A versioned object cannot be overwritten with different bytes. `latest` never moves to an older SemVer.

## Nightly builds

`nightly.yml` builds ecos-studio and aggregates ecc, ecc-sizer, kepler-formal, and the ICS55 PDK every night, publishing **one dated prerelease on this repository** (oss-cad-suite-build style): `v0.1.0-nightly.<yyyymmdd>[.N]`, where `.N` is the same-day rerun suffix (auto-incremented past any colliding tag; `NIGHTLY_SUFFIX` overrides it). Aggregation over rebuilding: ecc ships the PyInstaller bundle artifact of the newest main commit with a green nightly CI check (the existing `ci.yml` schedule at 18:17 UTC — when no green run exists yet, ecc is skipped for the night and its content carries forward), ecc-sizer ships its repository's newest green CI artifact, kepler-formal ships its own repository's latest nightly prerelease (verified against its `.sha256` sidecar), and the PDK is assembled from its newest complete release. Only the ecos-studio AppImage is built from source (no upstream CI artifact exists for it), tracked to its default-branch HEAD. Published tags are never overwritten; the newest 14 dated nightlies are kept. Exactly one asset per nightly (plus its sidecar):

- `ecos-nightly-linux-x86_64.tar.gz` — the whole toolchain in one bundle: `ecc/` PyInstaller onedir, `ecc-sizer/` and `kepler-formal/` portable runtimes, `pdk/` assembled ICS55 PDK, and `studio/` the AppImage
- `.sha256` sidecar for it

The PDK recipe reads its package set and validation file list from a projection of `toolchain.toml`, so the assembled layout can never drift from what the installer produces. OSS CAD Suite stays with the installer's `--with-toolchain` path.

The release body records each tool's full version (`<toolbase>-nightly.<date>.g<sha>`, with the base being the tool's next planned release; kepler-formal's version comes from its own nightly tag) and source commit, plus compare links against the previous nightly. A tool is rebuilt only when its HEAD moved or the recipe (`nightly/` tree hash, recorded in the body) changed; unchanged tools carry their content forward from the previous nightly's bundle, and when nothing moved at all no release is created.

The nightly release is a standalone download channel: the registry and the installer keep tracking the tools' stable releases, and Studio's runtime downloads are unaffected. If a CNB mirror of this repository's releases is wanted, create the `cnb.cool/ecoslab/ecos-installer` sync first (CNB retains only the latest nightly, which matches the rolling semantics).

The builds are driven by `nix run .#nightly-build -- <all|ecc|ecc-sizer|kepler-formal|ecos-studio|release>`, but nix only wraps the orchestration — aggregation downloads upstream artifacts and the one source build (ecos-studio) runs the repository's own Makefile, so published artifacts never reference `/nix/store`. Every artifact passes a smoke test before the release is created (the ecc tarball additionally runs on a clean ubuntu:24.04 container). The workflow runs as one serial job: ecc-sizer aggregates before ecos-studio because the AppImage bundles the sizer runtime, preferring that run's fresh artifact over the carried-forward one.

Manual triggers: `nightly.yml`'s `workflow_dispatch` takes `tool` (all or one), `force` (build even when HEAD is already covered), and `suffix` (same-day rerun). Tokens: the release itself uses the workflow's `GITHUB_TOKEN` (`contents: write` on this repository, injected only into the build step); the ecc and ecc-sizer recipes additionally need a `NIGHTLY_READ_TOKEN` repository secret — a read-only fine-grained PAT with Actions: read on `ecc` and `ecc-sizer` — to read ecc's nightly CI gate and download the two CI artifacts. kepler-formal reads a public repository and falls back to `GITHUB_TOKEN` when the read token is absent. Third-party build code (make, pnpm) never sees either token. For local runs, ecc needs docker for its clean-distro smoke test and ecos-studio expects an Ubuntu 22.04 host.

`publish-installer.yml` also runs automatically on every push to main that changes the ecc lock version (which is exactly what a merged `bot/lock-bump` PR does when ecc drifted): it re-runs the flake checks, builds the installer from the locked versions, and publishes the locked tag. Pushes that touch the lock file without changing the ecc version are skipped. The auto-publish job runs on the `installer-deploy` environment — configure a required reviewer on it in the repository settings so every installer release gets an explicit human approval. The built script is uploaded as the `ecc-installer` workflow artifact before the gate, so the reviewer can download the exact bytes that will be published; the publish job re-checks that the artifact's `ECC_VERSION` matches the lock tag. Manual dispatches run on the unprotected `installer-manual` environment; the dispatch itself is the approval.


## `nix flake check`

Default checks do not download the real ECC, OSS CAD Suite, or PDK archives.

| check | What it covers |
|---|---|
| `semver` | SemVer 2.0.0 order: `0.1.0-alpha.10` < `alpha.11` < `0.1.0`; numeric ident `0`; build metadata ignored |
| `installer-render` | Render the installer from the current TOML; reject darwin / empty Liberty lists; no leftover placeholders |
| `publish` | `latest` policy: missing → advance, older → keep, same version + same bytes → keep, same version + different bytes → reject, malformed `ECC_VERSION` → reject |
| `nightly-syntax` | `bash -n` and `shellcheck` on the nightly driver and recipes, plus unit assertions for the bash SemVer compare and decimal increment |
| `actionlint` | `actionlint` over `.github/workflows` (expression validity, context availability) |
| `archive` | `tarfile` safety on synthetic tars: traversal, absolute paths, control characters, escaping links, FIFOs, empty Liberty inventories |
| `installer-syntax` | `dash -n`, `bash -n`, and `shellcheck -s dash -S error` on the generated script |
| `installer-e2e` | Fake archives over local HTTP: GitHub success, GitHub failure then CNB, checksum mismatch, unsupported platform, wrapper env, lock, receipt, toolchain fallback |
| `registry-render` | Build `tool-registry.json` from the manifest: entity counts, single version per entity, PDK package shape, dependency closure, retired-field rejection, plus negative eval cases for the closed field sets |
| `registry-url-tests` | Offline unit tests for the URL checker (HEAD with ranged GET fallback, redirect handling, traversal and empty-URL coverage) |
| `lock-edit` | `lock-edit` updates one lock entry atomically without touching decoy entries or the canonical formatting; missing entries fail without touching the file |
| `treefmt` | `treefmt` dry-run: nixfmt, ruff, taplo, yamlfmt, shfmt, ormolu |

`nix develop` provides `treefmt`, `dash`, and `shellcheck`. `nix fmt` runs the same formatters as the `treefmt` check.

## Tool registry publishing

`nix/toolchain.toml` (rules) and `nix/_sources/generated.json` (locks) are the single source of truth for both the installer and the ECOS Studio registry. `nix build .#tool-registry` projects the merged model to `tool-registry.json` (`schema_version` 2; the PDK entry is a base lock plus a `packages` array; the sizer is installer-only and never appears).

Two URLs serve the same bytes:

- Canonical: `https://release.openecos.com/tools/registry.json` (OSS bucket; new Studio builds should use this)
- Legacy: `https://emin017.github.io/ecos-registry/tool-registry.json` (still hardcoded in released Studio builds)

`publish-registry.yml` runs on every push to main that touches `nix/**`, `lib/**`, `flake.nix`, or the workflow itself: it builds the JSON, publishes it to the OSS bucket (`nix run .#publish-registry-oss`, a mutable `tools/registry.json` object verified by anonymous read-back, like `installers/ecc/latest`), polls the canonical URL until it serves the built sha256, then force-pushes the fixed branch `bot/tool-registry-sync` in `Emin017/ecos-registry` and opens or updates a pull request whose body carries the artifact sha256. Runs without changes do nothing. The OSS publish reads the same five `OSS_*` repository secrets as the installer publish. The workflow also needs the repository secret `REGISTRY_SYNC_TOKEN`: a fine-grained PAT scoped to `Emin017/ecos-registry` only, with Contents: read and write plus Pull requests: read and write.

Publishes triggered by a merged `bot/lock-bump` PR publish on the `registry-deploy` environment instead of the `registry-publish` one — configure a required reviewer on `registry-deploy` and leave `registry-publish` unprotected, so an auto-bump merge pauses for approval before anything is published; the single approval covers both the OSS publish and the legacy sync PR. The built JSON is uploaded as the `tool-registry` workflow artifact in the ungated build job, so the exact bytes are downloadable from the run page before approving.

`verify-urls.yml` runs daily and fails when the two URLs stop serving identical bytes (for example while a sync PR waits for review). `check.yml` runs `nix flake check` and probes every download URL on PRs and pushes to main.

Rollback: revert the offending commit on main and re-run `publish-registry.yml` — the OSS URL converges on the previous artifact immediately, and the legacy URL follows once the resulting sync PR is merged. In an emergency, revert `tool-registry.json` directly in `ecos-registry` main; the next sync PR restores the generated version. If a sync PR sits unmerged, the legacy URL stays on the old bytes and `verify-urls` fails until it merges.

Bumps: `nix run .#bump` refreshes every lock entry; `nix run .#bump -- pin ecc v<tag>` locks an exact ecc tag. `mpc-frame` tracks its upstream branch automatically on every full bump (its published version advances from the 0.1.0 seed to the commit form).
