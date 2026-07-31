#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
WEBSITE = ROOT / "website"
HOST = "www.semper.systems"
KEY = "88c9034f2d635eff6940e8c74d3a1826"
KEY_LOCATION = f"https://{HOST}/{KEY}.txt"
ENDPOINT = "https://api.indexnow.org/indexnow"


def sitemap_urls() -> list[str]:
    namespace = {"sitemap": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    sitemap = ElementTree.parse(WEBSITE / "sitemap.xml")
    return [
        location.text
        for location in sitemap.findall("sitemap:url/sitemap:loc", namespace)
        if location.text
    ]


def validate_urls(urls: list[str]) -> None:
    if not urls:
        raise SystemExit("no URLs were provided or found in the sitemap")
    for url in urls:
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.netloc != HOST:
            raise SystemExit(f"URL must use the canonical host: {url}")
        if parsed.path == "/index.html":
            raise SystemExit(
                f"Use the canonical homepage URL instead of: {url}"
            )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Notify IndexNow after canonical Semper pages change."
    )
    parser.add_argument(
        "urls",
        nargs="*",
        help="Canonical URLs to submit. Defaults to every sitemap URL.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the request body without sending it.",
    )
    arguments = parser.parse_args()
    urls = arguments.urls or sitemap_urls()
    validate_urls(urls)

    payload = {
        "host": HOST,
        "key": KEY,
        "keyLocation": KEY_LOCATION,
        "urlList": urls,
    }
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if arguments.dry_run:
        print(json.dumps(payload, indent=2))
        return

    request = Request(
        ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=30) as response:
            status = response.status
    except HTTPError as error:
        details = error.read().decode("utf-8", errors="replace").strip()
        raise SystemExit(
            f"IndexNow rejected the request with HTTP {error.code}: {details}"
        ) from error
    except (URLError, TimeoutError) as error:
        reason = getattr(error, "reason", error)
        raise SystemExit(f"IndexNow request failed: {reason}") from error

    if status not in {200, 202}:
        raise SystemExit(f"IndexNow returned unexpected HTTP status {status}")
    print(f"IndexNow accepted {len(urls)} URL(s) with HTTP {status}")


if __name__ == "__main__":
    main()
