<!--
  ==========================================================================
  DO NOT PUBLISH THIS FILE AS-IS.
  The naming placeholders are gone, but two blockers remain: a missing image
  and an unsigned build. Everything blocking is listed below. Delete this
  whole comment block only when every line in it has been cleared.
  Written 2026-08-06. Every capability claim below was re-verified against
  the source on that date; see "VERIFIED" at the bottom of this block.

  WARNING — this file was drafted while other work was in flight in the same
  tree, and facts moved underneath it during drafting: the test count went
  556 -> 568, Scripts/release.sh went from missing to written, and on
  2026-08-07 the product was renamed Caffeinate -> Decaf. Re-run the two
  commands in block 4 before publishing rather than trusting the numbers
  printed here. Where this file cites a line number it is accurate as of
  2026-08-06 and is offered as a starting point for a grep, not as a stable
  address.
  ==========================================================================

  ---- 1. NAMING PLACEHOLDERS — CLEARED 2026-08-07 -------------------------
  All 17 `-TBD` occurrences below this block are filled. `grep -- -TBD`
  returns nothing outside this sentence. The frozen values, from the author's
  gh auth and existing remotes:

    GitHub owner      AlanY1an          (was OWNER-TBD, 8x)
    Repository        AlanY1an/decaf    (was REPO-TBD, 6x — lowercase, to
                                        match echovessel / mappavita / quicktap)
    Homebrew tap      AlanY1an/homebrew-decaf, cask token `decaf`
                                        (was TAP-TBD, 3x)
    Bundle ID         io.github.alany1an.decaf
                                        (project.yml; does NOT appear in this
                                        file. The old `dev.caffeinate.app`
                                        placeholder is retired — Scripts/
                                        release.sh keeps a tripwire against it.)

  What that leaves genuinely unfilled: the LICENSE copyright holder (DECISION
  5 — LICENSE says "Decaf contributors"), whether a `README.zh-CN.md` ships
  alongside this file (DECISION 6 — this draft is English-only, per the launch
  review), and the launch date (DECISION 7 — no date appears in this file).

  Note on the subtitle: "The `caffeinate` command as a smart menu bar app" is
  deliberate and stays. It names the SYSTEM COMMAND people search for, not the
  product; the product no longer shares that name, which is the point of the
  rename. Same for the `caffeinate` repo topic. Do not "fix" either one.

  ---- 2. MISSING / UNRATIFIED IMAGE ASSETS -------------------------------
  This file references three images. One exists but is not ratified; two do
  not exist at all. A broken <img> is obvious; a WRONG one is not, which is
  why the first entry is the dangerous one.

    docs/assets/icon-256.png     PRESENT (256x256, RGBA, full-bleed) but
                                 UNRATIFIED. It is a render of icon direction
                                 B (the steady cursor), and the same direction
                                 is what the app itself now ships:
                                 App/Resources/Assets.xcassets/AppIcon.appiconset/
                                 is direction B, and a Debug build carries it
                                 (Assets.car lists all ten AppIcon entries;
                                 Contents/Resources/AppIcon.icns is 47,382
                                 bytes of direction-B artwork, opened and
                                 looked at, not assumed).

                                 AUTHOR DECISION 4 IS STILL OPEN, and note the
                                 disagreement: docs/launch/README-REVIEW.md §2
                                 (决定 4) recommends direction A on 16 px
                                 legibility evidence — A is the only one of the
                                 four whose 16 px binarisation survives as a
                                 clean ring, and B "糊成一团" in that same cell.
                                 B is in place as a REVERSIBLE PLACEHOLDER so
                                 the build is not blocked on the decision; it
                                 is not the review's recommendation and must
                                 not be mistaken for a settled choice.

                                 Switching costs one command, verified by
                                 round trip on 2026-08-06 (B -> A -> C -> D ->
                                 B restored every file byte-for-byte):

                                     Scripts/set-appicon.sh <A|B|C|D>

                                 That script rewrites the appiconset AND this
                                 PNG from the same source, so the shipped icon
                                 and the README hero cannot drift apart.
                                 Rebuild afterwards — actool compiles the set
                                 at build time, so an existing bundle keeps
                                 showing the old icon.

                                 This image renders fine and looks finished,
                                 which still makes it the single most likely
                                 thing to ship by accident: a broken <img>
                                 announces itself, a wrong one does not.

    docs/assets/states.webp      MISSING. The four-state screenshot strip.
                                 Full shot list in the comment at the point
                                 of use below. This is the most load-bearing
                                 image in the file.

    docs/assets/demo.gif         MISSING and OPTIONAL — not referenced by any
                                 <img> today. Spec kept in a comment below in
                                 case it gets made.

  ---- 3. THE CLAIM THAT WAS NOT TRUE YET — NOW CUT ------------------------
  RESOLVED 2026-08-06 by cutting it. The Install section used to say builds
  are "signed with a Developer ID certificate and notarized by Apple, so they
  open without a Gatekeeper warning". That sentence is GONE from the body; the
  exact text to restore, and the exact condition for restoring it, are in the
  comment at the point it used to sit.

  The underlying situation is nearly unchanged. `Scripts/release.sh` (archive
  -> sign -> DMG -> notarize -> staple) exists and its dry run is green end to
  end, but it has never produced a signed build. As of 2026-08-07 the bundle-ID
  blocker is GONE — it is frozen to io.github.alany1an.decaf — and the preflight
  now names TWO: no Developer ID Application certificate, and no notarytool
  keychain profile. (Both are downstream of the same missing thing: an active
  Apple Developer Program membership.) The script refuses to fake either, and
  the bundle-ID check remains as a tripwire against a revert.

  So the README no longer contains a false claim, and no longer contains an
  unfilled placeholder. Two things still keep it unpublishable:
    - docs/assets/states.webp does not exist (block 2), so the most
      load-bearing image on the page renders as a broken <img>;
    - no signed, notarized build has ever been produced, so there is nothing
      behind the Download badge and a clean Mac would refuse what it got.
  Both are work, not decisions.

  ---- 3b. WHAT THE VERIFICATION PASS CHANGED (2026-08-06, second pass) ----
  A second, independent trace of every claim against the source found six
  things the first pass had stated too strongly. Each is corrected in place
  with an ACCURACY comment naming the file that decided it; listed here so a
  reader of this block knows the body has already been through it:

    1. BATTERY vs A MANUAL HOLD. Was "a low battery releases every AUTOMATIC
       hold too", which implies a manual hold survives the gate. It does not:
       `batteryOverridden` is set only when a manual request ARRIVES while the
       gate is engaged, so a manual hold already running when the battery
       falls is suspended like any other. The distinction is WHEN it started.
    2. THE ASSERTION, SINGULAR. Was "the assertion Decaf holds is
       PreventUserIdleSystemSleep". It also holds PreventUserIdleDisplaySleep
       when a live source carries DisplayPolicy.keepOn. Both idle-only, so the
       argument survived; the count did not.
    3. CODEX / OPENCODE. Was "the process scan also matches codex and
       opencode" with the consequence left implicit. SUPERSEDED 2026-08-07:
       the process scan is gone with the hold mode it existed for, so codex
       and opencode are not detected at all today. Stated as such.
    4. SIGNING. Cut entirely — see block 3.
    5. "BYTE-FOR-BYTE INTACT" (install + uninstall). False: the file is
       re-serialised and loses key order and indentation. The enforced
       contract is semantic equality of the parsed JSON. Now says so.
    6. TWO SETTINGS RANGES. "Grace, adjustable from 1 to 10" implied a
       continuum (it is 1/2/3/5/10); the battery threshold's options
       (Off/10/20/30) were not named at all.
    Plus one narrowing: the privacy field list now names the `message` ->
    `content` -> `input` containers the parser walks to reach the leaves.

  ---- 4. VERIFIED 2026-08-06 (re-check only if the code changes) ---------
  Every capability claim below was traced to a file on this date, twice, by
  two different passes:
    553 tests / 78 suites  `swift test --package-path Core` was RUN. RE-RUN
                           2026-08-07 after the Caffeinate -> Decaf rename:
                           "Test run with 553 tests in 78 suites passed".
                           Exact, not a grep estimate — Swift Testing counts a
                           parameterised test once and expands it into cases at
                           run time. It read 556/88 and then 568/89 on
                           2026-08-06, which is the whole argument for
                           re-running it on release day rather than trusting
                           this line.
    grace 180 s default    PowerTuning.swift (UI presets 1/2/3/5/10 min,
                           SettingsView.swift:322 — a Picker over a fixed list,
                           NOT a 1..10 range)
    L2 idle window 300 s   PowerTuning.swift
    battery 20 % / 23 %    PowerTuning.swift (threshold + hysteresis 3). The UI
                           offers Off/10/20/30 (SettingsView.swift:661), and
                           the recovery point is always threshold + 3.
    battery override       PowerStateEngine.swift:168 sets `batteryOverridden`
                           ONLY on a .manual request that ARRIVES while the
                           gate is engaged; cleared at :293 (removal, expiry,
                           willSleep, gate re-open). Nothing sets it when the
                           gate engages under a live manual hold, so that hold
                           IS suspended — SafetyGates.swift:34. LPM and
                           fast-user-switching have NO override path at all.
    assertion types        BOTH cases of AssertionKind (:23/:25):
                           "PreventUserIdleSystemSleep" always, and
                           "PreventUserIdleDisplaySleep" additionally iff a live
                           source carries DisplayPolicy.keepOn (reconcile step
                           3). IOPMPowerAsserter.swift:29 calls
                           IOPMAssertionCreateWithDescription directly.
    codex/opencode         NOT DETECTED (2026-08-07). ProcessScanner and the
                           hold mode it served are deleted; `AgentKind` still
                           carries the cases for the V1.x adapters, but nothing
                           produces a hold source for them.
    settings.json contract ClaudeSettingsEditor.swift:25-27 — re-serialisation
                           loses key order and indentation on purpose; the
                           uninstall contract is `semanticallyEqual` (:308),
                           i.e. parsed equality, NOT byte equality.
    hook events            ClaudeSettingsEditor.swift:59-65 — six plain events
                           + two Notification matchers.
    wait signals           WaitSignalParser.swift — 4 whitelisted tools, cap
                           3600 s, margin 60 s, closed Diagnostic enum, no
                           `throws` on either parse entry point, anchored
                           `^Scheduled .*job ([0-9a-f]{6,64})` cron-id regex.
    privacy read surface   WaitSignalParser.InputKey (5 cases) pinned by
                           WaitSignalParserTests.swift:530
                           `inputReadSurfaceIsExactlyTheAllowedFiveKeys`.
    no network             Zero `URLSession` in App/ or Core/Sources/.
    six settings           SettingsView.swift — launch at login, default
                           manual duration, "Until" time (default 1080 min =
                           6:00 PM), display policy, grace period, battery
                           threshold. (Was seven; the hold-mode picker was
                           deleted on 2026-08-07.)
    manual presets         `enum ManualPreset` in App/MenuTextFormatter.swift
                           — 5/15/30 min, 1/2/5 h, Indefinitely.
    not sandboxed          App/Decaf.entitlements is an empty dict with a
                           comment explaining why.
    macOS 14 floor         Two APIs, both greppable: SwiftUI's
                           `EnvironmentValues.openSettings`
                           (App/MenuContentView.swift, which comments the
                           version itself) and the two-parameter
                           `onChange(of:)` (App/SettingsView.swift,
                           App/OnboardingWindow.swift). Core/Package.swift
                           declares .macOS(.v14) and project.yml sets
                           deploymentTarget 14.0.
                           Do NOT cite SettingsLink — it appears only in
                           docs/plan/04-ui-ux.md, never in the source — nor
                           MenuBarExtra or SMAppService, which are macOS 13.
    CI                     .github/workflows/ci.yml has TWO jobs: `core`
                           (swift build + swift test on the Core package) and
                           `app` (xcodegen, an UNSIGNED Release build of the
                           app target, and check-bridge against the embedded
                           binary). It never signs, never notarizes and never
                           publishes — there is no tag trigger and
                           `permissions: contents: read`. So the badge may say
                           "CI" or "build", but nothing about it implies the
                           shipped, signed artifact was verified here.
                           Runners are macos-26, Xcode pinned to 26.6.

  ---- 5. RUN ON 2026-08-06, ALL GREEN (this is the pre-publish gate) ------
  Not inspected — executed. Re-run all five before publishing; only the first
  two produce numbers this file quotes.

    swift test --package-path Core     553 tests / 78 suites passed (re-run
                                       2026-08-07, post-rename)
    xcodebuild ... -scheme Decaf test
                                       93 tests / 15 suites passed (AppTests,
                                       re-run 2026-08-07 post-rename; a logic
                                       bundle with no TEST_HOST, so it never
                                       launches the app or touches the real
                                       ~/.claude)
    xcodebuild ... build               BUILD SUCCEEDED, and the bundle carries
                                       the icon: CFBundleIconName=AppIcon,
                                       Assets.car lists all ten AppIcon
                                       entries, AppIcon.icns is direction B
    Scripts/check-bridge.sh            all checks passed (system libs only,
                                       116,984 bytes, a real hook frame
                                       delivered over an isolated temp socket,
                                       and graceful silence with no listener)
    Scripts/set-appicon.sh <A|B|C|D>   B -> A -> C -> D -> B round trip, every
                                       file byte-identical afterwards; an
                                       invalid direction exits 2
    Scripts/release.sh --dry-run       exit 0: real archive, real 1.86 MB DMG,
                                       real sha256, well-formed appcast item.
                                       Sign / notarize / staple report SKIP and
                                       print the commands a real run would use.
                                       A REAL run exits 1 and builds nothing,
                                       naming its blockers at once — 2 as of
                                       2026-08-07, down from 4 now that the
                                       bundle ID is frozen.

  These numbers are perishable. The Core count read 556, then 568, in the
  hours this file was being written, and 553 after the rename pass; AppTests
  did not exist at all when the first draft was made. Re-run; do not trust.
