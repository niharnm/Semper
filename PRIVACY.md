# Semper Privacy Policy

Effective date: July 31, 2026

Last updated: July 31, 2026

Semper is an open-source macOS audio controller. This policy explains what the Semper app, the website at [semper.systems](https://semper.systems), and the project maintainers handle.

## The short version

- Semper does not require an account.
- Audio is processed on your Mac. Semper does not record captured audio to a file, upload it, or send it to the project maintainers.
- App, device, routing, volume, EQ, and shortcut settings are stored locally on your Mac.
- Semper makes network requests only for features that need them, including fetching AutoEQ data from GitHub and checking for app updates when an update feed is configured and you request or allow a check.
- The website has no Semper-controlled analytics, advertising, account system, contact form, or marketing cookies. Its host, Vercel, still receives ordinary web request data.

## 1. Scope

This policy applies to:

- The Semper macOS app.
- The website at [semper.systems](https://semper.systems).
- Information you send directly to Semper maintainers about the project.

It does not govern GitHub, Vercel, Apple, the AutoEq project, or other third-party services. Their own policies apply when you use them.

## 2. Information handled on your Mac

Semper handles the following information locally to provide its audio controls:

- **Audio content.** Semper uses Core Audio process taps to process app audio in memory for volume, routing, EQ, loudness, and limiting. It does not intentionally save that audio to disk or transmit it to Semper maintainers.
- **Running app information.** This can include process identifiers, app names, bundle identifiers, icons, current audio activity, and the settings you assign to an app.
- **Audio and Bluetooth device information.** This can include device names, device identifiers, transport type, capabilities, connection state, volume, mute state, and routing choices. Semper reads paired Bluetooth audio devices so you can connect them from the app.
- **Preferences.** This includes per-app volume, mute, routing, boost, and EQ settings; device preferences; AutoEQ selections; imported EQ profiles; display choices; and keyboard shortcuts.
- **Diagnostics.** Semper writes operational messages and errors to the macOS unified logging system. These logs remain under macOS control unless you choose to share them.

Semper stores its main settings and AutoEQ cache under `~/Library/Application Support/Semper`. macOS and included frameworks may also store preferences, such as shortcut and update settings, in the app's preferences domain.

## 3. macOS permissions

Semper may ask for:

- **Screen & System Audio Recording.** Required for the Core Audio process taps used for per-app audio control.
- **Microphone.** Used when Semper works with input-capable audio devices and input monitoring. Semper does not intentionally save or transmit microphone audio.
- **Bluetooth.** Used to list and connect paired Bluetooth audio devices.
- **Accessibility.** Optional. Used to intercept the system media keys for Semper's volume controls.

You can grant, review, or revoke these permissions in macOS System Settings under Privacy & Security. Features that depend on a revoked permission will stop working.

## 4. Network requests and third parties

### AutoEQ

When you open or use AutoEQ features, Semper may download the AutoEq catalog and selected headphone profiles from `raw.githubusercontent.com`. Semper caches this data locally for offline use. GitHub receives the ordinary information associated with a network request, such as your IP address, request time, and client information.

### Software updates

Semper includes the Sparkle update framework. The updater starts only when a release is configured with a feed URL and public signing key. If you manually check for updates or allow automatic checks, Sparkle contacts the configured update feed and may download release information or an update. The update host receives ordinary request data. Any optional system-profile sharing presented by Sparkle is controlled by the choice shown to you.

### Website hosting

The Semper website is hosted by Vercel. Vercel may process website request information, including IP address, approximate location derived from IP, browser or system configuration, requested URL, timestamps, and security or performance data. See the [Vercel Privacy Notice](https://vercel.com/legal/privacy-notice).

### GitHub

The source repository, releases, issue tracker, pull requests, and AutoEQ downloads use GitHub. If you visit or contribute through GitHub, GitHub processes that activity under the [GitHub General Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). Repository contributions and public issues can include your profile, commit authorship, messages, and other information you choose to publish.

## 5. Cookies and analytics

The Semper website does not add analytics scripts, advertising trackers, account cookies, or marketing cookies. Vercel may still use data needed to deliver, protect, and operate the hosted site as described in its privacy notice.

## 6. Information you send to maintainers

If you contact a maintainer, open an issue, submit a pull request, or send a security report, the project may receive the information you provide, such as your name, GitHub profile, contact details, message, code, logs, or device details. Maintainers use it to respond, review contributions, address bugs or security concerns, and administer the project.

Do not include private audio, credentials, or other sensitive information in a public issue. Use the private reporting instructions in [SECURITY.md](SECURITY.md) for security matters.

## 7. Retention and your choices

- Local settings remain on your Mac until you reset them, replace them, or remove the app's data.
- AutoEQ downloads and imported profiles remain in the Semper Application Support folder until you remove them.
- To remove local Semper data, quit Semper and delete `~/Library/Application Support/Semper`. You can also remove Semper preferences through macOS. Revoking permissions is a separate step in Privacy & Security settings.
- Public GitHub activity is retained and controlled through GitHub. Website request data is retained by Vercel under its policies.
- Information sent privately to maintainers is kept only as long as reasonably needed to respond, maintain project records, handle security concerns, or meet legal obligations.

Semper maintainers do not sell personal information or use it for targeted advertising.

## 8. Security

Semper is built in public so its behavior can be inspected. No software or storage method is completely secure. Keep macOS current, install Semper only from a source you trust, review requested permissions, and do not post sensitive information in public project spaces.

## 9. Children

Semper is a general-purpose developer project and is not directed to children. The project does not knowingly collect personal information from children.

## 10. Changes to this policy

This policy may change when Semper's features, hosting, or data practices change. The date at the top will be updated, and material changes will be noted in the repository.

## 11. Contact

For privacy questions or requests, contact the lead maintainer through a private contact method listed on [Nihar Manchikakapudi's GitHub profile](https://github.com/niharnm). Do not put sensitive personal information in a public issue.
