<!--
  Drafted 2026-08-06 from the actual git history (51 commits, 300403d..e8dd80c),
  not from the plans. One thing still needs an author decision before this file
  can be published:

    1. The release date on the 0.1.0 heading. Replace the word "Unreleased"
       with an ISO date on tag day (AUTHOR DECISION 7 — launch date).

  The GitHub owner and repo name are no longer open: the link references at the
  bottom point at AlanY1an/decaf, frozen on 2026-08-07 with the
  Caffeinate → Decaf rename.

  THREE THINGS TO DO ON THIS MAC, ONCE, IN THIS ORDER. Not changelog entries —
  the former name never shipped, so you are the only person who will ever do
  this. Verified against the machine on 2026-08-07; the order matters, and
  doing step 3 first is what breaks detection silently.

  1. QUIT THE PRE-RENAME BUILD THAT IS STILL RUNNING. As of 2026-08-07 12:28 a
     Debug Caffeinate.app out of DerivedData (started 11:39) was still alive,
     still holding a real PreventUserIdleSystemSleep assertion named
     "Caffeinate" in `pmset -g assertions`, still bound to
     `.../Caffeinate/agent.sock`, and still being fed by your hooks — the old
     `caff-bridge` binary has not gone anywhere, so every hook still fires and
     still lands in the OLD app. That is why nothing looks broken yet. Quit it
     (and delete its DerivedData) before running the renamed build, or two
     copies will hold assertions against each other.

  2. REPAIR THE HOOKS from the new build: Settings → Agents → "Repair Hooks…".
     Your eight entries in ~/.claude/settings.json still point at the retired
     `.../Caffeinate/bin/caff-bridge`. Once step 1 removes the process that was
     answering them, those commands deliver into nothing — and Claude Code does
     not report a hook that fails, so detection would fall back to file activity
     without a word. The probe now names this (`entriesFromRetiredName`) and
     repair rewrites the commands in place, keeping your own hooks untouched.

  3. ONLY THEN, remove the retired directory:

       rm -rf ~/Library/Application\ Support/Caffeinate

     Deliberately not automated. It holds `backups/` — the installer's copies of
     YOUR ~/.claude/settings.json — and deleting a user's backups on their
     behalf is not a thing an app gets to do. The rest of it is inert once
     step 2 is done: `sessions.json` is live state rebuilt within one turn,
     `agent.sock` is a socket with nothing on it, and `integrations.json` is a
     manifest the app no longer needs (it repairs from the markers in
     settings.json instead). Look in `backups/` first, then remove it.

  The test counts (553 in 78 suites for Core, 93 in 15 suites for the app
  bundle — both re-run 2026-08-07 after the rename) come from
  `swift test --package-path Core` and `xcodebuild … test`, and they move with
  almost every commit — Core read 556/88 and then 568/89 on 2026-08-06.
  Re-run both and update the numbers on tag day.

  A verification pass on 2026-08-06 re-traced every claim here to the source and
  corrected three: the low-battery gate does NOT spare an already-running manual
  hold (only one started under the gate is an override); the settings.json
  contract is semantic, not byte, equality; and the process scan's codex /
  opencode match really did hold the Mac in the optional "while an agent is
  running" mode. On 2026-08-07 that mode, the process scan and the permission
  prompt's indefinite hold were all deleted — this file has been rewritten to
  describe the shipping behaviour, not the path to it. The same corrections are
  in README.md.

  Why 0.1.0 has no "Fixed" section even though 14 `fix(...)` commits exist:
  every one of them repaired code that had never been released, so no user has
  ever met those bugs. Listing them would imply a 0.0.x that shipped. Keep this
  file about what a reader can observe between releases — from 0.2.0 onward
  every user-visible fix belongs under "Fixed".
-->

# Changelog

All notable changes to Decaf will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.1.0] — Unreleased

First release. A menu bar app that keeps a Mac awake while Claude Code is
working, and lets it sleep when the agent is only waiting on you.

Claude Code is the only agent supported in this release. Codex and opencode
exist in the source as agent kinds the protocol already carries, so their
adapters will not need a protocol change, but nothing detects them today.
Requires macOS 14 or later.

### Added

- **Keep-awake driven by what the agent is doing, not by whether it exists.**
  The app holds a `PreventUserIdleSystemSleep` IOKit assertion (plus
  `PreventUserIdleDisplaySleep`, and only if you ask it to keep the screen on)
  while a turn is
  in flight, and releases it after a grace period once the turn ends. One rule
  decides everything: the Mac stays awake while the agent is *working*, and any
  time the agent is waiting on you — at its prompt, or on an unanswered
  permission prompt — it sleeps normally. Only idle sleep is affected — closing
  the lid or choosing Sleep from the Apple menu always wins.
- **Two detection layers, with the active one always named in the menu.**
  Hooks (turn-precise) and FSEvents file activity under `~/.claude` (about five
  minutes of resolution, no configuration at all). The menu shows
  `Detection: file activity (approximate)` rather than letting you believe you
  have precision you do not have.
