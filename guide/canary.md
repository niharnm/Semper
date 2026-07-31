# Canary testing

Canary builds let testers run a signed release candidate before it is approved
for Stable. They are expected to be signed and notarized, but they may contain
regressions.

## Join or leave Canary

1. Download an approved Canary prerelease from
   [GitHub Releases](https://github.com/niharnm/Semper/releases?q=canary).
2. Open Semper Settings, then Updates.
3. Select **Canary** and click **Check Now**.

To leave, select **Stable**. A later stable release will replace an installed
Canary when its build number is newer.

When reporting a problem, include the Semper version, macOS version, audio
device, and the shortest sequence that reproduces it.

## Prepare a candidate

The `Build Release Candidate` workflow has two paths:

- A `vMAJOR.MINOR.PATCH` tag prepares a Stable candidate.
- A manual run from the default branch prepares a Canary candidate for the
  supplied base version.

The requested version must match the `MARKETING_VERSION` committed to the
project. The workflow first runs release-script checks, website checks, the
macOS test suite, and an unsigned Release build. No release credentials are
available to that job.

After the checks pass, the `production-release` GitHub environment gates the
credentialed packaging job. Configure required reviewers on that environment
before enabling the workflow.

The packaging job:

1. imports the Developer ID certificate into a temporary keychain;
2. archives and exports the app, then checks its certificate authority, Team
   ID, hardened runtime, secure timestamp, and nested signatures;
3. notarizes and staples the app, then runs Gatekeeper assessment;
4. creates a versioned DMG, signs it, notarizes it separately, staples it, and
   runs a second Gatekeeper assessment;
5. writes and verifies a SHA-256 checksum;
6. generates a locally staged Sparkle appcast with an Ed25519 signature;
7. uploads notarization reports as a retained Actions artifact; and
8. creates a draft GitHub release containing the DMG, checksum, and uniquely
   named appcast candidate.

The workflow does not modify the `update-feed` branch and does not publish the
draft. Those are separate review decisions.

## Required configuration

Define these secrets on the protected `production-release` environment:

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_ID_PASSWORD`
- `APPLE_TEAM_ID`
- `CERT_IDENTITY`
- `KEYCHAIN_PASSWORD`
- `SPARKLE_PRIVATE_ED_KEY`

`APPLE_ID_PASSWORD` must be an app-specific password. `CERT_IDENTITY` must
exactly match the imported Developer ID Application identity. The Sparkle
private key must match the public key embedded by
[automatic-updates PR #32](https://github.com/niharnm/Semper/pull/32).
Until that dependency lands, the workflow also accepts
`SPARKLE_PUBLIC_ED_KEY` for builds whose Info.plist still contains the build
setting placeholder.

## Review and publication

Before publishing a Canary or Stable draft:

1. Download all three draft assets through the authenticated GitHub UI.
2. Run `shasum -a 256 -c <checksum-file>` beside the DMG.
3. Mount the DMG, drag Semper to Applications, and launch it on a separate
   macOS account or test Mac without Xcode.
4. Confirm Gatekeeper allows the offline first launch.
5. Test permissions, per-app volume, routing, mute, sleep and wake, device
   reconnect, and update settings with real audio devices.
6. Check the retained app and DMG notarization reports in the workflow run.
7. Inspect the staged appcast and confirm its enclosure names the versioned
   DMG, includes `sparkle:edSignature`, and uses `canary` only for Canary.
8. Publish the GitHub draft. Keep Canary marked as a prerelease.
9. In a separately reviewed update-feed change, replace `appcast.xml` with the
   staged appcast only after its GitHub release is public.
10. Confirm the public feed downloads the exact checksum-verified DMG.

Never replace a release asset or edit a signed appcast item in place. Publish a
higher version for every correction.

## Recovery and rollback drill

Run this drill before the first Stable publication and after any workflow or
Sparkle-key change:

1. Save the current `update-feed/appcast.xml` and its commit SHA as the
   last-known-good feed.
2. Prepare a Canary draft and complete the review above without modifying the
   feed.
3. On a test-only feed branch, add the staged appcast and confirm an older test
   installation detects the Canary, verifies its signature, downloads it, and
   relaunches successfully.
4. Restore the saved appcast on that test branch and confirm the bad candidate
   is no longer offered.
5. Record the workflow run, release tag, appcast commit, test Mac version, and
   result in the release review.

If a draft fails, leave it unpublished and prepare a higher version. If a
public release fails, immediately restore the last-known-good appcast content
through a reviewed update-feed change. Leave the failed GitHub release and its
assets intact for audit, mark it as withdrawn in its notes, and ship the fix as
a higher version. Sparkle does not downgrade existing installations, so the
replacement build number must be higher than the failed build.
