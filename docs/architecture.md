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
sixth is ever added. Conversation bodies are not retained or logged. Log lines are parsed locally;
only scheduling metadata and the narrow cron-result job ID are extracted.

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

- It parses local transcript records and retains selected metadata, not
  conversation bodies. Tests pin the expected parser behavior; they are not
  a compiler-enforced security boundary.
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

## Daily and monthly usage, and Codex

The menu leads with today's combined Claude Code + Codex token count. Clicking it opens a compact, reusable native statistics window. Agent totals filter the
seven-day chart; selecting a date updates the headline and token breakdown.
The default view presents a daily summary and a small chart without dashboard
cards or axes. Input, output and cache counts expand under “The little details”.
Uncached input, output, cache reads and writes remain separate, and days without
recorded activity remain visible. The Monthly switch reads all retained daily
rollups from `UsageSnapshot.recordedHistory`, independently of the rolling hourly
retention. Recent daily history replaces overlapping dates instead of adding them.
Month navigation uses local calendar boundaries, stops at the current month and
earliest available history, and includes gaps between months. Future days are
muted and disabled; current-month totals are explicitly month-to-date. Selecting
a bar drills down to that day; selecting the month total restores the aggregate.
The Copy card action renders a separate SwiftUI view to a PNG on the clipboard.
Its input model contains only the selected date and selected agents’ daily or monthly token
totals. Filtering to one agent also excludes the other from the export. There is
no network request, automatic posting, or access to project names or conversations
in this export path. Documentation uses the same PNG renderer with example data.
Calendar arithmetic handles midnight and daylight-saving transitions. The
existing Claude official quota is shown separately only when viewing today; Codex tokens never enter
Claude's five-hour estimates. Counts cover available local logs, not account-wide
usage or subscription limits.

`UsageLedger` persists the selected complete record for every message ID and
request ID pair. Claude subagent records participate in the same deduplication.
An updated usage snapshot replaces the previous snapshot when its total is higher;
it is never added as a second request. The earliest observed timestamp determines
the local day. Record identity survives pruning, restarts and copied transcripts.
Persisted timestamps also allow daily history to be regrouped after a time-zone
change without mixing calendar boundaries.

`CodexUsageParser` retains token observations by session and reconciles them in
timestamp order. Cached input is a subset of input; reasoning is a subset of
output, and both count once. A new cumulative segment is recognized when the
counter changes at a later timestamp and matches that event's last-call usage.
Repeated observations and unchanged quota-only events add nothing. Backfilling an
earlier observation can replace neighboring event deltas to correct their daily
allocation without inflating the total. A counter discontinuity without sufficient
last-call evidence remains unresolved; statistics and exported cards indicate
that the recorded usage needs review. Log formats still cannot establish
account-wide usage or recover missing sessions.

The Codex ledger is `codex-usage.json`, beside the Claude ledger. Complete-line
resume offsets, request accounting and Codex observations are saved atomically.
Meter transactions serialize catch-up, live events and snapshots. Schema 3 backs
up prior store bytes under `Application Support/Decaf/Backups` before rebuilding
all available history; the old ten-day migration limit is removed. If the backup
fails, migration does not overwrite the previous store. History whose logs no
longer exist is recoverable only from the retained backup, not silently combined
with rebuilt totals.

The FSEvents stream watches live Codex sessions under `~/.codex` (or
`CODEX_HOME`). `CodexTurnMonitor` extends the five-minute file-activity window
when durable task events indicate an unfinished turn and `CodexLogOwnerProbe`
verifies that a `codex` executable still has that exact live log open for writing.
The native libproc probe checks executable basename, write flags, path, device
and inode; it never inspects command lines or launches a helper. It rechecks at
most once every 30 seconds. A process merely remaining open is insufficient.

The monitor recognizes `task_started` / `turn_started`, `task_complete` /
`turn_complete`, and `turn_aborted`. Recognized task item completions and tool
call/results can renew progress; token/quota/settings records cannot. Duplicate
starts cannot reopen a finished turn, and another turn's late stop cannot end
the current one. Each file has independent state. Completion, cancellation,
closed writers, read failure, or replacement revoke the extended hold. Normal
file-activity grace still lasts up to five minutes after a write.

On launch, only currently owned logs get a bounded last-1-MiB scan. A recognized
item completion carrying a turn ID can recover an active turn whose start falls
outside that tail. Complete-line resume offsets preserve a partial final record.
At most 32 logs are admitted, each read capped at 1 MiB per sweep; a reader behind
its backlog cannot extend a hold. Unknown formats, absent ownership or missing
recent task evidence retain ordinary file-activity behavior. Two hours without
recognized task progress ends an extension, with a boundary timer for expiry.

This remains `.fileActivity` precision: persisted logs do not reliably expose
approval/input waits, so an unanswered approval can hold until the silence cap.
No per-task CPU activity is inferred from a shared app-server process. See the
[Codex keep-awake verification](plans/codex-quiet-tasks.md) for protocol sources,
limits and test cases.

`archived_sessions` is scanned for usage at startup and receives a separate
usage-only event callback. Archives never enter the owner probe. Remote sessions
without local logs are not scanned, and no Codex configuration is changed. See
the [usage repair plan](plans/usage-accuracy.md) for accounting validation.

The [official Codex hooks documentation](https://learn.chatgpt.com/docs/hooks)
explicitly identifies transcript format as unstable. Future format changes may
require parser updates; unknown records are ignored rather than guessed.

## Your brew profile

`UsageProfileModel` reads the same retained and recent daily rollups as usage
statistics; recent days replace matching retained days. It aggregates the
selected local calendar month and creates 90 distinct calendar dates through
today for the current month, or through the final day of a past month, including
DST boundaries. Month navigation includes gaps, stops at the earliest positive
record across either agent, and cannot advance beyond the current local month.
Stale snapshots cannot move the reporting date back. Future and malformed dates are excluded.
Dates with positive recorded usage count once across agents. Blank cells mean
no recorded usage, not verified inactivity; the earliest record never serves
as a fabricated account join date. Monthly tool percentages describe tokens,
including cached tokens, not time or productivity.

`BrewProfileStore` stores an optional nickname, one of three built-in icons and
a sharing preference in local UserDefaults. The app injects one shared instance
into settings and statistics; tests and the renderer inject isolated suites.
No system account name, remote identity or new network service is used. The
profile is reachable through the menu, statistics navigation and Settings →
Profile. Existing daily/monthly usage views remain available.

`BrewProfileShareModel` is a separate export boundary containing only chosen
identity, selected-month activity, active tools and an allowlisted partial-history
flag. With totals hidden (the default), agent and aggregate quantities are nil
and active heatmap cells all use the same level. The PNG renderer refuses
loading and empty-month models. A preview uses the same SwiftUI view as the
export. The card has a System/Light/Dark appearance choice independent of the
app; preview and export resolve the same choice. Copy renders before replacing
the clipboard; Save uses the user's chosen destination and a month-specific
default filename. No automatic sharing occurs. Transient page interactions are
kept in a child view so selecting activity cells does not reaggregate history.

## Manual updates

`UpdateGuideView` is opened from the menu and General settings. It displays the
installed bundle version, a GitHub Releases link and copyable Homebrew commands.
Displaying the window does not contact a server. A release link explicitly opens
the user's browser; copying commands does not execute them. There is no automatic
update check or installer. The bundle identity and Application Support paths stay
constant across upgrades. Usage schema migration backs up the previous ledger
before rebuilding available history (see the usage metering section above).
