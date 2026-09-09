#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
LIMITATIONS = [
    "Observational sampling under concurrent machine workloads.",
    "Main application process only; helpers, drivers and system services excluded.",
    "No controlled competitor comparison or claim of total product overhead.",
    "Sampled RSS and physical footprint are distinct from energy or battery life.",
    "Installed version metadata does not verify an official release artifact.",
]
BUILD_KEYS = {
    "bundle_id", "version", "build", "executable_sha256", "plist_sha256", "image_uuid",
    "image_architecture"
}
SAMPLE_KEYS = {"elapsed_ns", "cpu_ns", "rss_bytes", "footprint_bytes"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def number(value: object, label: str, minimum: float = 0) -> None:
    require(type(value) in (int, float), f"{label} must be numeric")
    try:
        finite = math.isfinite(value)
    except OverflowError as error:
        raise ValueError(f"Invalid {label}") from error
    require(finite and value >= minimum, f"Invalid {label}")


def text_value(value: object, label: str) -> None:
    require(isinstance(value, str) and bool(value.strip()), f"Missing {label}")


def statistics_for(values: list[float]) -> dict:
    require(bool(values), "Cannot summarize empty measurements")
    for value in values:
        number(value, "measurement")
    ordered = sorted(values)
    return {
        "count": len(values),
        "min": ordered[0],
        "median": statistics.median(values),
        "mean": statistics.fmean(values),
        "p95": ordered[math.ceil(0.95 * len(values)) - 1],
        "max": ordered[-1],
        "sample_stdev": statistics.stdev(values) if len(values) > 1 else None,
    }


def summarize_trial(samples: list[dict]) -> dict:
    require(len(samples) >= 2, "A trial needs an initial sample and an interval")
    for sample in samples:
        require(set(sample) == SAMPLE_KEYS, "Unexpected sample fields")
        for key, value in sample.items():
            require(type(value) is int and 0 <= value <= 2 ** 64 - 1, f"Invalid {key}")
    require(samples[0]["elapsed_ns"] == samples[0]["cpu_ns"] == 0,
            "Trial counters must start at zero")
    interval_cpu = []
    for previous, current in zip(samples, samples[1:]):
        elapsed = current["elapsed_ns"] - previous["elapsed_ns"]
        cpu = current["cpu_ns"] - previous["cpu_ns"]
        require(elapsed > 0, "Sample time must increase")
        require(cpu >= 0, "CPU counter regressed")
        interval_cpu.append(100 * cpu / elapsed)
    duration_ns = samples[-1]["elapsed_ns"]
    return {
        "duration_seconds": duration_ns / 1e9,
        "cpu_seconds": samples[-1]["cpu_ns"] / 1e9,
        "cpu_percent": 100 * samples[-1]["cpu_ns"] / duration_ns,
        "interval_cpu_percent": statistics_for(interval_cpu),
        "rss_mib": statistics_for([s["rss_bytes"] / (1024 ** 2) for s in samples]),
        "footprint_mib": statistics_for([
            s["footprint_bytes"] / (1024 ** 2) for s in samples
        ]),
    }


def summarize_trials(trials: list[dict]) -> dict:
    require(bool(trials), "No trials")
    return {
        "trial_cpu_percent": statistics_for([t["summary"]["cpu_percent"] for t in trials]),
        "trial_median_rss_mib": statistics_for([
            t["summary"]["rss_mib"]["median"] for t in trials
        ]),
        "trial_median_footprint_mib": statistics_for([
            t["summary"]["footprint_mib"]["median"] for t in trials
        ]),
    }


def validate_summary(actual: object, expected: object) -> None:
    if isinstance(expected, dict):
        require(isinstance(actual, dict) and set(actual) == set(expected),
                "Unexpected summary fields")
        for key in expected:
            validate_summary(actual[key], expected[key])
    elif expected is None:
        require(actual is None, "Single-value uncertainty must be null")
    else:
        number(actual, "summary value")
        require(actual == expected, "Summary differs from samples")


def validate_protocol(protocol: dict) -> None:
    require(isinstance(protocol, dict), "Protocol must be an object")
    require(set(protocol) == {
        "job", "workload", "configuration", "build_label", "warmup_seconds",
        "interval_seconds", "intervals_per_repeat", "repeats", "confounds"
    }, "Unexpected protocol fields")
    for key in ("job", "workload", "configuration", "build_label"):
        text_value(protocol[key], key)
    number(protocol["warmup_seconds"], "warmup_seconds")
    number(protocol["interval_seconds"], "interval_seconds", 0.01)
    for key in ("intervals_per_repeat", "repeats"):
        require(type(protocol[key]) is int and protocol[key] >= 1, f"Invalid {key}")
    require(isinstance(protocol["confounds"], list) and bool(protocol["confounds"]),
            "Record at least one observational confound")
    for confound in protocol["confounds"]:
        text_value(confound, "confound")


def validate_evidence(evidence: dict) -> None:
    require(isinstance(evidence, dict), "Evidence must be an object")
    require(type(evidence.get("schema_version")) is int
            and evidence["schema_version"] == SCHEMA_VERSION, "Unsupported schema_version")
    require(evidence.get("status") in ("unmeasured", "observational"), "Invalid status")
    require(evidence.get("comparison_eligible") is False, "Comparison claims are unsupported")
    text_value(evidence.get("product"), "product")
    timestamp_text = evidence.get("recorded_at")
    text_value(timestamp_text, "recorded_at")
    if timestamp_text.endswith("Z"):
        timestamp_text = timestamp_text[:-1] + "+00:00"
    timestamp = datetime.fromisoformat(timestamp_text)
    require(timestamp.tzinfo is not None, "recorded_at needs a timezone")
    common = {"schema_version", "status", "comparison_eligible", "product", "recorded_at"}
    if evidence["status"] == "unmeasured":
        require(set(evidence) == common | {"reason"}, "Unmeasured evidence cannot contain metrics")
        text_value(evidence["reason"], "reason")
        return
    required = common | {
        "collector_sha256", "build", "machine", "protocol", "limitations", "trials", "summary"
    }
    require(set(evidence) in (required, required | {"_local"}), "Unexpected evidence fields")
    require(evidence["limitations"] == LIMITATIONS, "Required limitations were changed")
    require(isinstance(evidence["build"], dict) and set(evidence["build"]) == BUILD_KEYS,
            "Unexpected build fields")
    for key, value in evidence["build"].items():
        text_value(value, key)
    for value in [evidence["collector_sha256"], evidence["build"]["executable_sha256"],
                  evidence["build"]["plist_sha256"]]:
        require(isinstance(value, str) and len(value) == 64
                and all(c in "0123456789abcdef" for c in value), "Invalid SHA-256")
    machine = evidence["machine"]
    require(isinstance(machine, dict) and set(machine) == {
        "model", "chip", "logical_cpus", "memory_bytes", "os_version", "os_build",
        "architecture", "python_version", "power_source", "timebase_hz"
    }, "Unexpected machine metadata")
    for key in ("logical_cpus", "memory_bytes", "timebase_hz"):
        require(type(machine[key]) is int and machine[key] > 0, f"Invalid machine {key}")
    for key in set(machine) - {"logical_cpus", "memory_bytes", "timebase_hz"}:
        text_value(machine[key], key)
    validate_protocol(evidence["protocol"])
    protocol = evidence["protocol"]
    require(isinstance(evidence["trials"], list)
            and len(evidence["trials"]) == protocol["repeats"], "Missing repeats")
    for index, trial in enumerate(evidence["trials"], 1):
        require(isinstance(trial, dict) and set(trial) == {"repeat", "samples", "summary"},
                "Unexpected trial fields")
        require(type(trial["repeat"]) is int and trial["repeat"] == index, "Repeat order changed")
        require(len(trial["samples"]) == protocol["intervals_per_repeat"] + 1,
                "Missing samples")
        summary = summarize_trial(trial["samples"])
        validate_cadence(trial["samples"], protocol["interval_seconds"])
        validate_summary(trial["summary"], summary)
        require(summary["duration_seconds"] >=
                protocol["interval_seconds"] * protocol["intervals_per_repeat"],
                "Trial shorter than declared duration")
    validate_summary(evidence["summary"], summarize_trials(evidence["trials"]))
    if "_local" in evidence:
        require(set(evidence["_local"]) == {"pid", "app_path", "executable_path", "start_id"},
                "Unexpected local identity fields")


def validate_cadence(samples: list[dict], interval_seconds: float) -> None:
    for previous, current in zip(samples, samples[1:]):
        seconds = (current["elapsed_ns"] - previous["elapsed_ns"]) / 1e9
        require(0.75 * interval_seconds <= seconds <= 1.25 * interval_seconds,
                "Sample cadence missed its 25 percent tolerance; discard trial and retain failure log")


def collect_trials(pid: int, identity: dict, protocol: dict, sampler,
                   sleeper=time.sleep, clock=time.monotonic_ns) -> list[dict]:
    validate_protocol(protocol)
    trials = []
    for repeat in range(1, protocol["repeats"] + 1):
        sleeper(protocol["warmup_seconds"])
        samples = []
        first = None
        for index in range(protocol["intervals_per_repeat"] + 1):
            if first is not None:
                deadline = first["time_ns"] + round(index * protocol["interval_seconds"] * 1e9)
                sleeper(max(0, (deadline - clock()) / 1e9))
            current = sampler(pid)
            require(current["start_id"] == identity["start_id"]
                    and current["image_uuid"] == identity["image_uuid"],
                    "Process restarted or executable identity changed")
            if first is None:
                first = current
            samples.append({
                "elapsed_ns": current["time_ns"] - first["time_ns"],
                "cpu_ns": current["cpu_ns"] - first["cpu_ns"],
                "rss_bytes": current["rss_bytes"],
                "footprint_bytes": current["footprint_bytes"],
            })
            validate_cadence(samples[-2:], protocol["interval_seconds"])
        trials.append({"repeat": repeat, "samples": samples, "summary": summarize_trial(samples)})
    return trials


def public_evidence(evidence: dict) -> dict:
    validate_evidence(evidence)
    result = {key: value for key, value in evidence.items() if key != "_local"}
    validate_evidence(result)
    return result


def write_json(path: Path, value: dict) -> None:
    encoded = json.dumps(value, indent=2, allow_nan=False) + "\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(encoded)


def collector_fingerprint() -> str:
    source = Path(__file__).read_bytes() + Path(__file__).with_name("macos.py").read_bytes()
    return hashlib.sha256(source).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Read-only, observational macOS process measurements")
    commands = parser.add_subparsers(dest="command", required=True)
    observe = commands.add_parser("observe")
    observe.add_argument("--pid", type=int, required=True)
    observe.add_argument("--app", type=Path, required=True)
    observe.add_argument("--product", required=True)
    for name in ("job", "workload", "configuration", "build-label"):
        observe.add_argument("--" + name, required=True)
    observe.add_argument("--confound", action="append", required=True)
    observe.add_argument("--warmup-seconds", type=float, default=30)
    observe.add_argument("--interval-seconds", type=float, default=1)
    observe.add_argument("--intervals-per-repeat", type=int, default=120)
    observe.add_argument("--repeats", type=int, default=5)
    observe.add_argument("--output", type=Path, required=True)
    missing = commands.add_parser("unmeasured")
    missing.add_argument("--product", required=True)
    missing.add_argument("--reason", required=True)
    missing.add_argument("--output", type=Path, required=True)
    check = commands.add_parser("validate")
    check.add_argument("input", type=Path)
    export = commands.add_parser("export")
    export.add_argument("input", type=Path)
    export.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command in ("validate", "export"):
            evidence = json.loads(args.input.read_text())
            validate_evidence(evidence)
            if args.command == "export":
                write_json(args.output, public_evidence(evidence))
            print("Evidence valid. comparison_eligible=false")
            return 0
        evidence = {
            "schema_version": SCHEMA_VERSION, "product": args.product,
            "recorded_at": datetime.now(timezone.utc).isoformat(),
            "status": "unmeasured" if args.command == "unmeasured" else "observational",
            "comparison_eligible": False,
        }
        if args.command == "unmeasured":
            evidence["reason"] = args.reason
        else:
            import macos

            root = Path(__file__).resolve().parents[2]
            require(not args.output.resolve().is_relative_to(root),
                    "Raw observations must be written outside the repository")
            require(not args.output.exists(), "Output already exists")
            protocol = {key: getattr(args, key) for key in (
                "job", "workload", "configuration", "build_label", "warmup_seconds",
                "interval_seconds", "intervals_per_repeat", "repeats"
            )}
            protocol["confounds"] = args.confound
            validate_protocol(protocol)
            collector_sha256 = collector_fingerprint()
            identity = macos.app_identity(args.app, args.pid)
            machine = macos.machine_metadata()
            trials = collect_trials(args.pid, identity, protocol, macos.sample)
            require(macos.app_identity(args.app, args.pid) == identity,
                    "App identity or version changed during collection")
            require(macos.machine_metadata() == machine, "Machine configuration changed during collection")
            require(collector_fingerprint() == collector_sha256, "Collector source changed during collection")
            evidence.update(
                collector_sha256=collector_sha256,
                build={key: identity[key] for key in BUILD_KEYS}, machine=machine,
                protocol=protocol, limitations=LIMITATIONS, trials=trials,
                summary=summarize_trials(trials),
                _local={key: identity[key] for key in (
                    "pid", "app_path", "executable_path", "start_id"
                )},
            )
        validate_evidence(evidence)
        write_json(args.output, evidence)
        print(f"Saved {args.output}; status={evidence['status']}; comparison_eligible=false")
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError,
            OverflowError, subprocess.SubprocessError) as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
