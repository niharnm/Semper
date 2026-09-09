# Workspace operation receipts

Presentation can apply an explicitly selected workspace subset and later restore
its observed changes without using the direct Workspace Undo history.

## Prepare and apply

Use the same enabled `WorkspaceService` instance that owns the Workspace detail
view. Let the user choose an arrangement, resolve its window bindings, map any
missing displays, and request a preview. Then freeze the selected slots:

```swift
let plan = try workspace.makeRestorePlan(selectedSlotIDs: selectedSlotIDs)
```

Plan creation reads the completed preview. It does not request Accessibility or
move windows. The plan captures the chosen bindings, current frames, target
frames, and display topology. A later UI selection or rebinding does not alter
it. Presentation should require another preview when its own parameters change.

Apply the plan only after the user confirms Presentation:

```swift
let receipt = await workspace.apply(plan)
```

Keep the returned receipt even if the caller is cancelled or the result is
partial. Each selected slot has an outcome, including skipped and unattempted
slots. Observed partial changes remain available for recovery. A write with no
readback requires manual recovery because its resulting frame is unknown.

## Restore and recover

When Presentation ends, reverse its Workspace receipt before restoring the
preceding Scene:

```swift
let restoration = await workspace.reverse(receipt)
```

Inspect the per-slot restoration results. Reversal visits observed changes in
reverse order and requires the same live window, supported current state, the
original display identity and geometry, and an exact match with the recorded
post-apply frame.
Later manual moves and unrelated restores are left intact. Closed or recreated
windows are never matched by title, frame, or application guesswork.

Use the returned receipt's `pendingRecoverySlotIDs`, `manualRecoverySlotIDs`, and
`preservedManualChangeSlotIDs` to explain the result. `needsRecovery` covers
pending and unknown-state recovery; a preserved manual move is reported
separately. If another restoration is appropriate, pass the latest restoration
receipt to `reverse` so it uses the latest observed frame and original target.
Do not automatically retry failures or treat an unknown frame as restored.

Both operations use the service's single-operation admission and lifecycle
cleanup. Keep the module enabled through restoration, then await pause or
shutdown when the shared shell removes it. Applying and reversing receipts do
not read or overwrite direct `undoEntries`.

Receipts are in-memory values for the current application session. They do not
provide automatic matching after restart, control of every Space, or a record
of window movements that occurred and were later moved back to the same frame.
The existing conservative fullscreen geometry rule and native validation gaps
still apply; see [direct utilities](direct-utilities.md).

## Verification

Run the receipt and direct Workspace regressions without launching Semper:

```sh
python3 scripts/test-direct-utilities.py --jobs 2 --filter Workspace
```

The full utility suite also covers File Shelf and Safe Eject. Tests use injected
window backends and owned temporary data; no Accessibility prompt or real window
movement is required.
