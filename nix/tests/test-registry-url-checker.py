from __future__ import annotations

"""Offline unit tests for nix/registry-url-checker.py (no network).

Run directly, or from a Nix store checkout by pointing
REGISTRY_URL_CHECKER at the checker module path.
"""

from email.message import Message
from http.client import HTTPMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import sys
from threading import Thread
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request
import unittest


def load_checker():
    default = Path(__file__).resolve().parents[1] / "registry-url-checker.py"
    module_path = Path(os.environ.get("REGISTRY_URL_CHECKER", default))
    spec = importlib.util.spec_from_file_location("registry_url_checker", module_path)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


registry_url_checker = load_checker()


class FakeResponse:
    def __init__(self, status: int) -> None:
        self.status = status
        self.read_sizes: list[int | None] = []

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self, size: int | None = None) -> bytes:
        self.read_sizes.append(size)
        return b"x"


def sample_registry() -> dict[str, Any]:
    return {
        "schema_version": 2,
        "tools": [
            {
                "name": "ecc",
                "versions": [
                    {
                        "version": "0.1.0",
                        "platforms": {
                            "linux-x86_64": {
                                "url": "https://example.com/ecc.tar.gz",
                                "sha256": "0" * 64,
                                "size": 1,
                            }
                        },
                        "requires": ["tool:yosys", "pdk:ics55"],
                    }
                ],
            },
            {
                "name": "ecc-fe",
                "versions": [
                    {
                        "version": "latest",
                        "platforms": {
                            "linux-x86_64": {
                                "url": "https://example.com/ecc-fe-latest.tar.gz",
                                "metadata_url": "https://example.com/ecc-fe-latest.metadata.json",
                                "sha256": "0" * 64,
                                "size": 2,
                            }
                        },
                        "requires": [],
                    }
                ],
            },
        ],
        "pdks": [
            {
                "id": "ics55",
                "versions": [
                    {
                        "version": "1.10.102",
                        "platforms": {
                            "all-platform": {
                                "url": "https://example.com/pdk.tar.gz",
                                "cnb_url": "https://cnb.example.com/pdk.tar.gz",
                                "sha256": "0" * 64,
                                "size": 3,
                                "strip_prefix": "pdk-1.10.102",
                                "packages": [
                                    {
                                        "path": "a.tar.bz2",
                                        "url": "https://example.com/a.tar.bz2",
                                        "cnb_url": "https://cnb.example.com/a.tar.bz2",
                                        "sha256": "0" * 64,
                                        "size": 4,
                                        "dest": "IP/a",
                                    },
                                    {
                                        "path": "b.tar.bz2",
                                        "url": "https://example.com/b.tar.bz2",
                                        "cnb_url": "https://cnb.example.com/b.tar.bz2",
                                        "sha256": "0" * 64,
                                        "size": 5,
                                        "dest": "IP/b",
                                    },
                                ],
                            }
                        },
                    }
                ],
            }
        ],
        "mpcs": [
            {
                "id": "mpc-frame",
                "versions": [
                    {
                        "version": "0.1.0",
                        "platforms": {
                            "all-platform": {
                                "url": "https://example.com/mpc.tar.gz",
                                "sha256": "0" * 64,
                                "size": 6,
                                "strip_prefix": "mpc-frame-abc",
                                "update_source": {
                                    "type": "github_branch",
                                    "branch": "main",
                                },
                            }
                        },
                    }
                ],
            }
        ],
    }


