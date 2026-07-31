# Semper roadmap

Semper is source-first and does not have a packaged public release yet. This
roadmap describes the work needed to make the first release dependable and to
grow the project without hiding experimental behavior.

## Current priorities

### 1. First public release

- Test signed and notarized builds on a clean Mac.
- Verify install, permission, relaunch, update, and uninstall behavior.
- Publish accurate release notes and known device limits.
- Keep the website and README release status tied to real artifacts.

### 2. Audio reliability

- Add focused tests around tap lifecycle, crossfades, output gating, and device
  reconnect behavior.
- Collect reproducible reports for apps with custom audio engines.
- Preserve real-time callback safety and resource teardown order.

### 3. Device compatibility

- Record verified behavior for built-in, Bluetooth, USB, HDMI, DisplayPort,
  DDC, aggregate, and virtual devices.
- Improve handling for devices that report controls they do not actually
  support.
- Document where software volume or ignored-app behavior is the correct
  fallback.

### 4. Interface and accessibility

- Audit keyboard navigation, focus order, VoiceOver labels, contrast, reduced
  motion, and visible capability states.
- Keep the menu-bar popup and settings behavior consistent.
- Add tests for state transitions that do not require live audio hardware.

### 5. Contributor documentation

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
- Reliable today: source builds, unit tests, and the documented static website.
- Hardware-dependent: process taps, device routing, DDC, Bluetooth call mode,
  media keys, and permission behavior.
- Experimental until a public release proves otherwise: packaged distribution,
  update channels, and broad device compatibility claims.
- Out of scope today: Windows, Linux, iOS, cloud accounts, audio recording, and
  unrelated system utilities.
