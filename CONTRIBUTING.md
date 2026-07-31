# Contributing to Semper

Semper welcomes bug fixes, tests, documentation corrections, and focused audio features.

## Local setup

1. Fork the repository and clone your fork.
2. Open `Semper.xcodeproj`.
3. Select the `Semper` scheme.
4. Build once, then grant only the macOS permissions needed for the behavior you are testing.

Run unit tests:

```bash
xcodebuild test \
  -project Semper.xcodeproj \
  -scheme Semper \
  -configuration Debug \
  -skip-testing:SemperUITests \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

## Pull requests

- Keep each pull request focused.
- Add or update tests when behavior changes.
- Explain any audio-device assumptions and name the hardware used for manual testing.
- Do not add signing certificates, Sparkle private keys, Apple credentials, or generated build products.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Authorship and licensing

- Contributions are accepted under `GPL-3.0-only`.
- You retain copyright in your original contribution. Semper does not require copyright assignment.
- Use accurate commit authorship. Do not remove or rewrite another contributor’s credit.
- Disclose the source and license of copied or adapted material. Only submit material that can legally be distributed under GPLv3.
- Preserve `LICENSE`, `NOTICE.md`, `AUTHORS.md`, and all applicable copyright notices.

By submitting a contribution, you certify that you have the right to submit it under GPLv3.
