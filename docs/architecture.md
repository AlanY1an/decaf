# Architecture

How Decaf is put together, and why it is put together that way. This file
records **what the code does**; the design arguments, alternatives weighed and
review rulings behind it are working notes and are not part of the repository.

Every number here was read out of the source rather than copied from a plan.
Where a constant is cited its file is named, so a stale figure is one grep away
from being caught.

---

## The one rule

Decaf holds the Mac awake **while an agent is working**, and lets it sleep the
moment the agent is only waiting on you.

That distinction is the whole product. A tool call running for twenty minutes
is work. A prompt sitting unanswered on your screen is not — your Mac sleeping
does not lose it. Everything below exists to tell those two states apart
reliably enough that neither the false positive (a Mac that never sleeps) nor
the false negative (a Mac that sleeps mid-build) is common.

---

## Modules

The app is a thin SwiftUI shell over a Swift package. `Core/Package.swift`
declares six libraries and three executables.

| Module | Role |
|---|---|
| `DecafCore` | Power assertions, settings, app state, menu presentation. No knowledge of agents. |
| `AgentDetection` | Session state machine, the three detection layers, the hook socket server. |
| `HookWire` | The wire types shared between the app and the helper binaries. Deliberately tiny — it is the only thing `decaf-bridge` may import. |
| `TranscriptSupport` | Transcript file location and tailing, shared by detection and usage metering. |
| `UsageMetering` | Token ledger, block and window inference, API-equivalent pricing, quota state. |
| `DecafComposition` | `CompositionRoot` — wires the above into a running app. The only place that knows about all of them. |
| `decaf-bridge` | Helper executable. Claude Code runs it as a hook; it writes one frame to a socket and exits. |
| `decaf-statusline` | Helper executable for the statusLine channel, with passthrough to whatever statusline you already had. |
| `decaf-smoke` | Test-only harness. |

The app target adds `App/` — the menu, the settings window, onboarding, and the
menu bar icon renderer.

---

## Power assertions

`PowerStateEngine` (DecafCore) owns every assertion. It keeps a dictionary of
`HoldSourceID -> HoldRequest` and reconciles the real IOKit state against it,
idempotently, on a wall clock. Sources are things like "an agent is working",
"you chose Keep for 2 hours", "a schedule window is open"; they merge, and the
assertion is released only when the last one goes.

Two properties worth knowing:

- **Renewal is create-then-release**, at half the assertion's timeout.
  `IOPMAssertionSetProperty` is never used to extend one.
- **A 30-minute `TimeoutActionRelease` is set on every assertion.** If Decaf
  crashes or wedges, powerd drops the hold rather than leaving a Mac awake
  forever. Assertions are also reclaimed by the system when the process exits.

`kIOPMAssertPreventUserIdleSystemSleep` works on battery as well as on mains.
No assertion type prevents lid-close sleep — that is a kernel behaviour, not a
policy, and it is why clamshell support is a separate, unshipped phase.

---

## Detecting that an agent is working

Three layers, most precise first. They are not alternatives; the lower ones
cover the gaps in the higher ones.

### L1 — hooks (turn-precise)

Claude Code can run a command on lifecycle events. Decaf installs
`decaf-bridge` into `~/.claude/settings.json` (with your explicit consent, and
by deep-merging so your own hooks survive) on `SessionStart`,
`UserPromptSubmit`, `Notification`, `Stop`, `StopFailure`, `SessionEnd`, and
`PostToolUse`.

The bridge's contract is severe, because a hook that misbehaves breaks Claude
Code itself: read stdin, parse five head fields, connect a UNIX socket, write
one JSON line, exit 0. **Any** failure exits 0 silently — no stdout (which
would be injected into your conversation as context), no stderr, never a
non-zero code. A watchdog thread enforces the whole thing inside 90 ms
(`Core/Sources/decaf-bridge/main.swift`).

`SessionRegistry` turns those events into per-session state. Two rules are less
obvious than the rest:

- A permission prompt moves the session to *awaiting permission* and starts a
  grace period of `permissionGracePeriod = 300` seconds
  (`AgentDetection/DetectionCoordinator.swift:59`).
- Claude Code emits **nothing** when you click "allow". So the proof of
  approval is the tool's own completion: a `PostToolUse` on a session marked as
  awaiting approval puts it straight back to working. A tool cannot finish
  while its own dialog is unanswered, which is what makes that inference sound.

### L2 — file activity (zero-config fallback)

If hooks are not installed, an FSEvents stream on `~/.claude` infers activity
from transcript writes, with an idle window of `l2IdleWindow = 300` seconds
(`DetectionCoordinator.swift:68`). Coarser than L1 by design: it cannot see a
turn boundary, only that something is still being written.

### L3 — CPU sampling (a witness, never a trigger)

`proc_pid_rusage` sampling never starts a hold. It exists only to contradict
one: the stuck-session detector needs four independent witnesses to agree
before it downgrades a session that has looked "working" for
`stuckThreshold = 2` hours (`AgentDetection/StuckSessionDetector.swift:61`).

### Long silent tool calls

A twenty-minute build writes nothing and prints nothing, but the process is
live. All four witnesses must agree a working record has gone quiet before the
hold is dropped, which is what carries a session through it.

