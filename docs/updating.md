# In-app updates (0.3.1 and later)

Choose **Check for Updates…** from the cup menu, the application menu, or
**Settings → General**. Sparkle shows the available version and release notes.
Choose **Install Update** to download and verify it, then **Install and Relaunch**
when ready. Cancellation, download errors, read-only installs and invalid
signatures are handled by Sparkle. Manual DMG/Homebrew instructions remain in
**Update options…** and **Updates…** in the cup menu.

0.3.0 and earlier have no installer. Users must install 0.3.1 once manually;
subsequent releases can be installed in-app. When mixing Homebrew and in-app
updates, Homebrew's cask receipt may still list the earlier version. Users who
want Homebrew to own version tracking can continue using `brew upgrade --cask`.

Local **Debug** builds disable the public updater and explain this in Update
options. This avoids checking a feed that may not exist before the first release,
and prevents replacing a development app with a public release. To preview a real
update, use the isolated harness below; Release builds keep the normal updater.

## Network and signatures

Detection, token logs and profiles stay local. Only an explicit update check or
download contacts GitHub and its asset CDN. Like any HTTP download, these servers
receive connection information, including the IP address and updater user agent;
no token totals, conversation text or system-profile payload is sent. Background
checks/downloads, JavaScript in release notes and system profiling are disabled.

- Feed: `https://github.com/AlanY1an/decaf/releases/latest/download/appcast.xml`.
- Packages: version-specific GitHub release assets.
- Framework: Sparkle **2.9.6**, pinned with its upstream binary checksum.
- The app requires signed feeds and archive verification before extraction.
- Ed25519 account: `io.github.alany1an.decaf` in the maintainer's login Keychain.
  `generate_keys --account io.github.alany1an.decaf -p` prints the public key.
  Never export the private key into the repository or logs, or regenerate a
  shipped key as a routine fix. Keep a secure offline Keychain backup.
- Debug alone disables library validation for ad-hoc local builds. Release
  retains hardened runtime and library validation; export signs Sparkle's helpers.

## Preparing a release

1. Increment `MARKETING_VERSION` and the monotonically increasing
   `CURRENT_PROJECT_VERSION` in `project.yml`. Add `docs/releases/<version>.md`
   (or set `DECAF_RELEASE_NOTES` to a local notes file), update the changelog and
   run the required checks.
2. Run `Scripts/release.sh <version>` from a clean committed checkout. This
   generates `appcast.xml` only after signing, notarization and stapling finish.
   It verifies the feed signature, archive signature, version, URL and size.
3. Create a **draft** GitHub release containing the DMG, `.dmg.sha256` and
   `appcast.xml`. Check that all three uploads completed, then publish it as Latest.
   This switches the stable feed and its download together. Do not publish a
   release without its feed once 0.3.1 users depend on this endpoint.
4. Update the Homebrew cask, verify the public download and feed, and retain the
   archive/dSYMs. Never edit a signed feed in place; regenerate and verify it.

The scripts resolve tools from `build/SourcePackages/artifacts/sparkle/Sparkle/bin`.
`DECAF_SPARKLE_BIN` can override this path. The default Keychain account can be
overridden with `DECAF_SPARKLE_ACCOUNT`; its public key must still match the app.
Dry runs do not notarize, generate a distributable feed or publish anything.

## Local verification

`AppUpdaterTests` cover inert initialization, duplicate-check suppression,
availability changes, startup failure and retry. The app can be built/tested
without signing credentials. The screenshot harness remains inert.

For an actual installation/relaunch test without touching Decaf or its logs, use
[the isolated updater harness](assets/updater-smoke/README.md). It compiles the
production updater and update UI with a distinct bundle ID, two signed test apps
and a localhost-only feed. Test successful updates, unchanged preferences,
already-current responses, unreachable feeds and tampered signatures.

Based on [Sparkle's setup](https://sparkle-project.org/documentation/) and
[configuration reference](https://sparkle-project.org/documentation/customization/).
