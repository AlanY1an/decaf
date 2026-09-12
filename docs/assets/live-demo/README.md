# Real interaction recording

`../decaf-live-demo.mp4` and its GIF show a real Codex task, the **Decaf 0.3.3**
Home status changing from idle to working, and Monthly switching between combined
usage and Codex. The 16-second edit removes pauses between actions; retained
footage runs at normal speed. The usage history and profile are **example data**.

The harness compiles the repository's unchanged SwiftUI views and real
`CompositionRoot`, including its power assertion and activity detector. It has
its own bundle ID, temporary Decaf directory and fresh settings suite. It does
not install integrations or load the user's existing usage ledger. The window
presenter alone is adapted for recording size/placement and to inject an isolated
session catalog; no personal Claude account or migration state is loaded.

The Codex process uses an existing CLI login and a newly created demo session;
only that session's rollout is admitted to the detector. The stage displays
actual CLI command and response events, rather than a full terminal emulator.
Starting a real agent can consume usage. Simply opening the harness and clicking
its statistics does not start an agent.

Codex detection is approximate. Its working state can remain after the command
exits because recent file activity has a grace window. This recording demonstrates
activity detection, not immediate sleep on completion. The visible totals are
sample local usage, not the cost of the six-second task.

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
   with these environment variables. Never use a personal session for recording.
3. Click **Open usage** once to position Home. Build the recorder with
   `swiftc -parse-as-library docs/assets/live-demo/record.swift -o /tmp/decaf-recorder`.
   Bring the demo forward, then run
   `/tmp/decaf-recorder /tmp/decaf-raw.mp4 /tmp/decaf-recording.stop`.
   The stop path must not exist. Creating it ends capture. The recorder prints
   its starting Unix timestamp and stops automatically after three minutes.
4. In the stage, click **Run agent**, then **Open usage**. Observe the real
   idle → working change, select **Monthly**, click **Codex**, then click it
   again to restore both sources. Log completed actions as JSONL objects with
   `event` and Unix `t` fields. Use the five event names in `edit.py`.
   `working_status_shown` can use the first working timestamp in the harness's
   `state-trace.txt`; verify the transition appears in the resulting footage.
5. Run `python3 docs/assets/live-demo/edit.py RAW ACTIONS START OUTPUT.mp4`.
   Inspect the complete edit before sharing, then quit the demo to release its
   power assertion and remove the temporary settings suite.

The supplied capture frames a 1500 × 940 stage at the top right of the display.
The recorder includes only this app's windows and the menu area above the stage;
other apps, desktop and Dock are excluded. The editor crops the top 30 pixels
of the system status strip. Adapt the framing for smaller displays. Inspect for
unrelated status items and private information before publication. Raw footage,
CLI session paths and action logs stay out of the repository.

The separate `../decaf-walkthrough.*` assets are an earlier staged animation.
The README embeds the live recording above.
