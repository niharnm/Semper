# App Shortcuts

Semper provides native actions in the macOS Shortcuts app. Running an action
opens Semper when needed, then reports whether the change was applied,
accepted for completion, unchanged, or rejected.

Available actions:

- Set App Volume
- Set App Mute
- Route App to Output
- Make App Follow Default Output
- Switch Default Output
- Start Call Mode
- End Call Mode
- Bypass Audio Processing
- Resume Audio Processing
- Undo Last Audio Change

Application parameters are stored by Semper's persistence identifier. Active
applications and inactive pinned applications are available. If two
applications have the same display name, Shortcuts shows each identifier below
the name.

Output parameters are stored by Core Audio device UID. A saved shortcut keeps
that UID if the device disconnects, but Semper rejects the action until the
selected output reconnects. It does not silently route to another device.

Existing `semper://` URLs and global keyboard shortcuts remain available and
continue to use the same audio command dispatcher.
