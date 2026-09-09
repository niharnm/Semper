<p align="center">
  <img src="assets/icon.png" width="150" height="150" alt="Semper app icon"/>
</p>

<h1 align="center">Semper</h1>

<p align="center">
  <a href="https://github.com/niharnm/Semper/actions/workflows/ci.yml"><img src="https://github.com/niharnm/Semper/actions/workflows/ci.yml/badge.svg" alt="CI status"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/niharnm/Semper" alt="Apache-2.0 license"/></a>
  <a href="https://github.com/niharnm/Semper/contribute"><img src="https://img.shields.io/github/issues/niharnm/Semper/good%20first%20issue?label=good%20first%20issues" alt="Good first issues"/></a>
  <a href="https://github.com/niharnm/Semper/graphs/contributors"><img src="https://img.shields.io/github/contributors/niharnm/Semper" alt="Contributors"/></a>
</p>

Native macOS utilities in one menu bar app. Sound provides independent app volume, output routing, ISO 226 equal-loudness compensation, and AutoEQ headphone correction. Awake requests that macOS prevent automatic idle sleep for a chosen duration. Away covers each display with a customizable privacy curtain and requires Mac authentication or a Semper PIN to exit. External Displays provides supported brightness, contrast, volume, and input controls, while Scenes group reversible settings.

