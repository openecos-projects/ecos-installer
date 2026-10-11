# ecc nightly recipe: the PyInstaller onedir CLI bundle, built inside the
# manylinux_2_34 container so the artifact keeps the declared glibc 2.34 floor
# (nix/toolchain.toml [platform] min_glibc). Mirrors the upstream release
# pipeline (ecc/.github/actions/setup-python-deps + build-pyinstaller-bundle)
# instead of `nix build`: nothing in the tarball references /nix/store.
#
# The container runs upstream-controlled code (uv sync, PyInstaller's
# analysis), so it never sees a token: the native wheels are downloaded on
# the host first with the read-only NIGHTLY_READ_TOKEN, and the container
# gets no token at all.

# Emit the script that runs inside the manylinux container. It lives on the
# host and is bind-mounted in so the source checkout stays clean.
nightly_ecc_write_container_script() {
  cat >"$1" <<'CONTAINER_EOF'
#!/usr/bin/env bash
set -euo pipefail

git config --global --add safe.directory /work
cd /work

# manylinux_2_34's binutils 2.41 breaks ELF alignment when stripping .so
# files (sourceware.org bug 31208); install a fixed strip (>= 2.43) from
# conda-forge, as upstream's build-pyinstaller-bundle action does.
mkdir -p /tmp/micromamba
curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj -C /tmp/micromamba
/tmp/micromamba/bin/micromamba create -y -p /opt/bf -c conda-forge binutils=2.44
export PATH="/opt/bf/bin:$PATH"

curl -LsSf https://astral.sh/uv/install.sh | env INSTALLER_NO_MODIFY_PATH=1 sh
export PATH="$HOME/.local/bin:$PATH"
uv python install 3.11

dnf install -y epel-release dnf-plugins-core
dnf config-manager --set-enabled crb || true
dnf install -y \
  cmake ninja-build pkgconfig patchelf mold lld \
  boost-devel cairo-devel gflags-devel glog-devel \
  flex flex-devel bison eigen3-devel gtest-devel \
  tbb-devel hwloc-devel libcurl-devel libunwind-devel \
  metis-devel gmp-devel tcl-devel \
  unzip zip

# The native wheels for the submodule-pinned commits of ecc-dreamplace /
# ecc-tools were downloaded on the host (no token in here).
uv venv --python 3.11 --managed-python
uv pip install --python .venv/bin/python --no-deps dist/native-wheels/*.whl

uv sync --frozen --all-groups --python 3.11 --managed-python --inexact \
  --no-install-package ecc-dreamplace \
  --no-install-package ecc-tools-bin

uv run --no-sync --managed-python pyinstaller ecc.spec --clean
mkdir -p dist/release
tar -cf - -C dist/ecc . | gzip -n -9 >dist/release/ecc-cli-linux-x86_64.tar.gz
CONTAINER_EOF
  chmod +x "$1"
}

# Download one native-wheel CI artifact for the submodule pinned at
# <submodule path> in the source checkout (upstream setup-python-deps,
# build-all=false). Runs on the host through the read-only deps token —
# Actions reads cannot fall back to the release token (a GITHUB_TOKEN cannot
# read other repositories' Actions).
nightly_ecc_download_wheel() {
  local src="$1" repo="$2" submodule_path="$3" artifact_name="$4"
  if [ -z "${NIGHTLY_DEPS_TOKEN:-}" ]; then
    nightly_die "NIGHTLY_READ_TOKEN not set (needs Actions:read on ecc-dreamplace and ecc-tools for CI artifact downloads)"
  fi
  local commit run_id
  commit="$(git -C "$src" rev-parse "HEAD:${submodule_path}")"
  run_id="$(
    nightly_gh_deps api "repos/${repo}/actions/workflows/ci.yml/runs?head_sha=${commit}&per_page=20" \
      --jq '[.workflow_runs[] | select(.conclusion == "success") | .id][0] // empty'
  )"
  if [ -z "$run_id" ]; then
    nightly_die "no successful CI artifact found for ${repo} at submodule commit ${commit}"
  fi
  nightly_log "downloading ${artifact_name} from ${repo} CI run ${run_id} (${commit})"
  nightly_gh_deps run download "$run_id" --repo "$repo" --name "$artifact_name" --dir "$src/dist/native-wheels"
}

# Recipe body runs in a subshell so the EXIT trap cleans the workdir on every
# exit path without leaking traps into the dispatcher. Builds land in
# $NIGHTLY_ASSETS_DIR; publishing happens in nightly_recipe_release.
nightly_recipe_ecc() (
  tool=ecc
  repo="$(nightly_tool_repo ecc)"
  # The ecc nightly builds the newest main commit with a green nightly CI
  # check (ci.yml on a schedule), not the bare HEAD.
  head="$(nightly_effective_head "$tool" "$repo")"
  if [ -z "$head" ]; then
    nightly_log "ecc: no green scheduled CI run on main yet; skipping tonight's ecc build"
    exit 0
  fi
  if ! nightly_tool_should_build "$tool" "$head"; then
    exit 0
  fi
  version="$(nightly_tool_version "$repo" "$head")"
  nightly_log "building ecc ${version} from ${head} (latest green nightly check)"

  : "${NIGHTLY_ASSETS_DIR:?}"
  command -v docker >/dev/null 2>&1 || nightly_die "ecc recipe builds inside the manylinux container and needs docker"

  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT

  nightly_clone "$repo" "$workdir/src"
  git -C "$workdir/src" fetch --depth 1 origin "$head"
  git -C "$workdir/src" checkout --detach "$head"
  git -C "$workdir/src" submodule update --init --recursive --depth 1
  mkdir -p "$workdir/src/dist/native-wheels"
  nightly_ecc_download_wheel "$workdir/src" \
    "openecos-projects/ecc-dreamplace" \
    "chipcompiler/thirdparty/ecc-dreamplace" \
    "ecc-dreamplace-wheel"
  nightly_ecc_download_wheel "$workdir/src" \
    "openecos-projects/ecc-tools" \
    "chipcompiler/thirdparty/ecc-tools" \
    "ecc-tools-wheel"
  nightly_ecc_write_container_script "$workdir/build-in-container.sh"

  docker run --rm \
    -v "$workdir/src:/work" \
    -v "$workdir/build-in-container.sh:/nightly-build.sh:ro" \
    quay.io/pypa/manylinux_2_34_x86_64 \
    bash /nightly-build.sh

  tarball="$workdir/src/dist/release/ecc-cli-linux-x86_64.tar.gz"
  [ -f "$tarball" ] || nightly_die "build produced no tarball at ${tarball}"

  # Smoke test on the host (subset of upstream's build-pyinstaller-bundle
  # smoke): the bundle must run on a plain glibc system.
  smoke="$workdir/smoke"
  mkdir -p "$smoke"
  tar -xzf "$tarball" -C "$smoke"
  "$smoke/ecc" --help >/dev/null
  "$smoke/ecc" --version
  "$smoke/ecc" version --json >/dev/null
  test -x "$smoke/ecc-agent-rpc"
  "$smoke/ecc" doc config --plain >/dev/null

  # Clean-distro check: newer glibc than the build image, no development
  # packages — the tarball must carry every non-system dependency itself.
  nightly_clean_distro_smoke "$smoke" ecc --version

  cp "$tarball" "$NIGHTLY_ASSETS_DIR/"
  nightly_sha256_sidecar "$NIGHTLY_ASSETS_DIR/ecc-cli-linux-x86_64.tar.gz"
  nightly_record_built "$tool" "$head" "$version"
)
