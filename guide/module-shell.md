# Module shell

Semper has one menu-bar panel and a native detail window. Home lists added modules, their current summaries, pinned actions, and action search. Parameterized controls live in the detail window. Command-Option-K opens the action surface; its shortcut can be changed in Settings.

## Lifecycle

The module catalog is metadata. Adding a module exposes its controls and commands without creating its service or requesting permission. The first explicit Open or utility action creates the runtime. Sound owns its audio engine, media keys, device observers, feedback, and audio shortcuts. Starting Semper, viewing Home, and adding Awake do not create Sound.

Presence, runtime, and permission are separate state values. Pause hides actions immediately and drains owned work. Resume exposes actions with a stopped runtime. Removal unregisters active actions and removes their favorites. Saved module data is managed separately from presence; bundled code remains installed.

Cleanup failures remain visible and block a new runtime until cleanup succeeds. Retry stop repeats cleanup. Terminal services are replaced after successful cleanup. Quit drains composed sessions before the services they use, and awaits pending startup and stopping work.

The shared DDC controller is held above Sound so its serialized display transport can serve independent display controls. Sound detaches its callbacks when it stops.

## Commands

`ModuleRegistry` stores pure module and action descriptors. `UtilityCommandCenter` owns typed action handlers, current disabled reasons, confirmation, and cancellation. It rechecks admission immediately before execution. A pause or removal drains the module's command tasks before disposing its service.

Action identifiers are stable strings in the form `module.verb`; they identify compiled handlers and never contain executable text. Only actions belonging to added, unpaused modules appear in search. Search compares every entered word against the action title, module name, and keywords, with a deterministic title-and-identifier order.

Up to four favorites are stored by action identifier. Pausing preserves favorites for resume; removing a module removes its favorites. Unknown action identifiers are pruned after registration finishes.

## Verification scope

The test app entry in Debug bypasses runtime construction and the process lock. Registry, command, and lifecycle tests use injected closures and temporary stores. They do not require audio capture, power assertions, window movement, or storage ejection.

Compilation and controlled fixtures do not establish hardware, permission, accessibility, signed-install, update, or notarization readiness. Those checks remain separate release gates.
