# Semper roadmap

Semper has ten utility modules integrated on `main`: Sound, Awake, Displays,
Workspace Restore, Window Layout, File Shelf, Safe Eject, Scenes, Away, and
Presentation. File Shelf includes Resize a Copy. The downloadable release
is v1.0.0, which contains Sound only.
This roadmap orders the work to deliver the whole suite as dependable signed
releases without hiding experimental behavior. Per-module state lives in the
[product status guide](guide/product-status.md).

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
- Complete native acceptance of the integrated File Shelf picker and
  Presentation preparation/start cancellation, including keyboard routing,
  focus, dismissal, and recovery.

### 3. Window Layout acceptance and compatibility

The implementation from [PR #106](https://github.com/niharnm/Semper/pull/106)
is integrated on `main` through [PR #110](https://github.com/niharnm/Semper/pull/110).
Native acceptance remains open. See the [Window Layout guide](guide/window-layout.md).

- Verify all five manual commands, optional shortcuts, Home/search/pinned
  actions, intended-window selection, and later manual changes on real apps.
- Keep the conservative full-height exclusion explicit. Ordinary full-height
  windows and targets are refused; halves and maximize can be unavailable when
  both Dock and menu bar auto-hide. Smaller-window center and restore still
  require eligible geometry.
- After an attempted write, an excluded or unreadable result requires manual
  review. Verify that its recovery message survives cancellation and pause
  until acknowledged.
- Resolve full-height compatibility through verified behavior before broad
  support claims. Preserve Workspace Restore's protections. No automatic tiling
  or persisted window history is included.

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
- Complete native acceptance of File Shelf's **Resize a Copy**, integrated
  through [PR #111](https://github.com/niharnm/Semper/pull/111).
  It resizes one local JPEG or PNG to a longest
  edge of 1024 or 2048 pixels without enlargement or overwriting a file.
  Format, displayed orientation, color profile and PNG transparency are kept;
  descriptive metadata is removed. JPEG re-encoding can lose detail.
- Verify Save-dialog focus, keyboard access, cancellation, and refusal of
  destinations without macOS file-cloning support. Exercise cleanup recovery,
  the verified saved path retained until Done, and Finish Without Verification
  for changed or deleted output. Private cleanup remains required and public
  copies remain untouched. See the [image-copy guide](guide/shelf-image-copy.md)
  for input limits and remaining checks. No batch processing or uploads.
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
  Restore, Window Layout, File Shelf, Safe Eject, Scenes, Away, and Presentation.
- File Shelf's Resize a Copy is integrated on `main` and is not in v1.0.0.
- Hardware-dependent: process taps, device routing, DDC, Bluetooth call mode,
  media keys, Accessibility window operations, volume ejection, and permission
  behavior.
- Release-dependent: automatic updates require a current signed feed, and broad
  compatibility claims require verified hardware reports.
- Out of scope today: Windows, Linux, iOS, cloud accounts, and audio recording.
