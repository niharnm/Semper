# Direct utilities

Workspace Restore, File Shelf, and Safe Eject are independent native modules.
Their services do not own or start the audio engine. This feature stack supplies
the services and direct views; the application shell owns module registration,
navigation, shortcuts, and service lifetime.

## Integration boundaries

| Module | Source directory | Direct surface | Shell action identifiers |
| --- | --- | --- | --- |
| Workspace Restore | `Semper/Workspace` | `WorkspaceView` | `workspace.capture`, `workspace.preview`, `workspace.restore`, `workspace.undo` |
| File Shelf | `Semper/Shelf` | `ShelfCompactView`, `ShelfDetailView` | `shelf.open`, `shelf.clear` |
| Safe Eject | `Semper/Storage` | `SafeEjectView` | `storage.open`, `storage.ejectAllEligible` |

Keep selected apps, arrangements, files, and volumes in their detail surfaces.
Parameterless shell commands that need a selection open that surface. Do not
guess a target or silently select every item. Module-owned metadata can be mapped
to the shared catalog without constructing a live service.

Adding a module makes its UI available. The shell starts its service only when
the module is enabled, pauses it when disabled, and awaits asynchronous cleanup
before removal or quit. Do not request Accessibility from startup or from module
registration. Audio startup must remain a separate shell decision.

The shell should keep one service instance per added module. Discard the instance
after successful shutdown cleanup and construct a new one if the module is added again:

| Service | Start enabled module | Pause or disable | Remove or quit |
| --- | --- | --- | --- |
| `WorkspaceService()` | `await workspace.start()` | `await workspace.pause()` | `await workspace.shutdown()` |
| `ShelfService()` | `shelf.start()` | `await shelf.pause()` | `await shelf.shutdown()` |
| `SafeEjectService()` | `storage.start()` | `storage.pause(); await storage.waitForCleanup()` | `storage.shutdown(); await storage.waitForCleanup()` |

These calls run on the main actor. Workspace delegates Accessibility operations
to its backend actor; shelf imports and checksums have cancellable workers.
Safe Eject cancels monitoring immediately, then `waitForCleanup()` returns
`Result<Void, SafeEjectFailure>` after checking its owned metadata-query cleanup.
Handle the result before removal or quit. On `.failure(.cleanupPending)`, keep
the service alive, report incomplete cleanup, and offer an explicit retry. The
same failure is available through `cleanupFailure`; restart cannot clear it.
Calling `waitForCleanup()` again can clear it after the owned process has exited
and its resources have closed. A failed cleanup returns without an indefinite
quit wait. No replacement query starts while cleanup remains pending.
Mount `WorkspaceView(service: workspace)`, `ShelfDetailView(service: shelf)`, or
`SafeEjectView(service: storage)` in the appropriate detail route. The menu can
mount `ShelfCompactView(service: shelf, openDetail: openFiles)`.

Registration interfaces are `WorkspaceModuleMetadata`,
`ShelfModuleRegistration()`, and `SafeEjectModule.descriptor`. Map their static
metadata to the shared catalog without starting a service. All three have no
module dependency or conflict and use the application's macOS 15.4 minimum.

For commands, `await workspace.handle(command)` returns `.openWorkspace(workflow)`
for the distinct capture, preview, or restore intent, or `.completed` after Undo.
The shell registers a new `WorkspaceWorkflowRequest`, preserves the current
arrangement selection and live choices, and passes the request to `WorkspaceView`.
These navigation commands do not request Accessibility or move windows. Busy or
Presentation-reserved Workspace sessions reject a new workflow request.
`ShelfCommandHandler(service: shelf, openDetail: openFiles)` exposes
`execute(_:)`; the shared shell should confirm the broad `shelf.clear` action
before execution. `try SafeEjectModule.handle(command, service: storage,
openDetail: openStorage)` navigates to the storage detail surface. `.open` only
navigates; `.ejectAllEligible` prepares a review of the current candidates and
opens the confirmation sheet. It does not unmount or eject. Preparation failures
are thrown for the shell to present after navigation. Physical eject requires
the subsequent explicit confirmation in `SafeEjectView`.