[semper.systems](https://www.semper.systems/)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/niharm)

Semper is an open-source project founded and led by [**Nihar Manchikakapudi**](https://www.niharm.me/).

> [!IMPORTANT]
> **Contributors wanted.** Semper is looking for help with Swift, SwiftUI,
> Core Audio, DSP, device testing, accessibility, tests, and technical writing.
> Start on the [contribute page](https://github.com/niharnm/Semper/contribute)
> or read the [contributor guide](CONTRIBUTING.md).

## Download

<p>
  <a href="https://github.com/niharnm/Semper/releases/latest/download/Semper.dmg"><b>Download Semper for macOS</b></a>
</p>

Open the disk image and drag **Semper** into **Applications**. Requires
macOS 15.4 or later.

With [Homebrew](https://brew.sh):

```bash
brew install --cask niharnm/tap/semper
```

Or from the terminal:

```bash
curl -fL https://github.com/niharnm/Semper/releases/latest/download/Semper.dmg -o "$HOME/Downloads/Semper.dmg" && open "$HOME/Downloads/Semper.dmg"
```

Semper updates itself through its built-in updater. Only download Semper from
[GitHub Releases](https://github.com/niharnm/Semper/releases) or Homebrew. Do
not download a Semper DMG from an unofficial source.

## Architecture Highlights

- **Independent Utilities**: Home provides module summaries, attention items, up to four pinned actions, search, and recent action outcomes for the current session. Add, pause, or remove modules individually; adding a module starts no service and requests no permission. Detailed controls open in a native window.
- **Local Awake Sessions**: Public IOKit power assertions prevent idle system sleep, optionally keep the display on, and keep timed user sessions separate from Scene requests.
- **Authenticated Away Curtain**: One opaque panel covers each display, ordinary input is filtered, and local widgets can show time, battery, Away duration, and awake-request state.
- **Swift 6 & Core Audio TCC Taps**: Built using modern Swift 6 strict concurrency (`@MainActor`, `Sendable`) and low-latency CoreAudio process taps.
- **ISO 226 Equal-Loudness Compensation**: Dynamic frequency contour adjustment matching human psychoacoustics at varying volume levels.
- **Capability-Aware Audio Routing**: Per-application routing to independent output devices (e.g. video calls to AirPods, music to desktop monitors) with automatic hardware capability detection.
- **Verified Per-Output Gain & Peak Limiting**: Above-unity software master gain is offered only after Semper confirms an active single-output processing route, and its displayed range matches the enforced output limit (up to 300%).
- **AutoEQ Engine**: 10-band parametric EQ supporting AutoEQ headphone profiles and custom user presets.
- **Ramped Mono Audio**: Combines left and right channels for managed apps without abrupt signal changes, while retaining output balance control.
- **Transactional Scenes**: Saves audio, Awake, and supported external display settings together, verifies each change, and keeps a restore point that respects later user changes.
- **Timed Presentation**: Preview selected display, Sound, and workspace targets, then run a finite session with its own Awake request. End and restore through the same scene journal and owned window receipts. See the [module guide](guide/module-shell.md) for recovery limits.
- **External Display Controls**: Reads and sets brightness and contrast on uniquely identified DDC-compatible displays outside App Store builds.
- **Liquid Glass Interface**: High-vibrancy macOS design system with dynamic Tahoe-style HUDs, balance controls, and menu bar interaction.

## Requirements

- macOS 15.4 or later
- Starting an Awake session requires no additional macOS permission.
- Away requires Accessibility access for its active input filter. macOS may also require Input Monitoring. Mac authentication can use Touch ID, Apple Watch when available, or the account password through Apple's system dialog.
- Sound requires Screen & System Audio Recording permission for CoreAudio process taps.
- Microphone permission is used only for input-device monitoring.
- Accessibility permission is optional for system media-key control.

Away is a Semper privacy curtain, not the macOS Lock Screen or an operating-system security boundary. Force Quit, Semper failure, restart, administrator or Accessibility control, remote access, authorized capture software, and display-change timing can expose the desktop. Its awake request does not prevent lid-close sleep, manual Sleep, or forced low-power sleep.

## Building from Source

```bash
git clone https://github.com/niharnm/Semper.git
cd Semper
open Semper.xcodeproj
```

Unsigned local Release build:

```bash
xcodebuild \
  -project Semper.xcodeproj \
  -scheme Semper \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The output binary is placed at `build/Build/Products/Release/Semper.app`.

To build the current GitHub `main` commit and replace the installed app, run:

```bash
/usr/bin/curl -fsSL https://raw.githubusercontent.com/niharnm/Semper/main/scripts/update-local.sh | /bin/bash
```

The updater shows the installed and GitHub versions, asks for confirmation,
then replaces `/Applications/Semper.app` and reopens it. Declining leaves the
installed app unchanged. This is a local source build, not a signed public
release. It requires a Developer ID Application or Apple Development identity
in your keychain so macOS can recognize later source updates as the same app.

## Documentation & Guides

- [URL Schemes](guide/url-schemes.md)
- [App Shortcuts](guide/app-shortcuts.md)
- [Experiments](guide/experiments.md)
- [AutoEQ Integration](guide/autoeq.md)
- [Canary Testing](guide/canary.md)
- [Troubleshooting](guide/troubleshooting.md)
- [Real-time Audio Safety](guide/realtime-audio-safety.md)
- [Device Compatibility](guide/device-compatibility.md)
- [Contributing Guidelines](CONTRIBUTING.md)

## Contributing

External pull requests are welcome for the current release and ongoing work.

- Pick a scoped task from [good first issues](https://github.com/niharnm/Semper/contribute)
  or [help wanted issues](https://github.com/niharnm/Semper/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22help%20wanted%22).
- Read the [roadmap](ROADMAP.md) before proposing a larger feature.
- Use [GitHub Discussions](https://github.com/niharnm/Semper/discussions) for
  setup help, design questions, and early proposals.
- Follow [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests, audio-thread
  constraints, hardware reports, and pull-request expectations.

Documentation fixes, isolated tests, device reports, and accessibility work
are useful contributions. Changes to the real-time audio callback need focused
tests and a clear safety argument.

## Legal

- [Privacy Policy](PRIVACY.md)
- [Terms of Use](TERMS.md)

## License

Semper is distributed under the [Apache License 2.0](LICENSE) (`Apache-2.0`).

Copyright (C) 2026 Nihar Manchikakapudi and contributors.
