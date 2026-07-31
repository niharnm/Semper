# Contributing to Semper

Semper welcomes focused pull requests for bug fixes, tests, documentation,
device compatibility, accessibility, and audio features. The project is
source-first today, with no packaged public release yet.

## Find a task

Start with one of these lists:

- [Good first issues](https://github.com/niharnm/Semper/contribute) are small,
  documented tasks intended for a first Semper pull request.
- [Help wanted issues](https://github.com/niharnm/Semper/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22help%20wanted%22)
  need outside testing or implementation help.
- [The roadmap](ROADMAP.md) explains the current project priorities and areas
  that need design discussion before code.

Before starting non-trivial work, leave a short comment on the issue with your
planned approach and any hardware you expect to test. This prevents duplicate
work. Use [GitHub Discussions](https://github.com/niharnm/Semper/discussions)
for setup questions and proposals that are not ready to become issues.

## What makes a useful contribution

- Fix one reproducible problem without unrelated refactoring.
- Add an isolated test for behavior that can be checked without live hardware.
- Report or document behavior across Bluetooth, USB, HDMI, DisplayPort,
  built-in, aggregate, or virtual audio devices.
- Improve keyboard access, VoiceOver information, or visible capability states.
- Correct a guide using behavior you verified on the current `main` branch.

Large audio-engine changes should begin with an issue or discussion. They can
affect device routing, echo cancellation, output safety, or the Core Audio HAL
thread even when a local build appears correct.

## Repository map

| Path | Purpose |
| --- | --- |
| `Semper/Audio/Engine` | Process taps, routing, crossfades, gain, and resource lifecycle |
| `Semper/Audio/EQ` | Biquad filters, EQ processing, and limiter math |
| `Semper/Audio/AutoEQ` | AutoEQ catalog, parsing, profiles, and processing |
| `Semper/Audio/Loudness` | ISO 226 and loudness-compensation code |
| `Semper/Views` | SwiftUI menu-bar, settings, rows, sheets, and HUDs |
| `SemperTests` | Swift Testing suites and behavior contracts |
| `guide` | User, architecture, and troubleshooting documentation |
| `website` | Static public website |

Read [Real-time Audio Safety](guide/realtime-audio-safety.md) before editing
`ProcessTapController`, DSP processors, callback state, or tap resources.

## Local setup

You need a Mac running macOS 15.4 or later and a current Xcode version that can
build the repository's Swift 6 project.

1. Fork the repository and clone your fork.
2. Add this repository as the upstream remote.
3. Create a branch from the latest `upstream/main`.
4. Open `Semper.xcodeproj` and select the `Semper` scheme.
5. Build once, then grant only the macOS permissions needed for the behavior
   you are testing.

```bash
git clone https://github.com/YOUR-USER/Semper.git
cd Semper
git remote add upstream https://github.com/niharnm/Semper.git
git fetch upstream
git switch -c your-change upstream/main
open Semper.xcodeproj
```

Unsigned command-line build:

```bash
xcodebuild build \
  -project Semper.xcodeproj \
  -scheme Semper \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

Run unit tests:

```bash
xcodebuild test \
  -project Semper.xcodeproj \
  -scheme Semper \
  -configuration Debug \
  -skip-testing:SemperUITests \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

For website changes, also run:

```bash
python3 scripts/check-website.py
node --test website/ab-testing.test.js
```

## Audio-thread rules

The Core Audio callback has stricter rules than normal Swift code. Inside the
HAL I/O path, do not allocate memory, acquire locks, log, call Objective-C or
Foundation APIs, block, use `async` or `await`, or hop to an actor. Prepare
state on `@MainActor` and keep callback work in-place and bounded.

These rules apply even if a change passes unit tests. See
[guide/realtime-audio-safety.md](guide/realtime-audio-safety.md) for the full
review checklist and the existing code patterns to follow.

## Manual verification

Audio and device changes need a short test matrix in the pull request. Include:

- macOS version and the tested Semper commit;
- audio-producing apps used for the test;
- output and input device classes, not private device names;
- whether volume, mute, routing, EQ, reconnect, and relaunch were tested;
- expected behavior, actual behavior, and any known gap.

Do not upload logs that contain personal device names, usernames, paths, or
unrelated process information. Reduce a log to the lines needed to explain the
problem.

## Pull requests

- Link the issue the pull request addresses.
- Keep one behavior change per pull request.
- Add or update tests when behavior changes.
- Explain audio-device assumptions and name the device class used for manual
  testing.
- Include before and after screenshots for visible UI changes.
- Do not add signing certificates, Sparkle private keys, Apple credentials,
  captured audio, or generated build products.
- Do not reformat or rename unrelated code.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Reviews check scope, tests, real-time safety, device assumptions, accessibility,
privacy, and authorship. A green build does not by itself prove hardware audio
behavior.

## Authorship and licensing

- Contributions are accepted under `Apache-2.0`.
- You retain copyright in your original contribution. Semper does not require
  copyright assignment.
- Use accurate commit authorship. Do not remove or rewrite another
  contributor's credit.
- Disclose the source and license of copied or adapted material. Only submit
  material that can legally be distributed under Apache 2.0.
- Preserve `LICENSE`, `NOTICE.md`, `AUTHORS.md`, and all applicable copyright
  notices.

By submitting a contribution, you certify that you have the right to submit it
under Apache 2.0.
