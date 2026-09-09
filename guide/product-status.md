# Semper product status

Semper is one menu bar app with nine utility modules. This page is the shared
record of what each module does, where it stands, and what remains before
release. It changes in the same commit as the work that changes a status.

Snapshot: `main` at fb9a3d5, 2026-09-09. Latest downloadable release: v1.0.0,
published 2026-08-26, containing Sound only.

## States

- **Released**: included in a published signed release users can download.
- **Integrated**: merged on `main` in the shared shell with automated tests.
  Not included in the public binary release; native acceptance remains separate.
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

## Next increments

These changes are not on the snapshot of `main` above and are not released.

| Increment | State | Acceptance before integration |
| --- | --- | --- |
| Presentation preparation/start cancellation | Draft [PR #102](https://github.com/niharnm/Semper/pull/102) | Visible cancellation, owned-work cleanup, recovery and failure tests, then native interaction checks |
| File Shelf Choose Files | Planned | Keyboard-accessible native selection using the existing import path; cancelled selection leaves the shelf unchanged |
| Window Layout | Planned | Manual halves, maximize, center and previous-placement restore using [Workspace helpers](../Semper/Workspace); verify target identity, constrained windows and later manual changes |
| File Shelf Resize Image Copy | Planned | Separate local JPEG/PNG copy; correct dimensions, orientation, color and transparency; original unchanged; explicit metadata policy, save failures and cancellation |

## Shared release gates

Integrated modules pass automated tests that use injected fixtures. Those tests
do not establish signed-install, permission, hardware, accessibility, update,
or notarization readiness. See the
[verification scope](module-shell.md#verification-scope) and the
[remaining integrated checks](direct-utilities.md#remaining-integrated-checks).

Before an integrated module is called released, one signed build must pass on
hardware: clean-Mac install, real permission prompts including denial and
revocation recovery, module add, pause, remove, and quit with active work,
keyboard and VoiceOver access, and updater behavior.

Binary publication also requires completed signing and notarization checks,
source-rights and third-party-notice review, and verified install, update and
rollback behavior. These are release gates, not claims that they have passed.

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