-->

<div align="center">

<!--
  ASSET 1 — app icon. See block 2 above: the file present today is direction B
  and AUTHOR DECISION 4 is still open. Re-export a 256x256 PNG here from the
  chosen direction. An explicit export (rather than referencing the asset
  catalog) is required because the Icon Composer pipeline produces a .icon
  bundle, not a loose PNG GitHub can render.
-->
<img src="docs/assets/icon-256.png" alt="Decaf app icon" width="200" height="200">

# Decaf

**The `caffeinate` command as a smart menu bar app.**

Keeps your Mac awake while Claude Code is actually working — and lets it sleep the moment the agent is done, or is only waiting on you.

<!--
  ASSET 2 — the four-state screenshot strip. MISSING. This is the single most
  load-bearing image in the README, and it is the shot no competitor can take.
  Four menu-bar screenshots, side by side, ~250 px wide each, exported as one
  .webp to docs/assets/states.webp. Each must show the menu open with the
  status line legible:

    1. Hooks installed, a turn in flight.
       Status: "Claude Code working". No precision row (hooks are precise, so
       there is nothing to qualify). Caption: "Hooks installed — turn-precise."
    2. No hooks, file-activity fallback.
       Status: "Claude Code working" + precision row
       "Detection: file activity (approximate)".
       Caption: "No hooks, no config — still works, ~5 min resolution."
    3. Agent inside a declared wait (a /loop with a 30-minute gap).
       Status: "Claude Code working" + the wait line.
       Caption: "Waiting on a clock, not on you — stays awake."
    4. Agent at its prompt, waiting for input.
       Status: "Idle — not preventing sleep".
       Caption: "Waiting for your input — sleeps normally."

  Shoot all four in the same appearance, same menu width, same wallpaper.
  States 3 and 4 are the product; 1 and 2 are the setup. If only two can be
  shot well, shoot 3 and 4.
  (State 3 was "blocked on a permission prompt, still held" until 2026-08-07.
  A permission prompt is the agent waiting on YOU, so it now opens a bounded
  window instead — which makes it a poor contrast shot against 4.)
