# Real-time audio safety

Semper's audio engine crosses two execution domains. Code that is safe in the
menu-bar app may cause dropouts, deadlocks, or crashes when it runs in the Core
Audio HAL callback.

Read this guide before changing `ProcessTapController`, a DSP processor,
callback state, crossfades, output gating, or tap resources.

## Execution domains

### Main actor

The `@MainActor` side owns setup, teardown, routing state, device changes,
processor replacement, and SwiftUI-visible state. It may use normal Swift and
Foundation APIs as long as it does not block the UI unnecessarily.

Key entry points include:

- `ProcessTapController.activate()` and `invalidate()`;
- device and tap switching;
- `AudioEngine` state coordination;
- allocation and preparation of EQ, AutoEQ, and loudness processors.

### HAL I/O callback

The nonisolated callback processes an audio buffer under a hard time limit. It
may run concurrently with main-actor state changes.

Inside the callback, do not:

- allocate or free memory;
- acquire a lock or wait on a semaphore;
- log, print, or build an interpolated diagnostic string;
- call Objective-C, AppKit, Foundation, file, or network APIs;
- use `async`, `await`, a task, actor isolation, or a dispatch hop;
- perform blocking system calls;
- resize a collection or create a closure that captures new state.

Callback work must be bounded. Use scalar arithmetic, preallocated processor
state, fixed-size buffers, and in-place DSP operations.

## Shared state

`ProcessTapController` uses a small set of `nonisolated(unsafe)` scalar values
that the main actor writes and the callback reads. Treat each new shared value
as a safety decision, not a convenience.

Before adding shared callback state, explain:

1. which execution domain writes it;
2. which execution domain reads it;
3. why its read and write behavior is safe on supported Apple hardware;
4. how its lifetime outlasts every callback that can access it;
5. what happens during tap replacement, crossfade, cancellation, and teardown.

Do not pass mutable arrays, reference-counted objects, or replaceable processor
instances across the boundary without following an existing reviewed lifetime
pattern.

## Resource lifecycle

Tap and aggregate-device teardown order is part of correct audio behavior.
Follow `TapResources` and existing `ProcessTapController` paths. A device switch
can temporarily leave primary and secondary callbacks active at the same time,
so processors and callback identifiers must not be shared accidentally.

When replacing DSP state, confirm that an active callback cannot observe freed
storage. A unit test can verify state transitions, but it cannot prove callback
lifetime safety by itself.

## Pull-request checklist

For a change that touches the callback or callback-owned state, include all of
the following in the pull request:

- the old and new execution-domain boundary;
- every new allocation, lock, log, reference type, or lifetime transition;
- automated tests for pure math and state machines;
- manual testing with the macOS version, audio apps, and device transports;
- results for mute, unmute, route change, disconnect, reconnect, and relaunch
  when those paths are affected;
- confirmation that the callback contains no new blocking or unbounded work.

If the safety argument is unclear, open a discussion before writing the code.

## Useful source files

- `Semper/Audio/Engine/ProcessTapController.swift`
- `Semper/Audio/Engine/ProcessTapControlling.swift`
- `Semper/Audio/Engine/TapResources.swift`
- `Semper/Audio/Engine/CrossfadeState.swift`
- `Semper/Audio/EQ/BiquadProcessor.swift`
- `Semper/Audio/Engine/SoftLimiter.swift`
- `Semper/Audio/Loudness/LoudnessEqualizer.swift`

Keep comments close to the code when a safety rule depends on a specific
lifetime or teardown sequence. Keep the broader rule here so contributors have
one public reference.
