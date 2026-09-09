# Semper roadmap

Semper is one menu bar app with nine utility modules: Sound, Awake, Displays,
Workspace Restore, File Shelf, Safe Eject, Scenes, Away, and Presentation. All
nine are integrated on `main`. The downloadable release is v1.0.0, which
contains Sound only. This roadmap orders the work to deliver the whole suite as
dependable signed releases without hiding experimental behavior. Per-module
state lives in the [product status guide](guide/product-status.md).

## Current priorities

### 1. Ship the integrated multi-utility suite

- Complete native acceptance of the integrated build: signed clean-Mac install,
  real permission prompts, hardware behavior, accessibility, update, and
  uninstall. The [status guide](guide/product-status.md) records the gates.
- Publish the next release only when the website, README, release notes,
  Homebrew cask, and update feed describe the same artifact.
- Keep the released-versus-development boundary explicit everywhere.

### 2. Shell, navigation, permissions, and lifecycle

- Keep one predictable shell: Home summaries, action search, favorites, and
  module add, pause, resume, and remove.
- Adding a module must continue to start no service and request no permission.
  First explicit use creates the runtime and states its permission reason.
- Denied or revoked permissions, limited runtimes, and failed cleanup stay
  visible with a recovery path. Quit drains composed sessions before the
  services they use. See the [module shell guide](guide/module-shell.md).
- Finish the current interaction gaps first: keyboard-accessible file selection
  in File Shelf and cancellation while Presentation prepares or starts.

### 3. Window Layout

The next planned increment. It is not implemented today.

- Manual placement commands: left half, right half, maximize to the usable
  screen area, center, and restore the last placement.
- Built in its own branch on the existing Workspace Restore window helpers.
- Manual actions only: no automatic tiling and no window watching.
- Preserve the intended window when the menu bar takes focus. Verify each
  placement and keep later manual adjustments intact when restoring.
- Test half and maximized windows through later center and restore actions
  without weakening Workspace Restore's fullscreen protections.

### 4. Cross-module workflows

- Scenes and Presentation compose the other modules: preview before apply,
  verified writes, reverse-order recovery, and visible partial failures.
- Composition stays a feature, not a requirement. Every module must remain
  useful on its own.

### 5. Module depth guided by user jobs and reuse

- Sound and Displays: grow verified device compatibility and document correct
  fallbacks for devices that misreport controls.
- Workspace Restore: arrangement reliability across displays, Spaces, and
  restarts.
- File Shelf and Safe Eject: behavior improvements from reproducible reports,
  keeping original files and volumes safe.
- After File Shelf's file picker, add **Resize Image Copy** for one selected
  local JPEG or PNG. Offer 1024 or 2048 pixels on the longest edge without
  enlargement, show output dimensions, and save a separate copy. Preserve
  orientation, color and transparency, explain metadata handling, and support
  cancellation. No batch processing, uploads, or original-file replacement.
- Awake and Away: keep power assertions and the curtain testable and honest
  about what they do not block.
- A new utility needs a clear local user job, no account requirement, the
  shared lifecycle and disclosure rules, and reuse of existing services where
  reasonable.

### 6. Quality, accessibility, and contributor documentation

- Preserve real-time audio callback safety. Add focused tests around tap
  lifecycle, crossfades, output gating, and device reconnect behavior.
- Audit keyboard navigation, focus order, VoiceOver labels, contrast, and
  reduced motion across all module surfaces.
- Turn verified device reports and recurring support answers into guides, and
  keep starter issues small, testable, and unclaimed until someone begins.

## Reference utilities

Focused specialist tools set the expectations each Semper module must meet:

- [Rectangle](https://github.com/rxhanson/Rectangle) for window placement
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) for
  external display control
- [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704) for
  awake sessions
- [Dropover](https://dropoverapp.com/) for a file shelf
- [Vorssaint utilities](https://github.com/vorssaint/vorssaint-utils) for a
  broad free modular suite
- [FineTune](https://github.com/ronitsingh10/FineTune) for per-app audio with
  AutoEQ and ISO 226 loudness compensation

Semper has not benchmarked against these tools and claims no superiority. The
case for Semper is one shell with shared lifecycle, disclosure, and recovery
rules, and modules that can work together.

## Contribution levels

- **Starter:** documentation, pure-function tests, accessibility labels, and
  isolated UI state.
- **Intermediate:** parser behavior, settings state, device classification,
  module lifecycle transitions, and failure recovery with tests.
- **Advanced:** process taps, aggregate devices, HAL callback code, DSP
  lifecycle, DDC transport, Accessibility window operations, Disk Arbitration,
  power assertions, and curtain input filtering.

Use [good first issues](https://github.com/niharnm/Semper/contribute) for a
first pull request. Advanced work should begin with a GitHub issue or
discussion and include a hardware test plan.

## Current boundaries

- Supported platform: macOS 15.4 or later.
- Downloadable today: v1.0.0, published 2026-08-26, with Sound. Source builds,
  unit tests, the static website, and signed releases through GitHub and
  Homebrew are current.
- Integrated on `main` and in no download yet: Awake, Displays, Workspace
  Restore, File Shelf, Safe Eject, Scenes, Away, and Presentation.
- Planned additions: Window Layout and File Shelf's Resize Image Copy action.
- Hardware-dependent: process taps, device routing, DDC, Bluetooth call mode,
  media keys, Accessibility window operations, volume ejection, and permission
  behavior.
- Release-dependent: automatic updates require a current signed feed, and broad
  compatibility claims require verified hardware reports.
- Out of scope today: Windows, Linux, iOS, cloud accounts, and audio recording.
