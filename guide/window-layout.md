# Window Layout

Window Layout arranges one standard app window at a time. Add it in Modules and open it from Home or the sidebar. Adding the module does not request Accessibility access or read windows. The first layout action requests access if needed.

Select a window in another app, then invoke an action from Semper or an optional shortcut:

| Action | Result |
| --- | --- |
| Left Half | Fills the left half of the current display's usable area. |
| Right Half | Fills the right half of that area. |
| Top Half | Fills the top half of that area. |
| Bottom Half | Fills the bottom half of that area. |
| Top Left Quarter | Fills the top left quarter of that area. |
| Top Right Quarter | Fills the top right quarter of that area. |
| Bottom Left Quarter | Fills the bottom left quarter of that area. |
| Bottom Right Quarter | Fills the bottom right quarter of that area. |
| Maximize | Fills the area available around the Dock and menu bar without entering full screen. |
| Center | Centers the window without changing its size. Oversized windows are refused. |
| Restore Previous Placement | Returns the last changed window to its immediately preceding placement. |

Halves and quarters split the usable area exactly instead of rounding, so an odd width or height gives neighbouring placements a shared half-point edge rather than a gap or an overlap. A quarter is the intersection of its vertical and horizontal halves: Top Left Quarter and Top Right Quarter together equal Top Half, and Top Half and Bottom Half together equal Maximize. Displays placed left of or above the primary display, which have negative coordinates, use the same calculation.

The module view groups Halves and Quarters side by side, followed by Maximize, Center and Restore Previous Placement. Every row runs its action through the shared action list, so pinning, progress and unavailable reasons behave as they do on Home.

Actions are searchable from Home and can be pinned there. Settings > Shortcuts provides optional bindings for all eleven actions. No shortcut is assigned by default. Sound's shortcut reset does not remove these bindings.

When Semper is frontmost, Window Layout uses the last eligible app active while the module was running. If none is known, select another app and return to Semper. The module reads only that app's focused window and never substitutes a different window when the original is missing.

Only standard, nonminimized windows with readable geometry and move/resize support are eligible. Window Layout retains Workspace Restore's conservative full-height exclusion. It does not infer fullscreen state from a button role or use an undocumented fullscreen attribute. Full-height windows are refused even when they are ordinary windows. Targets that would enter the excluded area are also refused, so Left Half, Right Half and Maximize can be unavailable when the menu bar and Dock both auto-hide. Top Half, Bottom Half and the quarters use half of the usable height, so that check does not refuse them; Center remains available for smaller windows. Missing display bounds are refused.

Every change checks the resulting frame. The backend checks the expected display arrangement again after its final asynchronous window refresh and before writing. A refusal before any write preserves the preceding placement record and reports the refusal, even if an external change already reached the requested target. Repeating an action on a window that is already in that placement makes no write and keeps the preceding placement record. If an app limits an attempted write to another supported frame, the result says so and retains the observed change for restore. If an attempted write instead returns an excluded full-height frame, automatic restore is unavailable. The known before/after placement stays in memory for manual review. Restore skips windows moved since the previous action, missing windows, and changed display arrangements. After an excluded post-write result or an unverifiable write, check or adjust the window manually and confirm Keep Current Placement before another action. That confirmation discards the preceding placement record; the next action checks eligibility again.

Cancel stops additional writes and waits for the latest operation to finish. Supported, verified partial changes remain available to restore. Pause stops app observation and drains work while preserving the previous placement and any required manual review. Removing the module or quitting clears its window handles and previous-placement record. Window titles are not collected; only module and shortcut preferences persist.

Window Layout and Workspace Restore cannot write window positions concurrently. Presentation keeps its own recovery ownership; later manual changes are preserved by that recovery. Away prevents window changes while its curtain is active.
