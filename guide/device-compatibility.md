# Device Compatibility

This table records behavior observed on a specific Semper commit and test
setup. A passed result is evidence for that setup only. It is not a guarantee
for every device with the same transport or device class.

## Status key

- **Passed:** the expected state change and audio-route lifecycle completed.
- **Failed:** the result did not match the expected behavior.
- **Unsupported:** the device or transport cannot perform that check.
- **Not tested:** the check was outside that test run.

## Observed results

### Built-in laptop speakers

| Field | Result |
| --- | --- |
| Semper commit | [`910a9c29503cc7e7fa596dfe38975bd606ba204e`](https://github.com/niharnm/Semper/commit/910a9c29503cc7e7fa596dfe38975bd606ba204e) |
| macOS | 27.0 (26A5388g) |
| Mac architecture | Apple silicon, arm64 |
| Transport | Built-in |
| Generic device class | Laptop speakers |
| Per-app volume | Passed |
| Per-app mute | Passed |
| Routing | Passed |
| Disconnect and reconnect | Unsupported, the built-in output is not removable |
| Relaunch | Passed |

Native Core Audio controlled the output device. Semper's process tap handled
per-app gain and mute. With an isolated settings profile, a running app was
set to 40 percent, muted, assigned to the built-in output, and retained all
three settings after Semper relaunched. Redacted logs confirmed permission,
tap activation, the saved route, the saved gain, and the saved mute. Acoustic
quality was not judged in this run.

The built-in output above exposes native Core Audio volume control. Semper's
per-app volume and mute still use its software process tap. A device that does
not expose reliable hardware control can instead use Semper's **Software
volume** fallback, which applies output-device gain in the tap.

## Add a result

1. Build and test one exact Semper commit on a supported macOS version.
2. Use a generic device class and transport. Remove personal device names,
   usernames, file paths, and unrelated process data from notes and logs.
3. Exercise per-app volume, mute and unmute, an explicit output route, Semper
   relaunch, and disconnect and reconnect when the hardware supports it.
4. Mark every result **Passed**, **Failed**, **Unsupported**, or **Not tested**.
5. State whether the device used native hardware control or Semper's software
   volume fallback. Describe any check that observed only control state rather
   than acoustic output.
6. Add one row in a focused pull request and include the same test setup and
   expected versus actual results in the pull-request description.
