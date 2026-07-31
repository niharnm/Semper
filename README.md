<p align="center">
  <img src="assets/icon.png" width="150" height="150" alt="Semper app icon"/>
</p>

<h1 align="center">Semper</h1>

Native, per-application audio mixing and DSP engine for macOS. Semper resides in your menu bar, providing independent volume control, per-app output routing, ISO 226 equal-loudness contour compensation, AutoEQ headphone correction, and a Liquid Glass interface.

[semper.systems](https://semper.systems)

Semper is an open-source project founded and led by **Nihar Manchikakapudi**.

## Download

Download the latest Semper release to your Downloads folder and open it:

```bash
curl -fL https://github.com/niharnm/Semper/releases/latest/download/Semper.dmg -o "$HOME/Downloads/Semper.dmg" && open "$HOME/Downloads/Semper.dmg"
```

Drag **Semper** into **Applications** when the disk image opens.

## Architecture Highlights

- **Swift 6 & Core Audio TCC Taps**: Built using modern Swift 6 strict concurrency (`@MainActor`, `Sendable`) and low-latency CoreAudio process taps.
- **ISO 226 Equal-Loudness Compensation**: Dynamic frequency contour adjustment matching human psychoacoustics at varying volume levels.
- **Capability-Aware Audio Routing**: Per-application routing to independent output devices (e.g. video calls to AirPods, music to desktop monitors) with automatic hardware capability detection.
- **300% Device-Aware Gain & Peak Limiting**: Software master gain boosting up to 300% paired with a zero-latency peak soft limiter starting at -1 dBFS.
- **AutoEQ Engine**: 10-band parametric EQ supporting AutoEQ headphone profiles and custom user presets.
- **Liquid Glass Interface**: High-vibrancy macOS design system with dynamic Tahoe-style HUDs, balance controls, and menu bar interaction.

## Requirements

- macOS 15.4 or later
- Screen & System Audio Recording permission (required for CoreAudio process taps)
- Microphone permission (only for input-device monitoring)
- Accessibility permission (optional for system media-key control)

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

## Documentation & Guides

- [URL Schemes](guide/url-schemes.md)
- [AutoEQ Integration](guide/autoeq.md)
- [Canary Testing](guide/canary.md)
- [Troubleshooting](guide/troubleshooting.md)
- [Contributing Guidelines](CONTRIBUTING.md)

## License

Semper is distributed under the [GNU General Public License Version 3](LICENSE) (`GPL-3.0-only`).

Copyright (C) 2026 Nihar Manchikakapudi and contributors.
