#!/usr/bin/env python3

import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from types import ModuleType
from unittest.mock import patch
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parents[1]
CHECK_SCRIPT = ROOT / "scripts" / "check-website.py"
SUBMIT_SCRIPT = ROOT / "scripts" / "submit-indexnow.py"


def load_submit_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("submit_indexnow", SUBMIT_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load submit-indexnow.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WebsiteCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(CHECK_SCRIPT, self.root / "scripts" / CHECK_SCRIPT.name)
        shutil.copytree(ROOT / "website", self.root / "website")
        shutil.copy2(ROOT / "LICENSE", self.root / "LICENSE")
        shutil.copy2(ROOT / "README.md", self.root / "README.md")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_check(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.root / "scripts" / CHECK_SCRIPT.name)],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_lastmod_accepts_stripped_date_and_w3c_datetime(self) -> None:
        sitemap = self.root / "website" / "sitemap.xml"
        original = sitemap.read_text(encoding="utf-8")
        marker = "<lastmod>2026-07-31</lastmod>"

        for value in (" 2026-07-31 ", " 2026-07-31T12:34:56Z "):
            with self.subTest(value=value):
                sitemap.write_text(
                    original.replace(marker, f"<lastmod>{value}</lastmod>", 1),
                    encoding="utf-8",
                )
                result = self.run_check()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_whitespace_only_description_is_rejected(self) -> None:
        index = self.root / "website" / "index.html"
        source = index.read_text(encoding="utf-8")
        source, replacements = re.subn(
            r'(<meta\s+name="description"\s+content=")[^"]*',
            r"\1   ",
            source,
            count=1,
        )
        self.assertEqual(replacements, 1)
        index.write_text(source, encoding="utf-8")

        result = self.run_check()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("index.html is missing a meta description", result.stderr)

    def test_dot_slash_index_link_is_rejected(self) -> None:
        index = self.root / "website" / "index.html"
        source = index.read_text(encoding="utf-8")
        self.assertIn("</body>", source)
        index.write_text(
            source.replace(
                "</body>",
                '<a href="./index.html">Duplicate homepage</a>\n</body>',
                1,
            ),
            encoding="utf-8",
        )

        result = self.run_check()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "index.html links to duplicate homepage path: ./index.html",
            result.stderr,
        )


class IndexNowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_submit_module()

    def test_index_html_url_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            SystemExit,
            "Use the canonical homepage URL instead of",
        ):
            self.module.validate_urls(
                ["https://www.semper.systems/index.html"]
            )

    def run_main_with_error(self, error: Exception) -> str:
        arguments = [
            "submit-indexnow.py",
            "https://www.semper.systems/about.html",
        ]
        with patch.object(sys, "argv", arguments), patch.object(
            self.module, "urlopen", side_effect=error
        ), self.assertRaises(SystemExit) as raised:
            self.module.main()
        return str(raised.exception)

    def test_url_error_is_concise(self) -> None:
        message = self.run_main_with_error(URLError("network unavailable"))
        self.assertEqual(
            message,
            "IndexNow request failed: network unavailable",
        )

    def test_timeout_error_is_concise(self) -> None:
        message = self.run_main_with_error(TimeoutError("request timed out"))
        self.assertEqual(message, "IndexNow request failed: request timed out")

    def test_http_error_preserves_response_detail(self) -> None:
        error = HTTPError(
            self.module.ENDPOINT,
            429,
            "Too Many Requests",
            hdrs=None,
            fp=BytesIO(b"rate limit exceeded"),
        )

        message = self.run_main_with_error(error)

        self.assertEqual(
            message,
            "IndexNow rejected the request with HTTP 429: rate limit exceeded",
        )


if __name__ == "__main__":
    unittest.main()
