#!/usr/bin/env python3
from __future__ import annotations

import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ReleaseContractTests(unittest.TestCase):
    def test_export_options_preserve_version_and_require_manual_developer_id(self) -> None:
        with (ROOT / "ExportOptions.plist").open("rb") as handle:
            options = plistlib.load(handle)

        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["teamID"], "TEAM_ID_PLACEHOLDER")
        self.assertFalse(options["manageAppVersionAndBuildNumber"])

    def test_release_workflow_stages_reviewable_assets_without_publishing_feed(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text()

        required_fragments = (
            "environment: production-release",
            "base_version: ${{ steps.metadata.outputs.base_version }}",
            'echo "base_version=$BASE_VERSION"',
            "BASE_VERSION: ${{ needs.verify.outputs.base_version }}",
            '"MARKETING_VERSION=$BASE_VERSION"',
            'DMG_NAME="Semper.dmg"',
            'DMG_NAME="$ARTIFACT_STEM.dmg"',
            "draft: true",
            "scripts/notarize-and-log.sh",
            "xcrun stapler staple build/export/Semper.app",
            "xcrun stapler staple \"build/release/$DMG_NAME\"",
            "spctl --assess --type execute",
            "--type open",
            "shasum -a 256",
            "sparkle:edSignature",
            "scripts/validate-release-appcast.py",
            "scripts/verify-sparkle-signature.swift",
        )
        for fragment in required_fragments:
            self.assertIn(fragment, workflow)

        self.assertNotIn("Publish update feed", workflow)
        self.assertNotIn("--method PUT", workflow)
        self.assertNotIn('-f branch="update-feed"', workflow)
        self.assertNotIn('"MARKETING_VERSION=$VERSION"', workflow)
        self.assertNotIn("required+=(SPARKLE_PUBLIC_ED_KEY)", workflow)

        branch_lookup = '"repos/$GITHUB_REPOSITORY/git/ref/heads/update-feed"'
        feed_lookup = '"repos/$GITHUB_REPOSITORY/contents/appcast.xml?ref=update-feed"'
        template_fallback = "cp appcast.xml build/feed/appcast.xml"
        self.assertIn('(HTTP 404)', workflow)
        self.assertLess(workflow.index(branch_lookup), workflow.index(feed_lookup))
        self.assertLess(workflow.index(feed_lookup), workflow.index(template_fallback))

    def test_appcast_validation_selects_the_current_release_url(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            appcast = Path(temporary_directory) / "appcast.xml"
            archive = Path(temporary_directory) / "Semper.dmg"
            archive_contents = b"semper-dmg"
            archive.write_bytes(archive_contents)
            source = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Semper Updates</title>
    <link>https://www.semper.systems/</link>
    <description>Official Semper release feed.</description>
    <item>
      <title>Semper 1.1.0</title>
      <link>https://www.semper.systems/</link>
      <sparkle:version>42</sparkle:version>
      <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
      <enclosure url="https://github.com/niharnm/Semper/releases/download/v1.1.0/Semper.dmg" length="{len(archive_contents)}" sparkle:edSignature="new-signature" />
    </item>
    <item>
      <title>Semper 1.0.0</title>
      <link>https://www.semper.systems/</link>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <enclosure url="https://github.com/niharnm/Semper/releases/download/v1.0.0/Semper.dmg" length="7378898" sparkle:edSignature="old-signature" />
    </item>
  </channel>
</rss>
"""
            appcast.write_text(source, encoding="utf-8")

            command = [
                sys.executable,
                str(ROOT / "scripts/validate-release-appcast.py"),
                str(appcast),
                "niharnm/Semper",
                "v1.1.0",
                "Semper.dmg",
                "",
                "1.1.0",
                "42",
                str(archive),
            ]
            result = subprocess.run(
                command, text=True, capture_output=True, check=False
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "new-signature")

            invalid_cases = {
                "item link": source.replace(
                    "<title>Semper 1.1.0</title>\n"
                    "      <link>https://www.semper.systems/</link>",
                    "<title>Semper 1.1.0</title>\n"
                    "      <link>https://invalid.example/</link>",
                    1,
                ),
                "build": source.replace(
                    "<sparkle:version>42</sparkle:version>",
                    "<sparkle:version>0</sparkle:version>",
                    1,
                ),
                "version": source.replace(
                    "<sparkle:shortVersionString>1.1.0"
                    "</sparkle:shortVersionString>",
                    "<sparkle:shortVersionString>9.9.9"
                    "</sparkle:shortVersionString>",
                    1,
                ),
                "nonnumeric length": source.replace(
                    f'length="{len(archive_contents)}"',
                    'length="not-a-number"',
                    1,
                ),
                "wrong length": source.replace(
                    f'length="{len(archive_contents)}"',
                    f'length="{len(archive_contents) + 1}"',
                    1,
                ),
            }
            for case, invalid_source in invalid_cases.items():
                with self.subTest(case=case):
                    appcast.write_text(invalid_source, encoding="utf-8")
                    invalid_result = subprocess.run(
                        command, text=True, capture_output=True, check=False
                    )
                    self.assertNotEqual(invalid_result.returncode, 0)

    def test_sparkle_signature_verifier_executes_known_ed25519_vector(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            archive = Path(temporary_directory) / "Semper.dmg"
            archive.write_bytes(b"")
            public_key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
            signature = (
                "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+"
                "bRr0lv18FlbviRlUUFDjnoQCw=="
            )

            result = subprocess.run(
                [
                    "xcrun",
                    "swift",
                    str(ROOT / "scripts/verify-sparkle-signature.swift"),
                    str(archive),
                    signature,
                    public_key,
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("signature matches", result.stdout)

            invalid_result = subprocess.run(
                [
                    "xcrun",
                    "swift",
                    str(ROOT / "scripts/verify-sparkle-signature.swift"),
                    str(archive),
                    "A" * 86 + "==",
                    public_key,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(invalid_result.returncode, 1)
            self.assertIn("does not match", invalid_result.stderr)

    def test_canary_guide_matches_current_release_contract(self) -> None:
        guide = (ROOT / "guide/canary.md").read_text()

        self.assertIn("three-integer base version", guide)
        self.assertIn("Mark a verified Stable release as latest", guide)
        self.assertIn("update the `niharnm/homebrew-tap` cask version", guide)
        self.assertNotIn("Until that dependency lands", guide)
        self.assertNotIn("SPARKLE_PUBLIC_ED_KEY", guide)


class DmgScriptTests(unittest.TestCase):
    def test_rejects_a_missing_app(self) -> None:
        result = subprocess.run(
            [
                str(ROOT / "scripts/build-dmg.sh"),
                "/missing/Semper.app",
                "/tmp/Semper.dmg",
                "Developer ID Application: Test (TEAMID1234)",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 66)
        self.assertIn("App bundle does not exist", result.stderr)

    def test_creates_and_verifies_the_requested_dmg(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            app = temporary / "Semper.app"
            app.mkdir()
            output = temporary / "release" / "Semper-1.0.0-1-macOS.dmg"
            bin_directory = temporary / "bin"
            bin_directory.mkdir()

            self._write_executable(
                bin_directory / "npx",
                """#!/bin/bash
set -euo pipefail
output_dir=\"${@: -2:1}\"
touch \"$output_dir/generated.dmg\"
""",
            )
            self._write_executable(
                bin_directory / "codesign",
                """#!/bin/bash
set -euo pipefail
if [[ \"$1\" == \"-dvvv\" ]]; then
  echo \"Authority=Developer ID Application: Test (TEAMID1234)\" >&2
  echo \"Timestamp=Jul 31, 2026 at 12:00:00\" >&2
fi
""",
            )

            environment = os.environ.copy()
            environment["PATH"] = f"{bin_directory}:{environment['PATH']}"
            result = subprocess.run(
                [
                    str(ROOT / "scripts/build-dmg.sh"),
                    str(app),
                    str(output),
                    "Developer ID Application: Test (TEAMID1234)",
                ],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output.is_file())

    @staticmethod
    def _write_executable(path: Path, contents: str) -> None:
        path.write_text(contents)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
