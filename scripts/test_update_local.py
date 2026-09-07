#!/usr/bin/env python3
from __future__ import annotations

import fcntl
import os
import pty
import select
import shlex
import shutil
import stat
import subprocess
import tempfile
import termios
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPDATE_SCRIPT = ROOT / "scripts" / "update-local.sh"
UPDATE_COMMAND = (
    "/usr/bin/curl -fsSL "
    "https://raw.githubusercontent.com/niharnm/Semper/main/"
    "scripts/update-local.sh | /bin/bash"
)
APPLE_DEVELOPMENT_HASH = "1111111111111111111111111111111111111111"
APPLE_DEVELOPMENT_TEAM = "APPLE12345"
DEVELOPER_ID_HASH = "2222222222222222222222222222222222222222"
DEVELOPER_ID_TEAM = "TEAMID1234"
OTHER_DEVELOPER_ID_HASH = "3333333333333333333333333333333333333333"
OTHER_DEVELOPER_ID_TEAM = "OTHER12345"
WRONG_TEAM = "WRONG12345"


class LocalUpdateScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.archive_marker = self.root / "archive-download"
        self.build_marker = self.root / "build"
        self.build_arguments_marker = self.root / "build-arguments"
        self.codesign_marker = self.root / "codesign"
        self.open_marker = self.root / "open"
        self.install_path = self.root / "Applications" / "Semper.app"
        self.install_path.mkdir(parents=True)
        (self.install_path / "old-app").write_text("old", encoding="utf-8")

        self.write_executable("uname", "#!/bin/sh\necho Darwin\n")
        self.write_executable(
            "git",
            "#!/bin/sh\n"
            "echo 0123456789abcdef0123456789abcdef01234567\n",
        )
        self.write_executable(
            "curl",
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  *project.pbxproj*)\n"
            "    echo 'MARKETING_VERSION = 9.8.7;'\n"
            "    ;;\n"
            "  *)\n"
            "    : > \"$SEMPER_TEST_ARCHIVE_MARKER\"\n"
            "    while [ \"$#\" -gt 0 ]; do\n"
            "      if [ \"$1\" = '-o' ]; then\n"
            "        shift\n"
            "        : > \"$1\"\n"
            "        exit 0\n"
            "      fi\n"
            "      shift\n"
            "    done\n"
            "    exit 64\n"
            "    ;;\n"
            "esac\n",
        )
        self.write_executable(
            "ditto",
            "#!/bin/sh\n"
            "if [ \"$1\" = '-x' ]; then\n"
            "  destination=$4\n"
            "  project=\"$destination/Semper-0123456789abcdef0123456789abcdef01234567/Semper.xcodeproj\"\n"
            "  mkdir -p \"$project\"\n"
            "  : > \"$project/project.pbxproj\"\n"
            "else\n"
            "  cp -R \"$1\" \"$2\"\n"
            "fi\n",
        )
        self.write_executable(
            "xcodebuild",
            "#!/bin/sh\n"
            ": > \"$SEMPER_TEST_BUILD_MARKER\"\n"
            "printf '%s\\n' \"$@\" > \"$SEMPER_TEST_BUILD_ARGUMENTS_MARKER\"\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  if [ \"$1\" = '-derivedDataPath' ]; then\n"
            "    shift\n"
            "    product=\"$1/Build/Products/Release/Semper.app\"\n"
            "    mkdir -p \"$product/Contents/MacOS\"\n"
            "    : > \"$product/Contents/Info.plist\"\n"
            "    echo executable > \"$product/Contents/MacOS/Semper\"\n"
            "    chmod +x \"$product/Contents/MacOS/Semper\"\n"
            "    exit 0\n"
            "  fi\n"
            "  shift\n"
            "done\n"
            "exit 64\n",
        )
        self.write_executable(
            "open",
            "#!/bin/sh\n"
            ": > \"$SEMPER_TEST_OPEN_MARKER\"\n"
            "if [ \"${SEMPER_TEST_OPEN_MODE:-success}\" = failure ]; then exit 1; fi\n",
        )
        self.write_executable("osascript", "#!/bin/sh\nexit 0\n")
        self.write_executable("pgrep", "#!/bin/sh\nexit 1\n")
        self.write_executable(
            "security",
            "#!/bin/sh\n"
            "mode=${SEMPER_TEST_IDENTITY_MODE:-both}\n"
            "case \"$1:$mode\" in\n"
            "  find-identity:failure) exit 1 ;;\n"
            "  find-identity:none) echo '     0 valid identities found'; exit 0 ;;\n"
            "  find-identity:malformed)\n"
            "    echo '  1) NOT_A_HASH \"Developer ID Application: Test (TEAMID1234)\"'\n"
            "    echo '     1 valid identities found'\n"
            "    exit 0\n"
            "    ;;\n"
            "  find-identity:apple-only)\n"
            f"    echo '  1) {APPLE_DEVELOPMENT_HASH} \"Apple Development: Contributor (CERTID1234)\"'\n"
            "    echo '     1 valid identities found'\n"
            "    exit 0\n"
            "    ;;\n"
            "  find-identity:multiple-forward)\n"
            f"    echo '  1) {OTHER_DEVELOPER_ID_HASH} \"Developer ID Application: Another ({OTHER_DEVELOPER_ID_TEAM})\"'\n"
            f"    echo '  2) {APPLE_DEVELOPMENT_HASH} \"Apple Development: Contributor (CERTID1234)\"'\n"
            f"    echo '  3) {DEVELOPER_ID_HASH} \"Developer ID Application: Test ({DEVELOPER_ID_TEAM})\"'\n"
            "    echo '     3 valid identities found'\n"
            "    exit 0\n"
            "    ;;\n"
            "  find-identity:multiple-reverse)\n"
            f"    echo '  1) {DEVELOPER_ID_HASH} \"Developer ID Application: Test ({DEVELOPER_ID_TEAM})\"'\n"
            f"    echo '  2) {APPLE_DEVELOPMENT_HASH} \"Apple Development: Contributor (CERTID1234)\"'\n"
            f"    echo '  3) {OTHER_DEVELOPER_ID_HASH} \"Developer ID Application: Another ({OTHER_DEVELOPER_ID_TEAM})\"'\n"
            "    echo '     3 valid identities found'\n"
            "    exit 0\n"
            "    ;;\n"
            "  find-identity:*)\n"
            f"    echo '  1) {APPLE_DEVELOPMENT_HASH} \"Apple Development: Contributor (CERTID1234)\"'\n"
            f"    echo '  2) {DEVELOPER_ID_HASH} \"Developer ID Application: Test ({DEVELOPER_ID_TEAM})\"'\n"
            "    echo '     2 valid identities found'\n"
            "    exit 0\n"
            "    ;;\n"
            "  find-certificate:apple-only)\n"
            f"    echo 'SHA-1 hash: {APPLE_DEVELOPMENT_HASH}'\n"
            "    echo '-----BEGIN CERTIFICATE-----'\n"
            "    echo 'APPLE_DEVELOPMENT_CERTIFICATE'\n"
            "    echo '-----END CERTIFICATE-----'\n"
            "    exit 0\n"
            "    ;;\n"
            "  find-certificate:*)\n"
            f"    echo 'SHA-1 hash: {APPLE_DEVELOPMENT_HASH}'\n"
            "    echo '-----BEGIN CERTIFICATE-----'\n"
            "    echo 'APPLE_DEVELOPMENT_CERTIFICATE'\n"
            "    echo '-----END CERTIFICATE-----'\n"
            f"    echo 'SHA-1 hash: {DEVELOPER_ID_HASH}'\n"
            "    echo '-----BEGIN CERTIFICATE-----'\n"
            "    echo 'DEVELOPER_ID_CERTIFICATE'\n"
            "    echo '-----END CERTIFICATE-----'\n"
            f"    echo 'SHA-1 hash: {OTHER_DEVELOPER_ID_HASH}'\n"
            "    echo '-----BEGIN CERTIFICATE-----'\n"
            "    echo 'OTHER_DEVELOPER_ID_CERTIFICATE'\n"
            "    echo '-----END CERTIFICATE-----'\n"
            "    if [ \"$mode\" = large-certificate-list ]; then\n"
            "      index=0\n"
            "      while [ \"$index\" -lt 20000 ]; do\n"
            "        echo \"TRAILING-CERTIFICATE-DATA-$index\"\n"
            "        index=$((index + 1))\n"
            "      done\n"
            "    fi\n"
            "    exit 0\n"
            "    ;;\n"
            "esac\n"
            "exit 64\n",
        )
        self.write_executable(
            "openssl",
            "#!/bin/sh\n"
            "certificate=$(cat)\n"
            "case \"$certificate\" in\n"
            "  *OTHER_DEVELOPER_ID_CERTIFICATE*)\n"
            f"    echo 'subject=C=US,O=Test,OU={OTHER_DEVELOPER_ID_TEAM},CN=Developer ID Application: Another'\n"
            "    ;;\n"
            "  *DEVELOPER_ID_CERTIFICATE*)\n"
            f"    echo 'subject=C=US,O=Test,OU={DEVELOPER_ID_TEAM},CN=Developer ID Application: Test'\n"
            "    ;;\n"
            "  *APPLE_DEVELOPMENT_CERTIFICATE*)\n"
            f"    echo 'subject=C=US,O=Test,OU={APPLE_DEVELOPMENT_TEAM},CN=Apple Development: Contributor'\n"
            "    ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n",
        )
        self.write_executable(
            "codesign",
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> \"$SEMPER_TEST_CODESIGN_MARKER\"\n"
            "app_path=${@: -1}\n"
            "mode=${SEMPER_TEST_CODESIGN_MODE:-valid}\n"
            "identity_mode=${SEMPER_TEST_IDENTITY_MODE:-both}\n"
            f"team_id={DEVELOPER_ID_TEAM}\n"
            f"authority='Developer ID Application: Test ({DEVELOPER_ID_TEAM})'\n"
            f"if [[ \"$identity_mode\" == apple-* ]]; then team_id={APPLE_DEVELOPMENT_TEAM}; authority='Apple Development: Contributor (CERTID1234)'; fi\n"
            "if [[ \"$identity_mode\" == current-unavailable ]]; then authority='Developer ID Application: Missing (MISSING1234)'; fi\n"
            "if [[ \"$1\" == --verify ]]; then\n"
            "  if [[ \"$mode\" == invalid-built && \"$app_path\" == */DerivedData/* ]]; then exit 1; fi\n"
            "  if [[ \"$mode\" == invalid-staged && \"$app_path\" == *.Semper.app.update.* ]]; then exit 1; fi\n"
            "  if [[ \"$mode\" == invalid-installed && \"$app_path\" == */Applications/Semper.app ]]; then exit 1; fi\n"
            "  exit 0\n"
            "fi\n"
            "if [[ \"$1\" == -dvvv ]]; then\n"
            "  if [[ (\"$mode\" == adhoc-built && \"$app_path\" == */DerivedData/*) || (\"$mode\" == adhoc-installed && -e \"$app_path/old-app\") ]]; then\n"
            "    echo 'Identifier=Semper' >&2\n"
            "    echo 'CodeDirectory v=20400 flags=0x20002(adhoc,linker-signed)' >&2\n"
            "    echo 'Signature=adhoc' >&2\n"
            "    echo 'TeamIdentifier=not set' >&2\n"
            "  else\n"
            f"    if [[ \"$mode\" == wrong-team-built && \"$app_path\" == */DerivedData/* ]]; then team_id={WRONG_TEAM}; fi\n"
            "    echo 'Identifier=systems.semper.Semper' >&2\n"
            "    echo 'CodeDirectory v=20500 flags=0x10000(runtime)' >&2\n"
            "    echo \"TeamIdentifier=$team_id\" >&2\n"
            "    echo \"Authority=$authority\" >&2\n"
            "  fi\n"
            "  exit 0\n"
            "fi\n"
            "if [[ \"$1\" == -d && \"$2\" == -r- ]]; then\n"
            "  if [[ \"$mode\" == compound-cdhash-built && \"$app_path\" == */DerivedData/* ]]; then\n"
            "    echo \"designated => anchor apple generic and identifier \\\"systems.semper.Semper\\\" and certificate leaf[subject.OU] = $team_id and cdhash H1234\" >&2\n"
            "  elif [[ \"$mode\" == missing-team-built && \"$app_path\" == */DerivedData/* ]]; then\n"
            "    echo 'designated => anchor apple generic and identifier \"systems.semper.Semper\"' >&2\n"
            "  else\n"
            "    echo \"designated => anchor apple generic and identifier \\\"systems.semper.Semper\\\" and certificate leaf[subject.OU] = $team_id\" >&2\n"
            "  fi\n"
            "  exit 0\n"
            "fi\n"
            "exit 64\n",
        )
        self.write_executable(
            "shasum",
            "#!/bin/sh\n"
            "echo '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  file'\n",
        )
        self.plist_buddy = self.bin / "PlistBuddy"
        self.write_executable(
            "PlistBuddy",
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  *CFBundleShortVersionString*) echo 9.8.7 ;;\n"
            "  *CFBundleIdentifier*) echo systems.semper.Semper ;;\n"
            "  *) exit 64 ;;\n"
            "esac\n",
        )

    def updater_fixture(self) -> Path:
        source = UPDATE_SCRIPT.read_text(encoding="utf-8")
        source = source.replace(
            'readonly INSTALL_PATH="/Applications/Semper.app"',
            f'readonly INSTALL_PATH="{self.install_path}"',
            1,
        )
        source = source.replace(
            "/usr/libexec/PlistBuddy",
            str(self.plist_buddy),
        )
        fixture = self.root / "update-local.sh"
        fixture.write_text(source, encoding="utf-8")
        fixture.chmod(fixture.stat().st_mode | stat.S_IXUSR)
        return fixture

    def run_piped_updater(
        self,
        response: bytes,
        environment_overrides: dict[str, str] | None = None,
    ) -> tuple[int, str]:
        updater = self.updater_fixture()
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "SEMPER_TEST_ARCHIVE_MARKER": str(self.archive_marker),
                "SEMPER_TEST_BUILD_MARKER": str(self.build_marker),
                "SEMPER_TEST_BUILD_ARGUMENTS_MARKER": str(
                    self.build_arguments_marker
                ),
                "SEMPER_TEST_CODESIGN_MARKER": str(self.codesign_marker),
                "SEMPER_TEST_OPEN_MARKER": str(self.open_marker),
            }
        )
        if environment_overrides:
            environment.update(environment_overrides)

        master, slave = pty.openpty()

        def attach_controlling_terminal() -> None:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        command = f"cat {shlex.quote(str(updater))} | bash"
        process = subprocess.Popen(
            ["bash", "-c", command],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=environment,
            preexec_fn=attach_controlling_terminal,
            close_fds=True,
        )
        os.close(slave)

        output = bytearray()
        deadline = time.monotonic() + 10
        try:
            while b"Continue? [y/N]" not in output:
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0, output.decode(errors="replace"))
                ready, _, _ = select.select([master], [], [], remaining)
                self.assertTrue(ready, output.decode(errors="replace"))
                output.extend(os.read(master, 4096))

            os.write(master, response)
            while process.poll() is None:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        output.extend(os.read(master, 4096))
                    except OSError:
                        break
                if time.monotonic() > deadline:
                    process.kill()
                    self.fail("updater did not exit after confirmation")
            process.wait(timeout=2)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()

        return process.returncode, output.decode(errors="replace")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_executable(self, name: str, source: str) -> None:
        path = self.bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def test_script_has_valid_bash_syntax(self) -> None:
        result = subprocess.run(
            ["bash", "-n", str(UPDATE_SCRIPT)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_command_is_used_by_all_copy_surfaces(self) -> None:
        paths = (
            ROOT / "README.md",
            ROOT / "website" / "index.html",
            ROOT
            / "Semper"
            / "Views"
            / "Settings"
            / "Tabs"
            / "UpdatesTab.swift",
        )

        for path in paths:
            with self.subTest(path=path):
                self.assertIn(UPDATE_COMMAND, path.read_text(encoding="utf-8"))

    def test_piped_command_prompts_and_cancel_does_not_replace_app(self) -> None:
        returncode, rendered = self.run_piped_updater(b"n\n")

        self.assertEqual(returncode, 0, rendered)
        self.assertIn("GitHub main: 9.8.7 (01234567)", rendered)
        self.assertIn("Update cancelled.", rendered)
        self.assertFalse(self.archive_marker.exists())
        self.assertFalse(self.build_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_confirmation_replaces_old_app_and_opens_new_app(self) -> None:
        returncode, rendered = self.run_piped_updater(b"y\n")

        self.assertEqual(returncode, 0, rendered)
        self.assertIn("Semper 9.8.7 (01234567) is installed and open.", rendered)
        self.assertTrue(self.archive_marker.is_file())
        self.assertTrue(self.build_marker.is_file())
        self.assertTrue(self.open_marker.is_file())
        self.assertFalse((self.install_path / "old-app").exists())
        self.assertTrue(
            (self.install_path / "Contents" / "MacOS" / "Semper").is_file()
        )
        build_arguments = self.build_arguments_marker.read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertIn(f"CODE_SIGN_IDENTITY={DEVELOPER_ID_HASH}", build_arguments)
        self.assertIn("CODE_SIGN_STYLE=Manual", build_arguments)
        self.assertIn(f"DEVELOPMENT_TEAM={DEVELOPER_ID_TEAM}", build_arguments)
        self.assertIn("CODE_SIGNING_REQUIRED=YES", build_arguments)
        self.assertIn("CODE_SIGNING_ALLOWED=YES", build_arguments)
        self.assertNotIn("CODE_SIGN_IDENTITY=", build_arguments)
        self.assertIn(
            f"Signing with Developer ID Application: Test ({DEVELOPER_ID_TEAM})",
            rendered,
        )

    def test_apple_development_identity_is_used_as_fallback(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "apple-only"},
        )

        self.assertEqual(returncode, 0, rendered)
        build_arguments = self.build_arguments_marker.read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertIn(
            f"CODE_SIGN_IDENTITY={APPLE_DEVELOPMENT_HASH}", build_arguments
        )
        self.assertIn(
            f"DEVELOPMENT_TEAM={APPLE_DEVELOPMENT_TEAM}", build_arguments
        )

    def test_existing_apple_development_signer_is_preserved(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "apple-current-multiple"},
        )

        self.assertEqual(returncode, 0, rendered)
        build_arguments = self.build_arguments_marker.read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertIn(
            f"CODE_SIGN_IDENTITY={APPLE_DEVELOPMENT_HASH}", build_arguments
        )
        self.assertIn(
            f"DEVELOPMENT_TEAM={APPLE_DEVELOPMENT_TEAM}", build_arguments
        )

    def test_current_signer_is_stable_across_identity_ordering(self) -> None:
        for identity_mode in ("multiple-forward", "multiple-reverse"):
            with self.subTest(identity_mode=identity_mode):
                returncode, rendered = self.run_piped_updater(
                    b"y\n",
                    {"SEMPER_TEST_IDENTITY_MODE": identity_mode},
                )
                self.assertEqual(returncode, 0, rendered)
                build_arguments = self.build_arguments_marker.read_text(
                    encoding="utf-8"
                ).splitlines()
                self.assertIn(
                    f"CODE_SIGN_IDENTITY={DEVELOPER_ID_HASH}", build_arguments
                )

    def test_no_signing_identity_stops_before_build_or_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "none"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("no valid Developer ID Application or Apple Development", rendered)
        self.assertIn("releases/latest", rendered)
        self.assertFalse(self.archive_marker.exists())
        self.assertFalse(self.build_marker.exists())
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_keychain_read_failure_stops_before_build_or_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "failure"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("could not read code-signing identities", rendered)
        self.assertFalse(self.archive_marker.exists())
        self.assertFalse(self.build_marker.exists())
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_missing_current_signer_stops_before_build_or_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "current-unavailable"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("no valid identity matches the current Semper signer", rendered)
        self.assertFalse(self.archive_marker.exists())
        self.assertFalse(self.build_marker.exists())
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_malformed_signing_identity_stops_before_build_or_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "malformed"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("selected code-signing identity is malformed", rendered)
        self.assertFalse(self.archive_marker.exists())
        self.assertFalse(self.build_marker.exists())
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_ad_hoc_built_signature_stops_before_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "adhoc-built"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("The app has an ad hoc signature.", rendered)
        self.assertIn("built app does not have a valid persistent code signature", rendered)
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_ad_hoc_installed_app_migrates_to_persistent_signing(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "adhoc-installed"},
        )

        self.assertEqual(returncode, 0, rendered)
        self.assertIn(
            f"Signing with Developer ID Application: Test ({DEVELOPER_ID_TEAM})",
            rendered,
        )
        self.assertFalse((self.install_path / "old-app").exists())
        self.assertTrue(
            (self.install_path / "Contents" / "MacOS" / "Semper").is_file()
        )

    def test_compound_code_hash_requirement_stops_before_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "compound-cdhash-built"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("contains a code-hash constraint", rendered)
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_missing_team_requirement_stops_before_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "missing-team-built"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("has no matching Apple Team ID", rendered)
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_wrong_team_built_signature_stops_before_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "wrong-team-built"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("unexpected Apple Team ID", rendered)
        self.assertIn("built app does not have a valid persistent code signature", rendered)
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_staged_signature_failure_stops_before_replacement(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "invalid-staged"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("staged app does not have a valid persistent code signature", rendered)
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())
        self.assertEqual(list(self.install_path.parent.glob(".Semper.app.update.*")), [])

    def test_installed_signature_failure_restores_previous_app(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_CODESIGN_MODE": "invalid-installed"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("installed app does not have a valid persistent code signature", rendered)
        self.assertIn("The old app was restored.", rendered)
        self.assertFalse(self.open_marker.exists())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_open_failure_restores_previous_app(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_OPEN_MODE": "failure"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("macOS could not open it", rendered)
        self.assertIn("The old app was restored.", rendered)
        self.assertTrue(self.open_marker.is_file())
        self.assertTrue((self.install_path / "old-app").is_file())

    def test_fresh_install_open_failure_removes_new_app(self) -> None:
        shutil.rmtree(self.install_path)

        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_OPEN_MODE": "failure"},
        )

        self.assertEqual(returncode, 1, rendered)
        self.assertIn("macOS could not open it", rendered)
        self.assertIn("The new app was removed.", rendered)
        self.assertNotIn("The old app was restored.", rendered)
        self.assertTrue(self.open_marker.is_file())
        self.assertFalse(self.install_path.exists())

    def test_large_certificate_list_does_not_break_identity_matching(self) -> None:
        returncode, rendered = self.run_piped_updater(
            b"y\n",
            {"SEMPER_TEST_IDENTITY_MODE": "large-certificate-list"},
        )

        self.assertEqual(returncode, 0, rendered)


if __name__ == "__main__":
    unittest.main()
