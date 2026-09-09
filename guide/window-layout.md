# Window Layout

Window Layout arranges one standard app window at a time. Add it in Modules and open it from Home or the sidebar. Adding the module does not request Accessibility access or read windows. The first layout action requests access if needed.

Select a window in another app, then invoke an action from Semper or an optional shortcut:

| Action | Result |
| --- | --- |
| Left Half | Fills the left half of the current display's usable area. |
| Right Half | Fills the right half of that area. |
| Maximize | Fills the area available around the Dock and menu bar without entering full screen. |
| Center | Centers the window without changing its size. Oversized windows are refused. |
| Restore Previous Placement | Returns the last changed window to its immediately preceding placement. |

Actions are searchable from Home and can be pinned there. Settings > Shortcuts provides optional bindings for all five actions. No shortcut is assigned by default. Sound's shortcut reset does not remove these bindings.

When Semper is frontmost, Window Layout uses the last eligible app active while the module was running. If none is known, select another app and return to Semper. The module reads only that app's focused window and never substitutes a different window when the original is missing.

Only standard, nonminimized windows with readable geometry and move/resize support are eligible. Window Layout retains Workspace Restore's conservative full-height exclusion. It does not infer fullscreen state from a button role or use an undocumented fullscreen attribute. Full-height windows are refused even when they are ordinary windows. Targets that would enter the excluded area are also refused, so halves and Maximize can be unavailable when the menu bar and Dock both auto-hide; Center remains available for smaller windows. Missing display bounds are refused.

Every change checks the resulting frame. The backend checks the expected display arrangement again after its final asynchronous window refresh and before writing. If an app limits the requested size, the result says so and retains the observed change for restore. Restore skips windows moved since the previous action, missing windows, and changed display arrangements. If a write cannot be verified, check the window manually and confirm Keep Current Placement before another action.

Cancel stops additional writes and waits for the latest operation to finish. Verified partial changes remain available to restore. Pause stops app observation and drains work while preserving the previous placement. Removing the module or quitting clears its window handles and previous-placement record. Window titles are not collected; only module and shortcut preferences persist.

Window Layout and Workspace Restore cannot write window positions concurrently. Presentation keeps its own recovery ownership; later manual changes are preserved by that recovery. Away prevents window changes while its curtain is active.
