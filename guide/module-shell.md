# Module shell

Semper has one menu-bar panel and a native detail window. Home shows pinned actions and a grid of added utilities with current summaries. All actions and recent history are collapsed until requested. Action search stays above the content. Parameterized controls live in the detail window. Command-Option-K opens the action surface; its shortcut can be changed in Settings. Command-K focuses search inside Semper. Type an action or utility name, select a result with Up or Down, and press Return to run it through the same availability and confirmation checks as a click. Escape clears the query. A pending Scene recovery remains visible during search.

When Sound is already running, its Home summary shows the current output and the number of apps with active audio. Home also shows module limitations, failed cleanup, and denied, restricted, or revoked permissions. Reading these summaries does not start Sound or another utility.

Recent actions retain the last eight registered action outcomes in memory for this session, with three shown in the compact panel. Entries contain an action identifier, timestamp, and outcome. They do not retain paths, filenames, window titles, or error text. An accepted asynchronous command remains distinct from a completed change.

Modules has a title-and-purpose search and All, Added, and Available filters. Open navigates to the selected utility; adding, pausing, resuming, and removing keep their existing lifecycle rules. Permission, activity, data, and hardware details remain available on each module.

## Lifecycle

The module catalog is metadata. Adding a module exposes its controls and commands without creating its service or requesting permission. Opening its page from Home or Modules also does not start its service. Its explicit start control or registered utility action starts the runtime through the existing admission and permission checks; paused modules must be resumed first. Sound owns its audio engine, media keys, device observers, feedback, and audio shortcuts. Starting Semper, viewing Home, and adding Awake do not create Sound.

Presence, runtime, and permission are separate state values. Pause blocks execution immediately and drains owned work. Once paused, actions remain visible with the reason "Resume this module in Modules first." Resume permits actions with a stopped runtime. Removal unregisters active actions and removes their favorites. Saved module data is managed separately from presence; bundled code remains installed.

Cleanup failures remain visible and block a new runtime until cleanup succeeds. Retry stop repeats cleanup. Terminal services are replaced after successful cleanup. Quit drains composed sessions before the services they use, and awaits pending startup and stopping work.

The shared DDC controller is held above Sound so its serialized display transport can serve independent display controls. Sound detaches its callbacks when it stops.

Scenes can open without starting Sound. Capturing saves controls from modules that are already running. Applying a scene starts only selected domains whose modules are added and unpaused; an unavailable required control stops the operation before changes begin. A pending recovery journal keeps the services it needs available. Deferred shutdown provides a recovery-only screen to restore or explicitly keep the current setup.

## Displays

Displays opens without Sound. Its inventory shows connected displays and explains unavailable controls. Refresh reads capabilities and supported brightness, contrast, volume, and input state. Individual and grouped slider changes keep each display's result visible, including partial, cancelled, and unverified writes.

Input switching requires confirmation and sends one request. It is never automatically retried or restored. Volume and input remain outside Scenes; Scenes use brightness and contrast, and Presentation selects brightness. Identify, a local diagnostics export, and Open Display Settings are explicit actions. Queued view actions recheck current Scene activity before dispatch.

## Presentation

Add Awake before opening Presentation. Choose 30 minutes, 1 hour, or 2 hours; optionally select display brightness, a Sound output and level, and individually selected windows from a Workspace Restore preview. Loading each optional control requires its module to be added and unpaused. Selecting Sound is the only Presentation path that starts audio controls.

Preview records the proposed targets and their current values without changing settings or acquiring a power assertion. Start rejects settings that changed after preview. Presentation acquires its own finite Awake lease, applies selected Sound/display controls through the existing scene coordinator, then applies the frozen Workspace plan. It does not add a saved scene to the library.

End, duration expiry, cancellation, and startup failure restore in reverse order: selected windows, scene controls, then Presentation's Awake request. Later manual changes stay in place. The latest window receipt is kept after every recovery attempt. Missing devices, unreadable state, or unverified window writes remain visible and may require retry or manual recovery.

While Presentation owns a preview or recovery, its dependency services cannot be removed. Workspace selection, binding, preview, and direct mutation actions cannot invalidate its reserved plan. **Keep Current Setup** is an explicit confirmation that accepts current settings and gives up this session's recovery. If cleanup fails afterward, every retry retains that choice for this session. Automatic cleanup never chooses it. Window receipts are process-local, so unfinished window recovery cannot be resumed after quitting.

## Away

Away opens independently of Sound and the manual Awake module. Its detail view and Settings pane use the same coordinator. Adding Away or browsing Settings does not create it; Open Away, Open Away Settings, and the Away action prepare it explicitly. Its shortcut is unassigned by default and remains independent of Sound and Workspace shortcuts.

Away holds exclusive mutation admission through authentication and cleanup. Scenes, Presentation, and direct control writes use the shared admission boundary. A queued hardware write keeps its admission until the owned work finishes. Pausing or removing a guarded Away session requires authentication to exit first. A countdown can be cancelled without entering the guarded state.

Ordinary Quit authenticates before cleanup begins. After authorization, Quit awaits Away and the other utilities. Incomplete cleanup retains the coordinator and its Awake owner for an explicit retry. Choosing Keep Open clears that Quit authorization. System logout, shutdown, restart, and quit-all requests still await cleanup but do not require Away authentication.

Reset All Settings authenticates before deleting Away PIN or photo data, then resets the other settings. A failed authentication or cleanup leaves an error visible. Away cleanup recovery remains available from its detail view and Settings after ordinary controls have stopped.

## Commands

`ModuleRegistry` stores pure module and action descriptors. `UtilityCommandCenter` owns typed action handlers, current disabled reasons, confirmation, and cancellation. It rechecks admission immediately before execution. A pause or removal drains the module's command tasks before disposing its service.

Sound exposes **Mute current output** and **Unmute current output** in search and favorites. Executing either action starts Sound if needed, resolves the current output again after startup, and sends the existing typed audio command. A missing output or unavailable mute state blocks the action with a reason. Browsing these actions does not start Sound.

Action identifiers are stable strings in the form `module.verb`; they identify compiled handlers and never contain executable text. Actions belonging to added modules appear in search, including disabled paused actions. Pending lifecycle transitions temporarily hide their actions. Search compares every entered word against the action title, module name, and keywords, with a deterministic title-and-identifier order.

Up to four favorites are stored by action identifier. Pausing preserves favorites for resume; removing a module removes its favorites. Unknown action identifiers are pruned after registration finishes.

## Verification scope

The test app entry in Debug bypasses runtime construction and the process lock. Registry, command, and lifecycle tests use injected closures and temporary stores. They do not require audio capture, power assertions, window movement, or storage ejection.

The explicit DEBUG Away UI-test launch path uses a separate fixture before normal runtime construction. It uses temporary settings and photo storage, fake input, power, PIN, and authentication providers, and the canonical Away views. It awaits coordinator cleanup and flushes settings before deleting temporary resources. These tests do not cover ordinary app startup or native permissions and hardware.

Compilation and controlled fixtures do not establish hardware, permission, accessibility, signed-install, update, or notarization readiness. Those checks remain separate release gates.
