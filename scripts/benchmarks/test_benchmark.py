from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import benchmark


def protocol() -> dict:
    return dict(job="inactive", workload="Fixture", configuration="Fixture",
                build_label="test fixture, not product evidence", warmup_seconds=0,
                interval_seconds=1, intervals_per_repeat=2, repeats=2,
                confounds=["Fixture only"])


def evidence() -> dict:
    samples = [
        dict(elapsed_ns=0, cpu_ns=0, rss_bytes=1024 ** 2, footprint_bytes=2 * 1024 ** 2),
        dict(elapsed_ns=10 ** 9, cpu_ns=10 ** 8, rss_bytes=2 * 1024 ** 2,
             footprint_bytes=3 * 1024 ** 2),
        dict(elapsed_ns=2 * 10 ** 9, cpu_ns=2 * 10 ** 8, rss_bytes=3 * 1024 ** 2,
             footprint_bytes=4 * 1024 ** 2),
    ]
    trials = [dict(repeat=i, samples=copy.deepcopy(samples),
                   summary=benchmark.summarize_trial(samples)) for i in (1, 2)]
    return dict(
        schema_version=1, product="Fixture", status="observational", comparison_eligible=False,
        recorded_at="2026-09-09T00:00:00+00:00", collector_sha256="a" * 64,
        build=dict(bundle_id="example.fixture", version="1", build="1", image_uuid="1234",
                   image_architecture="arm64",
                   executable_sha256="b" * 64, plist_sha256="c" * 64),
        machine=dict(model="Fixture", chip="Fixture", logical_cpus=4, memory_bytes=1024 ** 3,
                     os_version="26", os_build="fixture", architecture="arm64",
                     python_version="3.10", power_source="AC Power", timebase_hz=24_000_000),
        protocol=protocol(), limitations=benchmark.LIMITATIONS.copy(), trials=trials,
        summary=benchmark.summarize_trials(trials),
        _local=dict(pid=123, app_path="/private/Fixture.app", executable_path="/private/Fixture",
                    start_id=123456),
    )


