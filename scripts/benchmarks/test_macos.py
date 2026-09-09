import ctypes
import errno
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock
import uuid

import macos


IMAGE_UUID = "01234567-89ab-cdef-0123-456789abcdef"


class NativeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.platform = mock.patch.object(macos.sys, "platform", "darwin")
        self.platform.start()
        self.addCleanup(self.platform.stop)
        self.timebase = mock.patch.object(macos, "_timebase_hz", return_value=24_000_000)
        self.timebase.start()
        self.addCleanup(self.timebase.stop)

    def fill_usage(self, pid: int, flavor: int, pointer: object) -> int:
        self.assertEqual(pid, 42)
        self.assertEqual(flavor, 2)
        usage = ctypes.cast(pointer, ctypes.POINTER(macos.RusageInfoV2)).contents
        usage.ri_uuid[:] = uuid.UUID(IMAGE_UUID).bytes
        usage.ri_user_time = 36_000_000
        usage.ri_system_time = 12_000_000
        usage.ri_resident_size = 27_000_001
        usage.ri_phys_footprint = 9_000_001
        usage.ri_proc_start_abstime = 12345
        return 0

    def test_structure_layout_matches_macos_header(self) -> None:
        self.assertEqual(ctypes.sizeof(macos.RusageInfoV2), 160)
        self.assertEqual(macos.RusageInfoV2.ri_user_time.offset, 16)
        self.assertEqual(macos.RusageInfoV2.ri_resident_size.offset, 64)
        self.assertEqual(macos.RusageInfoV2.ri_phys_footprint.offset, 72)
        self.assertEqual(macos.RusageInfoV2.ri_proc_start_abstime.offset, 80)
        self.assertEqual(macos.RusageInfoV2.ri_diskio_byteswritten.offset, 152)

    def test_sample_converts_ticks_and_preserves_memory_units(self) -> None:
        library = mock.Mock()
        library.proc_pid_rusage.side_effect = self.fill_usage
        with mock.patch.object(macos, "_libproc", return_value=library), mock.patch.object(
            macos.time, "monotonic_ns", side_effect=[100, 120]
        ):
            self.assertEqual(macos.sample(42), {
                "time_ns": 110,
                "cpu_ns": 2_000_000_000,
                "rss_bytes": 27_000_001,
                "footprint_bytes": 9_000_001,
                "start_id": 12345,
                "image_uuid": IMAGE_UUID,
            })

    def test_sample_native_error_is_not_a_zero_measurement(self) -> None:
        library = mock.Mock()
        library.proc_pid_rusage.return_value = -1
        with mock.patch.object(macos, "_libproc", return_value=library), mock.patch.object(
            macos.ctypes, "get_errno", return_value=errno.ESRCH
        ):
            with self.assertRaises(ProcessLookupError):
                macos.sample(42)

    def test_sample_rejects_absent_or_exited_identity(self) -> None:
        for field in ("ri_uuid", "ri_proc_start_abstime", "ri_proc_exit_abstime"):
            with self.subTest(field=field):
                def fill(pid: int, flavor: int, pointer: object) -> int:
                    self.fill_usage(pid, flavor, pointer)
                    usage = ctypes.cast(pointer, ctypes.POINTER(macos.RusageInfoV2)).contents
                    if field == "ri_uuid":
                        usage.ri_uuid[:] = bytes(16)
                    else:
                        setattr(usage, field, 1 if field == "ri_proc_exit_abstime" else 0)
                    return 0

                library = mock.Mock()
                library.proc_pid_rusage.side_effect = fill
                with mock.patch.object(macos, "_libproc", return_value=library):
                    with self.assertRaisesRegex(ValueError, "live process identity"):
                        macos.sample(42)

    def test_pid_validation_precedes_native_calls(self) -> None:
        for value in (0, -1, True, "42", 2**31):
            for function in (macos.sample, macos.process_path):
                with self.subTest(value=value, function=function.__name__):
                    with mock.patch.object(macos, "_libproc") as library:
                        with self.assertRaises(ValueError):
                            function(value)
                        library.assert_not_called()

    def test_process_path_returns_only_requested_executable(self) -> None:
        expected = b"/Applications/Example.app/Contents/MacOS/Example"

        def fill(pid: int, buffer: object, size: int) -> int:
            self.assertEqual((pid, size), (42, 4096))
            buffer.value = expected
            return len(expected)

        library = mock.Mock()
        library.proc_pidpath.side_effect = fill
        with mock.patch.object(macos, "_libproc", return_value=library):
            self.assertEqual(macos.process_path(42), Path(expected.decode()))

    def test_process_path_permission_failure_is_explicit(self) -> None:
        library = mock.Mock()
        library.proc_pidpath.return_value = 0
        with mock.patch.object(macos, "_libproc", return_value=library), mock.patch.object(
            macos.ctypes, "get_errno", return_value=errno.EPERM
        ):
            with self.assertRaises(PermissionError):
                macos.process_path(42)

    def test_nonmacos_rejects_every_entrypoint(self) -> None:
        with mock.patch.object(macos.sys, "platform", "linux"):
            for function, args in (
                (macos.sample, (42,)),
                (macos.process_path, (42,)),
                (macos.app_identity, (Path("missing.app"), 42)),
                (macos.machine_metadata, ()),
            ):
                with self.subTest(function=function.__name__):
                    with self.assertRaisesRegex(RuntimeError, "requires macOS"):
                        function(*args)


class IdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.app = Path(directory.name).resolve() / "Example.app"
        self.executable = self.app / "Contents/MacOS/Example"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"example-executable")
        self.metadata = {
            "CFBundleIdentifier": "org.example.app",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "12",
            "CFBundleExecutable": "Example",
        }
        self.plist = self.app / "Contents/Info.plist"
        self.plist.write_bytes(plistlib.dumps(self.metadata))
        for target, value in (
            ("_require_macos", None),
            ("sample", {"start_id": 12345, "image_uuid": IMAGE_UUID}),
            ("process_path", self.executable),
        ):
            patch = mock.patch.object(macos, target, return_value=value)
            setattr(self, "mock_" + target, patch.start())
            self.addCleanup(patch.stop)
        patch = mock.patch.object(macos.subprocess, "run", return_value=mock.Mock(
            stdout=f"UUID: {IMAGE_UUID.upper()} (arm64) {self.executable}\n"
        ))
        self.command_run = patch.start()
        self.addCleanup(patch.stop)

    def test_identity_requires_matching_process_and_binary(self) -> None:
        identity = macos.app_identity(self.app, 42)
        self.assertEqual(identity, {
            "bundle_id": "org.example.app",
            "version": "1.2.3",
            "build": "12",
            "executable_sha256": hashlib.sha256(b"example-executable").hexdigest(),
            "plist_sha256": hashlib.sha256(self.plist.read_bytes()).hexdigest(),
            "image_uuid": IMAGE_UUID,
            "image_architecture": "arm64",
            "start_id": 12345,
            "executable_path": str(self.executable),
            "app_path": str(self.app),
            "pid": 42,
        })
        self.assertNotIn("release_status", identity)
        self.command_run.assert_called_once_with(
            ["/usr/bin/xcrun", "dwarfdump", "--uuid", str(self.executable)],
            capture_output=True, text=True, check=True, timeout=30,
        )
        self.assertEqual(self.mock_sample.call_count, 2)

    def test_identity_rejects_wrong_app_and_changed_process_path(self) -> None:
        for paths in ([self.plist], [self.executable, self.plist]):
            with self.subTest(paths=paths):
                self.mock_process_path.side_effect = paths
                with self.assertRaisesRegex(ValueError, "executable"):
                    macos.app_identity(self.app, 42)

    def test_identity_rejects_restarted_or_execed_process(self) -> None:
        for changed in (
            {"start_id": 12346, "image_uuid": IMAGE_UUID},
            {"start_id": 12345, "image_uuid": "11234567-89ab-cdef-0123-456789abcdef"},
        ):
            with self.subTest(changed=changed):
                self.mock_sample.side_effect = [
                    {"start_id": 12345, "image_uuid": IMAGE_UUID}, changed
                ]
                with self.assertRaisesRegex(ValueError, "Process identity changed"):
                    macos.app_identity(self.app, 42)

    def test_identity_rejects_missing_or_invalid_metadata(self) -> None:
        for field in self.metadata:
            for value in (None, "", " ", 12):
                with self.subTest(field=field, value=value):
                    metadata = self.metadata.copy()
                    if value is None:
                        del metadata[field]
                    else:
                        metadata[field] = value
                    self.plist.write_bytes(plistlib.dumps(metadata))
                    with self.assertRaisesRegex(ValueError, "metadata requires"):
                        macos.app_identity(self.app, 42)

    def test_identity_rejects_executable_outside_bundle(self) -> None:
        self.metadata["CFBundleExecutable"] = "../Info.plist"
        self.plist.write_bytes(plistlib.dumps(self.metadata))
        with self.assertRaisesRegex(ValueError, "one file"):
            macos.app_identity(self.app, 42)

    def test_identity_rejects_binary_uuid_mismatch_or_missing_uuid(self) -> None:
        for output in ("", "UUID: invalid (arm64) Example", f"UUID: {'0' * 8}-89AB-CDEF-0123-456789ABCDEF (arm64) Example"):
            with self.subTest(output=output):
                self.command_run.return_value.stdout = output
                with self.assertRaisesRegex(ValueError, "UUID does not match"):
                    macos.app_identity(self.app, 42)

    def test_identity_accepts_matching_uuid_in_universal_executable(self) -> None:
        self.command_run.return_value.stdout += "UUID: 11234567-89AB-CDEF-0123-456789ABCDEF (x86_64) Example\n"
        identity = macos.app_identity(self.app, 42)
        self.assertEqual(identity["image_uuid"], IMAGE_UUID)
        self.assertEqual(identity["image_architecture"], "arm64")

    def test_identity_records_intel_target_independently_of_collector(self) -> None:
        self.command_run.return_value.stdout = f"UUID: {IMAGE_UUID.upper()} (x86_64) Example\n"
        with mock.patch.object(macos.platform, "machine", return_value="arm64"):
            self.assertEqual(macos.app_identity(self.app, 42)["image_architecture"], "x86_64")

    def test_identity_rejects_ambiguous_uuid_architecture(self) -> None:
        self.command_run.return_value.stdout += f"UUID: {IMAGE_UUID.upper()} (x86_64) Example\n"
        with self.assertRaisesRegex(ValueError, "ambiguous executable architecture"):
            macos.app_identity(self.app, 42)

    def test_missing_app_or_executable_is_an_error(self) -> None:
        with self.assertRaises(FileNotFoundError):
            macos.app_identity(self.app / "Absent.app", 42)
        self.metadata["CFBundleExecutable"] = "Absent"
        self.plist.write_bytes(plistlib.dumps(self.metadata))
        with self.assertRaises(FileNotFoundError):
            macos.app_identity(self.app, 42)

    def test_missing_developer_tools_is_an_error(self) -> None:
        self.command_run.side_effect = subprocess.CalledProcessError(1, ["xcrun"])
        with self.assertRaises(subprocess.CalledProcessError):
            macos.app_identity(self.app, 42)


