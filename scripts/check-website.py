import json
import posixpath
import re
from datetime import datetime
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
EXPECTED_SCHEMA_TYPES = {
    "index.html": {"SoftwareApplication", "WebSite", "FAQPage"},
    "about.html": {"AboutPage"},
    "mac-volume-mixer.html": {"TechArticle"},
}


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []
        self.fragment_links: list[str] = []
        self.local_html_links: list[str] = []
        self.local_assets: list[str] = []
        self.release_links: list[str] = []
        self.canonical: str | None = None
        self.has_description = False
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
        if tag == "a" and href and not urlparse(href).scheme:
            local_path = urlparse(href).path
            if local_path:
                self.local_html_links.append(local_path)

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
        if tag == "meta" and values.get("name") == "description":
            self.has_description = bool((values.get("content") or "").strip())
        if tag == "meta" and values.get("name") == "google-site-verification":
            self.has_google_site_verification = bool(values.get("content"))

        if "data-release-status" in values and href:
            self.release_links.append(href)


def fail(message: str) -> None:
    raise SystemExit(f"website check failed: {message}")


def schema_types(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        item_type = value.get("@type")
        if isinstance(item_type, str):
            found.add(item_type)
        elif isinstance(item_type, list):
            found.update(item for item in item_type if isinstance(item, str))
        for child in value.values():
            found.update(schema_types(child))
    elif isinstance(value, list):
        for child in value:
            found.update(schema_types(child))
    return found


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

    for relative_path in parser.local_html_links:
        normalized_path = posixpath.normpath(
            "/" + relative_path.lstrip("/")
        )
        if normalized_path == "/index.html":
            fail(f"{filename} links to duplicate homepage path: {relative_path}")
        if normalized_path == "/":
            continue
        target = (WEBSITE / normalized_path.lstrip("/")).resolve()
        if WEBSITE.resolve() not in target.parents or not target.is_file():
            fail(f"{filename} has a missing local page: {relative_path}")

    if parser.canonical != expected_canonical:
        fail(f"{filename} has an incorrect canonical URL")
    if not re.search(r"<title>\s*\S.*?</title>", source, re.DOTALL | re.IGNORECASE):
        fail(f"{filename} is missing a non-empty title")
    if not parser.has_description:
        fail(f"{filename} is missing a meta description")
    if not parser.has_robots_meta:
        fail(f"{filename} is missing a robots meta tag")

    structured_data = re.findall(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        source,
        flags=re.DOTALL | re.IGNORECASE,
    )
    found_schema_types: set[str] = set()
    for block in structured_data:
        try:
            found_schema_types.update(schema_types(json.loads(block)))
        except json.JSONDecodeError as error:
            fail(f"{filename} contains invalid JSON-LD: {error}")

    missing_schema_types = (
        EXPECTED_SCHEMA_TYPES.get(filename, set()) - found_schema_types
    )
    if missing_schema_types:
        fail(
            f"{filename} is missing JSON-LD types: "
            f"{', '.join(sorted(missing_schema_types))}"
        )

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
update_command = (
    "/usr/bin/curl -fsSL "
    "https://raw.githubusercontent.com/niharnm/Semper/main/"
    "scripts/update-local.sh | /bin/bash"
)
if update_command not in index_source:
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
    fail("missing root Apache-2.0 license file")

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
for entry in sitemap.findall("sitemap:url", namespace):
    last_modified = (
        entry.findtext("sitemap:lastmod", namespaces=namespace) or ""
    ).strip()
    if last_modified.endswith("Z"):
        last_modified = f"{last_modified[:-1]}+00:00"
    try:
        datetime.fromisoformat(last_modified)
    except ValueError:
        fail("sitemap.xml contains an invalid or missing lastmod date")

vercel_config_path = WEBSITE / "vercel.json"
if not vercel_config_path.is_file():
    fail("missing website/vercel.json")
try:
    vercel_config = json.loads(vercel_config_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as error:
    fail(f"website/vercel.json contains invalid JSON: {error}")
if vercel_config.get("$schema") != "https://openapi.vercel.sh/vercel.json":
    fail("website/vercel.json must use the official Vercel schema")
homepage_redirect = {
    "source": "/index.html",
    "destination": "/",
    "permanent": True,
}
if homepage_redirect not in vercel_config.get("redirects", []):
    fail("website/vercel.json must redirect /index.html to /")

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
if update_command not in readme:
    fail("README.md is missing the Terminal update command")

print(
    f"website check passed: {len(CANONICALS)} pages, "
    f"{sum(len(parser.ids) for parser in parsers.values())} IDs"
)