The shared shell installs its `MutationAdmissionGate` on Safe Eject before
starting the service. Each single or batch eject holds a shared `.manual`
permit through completion and cancellation cleanup. Failed cleanup retains that
permit until an explicit retry succeeds. An exclusive owner refuses new eject
operations before storage writes.

## Behavior boundaries

Workspace Restore captures selected apps and standard windows, previews planned
frames, and performs only manually requested restores. Window identity must be
unambiguous. Missing, minimized, unsupported, and constrained windows have
separate outcomes. A conservative geometry rule excludes windows spanning a
display's usable height and asks for manual adjustment; it does not establish
the operating system's fullscreen state. Saved arrangements retain stable slots, app identities,
display-relative targets, and user labels. Live Accessibility bindings stay in
memory. After restart, unresolved slots require an explicit current-window choice
in preview; a missing display requires an explicit destination choice. Binding a
slot does not move it. Undo compares the observed post-restore frame before
changing a window, so later manual moves remain intact. Control of every Space
and automatic matching of recreated windows are not promised.

Choose an arrangement explicitly after opening a saved library. Each Restore
workflow requires a fresh Preview and a separate Restore action. A new workflow
invalidates the previous preview without changing the selected arrangement,
draft name, live window bindings, or display choices. Once Restore starts, it
owns its window plan and display snapshot through completion.

The Workspace restore shortcut is unassigned by default and can be recorded in
Settings. It opens Restore preparation without starting Sound, requesting
Accessibility, or moving windows. Pausing or removing Workspace disables the
shortcut while preserving its assignment. Search and existing Sound or Scene
shortcut conflicts are reported without replacing the other assignment.

The optional "Prompt after displays change" preference is off by default. While
Workspace is running and the preference is enabled, one public AppKit screen
notification observer compares display identities and geometry. It does not
enumerate windows, request Accessibility, create previews, or move windows.
Repeated equivalent snapshots do not create new notices. The latest notice
appears in Workspace's detail view for the selected saved arrangement. It is
deferred while Workspace is busy, Presentation has reserved the workspace, or
another mutation permit is held. "Preview Arrangement" rechecks those conditions
and invokes a fresh preview; Restore remains a separate action.

Pausing, removal, and disabling the preference remove the observer and clear its
pending notice. Re-enabling takes a new baseline. The Boolean is stored in a
separate versioned local preference file beside the saved arrangements; display
events and notices remain in memory. Deleting all saved Workspace data also
resets this preference. Unsupported preference versions are left untouched and
reported.

Presentation uses the separate [operation receipt API](workspace-operation-receipts.md)
to apply explicit slot selections and restore their observed changes without
depending on the direct Undo history.

File Shelf accepts explicit drops, retains original files by reference, and
keeps session data by default. Persisting a shelf requires an explicit choice.
Clearing and expiry remove shelf entries and owned cache content, never original
files. Quick Look, reveal, drag-out, and checksum access report missing or
unavailable files. Copy Path copies the retained path even when the file is
missing. Image and text imports are bounded; checksum reads stream
in bounded chunks and can be cancelled. The module does not watch the clipboard
or folders, upload content, execute scripts, or alter original files.

Safe Eject uses public Disk Arbitration APIs with default options and reports
observed results. It does not claim that an idle drive is ready to disconnect,
identify open handles, force an eject, or retry after a failure. A request must
identify one eligible mounted volume, and physical eject must not affect another
mounted volume.

"Review All Eligible Volumes" freezes a single-use confirmation with individually
eligible volumes and explicit exclusion reasons. Mounted siblings on the same
physical device remain excluded, even if both are visible in the list. The
confirmation contains at most 128 candidates; larger inventories are refused
without truncation. Execution revalidates each exact confirmed volume identity
against fresh inventory before using the same native path as an individual
request. Newly mounted or newly eligible volumes never join the batch.

One operation owns the whole batch. Per-volume denial or refusal can leave a
partial result; cancellation, sleep, pause, shutdown, pending cleanup, or
unavailable verification stops remaining requests. The report distinguishes
completed checks, including refusals and unverified outcomes, from volumes not attempted.
Cancellation cannot undo a request already sent to macOS. The module retains one
batch report and up to 20 recent individual results in session memory, with no
drive history saved.

