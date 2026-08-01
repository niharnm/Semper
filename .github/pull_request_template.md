## Summary

Describe the problem and the focused change. Include the behavior before and
after.

Fixes #

## Change type

- [ ] Bug fix
- [ ] Tests
- [ ] Documentation
- [ ] SwiftUI or accessibility
- [ ] Device compatibility
- [ ] Audio engine or DSP
- [ ] Website or project tooling

## Risk areas

List affected state, persistence, permissions, device routing, audio callbacks,
resource lifetimes, or output safety. Write `None` when none apply.

## Verification

List each automated command you ran and its result. Do not write only "CI".

```text
command: result
```

For audio behavior, include:

- macOS version and Semper commit;
- tested audio apps;
- device classes and transports;
- volume, mute, routing, disconnect, reconnect, and relaunch results when
  relevant.

## Real-time audio checklist

- [ ] This change does not touch a HAL callback or callback-owned state.
- [ ] Or, I read `guide/realtime-audio-safety.md` and documented the execution
      domains, lifetimes, and manual test matrix above.
- [ ] The callback contains no new allocation, lock, log, Objective-C or
      Foundation call, blocking work, actor hop, or unbounded loop.

## User-visible evidence

Add before and after screenshots for UI changes. Add privacy-safe reproduction
evidence for hardware behavior. Write `Not applicable` when there is no visible
change.

## Attribution and license

- [ ] I have the right to submit this work under `Apache-2.0`.
- [ ] I disclosed the source and license of copied or adapted material.
- [ ] I preserved existing authorship, copyright, and notice information.
- [ ] I added or updated tests when behavior changed.
- [ ] I kept unrelated refactoring and formatting out of this pull request.
- [ ] I followed the Code of Conduct.