class RegistryUrlCheckerTests(unittest.TestCase):
    def test_url_checker_accepts_successful_head(self) -> None:
        """Accept a successful HEAD response without issuing a fallback GET."""
        requests: list[Request] = []

        def opener(request: Request, timeout: float) -> FakeResponse:
            requests.append(request)
            self.assertEqual(5.0, timeout)
            return FakeResponse(200)

        error = registry_url_checker.check_url_reachable(
            "https://example.com/yosys.tar.gz",
            opener=opener,
            timeout=5.0,
        )

        self.assertIsNone(error)
        self.assertEqual(["HEAD"], [request.get_method() for request in requests])

    def test_url_checker_falls_back_to_ranged_get_without_full_download(self) -> None:
        """Use a one-byte ranged GET fallback when HEAD is not supported."""
        requests: list[Request] = []
        get_response = FakeResponse(206)

        def opener(request: Request, timeout: float) -> FakeResponse:
            del timeout
            requests.append(request)
            if request.get_method() == "HEAD":
                raise HTTPError(
                    request.full_url,
                    405,
                    "Method Not Allowed",
                    HTTPMessage(),
                    None,
                )
            return get_response

        error = registry_url_checker.check_url_reachable(
            "https://example.com/yosys.tar.gz",
            opener=opener,
        )

        self.assertIsNone(error)
        self.assertEqual(["HEAD", "GET"], [request.get_method() for request in requests])
        self.assertEqual("bytes=0-0", requests[1].headers["Range"])
        self.assertEqual([1], get_response.read_sizes)

    def test_url_checker_accepts_redirect_with_location(self) -> None:
        """Treat download redirects as reachable without probing large asset backends."""
        headers = Message()
        headers["Location"] = "https://downloads.example.com/yosys.tar.gz"

        def opener(request: Request, timeout: float) -> FakeResponse:
            del timeout
            raise HTTPError(
                request.full_url,
                302,
                "Found",
                headers,
                None,
            )

        error = registry_url_checker.check_url_reachable(
            "https://example.com/yosys.tar.gz",
            opener=opener,
        )

        self.assertIsNone(error)

    def test_real_no_redirect_opener_accepts_redirect_with_location(self) -> None:
        """Exercise the real no-redirect opener against a local HTTP server."""

        class RedirectHandler(BaseHTTPRequestHandler):
            def do_HEAD(self) -> None:
                self.send_response(302)
                self.send_header("Location", "https://downloads.example.com/asset.tar.gz")
                self.end_headers()

            def log_message(self, format: str, *args: object) -> None:
                del format, args

        server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address
            error = registry_url_checker.check_url_reachable(f"http://{host}:{port}/asset.tar.gz")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

        self.assertIsNone(error)

    def test_url_checker_reports_timeout_and_non_success_status(self) -> None:
        """Report timeout and HTTP status failures from lightweight URL probes."""

        def timeout_opener(request: Request, timeout: float) -> FakeResponse:
            del request, timeout
            raise TimeoutError("timed out")

        timeout_error = registry_url_checker.check_url_reachable(
            "https://example.com/yosys.tar.gz",
            opener=timeout_opener,
        )

        self.assertIsNotNone(timeout_error)
        self.assertIn("timed out", timeout_error)

        def not_found_opener(request: Request, timeout: float) -> FakeResponse:
            del timeout
            raise HTTPError(request.full_url, 404, "Not Found", HTTPMessage(), None)

        status_error = registry_url_checker.check_url_reachable(
            "https://example.com/yosys.tar.gz",
            opener=not_found_opener,
        )

        self.assertIsNotNone(status_error)
        self.assertIn("GET returned HTTP 404", status_error)

    def test_url_checking_reports_malformed_url_without_crashing(self) -> None:
        """Return a normal URL-check error for malformed URLs instead of crashing."""
        error = registry_url_checker.check_url_reachable("https://exa mple.com/yosys.tar.gz")

        self.assertIsNotNone(error)
        self.assertIn("failed", error)

    def test_traversal_covers_every_url_location(self) -> None:
        """Enumerate url/metadata_url and packages[].url/cnb_url across collections."""
        locations = dict(registry_url_checker.iter_registry_urls(sample_registry()))

        self.assertEqual(
            {
                "tools[0].versions[0].platforms.linux-x86_64.url",
                "tools[1].versions[0].platforms.linux-x86_64.url",
                "tools[1].versions[0].platforms.linux-x86_64.metadata_url",
                "pdks[0].versions[0].platforms.all-platform.url",
                "pdks[0].versions[0].platforms.all-platform.cnb_url",
                "pdks[0].versions[0].platforms.all-platform.packages[0].url",
                "pdks[0].versions[0].platforms.all-platform.packages[0].cnb_url",
                "pdks[0].versions[0].platforms.all-platform.packages[1].url",
                "pdks[0].versions[0].platforms.all-platform.packages[1].cnb_url",
                "mpcs[0].versions[0].platforms.all-platform.url",
            },
            set(locations),
        )
        self.assertEqual(
            "https://example.com/ecc.tar.gz",
            locations["tools[0].versions[0].platforms.linux-x86_64.url"],
        )

    def test_empty_url_is_reported(self) -> None:
        """An empty URL anywhere fails the registry check."""
        data = sample_registry()
        data["mpcs"][0]["versions"][0]["platforms"]["all-platform"]["url"] = ""

        errors = registry_url_checker.check_registry_urls(data, url_checker=lambda url: None)

        self.assertEqual(1, len(errors))
        self.assertIn("empty URL", errors[0])
        self.assertIn("mpcs[0]", errors[0])

    def test_registry_check_reports_failing_urls_with_location(self) -> None:
        """Checker failures are prefixed with the registry location."""

        def checker(url: str) -> str | None:
            return "GET returned HTTP 404" if url == "https://cnb.example.com/b.tar.bz2" else None

        errors = registry_url_checker.check_registry_urls(sample_registry(), url_checker=checker)

        self.assertEqual(1, len(errors))
        self.assertTrue(
            errors[0].startswith("pdks[0].versions[0].platforms.all-platform.packages[1].cnb_url:")
        )
        self.assertIn("https://cnb.example.com/b.tar.bz2", errors[0])

    def test_json_round_trip(self) -> None:
        """The enumerator works on the serialized form of a registry."""
        data = json.loads(json.dumps(sample_registry()))
        errors = registry_url_checker.check_registry_urls(data, url_checker=lambda url: None)
        self.assertEqual([], errors)


if __name__ == "__main__":
    unittest.main()
