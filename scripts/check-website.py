from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parents[1]
WEBSITE = ROOT / "website"
INDEX = WEBSITE / "index.html"


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []
        self.fragment_links: list[str] = []
        self.local_assets: list[str] = []
        self.canary_links: list[str] = []

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
        if src and not urlparse(src).scheme:
            self.local_assets.append(src)

        if tag == "link" and values.get("rel") == "stylesheet" and href:
            self.local_assets.append(href)

        if "data-canary-download" in values and href:
            self.canary_links.append(href)


def fail(message: str) -> None:
    raise SystemExit(f"website check failed: {message}")


parser = SiteParser()
parser.feed(INDEX.read_text(encoding="utf-8"))

duplicate_ids = sorted({item for item in parser.ids if parser.ids.count(item) > 1})
if duplicate_ids:
    fail(f"duplicate IDs: {', '.join(duplicate_ids)}")

missing_fragments = sorted(set(parser.fragment_links) - set(parser.ids))
if missing_fragments:
    fail(f"missing fragment targets: {', '.join(missing_fragments)}")

for relative_path in parser.local_assets:
    asset = (WEBSITE / relative_path).resolve()
    if WEBSITE.resolve() not in asset.parents or not asset.is_file():
        fail(f"missing or invalid local asset: {relative_path}")

if "canary" not in parser.ids:
    fail("the Canary section is missing")

if len(parser.canary_links) != 1:
    fail("expected one Canary download link")

canary_url = urlparse(parser.canary_links[0])
if (
    canary_url.scheme != "https"
    or canary_url.netloc != "github.com"
    or canary_url.path != "/niharnm/Semper/releases"
    or "canary" not in unquote(canary_url.query).lower()
):
    fail("the Canary download link must point to Semper prereleases")

print(
    f"website check passed: {len(parser.ids)} IDs, "
    f"{len(parser.local_assets)} local assets"
)