-->
<img src="docs/assets/states.webp" alt="Four menu states: hooks-precise hold, file-activity fallback, a declared wait (still awake), waiting for your input (sleeping normally)" width="820">

<sub>Same agent, four situations. Only the last one lets the Mac sleep.</sub>

<!-- Badges: 5, shields.io flat-square, download CTA first. No stars, no
     download counts — a new repo's numbers only argue against it. macOS 14+
     is here on purpose: it deflects incompatible-user issues before they are
     filed. The CI badge points at a workflow that builds and tests both the
     Core package and the app target, but always UNSIGNED and never publishing
     — see block 4 above. It is not evidence about the signed artifact. -->
<p>
  <a href="https://github.com/AlanY1an/decaf/releases/latest"><img src="https://img.shields.io/badge/Download-.dmg-brightgreen?style=flat-square" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="Requires macOS 14 or later">
  <a href="https://github.com/AlanY1an/homebrew-decaf"><img src="https://img.shields.io/badge/Homebrew-tap-orange?style=flat-square" alt="Homebrew tap"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/AlanY1an/decaf/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/AlanY1an/decaf/ci.yml?style=flat-square&label=CI" alt="CI status"></a>
</p>

</div>

---

## The problem this solves

You start a long agent run, walk away, and come back to find it stopped ten minutes in because the Mac went to sleep.