class SummaryTests(unittest.TestCase):
    def test_actual_duration_weighted_cpu_and_binary_memory_units(self):
        samples = evidence()["trials"][0]["samples"]
        samples[-1]["elapsed_ns"] = 3 * 10 ** 9
        summary = benchmark.summarize_trial(samples)
        self.assertAlmostEqual(summary["cpu_percent"], 100 * 0.2 / 3)
        self.assertEqual(summary["interval_cpu_percent"]["mean"], 7.5)
        self.assertEqual(summary["rss_mib"]["median"], 2)
        self.assertEqual(summary["footprint_mib"]["median"], 3)

    def test_percentile_nearest_rank_and_singleton_uncertainty(self):
        self.assertEqual(benchmark.statistics_for(list(range(1, 21)))["p95"], 19)
        self.assertIsNone(benchmark.statistics_for([0])["sample_stdev"])
        self.assertEqual(benchmark.statistics_for([0])["median"], 0)

    def test_multicore_cpu_is_not_clamped(self):
        samples = evidence()["trials"][0]["samples"][:2]
        samples[1]["cpu_ns"] = 2 * 10 ** 9
        self.assertEqual(benchmark.summarize_trial(samples)["cpu_percent"], 200)

    def test_reject_empty_nonfinite_and_regressing_values(self):
        for values in ([], [float("nan")], [float("inf")], [-1], [True]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                benchmark.statistics_for(values)
        for key, value in (("elapsed_ns", 0), ("cpu_ns", -1), ("rss_bytes", -1)):
            samples = evidence()["trials"][0]["samples"]
            samples[1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                benchmark.summarize_trial(samples)


class SamplingTests(unittest.TestCase):
    def test_missed_deadline_fails_without_clustered_catchup_samples(self):
        now = [0]
        calls = [0]
        def sampler(_):
            calls[0] += 1
            return dict(time_ns=now[0], cpu_ns=0, rss_bytes=1, footprint_bytes=1,
                        start_id=1, image_uuid="abc")
        def oversleep(seconds):
            now[0] += round(seconds * 1e9) + (2 * 10 ** 9 if seconds else 0)
        with self.assertRaisesRegex(ValueError, "cadence missed"):
            benchmark.collect_trials(1, dict(start_id=1, image_uuid="abc"), protocol(),
                                      sampler, oversleep, lambda: now[0])
        self.assertEqual(calls[0], 2)

    def test_repeats_warmup_absolute_deadlines_and_measured_duration(self):
        now = [0]
        sleeps = []
        def sleeper(seconds):
            sleeps.append(seconds)
            now[0] += round(seconds * 1e9)
        def sampler(pid):
            self.assertEqual(pid, 5)
            now[0] += 10_000_000
            return dict(time_ns=now[0], cpu_ns=now[0] // 10, rss_bytes=1024,
                        footprint_bytes=2048, start_id=99, image_uuid="abc")
        p = protocol()
        p["warmup_seconds"] = 2
        trials = benchmark.collect_trials(5, dict(start_id=99, image_uuid="abc"), p,
                                          sampler, sleeper, lambda: now[0])
        self.assertEqual(len(trials), 2)
        self.assertEqual([len(t["samples"]) for t in trials], [3, 3])
        self.assertEqual(sleeps, [2, 1, 0.99, 2, 1, 0.99])
        self.assertAlmostEqual(trials[0]["summary"]["duration_seconds"], 2.01)

    def test_restart_and_exec_abort_instead_of_returning_partial_trial(self):
        for changed in (dict(start_id=2, image_uuid="abc"), dict(start_id=1, image_uuid="new")):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "identity changed"):
                benchmark.collect_trials(5, dict(start_id=1, image_uuid="abc"), protocol(),
                                          lambda _: changed, lambda _: None)

    def test_disappearing_process_propagates_failure(self):
        def missing(_):
            raise ProcessLookupError("gone")
        with self.assertRaises(ProcessLookupError):
            benchmark.collect_trials(5, {}, protocol(), missing, lambda _: None)

    def test_invalid_parameters_fail_before_sleep(self):
        for key, value in (("interval_seconds", 0), ("warmup_seconds", -1),
                           ("repeats", 0), ("intervals_per_repeat", True),
                           ("interval_seconds", float("inf"))):
            p = protocol()
            p[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                benchmark.collect_trials(5, {}, p, None, None)


class EvidenceTests(unittest.TestCase):
    def test_committed_public_records_validate_and_exclude_private_identity(self):
        folder = Path(benchmark.__file__).parent / "evidence"
        records = sorted(folder.glob("*.json"))
        self.assertTrue(records)
        for path in records:
            with self.subTest(path=path.name):
                record = json.loads(path.read_text())
                benchmark.validate_evidence(record)
                self.assertNotIn("_local", record)

    def test_valid_observation_and_public_export(self):
        original = evidence()
        benchmark.validate_evidence(original)
        public = benchmark.public_evidence(original)
        self.assertNotIn("_local", public)
        self.assertIn("_local", original)
        self.assertNotIn("/private", json.dumps(public))
        self.assertFalse(public["comparison_eligible"])

    def test_reject_missing_samples_repeats_and_modified_statistics(self):
        for mutation in (
            lambda e: e["trials"].pop(),
            lambda e: e["trials"][0]["samples"].pop(),
            lambda e: e["trials"][0]["summary"].update(cpu_percent=0),
            lambda e: e["summary"]["trial_cpu_percent"].update(median=0),
            lambda e: e["build"].pop("version"),
            lambda e: e.update(comparison_eligible=True),
            lambda e: e.update(limitations=[]),
            lambda e: e["machine"].update(hostname="private"),
            lambda e: e.update(recorded_at="2026-09-09"),
            lambda e: e["protocol"].update(interval_seconds=10),
            lambda e: e.update(schema_version=True),
            lambda e: e["protocol"].update(warmup_seconds=10 ** 400),
            lambda e: e["trials"][0]["summary"]["interval_cpu_percent"].update(sample_stdev=False),
            lambda e: e["summary"]["trial_cpu_percent"].update(sample_stdev=False),
        ):
            item = evidence()
            mutation(item)
            with self.subTest(item=item), self.assertRaises(ValueError):
                benchmark.validate_evidence(item)

    def test_collector_change_rejects_output(self):
        import macos
        item = evidence()
        identity = item["build"] | item["_local"]
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "observation.json"
            argv = ["benchmark.py", "observe", "--pid", "1", "--app", "/Fixture.app",
                    "--product", "Fixture", "--job", "inactive", "--workload", "fixture",
                    "--configuration", "fixture", "--build-label", "fixture", "--confound",
                    "fixture", "--output", str(output)]
            with patch.object(sys, "argv", argv), \
                 patch.object(benchmark, "collector_fingerprint", side_effect=["a", "b"]), \
                 patch.object(macos, "app_identity", return_value=identity), \
                 patch.object(macos, "machine_metadata", return_value=item["machine"]), \
                 patch.object(benchmark, "collect_trials", return_value=item["trials"]):
                self.assertEqual(benchmark.main(), 1)
            self.assertFalse(output.exists())

    def test_unmeasured_cannot_smuggle_zero_metrics(self):
        item = dict(schema_version=1, product="Semper", status="unmeasured",
                    recorded_at="2026-09-09T00:00:00Z", comparison_eligible=False,
                    reason="No approved target")
        benchmark.validate_evidence(item)
        item["summary"] = dict(cpu_percent=0)
        with self.assertRaises(ValueError):
            benchmark.validate_evidence(item)

    def test_write_is_private_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "data.json"
            benchmark.write_json(path, {"one": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                benchmark.write_json(path, {"two": 2})
            self.assertEqual(json.loads(path.read_text()), {"one": 1})

    def test_cli_validation_and_missing_input_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "data.json"
            path.write_text(json.dumps(evidence()))
            script = str(Path(benchmark.__file__))
            success = subprocess.run([sys.executable, script, "validate", str(path)], capture_output=True)
            self.assertEqual(success.returncode, 0, success.stderr)
            failed = subprocess.run([sys.executable, script, "validate", str(path) + ".missing"],
                                    capture_output=True)
            self.assertEqual(failed.returncode, 1)
            self.assertIn(b"Benchmark failed:", failed.stderr)
            self.assertNotIn(b"Traceback", failed.stderr)


if __name__ == "__main__":
    unittest.main()
