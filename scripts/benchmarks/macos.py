"""Read-only macOS metrics for one explicitly selected process."""

import ctypes
import functools
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import time
import uuid


class RusageInfoV2(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "ri_user_time",
            "ri_system_time",
            "ri_pkg_idle_wkups",
            "ri_interrupt_wkups",
            "ri_pageins",
            "ri_wired_size",
            "ri_resident_size",
            "ri_phys_footprint",
            "ri_proc_start_abstime",
            "ri_proc_exit_abstime",
            "ri_child_user_time",
            "ri_child_system_time",
            "ri_child_pkg_idle_wkups",
            "ri_child_interrupt_wkups",
            "ri_child_pageins",
            "ri_child_elapsed_abstime",
            "ri_diskio_bytesread",
            "ri_diskio_byteswritten",
        )
    ]


def _require_macos() -> None:
    if sys.platform != "darwin":
        raise RuntimeError("Native process measurement requires macOS")


def _check_pid(pid: int) -> None:
    if type(pid) is not int or not 0 < pid <= 2**31 - 1:
        raise ValueError("PID must be a positive signed 32-bit integer")


@functools.lru_cache(maxsize=1)
def _libproc() -> ctypes.CDLL:
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    library.proc_pid_rusage.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    return library


@functools.lru_cache(maxsize=1)
def _timebase_hz() -> int:
    frequency = int(
        subprocess.run(
            ["/usr/sbin/sysctl", "-n", "hw.tbfrequency"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        ).stdout.strip()
    )
    if frequency <= 0:
        raise ValueError("Hardware timebase frequency must be positive")
    return frequency


def sample(pid: int) -> dict:
    _require_macos()
    _check_pid(pid)
    library = _libproc()
    timebase_hz = _timebase_hz()
    usage = RusageInfoV2()
    before_ns = time.monotonic_ns()
    result = library.proc_pid_rusage(pid, 2, ctypes.byref(usage))
    after_ns = time.monotonic_ns()
    if result != 0:
        raise OSError(ctypes.get_errno(), f"proc_pid_rusage failed for PID {pid}")
    image = uuid.UUID(bytes=bytes(usage.ri_uuid))
    if not image.int or not usage.ri_proc_start_abstime or usage.ri_proc_exit_abstime:
        raise ValueError(f"PID {pid} has no verifiable live process identity")
    # Kernel CPU counters use hardware ticks, including when Python runs in Rosetta.
    cpu_ns = (usage.ri_user_time + usage.ri_system_time) * 1_000_000_000 // timebase_hz
    return {
        "time_ns": (before_ns + after_ns) // 2,
        "cpu_ns": cpu_ns,
        "rss_bytes": usage.ri_resident_size,
        "footprint_bytes": usage.ri_phys_footprint,
        "start_id": usage.ri_proc_start_abstime,
        "image_uuid": str(image),
    }


def process_path(pid: int) -> Path:
    _require_macos()
    _check_pid(pid)
    buffer = ctypes.create_string_buffer(4096)
    result = _libproc().proc_pidpath(pid, buffer, len(buffer))
    if result <= 0:
        raise OSError(ctypes.get_errno(), f"proc_pidpath failed for PID {pid}")
    path = Path(os.fsdecode(buffer.value))
    if result >= len(buffer) or not path.is_absolute():
        raise ValueError(f"PID {pid} returned an invalid executable path")
    return path


def app_identity(app: Path, pid: int) -> dict:
    """Validate a running app; requires xcrun and dwarfdump from Apple tools."""
    _require_macos()
    _check_pid(pid)
    app = app.resolve(strict=True)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("App path must refer to an existing .app directory")
    before = sample(pid)
    plist_bytes = (app / "Contents/Info.plist").read_bytes()
    metadata = plistlib.loads(plist_bytes)
    fields = (
        "CFBundleIdentifier",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "CFBundleExecutable",
    )
    if not isinstance(metadata, dict) or any(
        not isinstance(metadata.get(field), str) or not metadata[field].strip()
        for field in fields
    ):
        raise ValueError("App metadata requires nonempty identifier, version, build and executable")
    executable_name = metadata["CFBundleExecutable"]
    if Path(executable_name).name != executable_name or executable_name in (".", ".."):
        raise ValueError("CFBundleExecutable must name one file in Contents/MacOS")
    executable = (app / "Contents/MacOS" / executable_name).resolve(strict=True)
    if not executable.is_relative_to(app) or not executable.is_file():
        raise ValueError("App executable must be a file inside the requested app")
    if process_path(pid).resolve(strict=True) != executable:
        raise ValueError("Running executable does not match the requested app")
    digest = hashlib.sha256()
    with executable.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    output = subprocess.run(
        ["/usr/bin/xcrun", "dwarfdump", "--uuid", str(executable)],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    ).stdout
    image_architectures = {
        architecture
        for image_uuid, architecture in re.findall(
            r"^UUID: ([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}) \(([^)\s]+)\) .+$",
            output,
            flags=re.MULTILINE,
        )
        if str(uuid.UUID(image_uuid)) == before["image_uuid"]
    }
    if not image_architectures:
        raise ValueError("Running image UUID does not match the app executable on disk")
    if len(image_architectures) != 1:
        raise ValueError("Running image UUID has an ambiguous executable architecture")
    after = sample(pid)
    if any(before[key] != after[key] for key in ("start_id", "image_uuid")):
        raise ValueError("Process identity changed while checking the app")
    if process_path(pid).resolve(strict=True) != executable:
        raise ValueError("Running executable path changed while checking the app")
    return {
        "bundle_id": metadata["CFBundleIdentifier"],
        "version": metadata["CFBundleShortVersionString"],
        "build": metadata["CFBundleVersion"],
        "executable_sha256": digest.hexdigest(),
        "plist_sha256": hashlib.sha256(plist_bytes).hexdigest(),
        "image_uuid": before["image_uuid"],
        "image_architecture": next(iter(image_architectures)),
        "start_id": before["start_id"],
        "executable_path": str(executable),
        "app_path": str(app),
        "pid": pid,
    }


def machine_metadata() -> dict:
    _require_macos()
    commands = {
        "model": ["/usr/sbin/sysctl", "-n", "hw.model"],
        "chip": ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
        "logical_cpus": ["/usr/sbin/sysctl", "-n", "hw.logicalcpu"],
        "memory_bytes": ["/usr/sbin/sysctl", "-n", "hw.memsize"],
        "os_version": ["/usr/bin/sw_vers", "-productVersion"],
        "os_build": ["/usr/bin/sw_vers", "-buildVersion"],
    }
    result = {}
    for key, command in commands.items():
        value = subprocess.run(
            command, capture_output=True, text=True, check=True, timeout=10
        ).stdout.strip()
        if not value:
            raise ValueError(f"Machine metadata {key} is empty")
        if key in ("logical_cpus", "memory_bytes"):
            value = int(value)
            if value <= 0:
                raise ValueError(f"Machine metadata {key} must be positive")
        result[key] = value
    power = subprocess.run(
        ["/usr/bin/pmset", "-g", "batt"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout
    match = re.search(r"^Now drawing from '(AC Power|Battery Power)'$", power, re.MULTILINE)
    if match is None:
        raise ValueError("Power source is unavailable or unsupported")
    result.update(
        architecture=platform.machine(),
        python_version=platform.python_version(),
        power_source=match.group(1),
        timebase_hz=_timebase_hz(),
    )
    return result