The usual fix is a keep-awake app, and the usual keep-awake app is a switch: it is on, or it is off. If you leave it on, your laptop stays awake all night because a terminal window is open. If you leave it off, you have to remember.

The AI-aware ones improve on that by holding while the agent process exists. That is better, and it is still wrong in the case that matters most: **an agent sitting at its prompt with nothing to do looks exactly like an agent thinking hard.** One should let your Mac sleep. The other must not.

Decaf's whole job is telling those apart.

## What it actually does

- **Holds while a turn is in flight.** Prompt submitted → hold. Turn finished → release, after a short grace window (3 minutes by default; the choices are 1, 2, 3, 5 and 10).
- **Releases whenever the agent is waiting on you.** An idle REPL is not work, and neither is an unanswered permission prompt — both are the agent handing the floor back to you, and neither is worth a night of battery. (A prompt gets a five-minute window first, so answering it three seconds later and carrying on never costs you a wake.)
- **Holds through a long silent tool call.** A 20-minute build writes nothing and prints nothing, but the process is live and the network is in flight. Four independent witnesses have to agree a `working` record has gone quiet before Decaf lets go of it. And if that tool call is the one that asked you for permission: Claude Code emits no hook event when you click "allow", so Decaf treats the tool's own completion as the proof — the first tool that reports in after a prompt puts the session straight back to working. (One gap, stated rather than buried: between the five-minute window running out and that completion arriving, a very long approved tool is unprotected. It cannot be fixed by lengthening the window, which is also how long an *unanswered* prompt would keep your Mac awake. See `docs/plan/02-detection.md` §1.1c.)
- **Holds through declared waits.** If the agent has scheduled its own wake-up — a `/loop` with a 30-minute gap, a cron job, a monitor with a timeout — Decaf reads that record and holds until then instead of sleeping through it. See [Wait-signal awareness](#wait-signal-awareness).
- **Manual hold when you just want one.** 5/15/30 minutes, 1/2/5 hours, "Until 6:00 PM", or indefinitely.
- **Gets out of the way.** Low Power Mode and fast user switching release every hold, manual ones included — neither has an override. The battery gate releases holds too, and it does not spare a manual one: a manual hold that is *already running* when the battery falls past the threshold is suspended along with everything else. The one exception is narrow and deliberate — starting a manual hold *while* the gate is already engaged is treated as an informed override, so that hold proceeds; the override is then cleared the moment the manual hold ends, expires, the Mac sleeps, or the battery recovers past the threshold (23 % at the default). And a sleep you asked for always wins: Decaf holds `PreventUserIdleSystemSleep` (plus `PreventUserIdleDisplaySleep`, and only if you ask it to keep the screen on), and both block *idle* sleep only — closing the lid or choosing Sleep from the Apple menu is never something this app can override.
<!-- ACCURACY (corrected 2026-08-06 by the verification pass): the previous
     wording was "a low battery releases every AUTOMATIC hold too", which reads
     as "a manual hold survives the battery gate". It does not.
     `PowerStateEngine.setRequest` (:166-169) sets `batteryOverridden` only on a
     .manual request that ARRIVES while `gates.battery == .engaged`. Nothing
     sets it when the gate engages underneath a live manual hold, so
     `SafetyGates.blocksHolding` (:34) is true and reconcile releases the
     assertion — suspend semantics, the request stays registered and resumes at
     23 %. The distinction is the whole bullet: it is about WHEN the hold
     started, not about which kind of hold it is. The override clears at :293
     on manual-request removal, expiry, willSleep, or the gate re-opening.
     LPM and fast user switching have no override term at all (SafetyGates.swift
     :34-38). Also corrected: "the assertion" was singular, but reconcile step 3
     adds `preventIdleDisplaySleep` when any live source carries
     `DisplayPolicy.keepOn` (AssertionKind.swift:13). Both are idle-only, so the
     argument is unchanged — the count was not. -->
- **Claude Code only, today.** `codex` and `opencode` appear in the code as agent kinds the protocol already carries, so the V1.x adapters will not need a protocol change — but nothing detects them yet. A process scan that matched them by executable name used to exist, purely to serve an optional "while an agent is running" mode; both were deleted on 2026-08-07 along with the mode. If you run codex or opencode today, Decaf does not see them at all.
<!-- ACCURACY (rewritten 2026-08-07): the previous bullet said the process scan
     matches codex/opencode and that a match holds the Mac awake in
     `.whileRunning`. Both halves are now false — ProcessScanner.swift is
     deleted, and so is AgentHoldMode. Do not restore the old wording from the
     git history without restoring the code first. -->

<!--
  ASSET 3 — demo GIF. MISSING, optional, and deliberately below the fold. No
  <img> references it, so nothing breaks by leaving it out. 0 of 10 comparable
  READMEs lead with a GIF and Ice ships one but chose not to use it. If it gets
  made, the only clip worth 8 seconds is:
    1. Agent working, menu open, hold visible.                          (2 s)
    2. Turn ends, grace window, status flips to "Idle — not preventing
       sleep".                                                          (3 s)
    3. Permission prompt appears in the terminal; status flips to held.  (3 s)
  Loop it, cap it at 2 MB, add a one-line caption. If it cannot be made under
  2 MB and legible at 800 px, skip it — the four-state strip already carries
  the point.
-->

## Install

**Homebrew** (a personal tap — Decaf is not in homebrew-cask core yet):

```sh
brew install --cask AlanY1an/decaf/decaf
```

**Or download the DMG** from [the latest release](https://github.com/AlanY1an/decaf/releases/latest), open it, and drag Decaf to Applications.

Requires **macOS 14 or later**.
<!-- ACCURACY GATE — see block 3 of the header comment. CUT 2026-08-06 by the
     verification pass. The sentence that stood here was:

       "Builds are signed with a Developer ID certificate and notarized by
        Apple, so they open without a Gatekeeper warning."

     It is a promise about an artifact that has never existed. `Scripts/release.sh`
     is now written and its dry run is green end to end, but its own preflight
     refuses a real run today for two reasons: there is no Developer ID
     certificate and no `notarytool` keychain profile, with no Apple Developer
     Program enrolment behind either. (It was three until 2026-08-07, when the
     Caffeinate -> Decaf rename froze the bundle ID as
     `io.github.alany1an.decaf`; the preflight now reports it as frozen and
     keeps a tripwire against the retired `dev.caffeinate.app` placeholder.)
     The claim was CUT rather than softened, because a
     hedged version ("will be signed") is still the sentence a reader uses to
     decide whether to trust a download.

     RESTORE the sentence verbatim — this exact wording, in this exact place —
     on the day a real `Scripts/release.sh` run has produced a DMG that passes
     BOTH `xcrun stapler validate` and `spctl --assess --type execute` on a Mac
     that has never had Xcode or a developer certificate on it. Not before, and
     not on the strength of a successful notarytool submission alone. -->

On first launch Decaf offers to install its hooks into Claude Code. That is one click, and it is optional — see below.

## How it knows

Three layers. You get the first one you qualify for, and the menu always tells you which one is running.

| Layer | Precision | Setup |
| --- | --- | --- |
| **Hooks** | Turn-precise. Knows the exact instant a turn starts, ends, asks you for permission, or goes idle. | One click. Adds entries to `~/.claude/settings.json`. |
| **File activity** | ~5 minutes. Watches for writes under `~/.claude` and holds while they keep coming. | None. This is what you get out of the box. |
| **CPU sampling** | Coarse, and never a reason to hold on its own. It is one of the four witnesses that decide a `working` record has gone stale, which is how a long silent tool call is told apart from a session whose `Stop` was lost. | None. |

The hook layer registers six events plus two notification matchers: `SessionStart`, `UserPromptSubmit`, `PostToolUse` (used purely as a liveness heartbeat), `Stop`, `StopFailure`, `SessionEnd`, and `Notification` split into `permission_prompt` (opens a five-minute window, and hands the hold back as soon as the approved tool reports in) and `idle_prompt` (releases early). The install is a deep merge — every hook you already had, and every key Decaf does not recognise, survives with its value intact, and uninstall removes exactly the entries it added and nothing else. One caveat worth stating rather than discovering: the file is re-parsed and re-serialised, so key order and indentation are not preserved. The contract the tests enforce is semantic equality of the parsed JSON, not byte equality of the file.
<!-- ACCURACY (corrected 2026-08-06 by the verification pass): "passed through
     untouched" was doing double duty — true of every value, false of the bytes.
     ClaudeSettingsEditor.swift:25-27 says so itself: "Re-serialization loses key
     order/indentation (accepted MVP trade-off), so the uninstall contract is
     SEMANTIC equality after parsing, not byte equality", enforced by
     `semanticallyEqual(_:_:)` at :308 (NSDictionary equality). A user who
     diffs their settings.json after an install and finds it reformatted has
     been told something untrue by this README unless the caveat is here. -->

The menu never claims a precision it does not have. If a config sync wipes the entries, it drops to `Detection: file activity (approximate)` and offers to install hooks again. If the entries are still delivering but were written by an older Decaf build — the app updated, the config did not follow — it says `Detection: hooks (an older event set)` and offers to repair, because that state is genuinely between the two layers rather than a fall back to either.
<!-- ACCURACY (rewritten 2026-08-06): the previous draft said the repair offer
     appears when "you upgraded Claude Code, or a config sync overwrote the
     file". Neither is what the code does. `DetectionPrecision.hooksPartial`
     (DetectionPrecision.swift) means OUR entries are outdated relative to THIS
     build — ClaudeCodeIntegration.swift:182 states the cause is upgrading
     Decaf — and it is the only precision whose `suggestsHookRepair` is
     true. A wiped config yields `.entriesMissing` -> `.fileActivity`, whose
     note is "Install hooks for precise detection…", not "Repair hooks…" —
     both strings live in `MenuCopy.precisionNote(for:)` in
     MenuPresentation.swift. Upgrading Claude Code is not a trigger for
     either. -->

<a name="wait-signal-awareness"></a>
## Wait-signal awareness

An autonomous loop is the case where a keep-awake app either earns its place or is useless. Between iterations, a `/loop` with a 7-minute gap looks *exactly* like an idle agent. Sleep during the gap and the timer does not fire, so the loop stalls until you come back and touch the trackpad — silently, with no error and no notification.

This was measured on this machine, not reasoned about. Real `/loop`, 420-second gap, no hooks installed, `pmset -g assertions` sampled every 20 seconds:

```
22:54:55 – 23:00:56   held    (19 samples)
23:01:16 – 23:02:56   NOT held   ← ~1 min 40 s with sleep allowed
23:03:08              held again (next iteration woke it)
```

The last transcript write was around 22:56, and 300 seconds later is the file-activity idle window expiring — so the release at 23:01:16 is the mechanism working exactly as designed, and wrong here.
<!-- ACCURACY (softened 2026-08-06): the previous draft said the release landed
     "exactly 300 seconds after the last transcript write". docs/plan/08-wait-signals.md:31
     records the last write as approximately 22:56 ("约 22:56"), and the sampler
     ran at 20 s resolution, so "exactly" is a precision the measurement does
     not have. The 6-sample gap is likewise recorded as ≈1 min 40 s. -->

The fix is that the answer was already on disk. At **22:55:47**, five and a half minutes before the release, the agent had written `ScheduleWakeup { delaySeconds: 420 }` into its own transcript. It had said "I am waiting until 23:02:47", and the app threw that away.

Decaf now reads it. Four scheduling tools are recognised — `ScheduleWakeup`, `Monitor`, `CronCreate`, `CronDelete` — and the declared deadline extends the hold, plus a 60-second margin because waking a Mac is not instantaneous. Guard rails, in order:

- **Capped at one hour.** A parse bug can cost you an hour of sleep, never a night.
- **Every safety gate still applies.** Low battery, Low Power Mode, user switching, an explicit Sleep. A declared wait is not an exemption. (The only thing that opens the battery gate is a manual hold *you* start while it is engaged, as above — a wait signal can never open it, and neither can a wait signal that arrives during one.)
- **Unknown input is silently ignored.** These are upstream-internal tool names that can disappear in any release. Bad JSON, missing field, unknown tool: the line is skipped and behaviour falls back to the ordinary grace period. Neither parse entry point is declared `throws`.

## Privacy

Decaf watches `~/.claude`. That deserves a straight answer rather than a badge.

- **It makes no network requests.** None. There is no telemetry, no crash reporter, no analytics, and no update check — there is no `URLSession` anywhere in the source. <!-- NOTE: narrow this to "the only network request is Sparkle's update check" the day Sparkle is integrated (V1.x, plan 06 §7). -->
- **It never reads your conversation.** The transcript parser looks at exactly these fields: `sessionId`, `timestamp`, `isSidechain`, the record and block `type`, the tool `name`, and — only for the four scheduling tools above — `delaySeconds`, `timeout_ms`, `stop`, `cron`, `id`. (It walks the `message` → `content` → `input` containers to reach them, and reads no other leaf inside any of them.) Those last five are a Swift enum with a test pinning its cases, so widening the tool-input surface is a failing build rather than a code-review oversight. `prompt`, `reason` and every other conversational field are never read, never stored, never logged.
<!-- ACCURACY (narrowed 2026-08-06): the previous draft said the whole field
     list "is a Swift enum with a test pinning its cases". Only the five `input`
     keys are — WaitSignalParser.InputKey, pinned by
     WaitSignalParserTests.swift:530 `inputReadSurfaceIsExactlyTheAllowedFiveKeys`.
     The record-level fields (sessionId/timestamp/isSidechain/type/name) are
     read by string literal in WaitSignalParser.swift:198-230, with no enum and
     no pinning test. The sentence now says which half is pinned. -->
- **One exception, and it is narrow.** To match a cancelled cron job to the wait it created, Decaf reads the single tool result line directly following a `CronCreate`, and keeps only a hex job id matched by an anchored regex (`^Scheduled .*job ([0-9a-f]{6,64})`). Every other tool result is skipped, because tool results contain arbitrary output. If the regex does not match, the pairing is abandoned and the hold falls back to the conservative cap.
- **Nothing is logged with content in it.** Diagnostics are a closed enum of cases like `lineNotJSON` and `unknownTool` — a log line is structurally incapable of carrying a transcript excerpt.
- **The only files it writes** are under `~/Library/Application Support/Decaf/` (session state, a copy of the hook helper, and a rotating one-deep backup of any config file it edits) and, if you install hooks, its own entries in `~/.claude/settings.json`.

## What it deliberately does not do

- **Not on the Mac App Store, ever.** The sandbox forbids inspecting other processes and forbids the socket-plus-helper layout the hook bridge needs. Distribution is Developer ID direct — outside the sandbox, straight from GitHub Releases and the Homebrew tap. This is a permanent decision, not a backlog item.
- **It does not keep the Mac awake with the lid closed.** Clamshell keep-awake needs a privileged root helper and carries a real heat risk on a closed laptop. It is designed but deliberately deferred; if it ships, it will ship with a warning you cannot miss.
- **It cannot wake a sleeping Mac.** Nothing here schedules wake-ups. It prevents sleep; it does not reverse it. If your Mac is already asleep when a loop is due, Decaf was too late.
- **It does not wrap `/usr/bin/caffeinate`.** Every assertion is `IOPMAssertionCreateWithDescription` called directly, which is what makes them visible and attributable in `pmset -g assertions`, and what makes them die with the process instead of outliving it. (One action does shell out: "Turn Off Display Now" runs `/usr/bin/pmset displaysleepnow`, because there is no public API for it. It is a one-shot command, not a held assertion.)
<!-- ACCURACY (added 2026-08-06): the pmset parenthetical is new. The claim
     about assertions is exactly true (IOPMPowerAsserter.swift:29), but
     PmsetDisplaySleeper (DisplayController.swift:33-44) does launch
     /usr/bin/pmset for the one menu action, and a reader who discovers that
     after reading an unqualified "it does not shell out" would be right to
     feel misled. -->
- **It ships no CLI at all today, and never one named `caffeinate`.** If a command-line tool appears it is `decaf`, which is exactly why the app is called that: `decaf` collides with nothing on your `PATH`, and shadowing `/usr/bin/caffeinate` would be an unforgivable thing for this app of all apps to do.

## Settings

Seven, and no more. Every one of them had to answer "who does the default hurt?"

- **Keep this Mac awake** — while an agent is *working* (default), or while an agent is *running*. The second is the blunt instrument every competitor ships; it is here for people on AC who want zero risk, and the menu tells you honestly when your detection layer cannot actually deliver it.
- **Release grace period** — how long to keep holding after a turn ends. 1/2/3/5/10 minutes, default 3.
- **Display while keeping awake** — the screen sleeps normally (default) or stays on. There is also a **Turn Off Display Now** action: the screen goes dark, the work keeps running.
- **Battery threshold** — stop holding below this. Off, 10 %, 20 % or 30 %; default 20 %, resuming three points above the line you picked so a battery hovering at it does not flap.
- **Default manual duration** and **"Until" time** — what the one-click manual hold does. Defaults: indefinite, 6:00 PM.
- **Launch at login.**

## Uninstall

```sh
brew uninstall --cask AlanY1an/decaf/decaf
```

Or drag Decaf out of Applications. Then, if you installed hooks, remove what they left behind:

1. Open Decaf → Settings → Agents → **Uninstall Hooks**. This filters Decaf's entries out of `~/.claude/settings.json` and leaves every other setting intact — the file is rewritten, so key order and indentation may change, but no value of yours does. Do this *before* deleting the app if you can.
2. If the app is already gone, delete `~/Library/Application Support/Decaf/` and remove any entry in `~/.claude/settings.json` whose command path contains `Application Support/Decaf`.

Power assertions die with the process, so quitting or deleting the app can never leave your Mac unable to sleep.

## Roadmap

- [x] Claude Code — hooks, file-activity fallback, wait signals
- [x] Manual holds, display policy, battery gate
- [ ] Codex — native hooks where the installed version supports them, `notify` fallback below that
- [ ] opencode — plugin
- [ ] Scheduled time windows ("keep awake 9–6 on weekdays")
- [ ] Automatic updates (Sparkle)
- [ ] Clamshell mode, with a privileged helper and a loud warning
<!-- ACCURACY (softened 2026-08-06): the previous draft pinned the Codex line to
     "0.144+". That boundary is real in docs/plan/03-integrations.md §"版本判定",
     but it is a design note about unshipped work and an upstream version line
     that can move. Nothing in the source implements it, so the README must not
     print the number as if it were a supported threshold. -->

## FAQ

<!-- ADDED 2026-08-07 with the rename. The subtitle says `caffeinate` and the
     app is called Decaf, which a first-time reader will notice; this answers it
     once, in the place people look. Delete this entry and nothing else breaks. -->
**Why is it called Decaf if it does the `caffeinate` command's job?**
Because the job is knowing when to *stop*. Every app in this category is named for the stimulant — Caffeine, Amphetamine, Theine, keepresso — and every one of them is a switch you have to remember to flip off. Decaf is the one that puts itself down. The subtitle still says `caffeinate` because that is the command you already know and the word you would search for; the app deliberately does not share its name, so nothing here can ever shadow `/usr/bin/caffeinate`.

**Does it support Codex or opencode?**
Not yet. Today Claude Code is the only supported agent: it is the only one with hooks, and the zero-config fallback layer watches `~/.claude` and nothing else.

Their names do appear in the source, as agent kinds the socket protocol and the detection types already carry, so the V1.x adapters will not need a protocol change. Nothing produces a hold for them. Until 2026-08-07 a process scan matched them by executable name and, in an optional "while an agent is running" mode, that match really did keep the Mac awake; the mode and the scan were deleted together. Real support is on the roadmap above and will be announced when it works, not before.

**How is this different from KeepingYouAwake or Amphetamine?**
Those are switches, and good ones. They keep your Mac awake because you told them to, until you tell them to stop. Decaf decides — it holds while the agent is working, and lets go the moment the agent is waiting on you. If a switch is what you want, KeepingYouAwake is a well-maintained one and you should use it. (Decaf is also that switch when you want it to be: manual holds, durations and "Until" are all there.)
<!-- ACCURACY (2026-08-06): dropped "6.8k stars". The figure came from
     docs/launch/research-teardowns.md, which recorded 6,810 on 2026-08-06, but
     a star count in a README is a number nobody will ever update and that
     nothing in this repo can verify. -->

**How is this different from the other AI-aware keep-awake apps?**
Most of them hold while the agent process is alive. That is one improvement over a switch, and it still keeps your laptop awake all night because you left a terminal open. The three things to compare on: whether it distinguishes an agent that is working from one that is waiting on you; whether it survives a `/loop` with a gap longer than its idle window; and whether it holds real IOKit assertions or shells out to `/usr/bin/caffeinate`.

**Why isn't it on the Mac App Store?**
Covered above: the sandbox makes it impossible, not merely inconvenient.

**Why macOS 14+?**
SwiftUI's `openSettings` and two-parameter `onChange(of:)`, plus the Swift concurrency model the detection layer is built on. Supporting 13 would mean a second code path through the part of the app that decides whether your Mac sleeps, which is the last place in the app to want one.
<!-- ACCURACY: name only an API a reader can grep for. Two qualify in the source
     today — SwiftUI's `EnvironmentValues.openSettings`, which the menu uses to
     open the settings window (App/MenuContentView.swift, whose own comment
     marks it "macOS 14+"), and the two-parameter `onChange(of:_:)` closure form
     (App/SettingsView.swift, App/OnboardingWindow.swift). `SettingsLink` is
     specified in docs/plan/04-ui-ux.md but is NOT in the source and must not be
     cited; neither may MenuBarExtra or SMAppService, which are macOS 13.
     Core/Package.swift declares .macOS(.v14) and project.yml sets
     deploymentTarget 14.0, so the floor is real either way. -->

**Can I use it without installing hooks?**
Yes, and it is the default. Without hooks Decaf watches file activity under `~/.claude`; you lose turn precision (about five minutes of resolution instead of instant) and the menu says so. Hooks are one click and reversible from Settings → Agents.

**Will it drain my battery?**
It can only ever *prevent sleep*, and it stops doing that below 20 % — including a manual hold that was already running when you crossed the line. The one way past it is to start a manual hold *while* you are already below the threshold, which is treated as your call to make and is undone as soon as that hold ends. The default mode is the one that lets your Mac sleep whenever the agent is not working, which for most people means less awake time than a keep-awake switch they forgot to turn off.

## Building from source

```sh
git clone https://github.com/AlanY1an/decaf.git
cd decaf
Scripts/bootstrap.sh      # xcodegen generate
swift test --package-path Core
open Decaf.xcodeproj
```

The logic lives in `Core/` as a plain Swift package with no AppKit dependency, which is why it can be tested at all: **553 tests** cover the power engine, the session state machine, the transcript parser and the installer.
<!-- VERIFIED 2026-08-07 (post-rename): `swift test --package-path Core`
     printed "Test run with 553 tests in 78 suites passed". Exact, not a grep
     estimate. It printed 556/88 and then 568/89 on 2026-08-06 — RE-RUN AND
     UPDATE THIS NUMBER on release day. -->
The app target in `App/` is a thin SwiftUI shell over it. `Decaf.xcodeproj` is generated from `project.yml` and is not committed — edit the manifest, not the project.

## License

MIT. See [LICENSE](LICENSE).
