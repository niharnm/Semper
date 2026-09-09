# Awake sessions

Choose a duration to start a manual Awake session. An optional reason appears with
the start time and remaining time. Changing the reason, display option, or stop
conditions does not extend the session. Choosing another duration starts a new
time limit.

## Stop conditions

- **App quits:** choose a currently running app. The condition follows that
  process instance, including its launch time. Relaunching the app does not keep
  the old session alive. Use Refresh apps to select a new instance.
- **Battery cutoff:** choose 10%, 20%, 30%, or 50%. The manual session ends at or
  below that level while running on battery. The cutoff is ignored on external
  power. A Mac without an internal battery can still run a session. If battery
  state is unknown while a cutoff is requested, the session cannot start or
  continue; Awake explains why.

Conditions apply immediately to an active manual session. They do not end an
Away, Scene, or Presentation request. End Awake stops only the manual session.
App and power observations stop with that session. Nothing is restored after
relaunch, and adding or configuring Awake requests no privacy permission.

Closing the lid and choosing Sleep retain their normal macOS behavior. Awake
prevents idle sleep; it does not override those controls.

## Shared service

The existing `start`, `stop`, display, and lease signatures remain compatible.
Use `setConditions`, `setSessionReason`, and `availableApplications` for manual
controls. `AwakeSession` includes the applied reason and conditions. Inject
`AwakeConditionMonitoring` to test process and battery events without live power
or application changes.

Inject `manualMutationAllowed` to reject direct manual controls while another
mode holds exclusive control. Rejection leaves the existing session and settings
unchanged and sets `manualMutationRejected` for the view. Automatic expiry,
condition stops, lease operations, and shutdown do not consult this callback.

Presentation requires a finite lease deadline. Explicit cleanup retries are:

- `retryReleaseLease(_:)` for pending assertion IDs associated with a token.
- `hasPendingLeaseCleanup(owner:)` and `retryPendingLeaseCleanup(owner:)` for
  cleanup failures, including an acquisition that threw before returning a token.

A retry touches only the specified owner's pending IDs. It does not stop live
requests. Other unresolved cleanup failures keep the service faulted. Retrying
is an explicit caller action; there is no automatic retry loop.

## Verification limits

Injected process, battery, observer, assertion, and view fixtures run without
launching installed Semper or changing system settings. Physical app termination,
AC transitions, VoiceOver, popup focus, sleep, wake, and signed distribution need
separate checks on supported Macs. Offscreen view rendering is not evidence that
those physical checks passed.
