# Semper product status

Semper is one menu bar app with nine utility modules. This page is the shared
record of what each module does, where it stands, and what remains before
release. It changes in the same commit as the work that changes a status.

Snapshot: `main` at `6afe10d`, 2026-09-09, including the interaction fixes from
[PR #108](https://github.com/niharnm/Semper/pull/108). Latest downloadable
release: v1.0.0, published 2026-08-26, containing Sound only.

## States

- **Released**: included in a published signed release users can download.
- **Integrated**: merged on `main` in the shared shell with automated tests.
  Not included in the public binary release; native acceptance remains separate.
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
| File Shelf | Hold temporary files, links, images, and text between apps | Integrated | Shared gates, plus drop-source, missing-file, and persistence checks | [Source](../Semper/Shelf), [guide](direct-utilities.md) |
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

## Next increments

These changes are outside the `main` snapshot above and are not released.

| Increment | State | Acceptance before integration |
| --- | --- | --- |
| Window Layout | In review, [PR #106](https://github.com/niharnm/Semper/pull/106) | Final source clearance and integration; native window, shortcut and recovery checks remain open |
| File Shelf Resize a Copy | In review, [PR #109](https://github.com/niharnm/Semper/pull/109) | Correct pending lifecycle/expiry, cleanup ownership and saved-path findings; verify the final implementation before integration and native acceptance |

### Window Layout

Reviewed source `b8ce5bd` adds left half, right half, maximize, center and
previous-placement restore with optional shortcuts and Home/search/pinned
actions. It becomes the tenth integrated module only after its source is
merged into `main`; it is not included in the nine-module snapshot above.

Full-height current windows and targets are refused even for ordinary windowed
apps. Halves and maximize can therefore be unavailable when both the Dock and
menu bar auto-hide. Eligible smaller windows can use center and restore. If an
app returns an excluded or unreadable result, automatic restore is unavailable
and manual review is required. An excluded full-height result retains its known
before/after placement. The review requirement survives pause; acknowledgement,
module removal or quitting clears it.

Passing source tests does not establish native focus, keyboard, VoiceOver,
permission, real-window or hardware acceptance. See the
[reviewed Window Layout guide](https://github.com/niharnm/Semper/blob/b8ce5bd7f402d117f8b1eec2a5bf06fd68a3bcc3/guide/window-layout.md).

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
