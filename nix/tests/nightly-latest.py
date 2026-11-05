#!/usr/bin/env python3
"""Exercise rolling release publication against a local GitHub CLI fixture."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

FULL = "ecos-nightly-linux-x86_64.tar.gz"
CLI = "ecc-cli-nightly-linux-x86_64.tar.gz"
NAMES = (FULL, FULL + ".sha256", CLI, CLI + ".sha256")
TAG_RE = r"v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}(\.[1-9][0-9]*)?"


def asset(name, data):
    return {
        "name": name,
        "size": len(data.encode()),
        "digest": "sha256:" + hashlib.sha256(data.encode()).hexdigest(),
        "state": "uploaded",
        "data": data,
    }


def release(tag, cli=True, draft=False):
    assets = []
    for name in (FULL, CLI) if cli else (FULL,):
        bundle = asset(name, f"bundle from {tag}: {name}\n")
        assets += [bundle, asset(name + ".sha256", f"{bundle['digest'][7:]}  {name}\n")]
    return {
        "tag_name": tag,
        "target_commitish": "main",
        "prerelease": True,
        "draft": draft,
        "body": f"Tools from {tag}",
        "assets": assets,
    }


def option(args, key):
    return args[args.index(key) + 1]


def fake_cli(kind, args):
    path = Path(os.environ["NIGHTLY_TEST_STATE"])
    state = json.loads(path.read_text())
    state["calls"].append([kind, *args])
    result = ""
    code = 0
    try:
        if kind == "git":
            assert args[:2] == ["ls-remote", "--tags"], args
            tag = args[3].removeprefix("refs/tags/")
            result = f"{state['refs'][tag]}\trefs/tags/{tag}"
        elif args[0] == "api":
            endpoint = next(a for a in args if a.startswith("repos/"))
            if "/releases?" in endpoint:
                assert "--paginate" in args
                if state.get("fail_api"):
                    code = 1
                else:
                    result = json.dumps(state["releases"])
            elif endpoint.endswith("/git/matching-refs/tags/latest"):
                result = state["refs"].get("latest", "")
            elif endpoint.endswith(("/git/refs", "/git/refs/tags/latest")):
                fields = dict(a.split("=", 1) for a in args if "=" in a)
                if option(args, "--method") == "POST":
                    assert fields["ref"] == "refs/tags/latest"
                    assert "latest" not in state["refs"]
                else:
                    assert option(args, "--method") == "PATCH" and fields["force"] == "true"
                state["refs"]["latest"] = fields["sha"]
            else:
                raise AssertionError(args)
        elif args[:2] == ["release", "download"]:
            source = next(r for r in state["releases"] if r["tag_name"] == args[2])
            requested = [args[i + 1] for i, a in enumerate(args) if a == "--pattern"]
            for a in source["assets"]:
                if a["name"] in requested:
                    data = a["data"]
                    if state.get("corrupt_download") and a["name"] == FULL:
                        data += "corrupt"
                    (Path(option(args, "--dir")) / a["name"]).write_text(data)
        elif args[0] == "release":
            assert args[2] == "latest", "dated releases must never be mutated"
            command = args[1]
            rolling = next((r for r in state["releases"] if r["tag_name"] == "latest"), None)
            if command == "create":
                assert rolling is None and "--verify-tag" in args
                rolling = release("latest")
                rolling["assets"] = []
                state["releases"].append(rolling)
            if command in ("create", "upload"):
                if command == "upload":
                    assert "--clobber" in args
                files = [Path(a) for a in args if Path(a).name in NAMES and Path(a).is_file()]
                assert files
                for f in files:
                    rolling["assets"] = [a for a in rolling["assets"] if a["name"] != f.name]
                    rolling["assets"].append(asset(f.name, f.read_text()))
                    if state.pop("fail_upload", False):
                        code = 1
                        break
            if command in ("create", "edit") and code == 0:
                assert "--prerelease" in args and "--latest=false" in args
                rolling.update(
                    body=Path(option(args, "--notes-file")).read_text(),
                    draft=False,
                    prerelease=True,
                )
            if command == "delete-asset":
                assert "--yes" in args
                rolling["assets"] = [a for a in rolling["assets"] if a["name"] != args[3]]
            assert command in ("create", "upload", "edit", "delete-asset"), args
        else:
            raise AssertionError(args)
    finally:
        path.write_text(json.dumps(state))
    if result:
        print(result)
    sys.exit(code)


class LatestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state_path = self.root / "state.json"
        for name in ("git", "gh"):
            stub = self.root / name
            stub.write_text(
                f"#!{sys.executable}\nimport os\nos.execv({sys.executable!r}, "
                f"[{sys.executable!r}, {str(Path(__file__).resolve())!r}, '--fake', {name!r}, "
                "*__import__('sys').argv[1:]])\n"
            )
            stub.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.root}:{os.environ['PATH']}",
            "NIGHTLY_TEST_STATE": str(self.state_path),
            "NIGHTLY_TAG_BODY_RE": TAG_RE,
            "NIGHTLY_CLI_BUNDLE_NAME": CLI.removesuffix(".tar.gz"),
            "NIGHTLY_RELEASE_REPO": "fixture/repo",
            "NIGHTLY_GH_TOKEN": "fixture-token",
            "LC_ALL": "C",
        }
        self.tag = "v0.1.0-nightly.20261027"
        self.seed([release(self.tag)])

    def seed(self, releases):
        self.save(
            {
                "releases": releases,
                "refs": {
                    r["tag_name"]: hashlib.sha1(r["tag_name"].encode()).hexdigest()
                    for r in releases
                },
                "calls": [],
            }
        )

    def state(self):
        return json.loads(self.state_path.read_text())

    def save(self, state):
        self.state_path.write_text(json.dumps(state))

    def sync(self, cached_tag="", cached_dir="", ok=True):
        script = "\n".join(
            [
                "set -euo pipefail",
                "shopt -s inherit_errexit",
                'source "$1/lib/common.sh"',
                'source "$1/scripts/latest.sh"',
                'nightly_recipe_latest "$2" "$3"',
            ]
        )
        result = subprocess.run(
            ["bash", "-c", script, "test", str(NIGHTLY_DIR), cached_tag, str(cached_dir)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return self.state()

    def assert_mirrored(self, tag):
        state = self.state()
        source = next(r for r in state["releases"] if r["tag_name"] == tag)
        rolling = next(r for r in state["releases"] if r["tag_name"] == "latest")
        self.assertEqual(state["refs"]["latest"], state["refs"][tag])
        self.assertEqual(
            sorted(rolling["assets"], key=lambda a: a["name"]),
            sorted(source["assets"], key=lambda a: a["name"]),
        )
        self.assertTrue(rolling["prerelease"])
        self.assertFalse(rolling["draft"])
        self.assertIn(f"<!-- nightly-source: {tag} -->", rolling["body"])
        self.assertIn(source["body"], rolling["body"])

    def test_bootstrap_legacy_release_and_idempotency(self):
        original = release(self.tag, cli=False)
        self.seed([original])
        state = self.sync()
        self.assert_mirrored(self.tag)
        self.assertEqual(state["releases"][0], original)
        state["calls"] = []
        self.save(state)
        state = self.sync()
        self.assertFalse(any(c[1] == "release" or "--method" in c for c in state["calls"]))

    def test_cached_new_release_and_backfill_order(self):
        self.sync()
        state = self.state()
        newer = release(self.tag + ".2")
        backfill = release("v0.1.0-nightly.20261020")
        draft = release("v0.1.0-nightly.20261028", draft=True)
        state["releases"] = [backfill, draft, newer, *state["releases"]]
        for r in (newer, backfill, draft):
            state["refs"][r["tag_name"]] = hashlib.sha1(r["tag_name"].encode()).hexdigest()
        state["calls"] = []
        self.save(state)
        for a in newer["assets"]:
            (self.root / a["name"]).write_text(a["data"])
        state = self.sync(newer["tag_name"], self.root)
        self.assert_mirrored(newer["tag_name"])
        self.assertFalse(any(c[1:3] == ["release", "download"] for c in state["calls"]))

    def test_partial_upload_retries_without_new_builds(self):
        self.sync()
        state = self.state()
        newer = release(self.tag + ".2")
        state["releases"].insert(0, newer)
        state["refs"][newer["tag_name"]] = "a" * 40
        state["fail_upload"] = True
        self.save(state)
        state = self.sync(ok=False)
        rolling = next(r for r in state["releases"] if r["tag_name"] == "latest")
        self.assertIn(f"<!-- nightly-source: {self.tag} -->", rolling["body"])
        self.sync()
        self.assert_mirrored(newer["tag_name"])

    def test_draft_alias_and_missing_assets_are_repaired(self):
        self.sync()
        state = self.state()
        rolling = next(r for r in state["releases"] if r["tag_name"] == "latest")
        rolling["draft"] = True
        rolling["assets"].pop()
        self.save(state)
        self.sync()
        self.assert_mirrored(self.tag)

    def test_invalid_sources_do_not_mutate_remote(self):
        for fault in ("fail_api", "corrupt_download", "missing_sidecar"):
            with self.subTest(fault=fault):
                self.seed([release(self.tag)])
                state = self.state()
                if fault == "missing_sidecar":
                    state["releases"][0]["assets"].pop()
                else:
                    state[fault] = True
                self.save(state)
                after = self.sync(ok=False)
                self.assertEqual(after["refs"], state["refs"])
                self.assertEqual(after["releases"], state["releases"])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fake"]:
        fake_cli(sys.argv[2], sys.argv[3:])
    NIGHTLY_DIR = Path(sys.argv.pop(1)).resolve()
    unittest.main()
