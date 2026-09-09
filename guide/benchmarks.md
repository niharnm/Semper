# Reproducible process measurements

Semper has no published controlled competitor performance result. The records in
[`scripts/benchmarks/evidence`](../scripts/benchmarks/evidence) state what remains
unmeasured. Product capabilities below are sourced claims, not performance tests.

## What the collector measures

[`benchmark.py`](../scripts/benchmarks/benchmark.py) observes one explicitly selected
running macOS app. It does not launch or quit apps, install components, request
permissions, change settings, or select processes by a partial name. Requirements:
macOS, Python 3.10 or newer, and Apple's command-line tools (`xcrun dwarfdump`) for
executable UUID verification. There are no Python package dependencies.

Each measurement contains the hardware model, CPU, logical CPU count, memory size,
OS version/build, collector architecture, Python version, power source and hardware
timebase frequency. It also contains bundle ID, version/build, executable UUID and
target architecture (matched to that UUID),
binary and Info.plist SHA-256 hashes, collector hash, workload/configuration,
warmup, interval, repeat count, raw samples, summaries and limitations.

An installed version string is not proof of a released build. Keep installed,
candidate and verified release runs in separate files and use `--build-label` to
state the provenance and reference. For a released result, separately verify the
download checksum, code signature, Gatekeeper assessment, notarization ticket and
release source. The collector's build label is operator supplied, not attested.

| Metric | Definition | Limits |
| --- | --- | --- |
| CPU seconds | Difference in cumulative user plus system CPU ticks, divided by `hw.tbfrequency` | Main PID only; excludes child processes and services |
| CPU percent | CPU seconds / actual monotonic elapsed seconds × 100 | One logical CPU is 100%; multithreaded work may exceed 100% |
| RSS MiB | Resident bytes / 1,048,576 | Not exclusive memory ownership or lifetime peak memory |
| Physical footprint MiB | `ri_phys_footprint` bytes / 1,048,576 | A different kernel accounting metric from RSS |

The first sample is a boundary, not an invented zero-CPU interval. Each repeat
contains `intervals_per_repeat + 1` memory observations and that many minus one CPU
intervals. CPU percent across the complete repeat is duration weighted. Interval
CPU mean is the arithmetic mean of individual interval percentages and is labeled
separately. Memory summaries include both boundary samples. Every series reports
count, minimum, median, mean, nearest-rank p95 (`ceil(0.95*n)`), maximum and sample
standard deviation. Standard deviation is `null` for a single value. Across
repeats, the tool summarizes each repeat's CPU percent and median memory value.
Repeated samples within a window are correlated, not independent trials.

Sampling uses actual monotonic timestamps and absolute deadlines. Each interval
must remain within 25% of its requested duration, and each repeat must cover the
declared duration. Missed cadence, counter regression, process exit/restart,
executable or version changes, power-source changes, missing samples and changed
collector files fail the run. It emits no result on failure. Keep the failed
attempt's stderr and record the reason before retrying; do not silently discard
unfavorable or interrupted attempts.