One gap is real and is stated rather than buried: between the five-minute
permission window expiring and an approved tool's completion arriving, a very
long approved tool is unprotected. Lengthening the window is not a fix — the
same window is how long an *unanswered* prompt would hold your Mac awake.

### Wait signals

When an agent declares it is going to wait — a scheduled wake-up, a monitor
with a timeout, a cron expression — that declaration appears in the transcript
as a tool-use record. Decaf reads it and holds until the stated instant, so a
self-paced loop with a seven-minute gap does not lose the machine at minute
five.

The parser reads exactly five fields and is pinned by a test that fails if a
sixth is ever added. Conversation content — prompts, reasons — is never read,
stored or logged.

Guard rails, in order: the extension is **capped at one hour**, so a parse bug
costs an hour of sleep rather than a night; **every safety gate still applies**,
and a declared wait is never an exemption; and **unparseable input is silently
ignored**, falling back to the ordinary grace period, because these are
upstream-internal tool names that can vanish in any release.

#### The measurement this came from

Reasoning said a loop would survive. Measurement said otherwise. A real `/loop`
with a 420-second gap, no hooks installed, `pmset -g assertions` sampled every
20 seconds by an independent process:

```
22:54:55 – 23:00:56   held       (19 samples)
23:01:16 – 23:02:56   NOT held   ← 1 min 40 s with sleep allowed
23:03:08              held again (the next iteration woke it)
```

The last transcript write was around 22:56, and 300 seconds later is
`l2IdleWindow` expiring — so the release was the mechanism working exactly as
designed, and wrong.

The answer was already on disk. At **22:55:47**, five and a half minutes before
the release, the agent had written `ScheduleWakeup { delaySeconds: 420 }` into
its own transcript. It had said when it would be back, and the app discarded it.

One methodological note worth keeping: the first attempt at this measurement
sampled once per loop iteration, which samples exactly when activity has just
happened and therefore could never observe the gap. The instrument must not be
synchronised with the thing it measures.

---

## The read surfaces, in full

Every place Decaf reads someone else's file is a closed Swift enum with a test
pinning its cases, so widening one is a failing build rather than something a
review has to catch.

**Hook payloads** (`decaf-bridge`): `session_id`, `hook_event_name`, `cwd`, the
matcher tag from argv, and the resolved pid. Five fields, nothing else.

**Transcripts, for detection**: `sessionId`, `timestamp`, `isSidechain`, record
and block `type`, tool `name`, and — only for the four scheduling tools —
`delaySeconds`, `timeout_ms`, `stop`, `cron`, `id`.

**Transcripts, for usage**: from assistant records only — `sessionId`,
`timestamp`, `isSidechain`, `requestId`, `message.id`, `model`, and the four
`usage` counters.

**Status JSON** (`decaf-statusline`): `session_id`, `model.id`,
`model.display_name`, and `rate_limits.five_hour` / `.seven_day` →
`used_percentage`, `resets_at`.

One exception, deliberately narrow: to match a cancelled cron job to the wait
it created, the single tool-result line following a `CronCreate` is read, and
only a hex job id matched by an anchored regex is kept. Every other tool result
is skipped, because tool results carry arbitrary output.

Diagnostics are an enum of cases such as `lineNotJSON` and `unknownTool` — a
log line is structurally incapable of carrying a transcript excerpt.

---

## The socket

One UNIX domain socket under the app's support directory. `HookSocketServer`
listens; the helper binaries connect, write a line, and disconnect. Frames are
`HookWire` types. The server tolerates garbage and unknown frame kinds by
design, because a future helper version will send things this one has not seen.

If the socket is unhealthy, L1 is not abandoned immediately —
`socketDegradeGrace = 15` seconds covers a rebuild
(`DetectionCoordinator.swift:61`). A reconcile sweep runs every
`sweepInterval = 30` seconds.

---

## Usage metering

Transcript records carry token counts. `UsageMetering` deduplicates them into a
ledger, infers five-hour blocks and rolling windows, prices them in
API-equivalent USD from a static table, and persists rollups with debounced
atomic writes. Official quota payloads, when present, are carried with their
provenance and staleness so an estimate is never shown as though it were
authoritative.

The static price table goes out of date whenever Anthropic changes pricing.
That is a maintenance obligation, not a bug, and it is worth knowing about.

---

## What the app never does

- It does not read your conversations. The hook read surface is five fields,
  enforced by a closed enum and a test.
- It does not touch `~/.claude` without consent. The install sheet shows the
  exact JSON that will be deep-merged, and uninstall restores what was there.
- It does not sandbox, and so it is not on the Mac App Store: detection needs
  `proc_listpids`, which App Sandbox forbids with no entitlement exemption.
  Distribution is Developer ID plus notarization, direct and via Homebrew.

---

## Building

```bash
Scripts/bootstrap.sh     # xcodegen -> Decaf.xcodeproj (generated, gitignored)
Scripts/run.sh           # build, quit the running copy, relaunch
swift test --package-path Core
Scripts/check-bridge.sh  # the helper's linked libraries, size and silence
Scripts/release.sh       # signed, notarized, stapled DMG
```

`Decaf.xcodeproj` is generated from `project.yml` on every run; edit the
manifest, never the project file.
