from __future__ import annotations

"""Reachability checks for every download URL in a generated registry JSON.

Usage: check-registry-urls <tool-registry.json>

HEAD is probed first; a ranged GET fallback covers servers that reject
HEAD. Any non-success status, timeout, empty URL, or malformed entry
fails with a non-zero exit.
"""

from collections.abc import Callable, Iterator
from http.client import HTTPException
import json
from pathlib import Path
import socket
import sys
from typing import Protocol
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

URL_TIMEOUT_SECONDS = 5.0

COLLECTIONS = ("tools", "pdks", "mpcs")


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, *args: object, **kwargs: object) -> None:
        return None


NO_REDIRECT_OPENER = build_opener(NoRedirectHandler)


class UrlResponse(Protocol):
    status: int

    def __enter__(self) -> "UrlResponse": ...

    def __exit__(self, *args: object) -> None: ...

    def read(self, size: int | None = None) -> bytes: ...


UrlOpener = Callable[[Request, float], UrlResponse]
UrlChecker = Callable[[str], str | None]


def urlopen(request: Request, *, timeout: float) -> UrlResponse:
    return NO_REDIRECT_OPENER.open(request, timeout=timeout)


def _open_url(request: Request, timeout: float) -> UrlResponse:
    return urlopen(request, timeout=timeout)


def check_url_reachable(
    url: str,
    *,
    opener: UrlOpener = _open_url,
    timeout: float = URL_TIMEOUT_SECONDS,
) -> str | None:
    head_error = _request_url(url, "HEAD", opener=opener, timeout=timeout)
    if head_error is None:
        return None
    return _request_url(
        url,
        "GET",
        opener=opener,
        timeout=timeout,
        headers={"Range": "bytes=0-0"},
        read_limit=1,
    )


def _request_url(
    url: str,
    method: str,
    *,
    opener: UrlOpener,
    timeout: float,
    headers: dict[str, str] | None = None,
    read_limit: int | None = None,
) -> str | None:
    try:
        request = Request(url, headers=headers or {}, method=method)
        with opener(request, timeout) as response:
            if not 200 <= response.status < 300:
                return f"{method} returned HTTP {response.status}"
            if read_limit is not None:
                response.read(read_limit)
            return None
    except HTTPError as exc:
        if 300 <= exc.code < 400 and exc.headers.get("Location"):
            return None
        return f"{method} returned HTTP {exc.code}"
    except (TimeoutError, socket.timeout) as exc:
        return f"{method} timed out: {exc}"
    except URLError as exc:
        reason = exc.reason
        if isinstance(reason, TimeoutError | socket.timeout):
            return f"{method} timed out: {reason}"
        return f"{method} failed: {reason}"
    except (HTTPException, ValueError) as exc:
        return f"{method} failed: {exc}"
    except OSError as exc:
        return f"{method} failed: {exc}"


def _platform_urls(path: str, platform: object) -> Iterator[tuple[str, str]]:
    if not isinstance(platform, dict):
        yield path, ""
        return
    # A present-but-empty required field yields ("", ""), which the checker
    # reports as an empty URL.
    required = [(field, platform.get(field)) for field in ("url",)]
    optional = [("metadata_url", platform.get("metadata_url"))]
    for field, value in required + optional:
        if isinstance(value, str) and value:
            yield f"{path}.{field}", value
        elif field in platform:
            yield f"{path}.{field}", ""
    packages = platform.get("packages")
    if isinstance(packages, list):
        for index, package in enumerate(packages):
            if not isinstance(package, dict):
                yield f"{path}.packages[{index}]", ""
                continue
            for field in ("url", "cnb_url"):
                value = package.get(field)
                if isinstance(value, str) and value:
                    yield f"{path}.packages[{index}].{field}", value
                elif field in package:
                    yield f"{path}.packages[{index}].{field}", ""


def iter_registry_urls(data: object) -> Iterator[tuple[str, str]]:
    """Yield (location, url) for every download URL in the registry."""
    if not isinstance(data, dict):
        yield "$", ""
        return
    for collection in COLLECTIONS:
        entries = data.get(collection)
        if not isinstance(entries, list):
            continue
        for entry_index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                yield f"{collection}[{entry_index}]", ""
                continue
            versions = entry.get("versions")
            if not isinstance(versions, list):
                yield f"{collection}[{entry_index}].versions", ""
                continue
            for version_index, version in enumerate(versions):
                if not isinstance(version, dict):
                    yield f"{collection}[{entry_index}].versions[{version_index}]", ""
                    continue
                platforms = version.get("platforms")
                if not isinstance(platforms, dict):
                    yield f"{collection}[{entry_index}].versions[{version_index}].platforms", ""
                    continue
                for platform_key, platform in platforms.items():
                    base = (
                        f"{collection}[{entry_index}].versions[{version_index}]"
                        f".platforms.{platform_key}"
                    )
                    yield from _platform_urls(base, platform)


def check_registry_urls(
    data: object,
    *,
    url_checker: UrlChecker = check_url_reachable,
) -> list[str]:
    errors: list[str] = []
    for location, url in iter_registry_urls(data):
        if not isinstance(url, str) or not url:
            errors.append(f"{location}: empty URL")
            continue
        error = url_checker(url)
        if error is not None:
            errors.append(f"{location}: URL check failed for {url}: {error}")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    try:
        data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"cannot read registry: {exc}", file=sys.stderr)
        return 1
    errors = check_registry_urls(data)
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