class MachineTests(unittest.TestCase):
    def setUp(self) -> None:
        macos._timebase_hz.cache_clear()
        self.addCleanup(macos._timebase_hz.cache_clear)
        self.values = {
            "hw.model": "MacExample1,1\n",
            "machdep.cpu.brand_string": "Apple M Example\n",
            "hw.logicalcpu": "8\n",
            "hw.memsize": "17179869184\n",
            "-productVersion": "15.4\n",
            "-buildVersion": "24E000\n",
            "hw.tbfrequency": "24000000\n",
            "batt": "Now drawing from 'AC Power'\n -InternalBattery-0 (id=123456)\t100%; charged\n",
        }

    def command(self, args: list, **kwargs: object) -> mock.Mock:
        self.assertTrue(kwargs["check"])
        return mock.Mock(stdout=self.values[args[-1]])

    def test_machine_metadata_contains_only_allowlisted_values(self) -> None:
        with mock.patch.object(macos, "_require_macos"), mock.patch.object(
            macos.subprocess, "run", side_effect=self.command
        ), mock.patch.object(macos.platform, "machine", return_value="arm64"), mock.patch.object(
            macos.platform, "python_version", return_value="3.10.0"
        ):
            metadata = macos.machine_metadata()
        self.assertEqual(metadata, {
            "model": "MacExample1,1", "chip": "Apple M Example", "logical_cpus": 8,
            "memory_bytes": 17179869184, "os_version": "15.4", "os_build": "24E000",
            "architecture": "arm64", "python_version": "3.10.0",
            "power_source": "AC Power", "timebase_hz": 24000000,
        })
        self.assertNotIn("123456", str(metadata))

    def test_machine_metadata_rejects_unknown_power_source(self) -> None:
        self.values["batt"] = "No power source found"
        with mock.patch.object(macos, "_require_macos"), mock.patch.object(
            macos.subprocess, "run", side_effect=self.command
        ):
            with self.assertRaisesRegex(ValueError, "Power source"):
                macos.machine_metadata()

    def test_timebase_rejects_missing_nonnumeric_or_zero_frequency(self) -> None:
        for value in ("", "unknown", "0", "-24"):
            with self.subTest(value=value):
                self.values["hw.tbfrequency"] = value
                with mock.patch.object(macos.subprocess, "run", side_effect=self.command):
                    with self.assertRaises(ValueError):
                        macos._timebase_hz()


if __name__ == "__main__":
    unittest.main()