Physical backing must be unambiguous before unmount begins. Logical whole-media
nodes, including synthesized APFS storage, do not establish physical identity.
The resolver follows public IOKit parent relationships to supported physical
media and validates APFS container membership with a bounded, read-only
`/usr/sbin/diskutil apfs list -plist` query. It revalidates source, store, and
device identities before each storage operation. Cached topology only informs
the UI.

The metadata query runs off the main actor with a 1 MiB output limit and a
three-second deadline. Cancellation requests termination through the owned
`Process` and waits up to 250 ms. If the process remains alive or closing its
resources fails, ownership is retained and cleanup is reported as pending.
Repeated notifications and preflight calls cannot launch another query until an
explicit cleanup retry confirms exit and closes the resources. There is no raw
PID-based forced signal. The plist schema is validated explicitly; unsupported
output refuses the operation without exposing volume data in errors.

Another mounted volume on the selected physical device blocks eject. Proven
disjoint backing, including internal-only startup storage, does not. Unknown
relationships still block the request: a virtual disk's backing file could be on
the selected drive. Multi-device, RAID, virtual, malformed, or incomplete backing
is unsupported under this single-device action. Use Finder or Disk Utility when
the module cannot establish the relationship. These checks narrow races without
claiming an atomic transaction across macOS storage changes.

## Automated verification

The regular Xcode unit test target uses `Semper.app` as its test host. To exercise
these utilities without starting the app, audio, or permission prompts, run:

```sh
python3 scripts/test-direct-utilities.py
```

The runner creates a temporary Swift package with only the three module source
directories and their namespaced tests. It has no production dependencies and
passes additional arguments to `swift test`, including `--filter`. Tests use
injected backends and temporary owned files. They must never eject a user drive
or request Accessibility.

Compile the full app separately with a unique DerivedData directory and signing
disabled. A build proves compilation, not live permission or hardware behavior.

## Remaining integrated checks

- Enable each optional module while audio remains stopped. Pause, remove, and
  quit with active work and verify cleanup.
- With an explicitly approved signed build, exercise first-use Accessibility,
  denial, revocation, multiple displays, Spaces, minimized/full-screen windows,
  app minimum sizes, subsequent manual moves, and undo. Check opt-in prompt
  behavior on display connect, disconnect, resolution, and arrangement changes.
- Exercise Finder, browser, Mail, text, and image drops; drag-out; Quick Look;
  missing files; iCloud placeholders; security-scoped bookmarks; expiry; and
  persistence after restart.
- Use a controlled disposable drive to check selected-volume eject, busy denial,
  multiple mounted partitions, mount/unmount, wake, and sudden-disconnect races.
  Use separate disposable physical devices for mixed batch results and
  cancellation while macOS is processing a request.
- Check keyboard navigation, VoiceOver, contrast, reduced motion, and both menu
  and full-window layouts in the integrated shell.

These checks require the manager's integrated application. This stack does not
establish signing, notarization, source provenance, installation, updater, or
public-release readiness.

## Design and API references

- [Apple Accessibility objects](https://developer.apple.com/documentation/applicationservices/axuielement)
- [Apple display-parameter notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification)
- [Apple provider file representations](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(for:openinplace:completionhandler:))
- [Apple Disk Arbitration unmount](https://developer.apple.com/documentation/diskarbitration/dadiskunmount(_:_:_:_:))
- [Apple whole-media lookup behavior](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/DiskArbitration/DADisk.c#L269-L310)
- [Apple storage protocol characteristics](https://github.com/apple-oss-distributions/IOStorageFamily/blob/main/IOStorageProtocolCharacteristics.h)
- [Apple IOKit parent iteration](https://developer.apple.com/documentation/iokit/1514366-ioregistryentrygetparentiterator)
- [Moom saved window layouts](https://manytricks.com/moom/)
- [Moom display-configuration actions](https://manytricks.com/moom/help/customactions.html)
- [Jettison individual and all-volume menu actions](https://www.stclairsoft.com/Jettison/)
- [Ejectify event-driven volume menu](https://github.com/nielsmouthaan/ejectify-macos/blob/main/Ejectify/View/StatusBarMenu.swift)
- [Dropover temporary shelf behavior](https://dropoverapp.com/)

These references informed API boundaries and expected behavior. No external
implementation is vendored by this stack.
