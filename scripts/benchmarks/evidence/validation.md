# Validation record, September 9, 2026 UTC

No Semper or competitor CPU or memory measurement was published. The JSON records
in this directory are all `unmeasured` and reject numeric metric fields.

## Collector validation

- Mac17,9, Apple M5 Pro, 15 logical CPUs, 24 GiB RAM, AC power.
- macOS 27.0 build 26A5425a, arm64 Python 3.14.6, timebase 24,000,000 Hz.
- Native collector CPU conversion compared with Python `process_time_ns` over a
  50 ms self-process CPU interval: ratio 0.999933. This is a unit sanity check,
  not a product performance result or accuracy guarantee across platforms.
- Full CLI observation, validation and public export passed against a test-owned
  sleeping Python process: two sequential windows, one second warmup each,
  six 0.5-second intervals per window, 12 intervals and 14 boundary samples total.
  That process exited normally. Fixture output remains outside the repository.
- `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py' -v`:
  38 tests passed.
- Python bytecode compilation passed for the four collector/test modules.
- Existing `scripts/test_release_tools.py`: 7 tests passed.
- Existing `scripts/test_website_tools.py`: 9 tests passed.

## Semper baseline attempt

The installed app reported version 1.0.0/build 1 but had an ad hoc signature and
failed `codesign --verify --strict`. It was not launched or replaced.

A separate copy of the [official v1.0.0 release asset](https://github.com/niharnm/Semper/releases/tag/v1.0.0)
was downloaded to a temporary directory and checked before launch:

| Artifact identity | Verified value |
| --- | --- |
| GitHub DMG asset ID | 531310236 |
| DMG bytes | 7,378,898 |
| DMG SHA-256 | `c81aee8f5d4e3d6c68621b951156ebc636314809fa8953056451a98ee21cca57` |
| Bundle ID | `systems.semper.Semper` |
| Version / build | 1.0.0 / 1 |
| Executable SHA-256 | `4011e52531ce39b567ab448ecab7776ecdcd2e3e90bfa135241849e71940e9a7` |
| Info.plist SHA-256 | `8daeb89246853b2f617c7e974817756ba49b76353401b64a143fbfb39f369dc2` |
| arm64 executable UUID | `C712B700-3931-3018-BD6B-F427830497B4` |
| Developer ID team | `QDKSUX27F9` |

`hdiutil verify`, deep strict code-signature verification, app/DMG Gatekeeper
assessment and app/DMG `xcrun stapler validate` all passed. The disk image was
mounted read-only, copied to a task-owned temporary directory, then detached.
No quarantine attribute was removed and no installed app was overwritten.

With no existing Semper process, the temporary signed executable was launched.
UI inspection timed out, preventing verification that no new permission prompt
had appeared. Sampling was aborted before collecting any Semper metric. An
ordinary quit was requested for the exact started process through
`NSRunningApplication.terminate()`, which returned true; a subsequent PID check
confirmed it exited. No permission prompt was accepted or settings changed.

This leaves Semper unmeasured despite successful release artifact verification.
No candidate build was launched. Competitor performance also remains unmeasured.
The next baseline requires a visible, approved app state with existing permissions;
a controlled comparison additionally requires matched jobs and complete accounting
for helpers/services. See [the methodology](../../../guide/benchmarks.md).
