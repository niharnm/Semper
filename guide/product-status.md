# Semper product status

Semper has ten utility modules integrated on `main`. This page
records what each module does, where it stands, and what remains before
release. It changes in the same commit as the work that changes a status.

App source `4be9555` includes the macOS experience update below. It builds on
`main` at `20ab341`, including Window Layout handle retention from
[PR #112](https://github.com/niharnm/Semper/pull/112) and Resize a Copy from
[PR #111](https://github.com/niharnm/Semper/pull/111).
Latest downloadable release: v1.0.0, published 2026-08-26, containing Sound only.

## macOS experience

Current source keeps Semper exclusively on macOS. It adds a reorganized
Home, keyboard action selection and execution, searchable module discovery,
and six Window Layout placements: top and bottom halves and all four quarters.
All eleven Window Layout actions have optional shortcuts. These changes are
included in source; they are not in the public v1.0.0 binary.

The existing command admission, confirmation, permission and recovery rules
still apply. Native keyboard, VoiceOver and real-window acceptance remain
separate from compilation, unit tests and offscreen view rendering.

## States

- **Released**: included in a published signed release users can download.
- **Integrated**: merged on `main` in the shared shell with automated tests.
  Not included in the public binary release; native acceptance remains separate.
- **Implemented in this change set**: included in the staged source snapshot.
  It becomes integrated only when this change set merges into `main`.
- **In review**: proposed source outside `main`. Passing source checks alone
  does not establish integration, native acceptance, or public release.
- **Planned**: agreed scope with no implementation on `main`.

## Modules

| Module | User job | State | Remaining before release | Evidence |
| --- | --- | --- | --- | --- |
| Sound | Control app and device audio: per-app volume, output routing, EQ, equal-loudness compensation | Released, v1.0.0 | Later Sound changes remain subject to the next release's shared acceptance gates | [Source](../Semper/Audio), [AutoEQ](autoeq.md), [audio safety](realtime-audio-safety.md) |
| Awake | Keep the Mac awake for a chosen duration, with app and battery stop conditions | Integrated | Shared gates, plus assertion, expiry, and stop-condition checks on hardware | [Source](../Semper/Awake), [guide](awake-sessions.md) |
| Displays | Read and set supported external display brightness, contrast, volume, and input | Integrated | Shared gates, plus DDC checks on real displays | [Source](../Semper/Displays), [guide](module-shell.md#displays) |
| Workspace Restore | Return selected app windows to a saved arrangement | Integrated | Shared gates, plus Accessibility permission flows, multi-display, and Spaces checks | [Source](../Semper/Workspace), [guide](direct-utilities.md) |
| Window Layout | Place one eligible window or restore its preceding placement | Integrated | Shared gates; full-height/auto-hide limits, focus, shortcuts, constrained windows and recovery need native verification | [Source](../Semper/WindowLayout), [guide](window-layout.md) |
| File Shelf | Hold temporary items between apps and resize local image copies | Integrated | Shared gates, plus drop-source, missing-file, persistence and image-copy checks below | [Source](../Semper/Shelf), [guide](direct-utilities.md), [image copies](shelf-image-copy.md) |
| Safe Eject | Review removable volumes to eject and check each observed result | Integrated | Shared gates, plus disposable-drive single and batch eject checks | [Source](../Semper/Storage), [guide](direct-utilities.md) |
| Scenes | Save and apply settings across utilities together, with a restore point | Integrated | Shared gates, plus capture, apply, and recovery checks on hardware | [Source](../Semper/Scenes), [guide](module-shell.md) |
| Away | Cover every display with a privacy curtain that requires authentication to exit | Integrated | Shared gates, plus input-filter permission, authentication, and multi-display checks | [Source](../Semper/Away), [guide](module-shell.md#away) |
| Presentation | Run a timed session that applies selected display, sound, and window targets | Integrated | Shared gates, plus a full session with reverse-order recovery on hardware | [Source](../Semper/Presentation), [guide](module-shell.md#presentation) |

## Integrated interaction fixes

These fixes are included in the `main` snapshot above. Native acceptance and
the shared release gates remain separate.

| Fix | State | Remaining native verification | Guide |
| --- | --- | --- | --- |
| Presentation preparation/start cancellation | Integrated | Visible cancellation and Escape during preparation/start, pending-work drainage, recovery and retry controls | [Presentation controls](presentation-controls.md) |
| File Shelf Choose Files | Integrated | Native picker focus, selection and cancellation, keyboard navigation and Command-O routing in compact and detail views | [File selection](shelf-file-selection.md) |

## Integrated File Shelf feature

This feature extends File Shelf in the `main` snapshot above. It is not
released and adds no new module.

| Increment | State | Remaining acceptance |
| --- | --- | --- |
| File Shelf Resize a Copy | Integrated, [PR #111](https://github.com/niharnm/Semper/pull/111) | Native Save, keyboard/VoiceOver, cancellation, recovery, destination compatibility and shared release gates |

## Window Layout

Source `0f25f65` adds left half, right half, maximize, center and
previous-placement restore with optional shortcuts and Home/search/pinned
actions. It is integrated through PR #110 at `f3e278d`.

Full-height current windows and targets are refused even for ordinary windowed
apps. Halves and maximize can therefore be unavailable when both the Dock and
menu bar auto-hide. Eligible smaller windows can use center and restore. After
an attempted write, an excluded or unreadable result requires manual review
instead of automatic restore. An excluded full-height readback from that write
retains its known before/after placement. A refusal without a write preserves
the preceding placement record instead.
The review requirement survives pause; acknowledgement, module removal or
quitting clears it.

Passing source tests does not establish native focus, keyboard, VoiceOver,
permission, real-window or hardware acceptance. See the
[Window Layout guide](window-layout.md).

## File Shelf Resize a Copy

Source `2db9a4a` is integrated through PR #111 at `ced1a2b`. Select one fully
downloaded local JPEG or PNG, review dimensions for a longest edge of 1,024 or
2,048 pixels, then save a separate copy. Images are not enlarged. The source
format, displayed orientation, color profile and PNG transparency are kept;
JPEG re-encoding can lose detail. Descriptive metadata, including camera and
location data, is removed. Information visible in the pixels remains.

Inputs are limited to 32 MiB, 40 million pixels and 16,384 pixels per side.
Animated, unsupported, corrupt, unavailable or larger images are refused.
The original is untouched and existing destinations are never overwritten.
Saving requires a destination filesystem that supports macOS file cloning;
unsupported locations are refused. There are no uploads, cloud downloads or
batch operations.

Failed cleanup retains the affected items and file access for explicit retry.
Recovery keeps the verified saved path visible until Done; pending Pause or
Quit waits for that acknowledgement. If edited or deleted output cannot be
verified, Finish Without Verification ends tracking only after private cleanup.
It does not delete or republish the public copy. Native image calls may finish
before cancellation, and no fixed peak memory bound is claimed.

Source clearance does not establish native Save-dialog focus, keyboard,
VoiceOver, cancellation, recovery, provider/volume or signed-build acceptance.
See the [image-copy guide](shelf-image-copy.md) for cleanup ownership limits and
the remaining checks.

## Shared release gates

Integrated modules pass automated tests that use injected fixtures. Those tests
do not establish signed-install, permission, hardware, accessibility, update,
or notarization readiness. See the
[verification scope](module-shell.md#verification-scope) and the
[remaining integrated checks](direct-utilities.md#remaining-integrated-checks).

Before an integrated module is called released, one signed build must pass on
hardware: clean-Mac install, real permission prompts including denial and
revocation recovery, module add, pause, remove, and quit with active work,
keyboard and VoiceOver access, updater behavior, and uninstall cleanup.

Binary publication also requires completed signing and notarization checks,
source-rights and third-party-notice review, and verified install, update and
rollback behavior. These are release gates, not claims that they have passed.

Before publication, the website, README, release notes, Homebrew cask, and
update feed must refer to the same verified release artifact.

## Update contract

Status moves only with evidence, never by assumption:

- A feature change lands with its implementation, tests, and guide updates in
  the same change set.
- Integrated requires the code merged on `main`. Released requires a published
  signed artifact containing it. An acceptance item is marked done only after
  the check was run and its result recorded.
- The website, README, and release notes use the same verified feature states.
  Planned and development work may appear before release when clearly labeled;
  the download description lists only what its artifact contains.
- Whoever changes a state updates the snapshot line above in the same change.

Passing tests alone advance nothing, and a compiled build proves compilation,
not behavior on hardware.
