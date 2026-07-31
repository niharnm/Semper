import json
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
WEBSITE = ROOT / "website"
INDEXNOW_KEY = "88c9034f2d635eff6940e8c74d3a1826"
KO_FI_URL = "https://ko-fi.com/niharm"
CANONICALS = {
    "index.html": "https://www.semper.systems/",
    "about.html": "https://www.semper.systems/about.html",
    "mac-volume-mixer.html": "https://www.semper.systems/mac-volume-mixer.html",
    "privacy.html": "https://www.semper.systems/privacy.html",
    "terms.html": "https://www.semper.systems/terms.html",
}


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []
        self.fragment_links: list[str] = []
        self.local_assets: list[str] = []
        self.release_links: list[str] = []
        self.canonical: str | None = None
        self.has_robots_meta = False
        self.has_google_site_verification = False

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        values = dict(attrs)
        element_id = values.get("id")
        if element_id:
            self.ids.append(element_id)

        href = values.get("href")
        if href and href.startswith("#"):
            self.fragment_links.append(href[1:])

        src = values.get("src")
        if src and not urlparse(src).scheme and not src.startswith("/"):
            self.local_assets.append(src)

        if tag == "link" and href:
            rel = (values.get("rel") or "").lower()
            if rel == "canonical":
                self.canonical = href
            if ("stylesheet" in rel or "icon" in rel) and not urlparse(href).scheme:
                self.local_assets.append(href)

        if tag == "meta" and values.get("name") == "robots":
            self.has_robots_meta = True
        if tag == "meta" and values.get("name") == "google-site-verification":
            self.has_google_site_verification = bool(values.get("content"))

        if "data-release-status" in values and href:
            self.release_links.append(href)


def fail(message: str) -> None:
    raise SystemExit(f"website check failed: {message}")


def check_html(filename: str, expected_canonical: str) -> SiteParser:
    path = WEBSITE / filename
    source = path.read_text(encoding="utf-8")
    parser = SiteParser()
    parser.feed(source)

    duplicate_ids = sorted(
        {item for item in parser.ids if parser.ids.count(item) > 1}
    )
    if duplicate_ids:
        fail(f"{filename} has duplicate IDs: {', '.join(duplicate_ids)}")

    missing_fragments = sorted(set(parser.fragment_links) - set(parser.ids))
    if missing_fragments:
        fail(
            f"{filename} has missing fragment targets: "
            f"{', '.join(missing_fragments)}"
        )

    for relative_path in parser.local_assets:
        asset = (WEBSITE / relative_path).resolve()
        if WEBSITE.resolve() not in asset.parents or not asset.is_file():
            fail(f"{filename} has a missing local asset: {relative_path}")

    if parser.canonical != expected_canonical:
        fail(f"{filename} has an incorrect canonical URL")
    if not parser.has_robots_meta:
        fail(f"{filename} is missing a robots meta tag")

    structured_data = re.findall(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        source,
        flags=re.DOTALL | re.IGNORECASE,
    )
    for block in structured_data:
        try:
            json.loads(block)
        except json.JSONDecodeError as error:
            fail(f"{filename} contains invalid JSON-LD: {error}")

    return parser


parsers = {
    filename: check_html(filename, canonical)
    for filename, canonical in CANONICALS.items()
}
index = parsers["index.html"]
index_source = (WEBSITE / "index.html").read_text(encoding="utf-8")

if not index.has_google_site_verification:
    fail("index.html is missing the Google Search Console verification tag")

for required_id in ("release", "faq"):
    if required_id not in index.ids:
        fail(f"index.html is missing the {required_id} section")

if index.release_links != ["https://github.com/niharnm/Semper/releases"]:
    fail("the release status link must point to the official releases page")
if f'href="{KO_FI_URL}"' not in index_source:
    fail("index.html is missing the canonical Ko-fi fallback link")
if 'open &quot;semper://update&quot;' not in index_source:
    fail("index.html is missing the Terminal update command")

for required_file in ("robots.txt", "sitemap.xml", "llms.txt"):
    if not (WEBSITE / required_file).is_file():
        fail(f"missing required public file: {required_file}")

indexnow_file = WEBSITE / f"{INDEXNOW_KEY}.txt"
if (
    not indexnow_file.is_file()
    or indexnow_file.read_text(encoding="utf-8").strip() != INDEXNOW_KEY
):
    fail("missing or invalid IndexNow ownership key file")

if not (ROOT / "LICENSE").is_file():
    fail("missing root GPL-3.0-only license file")

robots = (WEBSITE / "robots.txt").read_text(encoding="utf-8")
if "User-agent: OAI-SearchBot" not in robots:
    fail("robots.txt must explicitly allow OAI-SearchBot")
if "Sitemap: https://www.semper.systems/sitemap.xml" not in robots:
    fail("robots.txt must advertise the sitemap")

namespace = {"sitemap": "http://www.sitemaps.org/schemas/sitemap/0.9"}
sitemap = ElementTree.parse(WEBSITE / "sitemap.xml")
sitemap_urls = {
    location.text
    for location in sitemap.findall("sitemap:url/sitemap:loc", namespace)
}
if sitemap_urls != set(CANONICALS.values()):
    fail("sitemap.xml does not match the canonical page set")

llms = (WEBSITE / "llms.txt").read_text(encoding="utf-8")
if "There is no packaged public release yet" not in llms:
    fail("llms.txt must state the current release status")
for canonical in CANONICALS.values():
    if canonical not in llms:
        fail(f"llms.txt is missing an official page: {canonical}")

contributor_urls = {
    "https://github.com/niharnm/Semper/contribute",
    "https://github.com/niharnm/Semper/blob/main/CONTRIBUTING.md",
    "https://github.com/niharnm/Semper/blob/main/ROADMAP.md",
    "https://github.com/niharnm/Semper/discussions",
}
for filename in ("index.html", "about.html", "llms.txt"):
    source = (WEBSITE / filename).read_text(encoding="utf-8")
    for contributor_url in contributor_urls:
        if contributor_url not in source:
            fail(f"{filename} is missing contributor link: {contributor_url}")

readme = (ROOT / "README.md").read_text(encoding="utf-8")
if "releases/latest/download/Semper.dmg" in readme:
    fail("README.md contains a broken packaged download link")
if f"]({KO_FI_URL})" not in readme:
    fail("README.md is missing the canonical Ko-fi badge link")
if 'open "semper://update"' not in readme:
    fail("README.md is missing the Terminal update command")

print(
    f"website check passed: {len(CANONICALS)} pages, "
    f"{sum(len(parser.ids) for parser in parsers.values())} IDs"
)
