<div align="center">

<img src="docs/assets/icon-256.png" alt="Decaf app icon" width="180" height="180">

# Decaf

**The `caffeinate` command as a smart menu bar app.**

Keeps your Mac awake while Claude Code is actually working — and lets it sleep the moment the agent is done, or is only waiting on you.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/menubar-icons-dark.png">
  <img src="docs/assets/menubar-icons-light.png" alt="Four menu bar icon states: idle, manual hold, agents working with a session count, and paused by a safety protection" width="480">
</picture>

<sub>Four states. The Mac sleeps normally in the first one.</sub>

<p>
  <a href="https://github.com/AlanY1an/decaf/releases/latest"><img src="https://img.shields.io/badge/Download-.dmg-brightgreen?style=flat-square" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="Requires macOS 14 or later">
  <a href="https://github.com/AlanY1an/homebrew-decaf"><img src="https://img.shields.io/badge/Homebrew-tap-orange?style=flat-square" alt="Homebrew tap"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/AlanY1an/decaf/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/AlanY1an/decaf/ci.yml?style=flat-square&label=CI" alt="CI status"></a>
</p>

<a href="README.zh-CN.md">中文</a>

</div>

---

## The problem

You start a long agent run, walk away, and come back to find it stopped ten minutes in because the Mac slept.

Keep-awake apps are switches: on, or off. Leave it on and your laptop stays awake all night because a terminal is open. Leave it off and you have to remember.

The AI-aware ones hold while the agent *process* exists. Better — and still wrong in the case that matters: **an agent sitting at its prompt looks exactly like an agent thinking hard.** One should let your Mac sleep. The other must not.

Telling those apart is the whole product.

## What it does

