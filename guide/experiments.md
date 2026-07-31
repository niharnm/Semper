# Experiments

Semper has a dependency-free experiment layer for the static website and the
macOS app. It assigns a local subject to a fixed variant and emits exposure and
outcome events inside the current process.

No experiment event is sent over the network. The repository does not include
an event collector, so the current code can verify assignment and event
behavior but cannot aggregate results or select a winner across visitors or
installations.

## Assignment

Each surface creates its own random UUID. The UUID and the chosen variants are
stored in browser storage on the website and `UserDefaults` in the app.

Both implementations calculate a 32-bit FNV-1a hash of:

```text
EXPERIMENT_ID:SUBJECT_ID
```

The unsigned hash modulo 10,000 maps buckets 0 through 4,999 to `control` and
5,000 through 9,999 to `treatment`. The resolved variant is stored under the
versioned experiment ID, so later allocation changes do not move an existing
subject.

## Active experiments

| Surface | Experiment | Control | Treatment | Outcome |
| --- | --- | --- | --- | --- |
| Website | `website.hero-repository-cta-copy.v1` | `View the source` | `Open Semper on GitHub` | `hero_repository_clicked` |
| macOS | `macos.popup-empty-state-guidance.v1` | `No apps playing audio` | Guided empty-state copy | `first_audio_app_detected`, `first_app_volume_changed` |

The website variants use the same destination. The app treatment changes only
the empty-state text.

## Local event contract

Both surfaces emit the same fields:

```json
{
  "schema_version": 1,
  "event_id": "UUID",
  "event_name": "experiment_exposure",
  "occurred_at": "RFC3339 timestamp",
  "surface": "website",
  "experiment_id": "website.hero-repository-cta-copy.v1",
  "variant": "control",
  "assignment_source": "bucket",
  "subject_id": "surface-local UUID",
  "session_id": "UUID",
  "collection_mode": "local",
  "metric_key": null
}
```

The website dispatches a `semper:experiment` `CustomEvent` on `window`. The app
posts `Notification.Name.semperExperiment` through `NotificationCenter`.
Exposure and each declared outcome emit at most once per page or app session.
Outcomes are ignored until the matching exposure has occurred.

The payload does not include URLs, query values, referrers, app names, bundle
identifiers, audio, volume values, device data, hardware identifiers, or
permission state.

## Force a variant

Use `semper_ab` on the website:

```text
http://localhost:4173/website/?semper_ab=website.hero-repository-cta-copy.v1:treatment
```

Use the app preferences domain on macOS:

```bash
defaults write systems.semper.Semper \
  "SemperABOverride.macos.popup-empty-state-guidance.v1" treatment
```

Remove the app override to return to the stored assignment:

```bash
defaults delete systems.semper.Semper \
  "SemperABOverride.macos.popup-empty-state-guidance.v1"
```

Overrides are marked `debug_override` in local events and do not replace the
stored assignment.

## Checks

From the repository root:

```bash
node --test website/ab-testing.test.js

xcodebuild \
  -project Semper.xcodeproj \
  -scheme Semper \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:SemperTests/ExperimentManagerTests
```

Before enabling remote collection, choose and document the collector, consent
flow, retention period, deletion path, access rules, primary metric, sample
size, and stopping rule. Update the privacy policy before any event leaves the
browser or app.
