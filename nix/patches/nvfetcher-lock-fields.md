# nvfetcher lock-fields patch

`nvfetcher-lock-fields.patch` is a patch against upstream
[berberman/nvfetcher](https://github.com/berberman/nvfetcher), pinned to
`e41af9779ea14adf1d8c3edb075713c2668d45b9` (master, which includes the
prerelease option for the github version source). It is applied by
`nix/nvfetcher.nix` to build the nvfetcher used by this repository, and exists
so that `_sources/generated.json` natively carries the three lock fields the
registry/installer pipeline needs. Design background:
`docs/superpowers/plans/2026-09-15-nvfetcher-bump-driver-plan.md`.

## What the patch changes

Each generated.json entry gains three fields at entry top level (siblings of
`name`/`version`/`src`):

- `size` — byte size of the fetched file, recorded for `fetch.url` packages.
  It is measured on the store path reported by `nix-prefetch-url --print-path`,
  i.e. on the exact bytes that were hashed, so it needs no extra HTTP requests
  and also works for servers that do not honor `HEAD` or `Range`
  (e.g. codeload: HEAD 200 without `Content-Length`, Range GETs ignored).
  Empty files and sizes not fitting into an `Int64` fail the prefetch.
  Non-url fetchers (git, github, tarball/unpack, docker) record `null`.
- `sha256_hex` — lowercase hex form of `src.sha256` (which stays SRI), for
  consumers that require 64-char lowercase hex instead of SRI. A conversion
  failure fails the build; `null` is unrepresentable for this field.
- `cnb_sha256` — lowercase hex sha256 of an additional CNB url prefetched for
  the package, for the rare cases where the CNB mirror's bytes differ from the
  GitHub bytes (in practice the ICS55 PDK base package). `null` when the
  package does not declare a CNB url.

Example entry (fetch.url package with a CNB url declared):

```json
{
    "cnb_sha256": "9bd412ce…",
    "name": "icsprout55-base",
    "sha256_hex": "68f81ab6…",
    "size": 49757561,
    "src": {
        "name": null,
        "sha256": "sha256-…",
        "type": "url",
        "url": "https://github.com/openecos-projects/icsprout55-pdk/archive/refs/tags/v1.10.102.tar.gz"
    },
    "version": "v1.10.102"
}
```

## `fetchCnb` (Haskell DSL only)

The CNB url is declared per package with the new `fetchCnb` combinator; like
`fetchUrl`, it computes the url from the version:

```haskell
define $
  package "icsprout55-base"
    `sourceManual` "v1.10.102"
    `fetchUrl` (\v -> "https://github.com/openecos-projects/icsprout55-pdk/archive/refs/tags/" <> coerce v <> ".tar.gz")
    `fetchCnb` (\v -> "https://cnb.cool/ecoslab/icsprout55-pdk/-/git/archive/" <> coerce v <> ".tar.gz")
```

The CNB prefetch goes through the same cached `RunFetch` shake rule as the
package source and follows the package's `forceFetch`, so unchanged packages
do not re-download their CNB url. A failed CNB prefetch fails the package,
like a failed source prefetch. `fetchCnb` is not available in the TOML
frontend; the CLI behaves exactly like upstream.

## Compatibility

Breaking changes are limited to the Haskell library API:

- `prefetch` now returns the fetched file size alongside the fetcher.
- `newPackage` takes an additional `Maybe PackageCnbUrl` argument.
- `Package` gained `_pcnburl`; `PackageResult` gained `_prsize`,
  `_prsha256Hex`, `_prcnbSha256`.
- The shake database version is bumped to 3 (old databases are invalidated
  automatically).

The CLI, the TOML config format, generated.nix, and the top-level shape of
generated.json stay compatible (the new fields are additive).

## Patch maintenance

The patch is developed in the git-ignored `nvfetcher/` checkout at the repo
root (upstream master + the patch as its working-tree diff). It contains only
modifications of upstream files; brand-new files are kept next to it as plain
files for readability, under `nix/patches/nvfetcher/` mirroring the source
tree layout (currently the two test specs `test/SriSpec.hs` and
`test/PackageResultSpec.hs`), and are copied into the source tree by the
packaging. Regenerate with:

```sh
git -C nvfetcher diff > nix/patches/nvfetcher-lock-fields.patch
```

To run the patched test suite inside the checkout, copy the extra specs in
first: `cp nix/patches/nvfetcher/test/*.hs nvfetcher/test/`.

When bumping the upstream pin in `nix/nvfetcher.nix`, update the fetch hash
and make sure the patch still applies — `nix build .#nvfetcher` fails at the
patch step otherwise.
