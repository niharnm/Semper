# Canary testing

Canary builds let testers run the newest release candidate before it is
promoted to Stable. They are signed and notarized, but they may contain
regressions.

## Join or leave Canary

1. Download a Canary prerelease from
   [GitHub Releases](https://github.com/niharnm/Semper/releases?q=canary).
2. Open Semper Settings, then Updates.
3. Select **Canary** and click **Check Now**.

To leave, select **Stable**. A later stable release will replace an installed
Canary when its build number is newer.

When reporting a problem, include the Semper version, macOS version, audio
device, and the shortest sequence that reproduces it.

## Publish a Canary

The `Build and Release` GitHub Actions workflow has two paths:

- A `vMAJOR.MINOR.PATCH` tag publishes a stable release.
- A manual run publishes a Canary prerelease for the supplied base version.

Both paths run the website smoke check and macOS test suite before building.
They then sign and notarize the DMG, create a GitHub release, generate a signed
Sparkle appcast entry, and publish the shared appcast to the `update-feed`
branch. Canary entries use Sparkle's `canary` channel. Stable entries use the
default channel.

The repository must define these Actions secrets:

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_ID_PASSWORD`
- `APPLE_TEAM_ID`
- `CERT_IDENTITY`
- `KEYCHAIN_PASSWORD`
- `SPARKLE_PRIVATE_ED_KEY`
- `SPARKLE_PUBLIC_ED_KEY`

The Sparkle keys must be a matching Ed25519 pair. Keep the private key only in
Actions secrets. The public key is written into release builds so Sparkle can
verify downloaded updates.

## Promotion checks

Before publishing Stable:

1. Install the newest Canary on a separate macOS account or test Mac.
2. Verify first launch, permissions, per-app volume, routing, mute, and update
   checks with real audio devices.
3. Confirm the Canary release is marked as a prerelease on GitHub.
4. Confirm the `update-feed` appcast contains a signed `canary` item.
5. Tag the approved commit with `vMAJOR.MINOR.PATCH`.

If the Canary is bad, remove its GitHub prerelease and publish a newer Canary.
Do not edit a signed appcast item or replace its DMG in place.