CPU units follow [Apple's rusage assignment](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/bsd_kern.c#L1257-L1261)
and [Mach-time counter definition](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/recount.h#L135-L137).
The frequency conversion follows [psutil's macOS implementation](https://github.com/giampaolo/psutil/blob/dcccef25416cecdb319d1db2af86d7490757c5ed/psutil/arch/osx/proc.c#L134-L139),
including its Rosetta caveat. RSS and footprint use [distinct Apple ledger fields](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/bsd_kern.c#L1274-L1277).

## Run an observation

First identify and approve the exact running app and PID. Inspect its executable
path, bundle version, signature and permissions. Do not change security settings
to make measurement possible. The command below is a template; replace the PID,
build reference and workload details with verified facts. It is not a recorded
Semper result.

```bash
python3 scripts/benchmarks/benchmark.py observe \
  --pid "$BENCHMARK_PID" --app /Applications/Semper.app --product Semper \
  --job inactive \
  --workload 'Describe the actual running feature and UI state' \
  --configuration 'Record display, audio device, sample rate and app settings' \
  --build-label 'State installed/candidate/released and the verified reference' \
  --confound 'Concurrent workloads and thermal conditions are not controlled' \
  --warmup-seconds 30 --interval-seconds 1 --intervals-per-repeat 120 --repeats 5 \
  --output /tmp/semper-observation.json
python3 scripts/benchmarks/benchmark.py validate /tmp/semper-observation.json
python3 scripts/benchmarks/benchmark.py export /tmp/semper-observation.json \
  --output /tmp/semper-public-review.json
```

The default protocol is five sequential windows, each with 30 seconds of warmup
and 120 seconds of sampling. Windows on one running process are not five cold
starts or independently randomized trials. Record the actual start order and
session state. CLI arguments are required for workload, configuration and
confounds so a number cannot silently acquire an invented workload label.

Raw output must be outside the repository, is created with mode `0600`, and never
overwrites a file. It includes the selected PID, app/executable paths and start
token under `_local`. Export removes that object and recomputes every summary.
Machine metadata excludes hostnames, usernames, serial numbers and process lists.
Operator-provided text still needs human privacy review before publication. Keep
raw files private; commit only reviewed exports and their supporting run notes.

## Website data contract

[`public.schema.json`](../scripts/benchmarks/public.schema.json) specifies the
public JSON shape. `benchmark.py validate` is authoritative for arithmetic,
timing, required limitations and repeat integrity. JSON Schema alone cannot
recompute summaries or prove that samples came from hardware.

| Status | Required content | Website treatment |
| --- | --- | --- |
| `unmeasured` | Product, timestamp, reason; no metric fields | Show “Not measured” with the reason, never a zero or empty bar |
| `observational` | Build, machine, protocol, all trials, summaries, limitations | A separately labeled observation with methodology; no ranking |

Both states require `comparison_eligible: false`. No output from this collector
alone qualifies as a controlled comparison. Do not interpret feature counts as
performance, average unlike jobs into one score, or infer superiority from absent
competitor results. The collector hash identifies the concatenated bytes of
`benchmark.py` followed by `macos.py`; it is reproducibility metadata, not a
digital signature or proof against edited evidence.

## Matched jobs for a future controlled study

Predeclare product versions, editions/extensions, exact jobs, sample parameters,
run order, exclusion rules and success criteria before collecting results. Use the
same Mac, OS, power state, connected hardware and verified workload. Rotate product
order and retain every attempt. A suggested starting protocol is five independently
set-up trials per product/job, 30 seconds of warmup and 120 seconds sampled at 1 Hz.
This protocol is proposed, not a completed comparison.

| Job | Match before measuring | Additional evidence required |
| --- | --- | --- |
| Inactive app | Controls closed; verify no active session or effects | Document all enabled background features |
| Per-app volume | Same PCM file, player, output, sample rate and measured attenuation | Matching slider percentages do not establish matching gain; include audio helpers |
| Display control | Same monitor, connection, mode and brightness change | Compare hardware DDC to DDC; separate software dimming and HDR |
| Keep awake | Same duration; lid open; AC power; display sleep allowed; triggers off | Inspect the requested power assertion and test behavior with permission |
| Multiple utilities | One common action and equivalent configuration | Record extensions/editions; compare shared jobs individually |

Main-PID measurements omit helper work. For example, KeepingYouAwake invokes
`caffeinate`; audio tools may use services or drivers. These omissions can reverse
a superficial app-only ranking. Total-product performance needs a separately
reviewed process-set or system-level method that accounts for shared services
without double counting. Energy, battery life, audio latency, dropouts, DDC
reliability and actual sleep prevention are not measured by this tool.

## Sourced alternatives

Primary sources checked September 8, 2026. These entries describe documented
capabilities. They do not assert that any feature was tested on this Mac or that
undocumented features are absent. Every competitor remains unmeasured here.

| Category | Product | Documented capability and primary source |
| --- | --- | --- |
| Per-app sound | SoundSource | [Application volume, mute, output routing and effects](https://rogueamoeba.com/support/manuals/soundsource/?page=application-adjustments) |
| Per-app sound | Background Music | [Per-app volume, music auto-pause and recording; project labeled alpha](https://github.com/kyleneideck/BackgroundMusic) |
| Display control | BetterDisplay | [Hardware DDC, software brightness and display configuration; some features require Pro](https://github.com/waydabber/BetterDisplay) |
| Display control | MonitorControl | [DDC brightness, contrast and volume, with native and software alternatives](https://github.com/MonitorControl/MonitorControl) |
| Keep awake | Amphetamine | [Manual/timed sessions and configurable triggers](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) |
| Keep awake | KeepingYouAwake | [Timed or indefinite sleep prevention through caffeinate; closed-lid use excluded](https://github.com/newmarcel/KeepingYouAwake) |
| Multiple utilities | Raycast | [Window management, clipboard history, snippets and calculator](https://manual.raycast.com/quickstart); [Coffee is a separate extension](https://www.raycast.com/mooxl/coffee) |
| Multiple utilities | Almighty | [Brightness, window snapping, keep-awake and combined tweak workflows; editions differ](https://indiegoodies.com/almighty) |

## Check the tooling

```bash
python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py' -v
python3 -m py_compile scripts/benchmarks/benchmark.py scripts/benchmarks/macos.py
python3 scripts/benchmarks/benchmark.py validate scripts/benchmarks/evidence/semper.json
```

The unit suite uses synthetic data, including non-billion-Hz CPU conversion,
unequal intervals, process replacement, missing input and altered evidence. Test
fixture numbers are not product measurements. Run a native self-process check on
each new OS/architecture and compare a short CPU interval with Python's
`process_time_ns` before trusting a new platform's counter conversion.
