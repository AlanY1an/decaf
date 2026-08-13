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

The AI-aware ones hold while the agent *process* is alive. Better — and still wrong in the case that matters: **an agent sitting at its prompt looks exactly like an agent thinking hard.** One should let your Mac sleep. The other must not.

Telling those apart is the whole product.

## What it does

- **Stays awake while a turn is running**, and lets go a few minutes after it finishes.
- **Lets your Mac sleep when the agent is waiting on you.** An idle prompt is not work.
- **Doesn't give up on a long, quiet job.** A 20-minute build looks idle and isn't.
- **Survives self-paced loops.** When an agent schedules its own wake-up, Decaf waits with it instead of sleeping through the gap.
- **Works as a plain switch too.** Hold for 30 minutes, until 6 PM, or indefinitely.
- **Knows when to get out of the way.** Low Power Mode, fast user switching and a low battery all release it. Closing the lid always wins.

Claude Code only, today. Codex and opencode are on the roadmap.

## Install

```sh
brew install --cask AlanY1an/decaf/decaf
```

Or download the DMG from [the latest release](https://github.com/AlanY1an/decaf/releases/latest). Requires **macOS 14 or later**.

It works out of the box. On first launch it offers to install hooks into Claude Code, which makes it precise to the exact turn rather than to about five minutes — one click, optional, and reversible.

## Privacy

Decaf watches `~/.claude`. That deserves a straight answer.

- **It makes no network requests.** No telemetry, no analytics, not even an update check.
- **It never reads your conversation.** It reads timestamps, ids and token counts — never a prompt, never a reply. That limit is enforced by the code's structure and pinned by tests, not by good intentions.
- **It writes only** to its own folder, plus its hook entries in `~/.claude/settings.json` if you let it. Both are reversible from Settings.

You see exactly what it will write before it writes anything:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/consent-sheet-dark.png">
  <img src="docs/assets/consent-sheet-light.png" alt="The install consent sheet, listing the files Decaf will write and previewing the exact JSON it merges into ~/.claude/settings.json" width="520">
</picture>

## Settings

Six, and no more.

| | |
| --- | --- |
| **Auto keep awake for agents** | On by default. Off means Decaf ignores agents entirely. |
| **Release grace period** | How long to hold after a turn ends. 1–10 minutes, default 3. |
| **Display while keeping awake** | Screen sleeps normally, or stays on. Plus **Turn Off Display Now**. |
| **Battery threshold** | Stop holding below this. Default 20%. |
| **Default manual duration** and **"Until" time** | What the one-click hold does. |
| **Launch at login** | |

## Uninstall

```sh
brew uninstall --cask AlanY1an/decaf/decaf
```

If you installed hooks, use **Settings → Agents → Uninstall Hooks** first — it removes Decaf's entries and leaves everything else untouched.

Power assertions die with the process, so quitting or deleting Decaf can never leave your Mac unable to sleep.

## Roadmap

- [x] Claude Code — precise detection, zero-config fallback, self-paced loops
- [x] Manual holds, display policy, battery gate
- [x] Token usage and rate limits, every number labelled official or estimated
- [ ] Codex, opencode
- [ ] Scheduled time windows
- [ ] Automatic updates
- [ ] Clamshell mode, with a loud warning

## FAQ

**Why "Decaf" if it does `caffeinate`'s job?**
Because the job is knowing when to *stop*. Everything in this category is named for the stimulant, and every one of them is a switch you have to remember to turn off. Decaf puts itself down. The subtitle keeps the word `caffeinate` because that is the command you already know — but the app deliberately does not share the name, so it can never shadow `/usr/bin/caffeinate`.

**How is this different from KeepingYouAwake or Amphetamine?**
Those are switches, and good ones. Decaf decides. If a switch is what you want, KeepingYouAwake is well maintained and you should use it. (Decaf is also that switch when you want it to be.)

**Do I have to install the hooks?**
No. Without them it watches for file activity instead — roughly five minutes of resolution rather than instant — and the menu tells you which one is running.

**Why isn't it on the Mac App Store?**
The sandbox makes what Decaf does impossible, not merely inconvenient. Permanent, not a backlog item.

**Will it drain my battery?**
It can only prevent sleep, and it stops below 20%. The default lets your Mac sleep whenever the agent isn't working — for most people that is less awake time than a switch they forgot about.

## Contributing

```sh
git clone https://github.com/AlanY1an/decaf.git
cd decaf
Scripts/bootstrap.sh
swift test --package-path Core
```

How it all works: [`docs/architecture.md`](docs/architecture.md).

## License

MIT. See [LICENSE](LICENSE).
