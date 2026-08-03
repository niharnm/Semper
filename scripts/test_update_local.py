#!/usr/bin/env python3

import fcntl
import os
import pty
import select
import shlex
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


class LocalUpdateScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.archive_marker = self.root / "archive-download"
        self.build_marker = self.root / "build"
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
            "#!/bin/sh\n: > \"$SEMPER_TEST_OPEN_MARKER\"\n",
        )
        self.write_executable("osascript", "#!/bin/sh\nexit 0\n")
        self.write_executable("pgrep", "#!/bin/sh\nexit 1\n")
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

    def run_piped_updater(self, response: bytes) -> tuple[int, str]:
        updater = self.updater_fixture()
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "SEMPER_TEST_ARCHIVE_MARKER": str(self.archive_marker),
                "SEMPER_TEST_BUILD_MARKER": str(self.build_marker),
                "SEMPER_TEST_OPEN_MARKER": str(self.open_marker),
            }
        )

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


if __name__ == "__main__":
    unittest.main()
