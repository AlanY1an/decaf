# Real interaction recording

`../decaf-live-demo.mp4` and its GIF show a real Codex task, Decaf's native menu,
monthly usage, a monthly card, and a PNG export through the macOS save dialog.
The 16-second edit removes pauses between actions; retained footage runs at normal
speed. The monthly usage history and profile are **example data**.

The harness builds the repository's unchanged application views and real
`CompositionRoot`, including its power assertion and activity detector. It has
its own bundle ID, temporary Decaf data directory and fresh settings suite. It
does not install integrations or load the user's existing usage ledger. The
Codex process uses an existing CLI login and a newly created demo session; only
that session's rollout is admitted to the detector. The stage displays actual
CLI command and response events, rather than a full terminal emulator.

Codex detection is approximate. The menu can remain in its working state after
the command exits because recent file activity has a grace window. This recording
demonstrates activity detection, not an assertion of immediate sleep on completion.

## Reproduce

Requires Xcode/Swift, an already authenticated agent CLI, and `ffmpeg`. The
ScreenCaptureKit recorder additionally requires macOS 15+ and Screen Recording
permission. The app itself still targets macOS 14.

1. Run `./docs/assets/live-demo/build.sh` from the repository root.
2. Create a fresh throwaway Codex session in a temporary directory. Set
   `DECAF_DEMO_DIRECTORY` to that directory, `DECAF_DEMO_CODEX` to the CLI
   executable, `DECAF_DEMO_CODEX_SESSION` to its session ID, and
   `DECAF_DEMO_CODEX_LOG` to its newly created rollout file. Launch
   `docs/assets/live-demo/.build/Decaf Demo.app/Contents/MacOS/DecafLiveDemo`
   with these environment variables. Do not use an unrelated personal session.
3. Build the recorder with
   `swiftc -parse-as-library docs/assets/live-demo/record.swift -o /tmp/decaf-recorder`.
   Bring the demo forward, close unrelated Apple application windows, then run
   `/tmp/decaf-recorder /tmp/decaf-raw.mp4 /tmp/decaf-recording.stop`.
   The stop path must not exist when recording starts. Creating it ends capture.
4. Click **Run agent**, inspect the native menu, open **Monthly** usage, open
   **Your brew**, make a monthly card, and save its PNG. Record each completed
   action's Unix timestamp in a JSONL file using the six event names in `edit.py`.
   The recorder prints its starting timestamp. Actual CLI calls can consume usage.
5. Run `python3 docs/assets/live-demo/edit.py RAW ACTIONS START OUTPUT.mp4`.
   Inspect the final video before sharing, then quit the demo to release its
   power assertion and remove its temporary settings suite.

The supplied capture framing was verified on a 1920 × 1080 display: the recorder
excludes the bottom 85 pixels and the editor crops the top 30-pixel system status
strip. Adjust those dimensions for another display. The raw capture can include
unrelated menu-bar items or Apple system windows; only the reviewed, cropped edit
is intended for publication. Raw footage, session paths and action logs stay out
of the repository.

The separate `../decaf-walkthrough.*` assets are an earlier staged animation.
The README now embeds this live recording.
