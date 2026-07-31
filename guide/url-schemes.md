# URL Schemes

Control Semper from Terminal, shell scripts, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or any app that can open URLs. This makes it easy to automate volume changes, build keyboard shortcuts, or integrate Semper into your workflow.

## Actions

| Action | Format | Description |
|--------|--------|-------------|
| Set volume | `semper://set-volumes?app=BUNDLE_ID&volume=PERCENT` | Set per-app volume from 0 to 100 |
| Step volume | `semper://step-volume?app=BUNDLE_ID&direction=up` | Nudge volume up or down by ~5% |
| Set mute | `semper://set-mute?app=BUNDLE_ID&muted=true` | Mute or unmute an app |
| Toggle mute | `semper://toggle-mute?app=BUNDLE_ID` | Toggle mute state |
| Set device | `semper://set-device?app=BUNDLE_ID&device=DEVICE_UID` | Route an app to a specific output |
| Update | `semper://update` | Check for and install a Semper update |
| Reset | `semper://reset` | Reset all apps to 100% and unmuted |

## Examples

```bash
# Set Spotify to 50% volume
open "semper://set-volumes?app=com.spotify.client&volume=50"

# Set different volumes for different apps at once
open "semper://set-volumes?app=com.spotify.client&volume=80&app=com.hnc.Discord&volume=40"

# Mute multiple apps at once
open "semper://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"

# Step Discord volume down
open "semper://step-volume?app=com.hnc.Discord&direction=down"

# Route an app to a specific device
open "semper://set-device?app=com.spotify.client&device=YOUR_DEVICE_UID"

# Check for and install the latest Semper update
open "semper://update"

# Reset everything
open "semper://reset"
```

## Use Cases

**Meeting mode:** Mute everything except your video call app:

```bash
open "semper://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"
```

**Focus playlist:** Set music to a low background level and silence notifications:

```bash
open "semper://set-volumes?app=com.spotify.client&volume=30&app=com.apple.systemuiserver&volume=0"
```

**Gaming setup:** Set a game to full level and lower Discord:

```bash
open "semper://set-volumes?app=com.game.example&volume=100&app=com.hnc.Discord&volume=40"
```

These commands work in Terminal, shell scripts, Automator, Raycast script commands, macOS Shortcuts (using "Open URL"), and any other tool that can open URLs.

The URL interface controls per-app volume from 0 to 100. Device-aware master gain above 100 percent is controlled in Semper’s menu-bar interface.

## Finding Bundle IDs

App names shown in Semper map to bundle IDs. Common ones:

| App | Bundle ID |
|-----|-----------|
| Spotify | `com.spotify.client` |
| Apple Music | `com.apple.Music` |
| Chrome | `com.google.Chrome` |
| Safari | `com.apple.Safari` |
| Discord | `com.hnc.Discord` |
| Slack | `com.tinyspeck.slackmacgap` |
| Zoom | `us.zoom.xos` |
| Firefox | `org.mozilla.firefox` |
| Arc | `company.thebrowser.Browser` |

To find any app's bundle ID:

```bash
osascript -e 'id of app "App Name"'
```

## Finding Device UIDs

In Semper, click the pencil icon to enter edit mode, tap the **info button** on a device row to open the device inspector, then click the copy button next to the UID to put it on the clipboard.
