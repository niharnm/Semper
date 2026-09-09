#!/usr/bin/env python3
"""Run the direct utility tests without launching Semper or its audio engine."""

import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULES = ("Workspace", "Shelf", "Storage")
TEST_PREFIXES = ("Workspace", "Shelf", "SafeEject", "WindowLayout", "MutationAdmissionGate")
# Shell shortcut tests use the app's package dependencies and run through Xcode.
APP_TESTS = {"WorkspaceShortcutIsolationTests.swift"}


with tempfile.TemporaryDirectory(prefix="semper-direct-utilities-") as directory:
    package = pathlib.Path(directory)
    sources = package / "Sources" / "Semper"
    tests = package / "Tests" / "SemperTests"
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    (sources / "MutationAdmissionGate.swift").symlink_to(ROOT / "Semper/Utilities/MutationAdmissionGate.swift")
    (sources / "ModuleRegistry.swift").symlink_to(ROOT / "Semper/Modules/ModuleRegistry.swift")
    for name in ("WindowLayoutModels.swift", "WindowLayoutService.swift", "WindowLayoutTargetTracker.swift"):
        (sources / name).symlink_to(ROOT / "Semper/WindowLayout" / name)
    for module in MODULES:
        source = ROOT / "Semper" / module
        if not source.is_dir():
            raise SystemExit(f"Missing utility module: {module}")
        (sources / module).symlink_to(source, target_is_directory=True)
    for prefix in TEST_PREFIXES:
        matches = sorted((ROOT / "SemperTests").glob(f"{prefix}*.swift"))
        if not matches:
            raise SystemExit(f"Missing tests: {prefix}")
        for source in matches:
            if source.name in APP_TESTS:
                continue
            (tests / source.name).symlink_to(source)
    (package / "Package.swift").write_text(
        """// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SemperDirectUtilitiesTests",
    platforms: [.macOS("15.4")],
    targets: [
        .target(
            name: "Semper",
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        .testTarget(
            name: "SemperTests", dependencies: ["Semper"],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
                .unsafeFlags(["-default-isolation", "MainActor"])
            ]
        )
    ]
)
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["swift", "test", "--package-path", str(package), *sys.argv[1:]],
        check=False,
    )
    raise SystemExit(result.returncode)
