# Isolated updater test

This harness compiles `AppUpdater.swift` and `UpdateGuideView.swift` from production
with a minimal native window. It has a separate bundle ID
`io.github.alany1an.decaf.updater-smoke`, no Decaf engine, and no log readers.
Build 41 stores a test preference; build 42 must preserve it after installation.

Resolve packages with `xcodebuild -resolvePackageDependencies -scheme Decaf
-clonedSourcePackagesDirPath build/SourcePackages`, then run from the repo root:

```sh
DECAF_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' docs/assets/updater-smoke/prepare.sh
python3 -m http.server 8894 --bind 127.0.0.1 --directory build/updater-smoke/feed
```

Open `build/updater-smoke/install/DecafUpdaterSmoke.app`. Choose Check for Updates,
Install Update, then Install and Relaunch. Confirm build 42 and the saved
`kept-through-update` preference. Check again for the already-current response.

For failure cases, stop the server to test an unreachable feed; temporarily
change the feed or archive bytes to test signature rejection. Restore the exact
signed files afterward. Do not run the preparation script while the test app is
open. It replaces only the two test app bundles under `build/updater-smoke`.

HTTP transport relaxation exists only in this test app. Production uses HTTPS
with signed feeds and archives. No production bundle or update feed is published.
This local test does not replace a notarized clean-Mac release smoke test.
