# Semper roadmap

Semper publishes signed macOS releases. This roadmap describes the work needed
to keep distribution dependable and grow the project without hiding
experimental behavior.

## Current priorities

### 1. Release maintenance

- Test signed and notarized builds on a clean Mac before publication.
- Verify install, permission, relaunch, update, and uninstall behavior for each
  release.
- Publish accurate release notes and known device limits.
- Keep the website, README, Homebrew cask, and update feed tied to the same
  release artifact.

### 2. Modules and utility foundation

- Keep Sound and Awake independent while they share the same menu bar shell.
- Add new utilities only when they have a clear local use case and no hidden account requirement.
- Keep module actions testable without live audio or power-management side effects.

### 3. Audio reliability

- Add focused tests around tap lifecycle, crossfades, output gating, and device
  reconnect behavior.
- Collect reproducible reports for apps with custom audio engines.
- Preserve real-time callback safety and resource teardown order.

### 4. Device compatibility

- Record verified behavior for built-in, Bluetooth, USB, HDMI, DisplayPort,
  DDC, aggregate, and virtual devices.
- Improve handling for devices that report controls they do not actually
  support.
- Document where software volume or ignored-app behavior is the correct
  fallback.

### 5. Interface and accessibility

- Audit keyboard navigation, focus order, VoiceOver labels, contrast, reduced
  motion, and visible capability states.
- Keep the menu-bar popup and settings behavior consistent.
- Add tests for state transitions that do not require live audio hardware.

### 6. Contributor documentation

- Keep starter issues small, testable, and unclaimed until someone begins.
- Add architecture notes for high-risk audio paths.
- Turn verified device reports and recurring support answers into guides.

## Contribution levels

- **Starter:** documentation, pure-function tests, accessibility labels, and
  isolated UI state.
- **Intermediate:** parser behavior, settings state, device classification,
  and failure recovery with tests.
- **Advanced:** process taps, aggregate devices, HAL callback code, crossfades,
  DSP lifecycle, and output safety.

Use [good first issues](https://github.com/niharnm/Semper/contribute) for a
first pull request. Advanced work should begin with a GitHub issue or
discussion and include a hardware test plan.

## Current boundaries

- Supported platform: macOS 15.4 or later.
- Available today: Sound controls, timed or indefinite Awake sessions, source
  builds, unit tests, the static website, and signed macOS releases through
  GitHub and Homebrew.
- Hardware-dependent: process taps, device routing, DDC, Bluetooth call mode,
  media keys, and permission behavior.
- Release-dependent: automatic updates require a current signed feed, and broad
  device compatibility claims require verified hardware reports.
- Out of scope today: Windows, Linux, iOS, cloud accounts, and audio recording.
