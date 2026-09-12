<div align="center">

<img src="docs/assets/icon-256.png" alt="Decaf" width="72" height="72">

# Decaf

**Keep your Mac awake while your agents work.**

Automatic keep-awake and local token stats for **Claude Code + Codex**.
A little companion in your Mac’s menu bar.

**[Download for macOS](https://github.com/AlanY1an/decaf/releases/latest)** · [Guide](docs/usage.md) · [中文](README.zh-CN.md)

macOS 14+ · Free & open source · Signed & notarized

</div>

```sh
brew install --cask AlanY1an/decaf/decaf
```

Open Decaf from Applications and find the cup in your menu bar.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/readme-hero-dark.png">
  <img src="docs/assets/readme-hero-light.png" alt="Decaf: an agent-working status excerpt beside the current Home window with Claude Code and Codex usage" width="880">
</picture>

<sub>Current native Home and an excerpt of the menu status, with example data.</sub>

## Start a task. Step away.

Decaf detects supported Claude Code and Codex activity and automatically prevents
idle sleep. It releases the hold after activity ends and the applicable grace
window expires. Running both? One finishing does not cancel the other’s hold.

Keep-awake respects your safety settings. Codex detection is approximate.
The screen can sleep while work continues; closing the lid still allows system sleep. [Detection and safety settings →](docs/usage.md#what-to-expect)

<picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/assets/home-light.png">
  <img src="docs/assets/decaf-live-demo.gif" alt="A real Codex task: automatic keep-awake, live Home status and monthly usage filters" width="880">
</picture>

<sub>Real Codex process and native Decaf 0.3.3 UI; example usage history. Pauses between actions removed. [Watch the MP4](docs/assets/decaf-live-demo.mp4).</sub>

## Two agents. One usage view.

See daily and monthly token usage for **Claude Code, Codex, or both**. Browse
earlier months, inspect cache details and see when the local import needs attention.

Counts include cached tokens and available records on this Mac. They are not
your subscription allowance or an account-wide bill.

At the end of the month, save a little coffee receipt of your activity. Token
totals are hidden by default; you decide what to share.
[Your brew →](docs/usage.md#your-brew)

<details>
<summary>A little receipt to share</summary>

<img src="docs/assets/profile-previous-month-card-light.png" alt="Example monthly coffee receipt; token totals hidden" width="340">

</details>

## Switch Claude accounts. Keep the conversation.

Changed accounts in Claude Desktop and your earlier Code conversations stopped
appearing? **Move sessions** brings eligible local sessions to the account you’re
using. Select source accounts, confirm the signed-in destination, review the move, then continue
in Claude. Original entries are saved; Undo is available while the records and
history can still be verified.

**Claude Code only.** Currently verified for **Claude Desktop 1.52386.3**. Sign in
to the destination in Claude first. Pins and group placement do not transfer.
[Supported sessions and how moves work →](docs/usage.md#move-sessions)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/sessions-selected-dark.png">
  <img src="docs/assets/sessions-selected-light.png" alt="Move sessions in Decaf, with example source accounts and a destination" width="800">
</picture>

<sub>Native interface with example accounts.</sub>

## Your work stays on your Mac

No Decaf account and no conversation uploads. Detection, usage analysis and
session moves run locally. Explicit update checks and downloads contact GitHub.
Your share cards are exported locally and shared only when you choose.

[Data sources and limits](docs/usage.md#your-data) · [Update](docs/usage.md#update) · [Uninstall](docs/usage.md#uninstall) · [MIT license](LICENSE)

## Help shape Decaf

Try it during a normal Claude Code or Codex workday. Tell us **one thing that
helped and one thing that got in your way**. English and 中文 are welcome.

**[Share your experience](https://github.com/AlanY1an/decaf/issues/new?template=feedback.yml)** · [Report a bug](https://github.com/AlanY1an/decaf/issues/new/choose) · [Good first issues](https://github.com/AlanY1an/decaf/labels/good%20first%20issue) · [Contribute](CONTRIBUTING.md)

You can help with a reproducible bug report, clearer copy, accessibility checks
or Swift code. Please use synthetic examples instead of uploading conversations
or credentials.