- **Holds while a turn is in flight.** Prompt submitted → hold. Turn done → release after a grace period (3 minutes by default).
- **Releases when the agent is waiting on you.** An idle prompt is not work. Neither is an unanswered permission dialog — though that gets a five-minute window first, so answering it and carrying on never costs you a wake.
- **Holds through long silent tool calls.** A 20-minute build writes nothing, but it is working. Four independent witnesses must agree a session has gone quiet before the hold drops.
- **Holds through declared waits.** If the agent scheduled its own wake-up — a `/loop` with a 30-minute gap, a cron job — Decaf reads that and holds until then. [Why that matters ↓](#declared-waits)
- **Manual holds too.** 5/15/30 minutes, 1/2/5 hours, "Until 6:00 PM", or indefinitely.
- **Gets out of the way.** Low Power Mode, fast user switching and the battery gate release every hold. Closing the lid or choosing Sleep always wins — Decaf blocks *idle* sleep only.

Claude Code only, today. Codex and opencode are on the roadmap.

## Install

```sh
brew install --cask AlanY1an/decaf/decaf
```

Or download the DMG from [the latest release](https://github.com/AlanY1an/decaf/releases/latest). Requires **macOS 14 or later**.

On first launch Decaf offers to install hooks into Claude Code. One click, optional, reversible.

## How it knows

| Layer | Precision | Setup |
| --- | --- | --- |
| **Hooks** | Turn-precise — the exact instant a turn starts, ends, or asks you something. | One click. Adds entries to `~/.claude/settings.json`. |
| **File activity** | ~5 minutes. Watches writes under `~/.claude`. | None. This is the default. |
| **CPU sampling** | Never a reason to hold on its own; one of the witnesses that decide a session has gone stale. | None. |

The menu always says which layer is running, and never claims a precision it does not have. Hook installs are a deep merge — your existing hooks survive, and uninstall removes only what Decaf added.

<a name="declared-waits"></a>
## Declared waits

An autonomous loop is where a keep-awake app earns its place or is useless. Between iterations, a `/loop` with a 7-minute gap looks exactly like an idle agent — and if the Mac sleeps in the gap, the timer never fires. The loop stalls silently until you touch the trackpad.

Measured on a real run, no hooks, `pmset -g assertions` sampled every 20 seconds: the hold released 300 seconds after the last transcript write, and the Mac was sleepable for **1 minute 40 seconds** before the next iteration woke it.

The answer was already on disk. Five and a half minutes before that release, the agent had written `ScheduleWakeup { delaySeconds: 420 }` into its own transcript — it had said when it would be back, and the app threw it away.

Decaf now reads it. Four scheduling tools are recognised, the declared deadline extends the hold, and three guard rails apply: capped at one hour, every safety gate still wins, and unparseable input is silently ignored rather than trusted.

## Privacy

Decaf watches `~/.claude`. That deserves a straight answer.

- **No network requests.** No telemetry, no analytics, no update check — there is no `URLSession` anywhere in the source.
- **It never reads your conversation.** The transcript parser reads a fixed list of identifiers, timestamps and token counters. `prompt`, `reason` and every other conversational field are never read, stored or logged. Each read surface is a closed Swift enum pinned by a test, so widening it is a failing build rather than a review oversight.
- **Nothing logged can carry content.** Diagnostics are an enum of cases like `lineNotJSON` — a log line is structurally incapable of holding a transcript excerpt.
- **It writes only** to `~/Library/Application Support/Decaf/`, plus its own entries in `~/.claude/settings.json` if you install hooks. Both are reversible from Settings.

You see all of that before any of it happens, and the file list on the sheet is generated by the same code that does the writing:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/consent-sheet-dark.png">
  <img src="docs/assets/consent-sheet-light.png" alt="The install consent sheet, listing the files Decaf will write and previewing the exact JSON it merges into ~/.claude/settings.json" width="520">
</picture>

Full field lists are in [`docs/architecture.md`](docs/architecture.md).

## Settings

Six, and no more.

| | |
| --- | --- |
| **Auto keep awake for agents** | On by default. Off means Decaf ignores agents entirely. |
| **Release grace period** | How long to hold after a turn ends. 1–10 minutes, default 3. |
| **Display while keeping awake** | Screen sleeps normally (default) or stays on. Plus a **Turn Off Display Now** action. |
| **Battery threshold** | Stop holding below this. Off / 10 / 20 / 30 %, default 20. |
| **Default manual duration** and **"Until" time** | What the one-click manual hold does. |
| **Launch at login** | |

## Uninstall

```sh
brew uninstall --cask AlanY1an/decaf/decaf
```

If you installed hooks, use **Settings → Agents → Uninstall Hooks** first — it removes Decaf's entries and leaves everything else intact. If the app is already gone, delete `~/Library/Application Support/Decaf/` and any entry in `~/.claude/settings.json` whose command path contains `Application Support/Decaf`.

Power assertions die with the process, so quitting or deleting Decaf can never leave your Mac unable to sleep.

## Roadmap

- [x] Claude Code — hooks, file-activity fallback, declared waits
- [x] Manual holds, display policy, battery gate
- [x] Token usage and rate-limit display, every number labelled official or estimated
- [ ] Codex — native hooks, `notify` fallback
- [ ] opencode — plugin
- [ ] Scheduled time windows
- [ ] Automatic updates
- [ ] Clamshell mode, with a privileged helper and a loud warning

## FAQ

**Why "Decaf" if it does `caffeinate`'s job?**
Because the job is knowing when to *stop*. Every app in this category is named for the stimulant, and every one is a switch you must remember to flip off. Decaf puts itself down. The subtitle still says `caffeinate` because that is the command you know — but the app deliberately does not share the name, so nothing here can ever shadow `/usr/bin/caffeinate`.

**How is this different from KeepingYouAwake or Amphetamine?**
Those are switches, and good ones. Decaf decides. If a switch is what you want, KeepingYouAwake is well maintained and you should use it. (Decaf is also that switch when you want it: manual holds are all there.)

**Can I use it without installing hooks?**
Yes, and that is the default. You lose turn precision — about five minutes of resolution instead of instant — and the menu says so.

**Why isn't it on the Mac App Store?**
The sandbox forbids inspecting other processes and forbids the socket-plus-helper layout the hook bridge needs. Permanent, not a backlog item.

**Will it drain my battery?**
It can only prevent sleep, and it stops below 20 %. The default mode lets your Mac sleep whenever the agent is not working — for most people, less awake time than a switch they forgot to turn off.

## Building from source

```sh
git clone https://github.com/AlanY1an/decaf.git
cd decaf
Scripts/bootstrap.sh
swift test --package-path Core
```

The logic lives in `Core/` as a plain Swift package with no AppKit dependency, which is why it can be tested at all: **642 tests** over the power engine, the session state machine, the transcript parsers and the installer, plus 105 in the app layer. `Decaf.xcodeproj` is generated from `project.yml` and not committed — edit the manifest.

Architecture notes: [`docs/architecture.md`](docs/architecture.md).

## License

MIT. See [LICENSE](LICENSE).