- **One-click Claude Code hooks install.** Deep-merges six events
  (`SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure`,
  `SessionEnd`) plus two `Notification` matchers (`permission_prompt`, which
  opens a 5-minute window and hands the hold back the moment the approved tool
  reports in, and `idle_prompt`, which releases early) into
  `~/.claude/settings.json`. The file is backed up first,
  every key the app does not recognise keeps its value, and uninstall removes
  exactly the entries it added. The file is re-serialised, so key order and
  indentation are not preserved; the contract is semantic equality, not byte
  equality.
- **Repair for an outdated hook set.** When the installed entries predate the
  running build, the app reports it as a distinct state — hooks are still
  delivering, so this is neither "installed" nor "fallback" — and offers to
  repair instead of silently rewriting a file the user owns.
- **Wait-signal awareness.** The transcript reader recognises four scheduling
  tools (`ScheduleWakeup`, `Monitor`, `CronCreate`, `CronDelete`) and holds
  until the deadline the agent declared for itself, plus a 60-second margin.
  Capped at one hour, subject to every safety gate, and silent on anything it
  does not recognise. Without this, a `/loop` with a gap longer than the
  five-minute fallback window stalls at a Mac that went to sleep between
  iterations.
- **Stuck-session detection.** A session that claims to be working while four
  independent witnesses — hook events, the mid-turn heartbeat, transcript
  writes and CPU time — all agree it has been silent for two hours is
  downgraded and stops holding. Any one witness dissenting vetoes the verdict,
  and any real sign of life restores the session in one step.
- **Manual holds.** 5/15/30 minutes, 1/2/5 hours, "Until" a chosen hour, or
  indefinitely, all shown as absolute clock times rather than countdowns.
- **Display policy.** The screen sleeps normally while a hold is active
  (default) or stays on, plus a **Turn Off Display Now** action that darkens
  the screen without touching the hold.
- **Safety gates that outrank every hold.** Low Power Mode and fast user
  switching release everything, manual holds included. A low battery (below
  20 %, resuming at 23 %) does the same, and it does not spare a manual hold
  that was already running. The single exception: starting a manual hold *while*
  that gate is engaged is treated as an informed override, and the override is
  undone as soon as the hold ends or the battery recovers.
- **A settings window with six settings** — release grace period,
  display policy, battery threshold, default manual duration, the "Until" time,
  and launch at login — in native grouped forms, plus a first-launch onboarding
  flow that asks for hooks consent instead of assuming it.
- **A bounded transcript read surface.** The parser reads `sessionId`,
  `timestamp`, `isSidechain`, record and block `type`, tool `name`, and five
  scheduling-tool input keys. Those five are an enum pinned by a test, so
  widening them is a build failure. Diagnostics are a closed enum of cases, so
  a log line cannot structurally carry a transcript excerpt.
- **No network access of any kind.** No telemetry, no crash reporter, no
  analytics, no update check; there is no `URLSession` in the app or the core.
- **`decaf-bridge`**, the hook helper the installed entries invoke, talking to
  the app over a unix socket in Application Support, plus `decaf-smoke` for
  exercising assertions by hand.
- **Build, release and test tooling.** `Scripts/bootstrap.sh` (XcodeGen),
  `run.sh`, `bench-bridge.sh`, `check-bridge.sh`, `set-appicon.sh`, and
  `release.sh` for the archive → sign → DMG → notarize → staple pipeline. CI
  runs two jobs: build and test the `Core` package, and generate the Xcode
  project, build the app unsigned, and check the embedded `decaf-bridge`. CI
  never signs, never notarizes and never publishes.
- **553 tests in 78 suites** over the power engine, the session state machine,
  the transcript parser and the hooks installer, plus **93 tests in 15 suites**
  over the app's menu and icon formatting. `Core` is a plain Swift package with
  no AppKit dependency, and the app bundle is a logic-test target with no test
  host, which is what makes both testable without launching anything.

### Known limitations

- **A tool approved and running longer than five minutes has a gap before the
  hold comes back.** Claude Code emits no hook event when you click "allow" —
  `PreToolUse` fires *before* the dialog, and the next event is `PostToolUse`,
  which only fires once the tool finishes. So a permission prompt opens a
  5-minute window of its own, and if the tool you approved is still running when
  that runs out, the Mac can idle-sleep until the tool finishes and reports in —
  at which point the hold comes back and stays for the rest of the turn. The
  window cannot simply be made longer: it is also how long an *unanswered*
  prompt keeps your Mac awake, which the one rule says should be as short as
  possible. Workaround for a known-long approval: start a manual hold before
  approving it.

### Not in this release

Not a Keep a Changelog section — a deliberate note, because a first release has
no prior entry to imply these were dropped. Codex and opencode integration;
scheduled time windows; automatic updates (Sparkle), so a DMG installed at
0.1.0 has no update channel; clamshell / lid-closed keep-awake; and any
Mac App Store build, which the sandbox makes permanently impossible.

<!-- Owner and repo frozen 2026-08-07; keep in step with the same links in README.md. -->
[Unreleased]: https://github.com/AlanY1an/decaf/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AlanY1an/decaf/releases/tag/v0.1.0
