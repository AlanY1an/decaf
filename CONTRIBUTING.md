# Contributing to Decaf

Small, specific contributions are welcome. You do not need to write Swift to help: try the app for a workday, describe a confusing interaction, check VoiceOver, or improve the docs. English and Chinese reports are both welcome.

## Try it and report what happened

Use [the issue chooser](https://github.com/AlanY1an/decaf/issues/new/choose) for bugs, ideas or first-day feedback. Include your macOS version, Decaf version or commit, and whether you use Claude Code, Codex or both.

For usage issues, v0.2.0 and later offer **Usage Statistics → read-status line → Copy support summary**. It copies app/macOS versions, selected sources and import status; token totals, usage dates, file paths, session IDs, conversations and raw errors are excluded. Paste it into the optional support-summary field if useful. Copying never sends it anywhere.

A useful bug report says what you expected, what happened, and the shortest way to reproduce it. Share synthetic or redacted examples instead of full session logs, project paths, prompts or credentials.

The v0.1.0 download and the development checkout have different features; the README lists which is which.

### A first-day check

Pick the setup you actually use; you do not need to install another tool just to give feedback.

| Setup | Try during a normal task | What to report |
| --- | --- | --- |
| Claude Code | Start and finish a task; note whether hooks are enabled. | Does the cup's status make sense while working and after finishing? |
| Codex (preview) | Include a task with a quiet stretch, then finish or cancel it. | Does keep-awake last through the task and clear after the applicable idle window? |
| Both (preview) | Overlap two tasks, then finish one while the other continues. | Does the remaining task keep its hold? Are the usage totals separate and the combined total understandable? |

For the preview, also open usage after the first import, look at Monthly and Your brew, and preview a card. Missing logs should be distinguishable from a day with no recorded usage. The next day, tell us whether you wanted to open Decaf again. These are invitations to test, not claims that a user study has already happened.

[Usage guide](docs/usage.md) · [中文指南](docs/usage.zh-CN.md) · [First-day feedback](https://github.com/AlanY1an/decaf/issues/new?template=feedback.yml)

## Build locally

Use macOS 14+ and full Xcode with Swift 6 support. Development and CI use Xcode 26.6. XcodeGen generates the project from `project.yml`; do not edit the generated `.xcodeproj`.

```sh
git clone https://github.com/AlanY1an/decaf.git
cd decaf
Scripts/bootstrap.sh
Scripts/run.sh
```

`bootstrap.sh` installs XcodeGen through Homebrew if needed. `run.sh` builds a Debug app, quits an existing Decaf instance and opens the fresh build. Launching the app uses your normal local Decaf preferences and agent logs; the test suites use isolated data.

## Check a change

Core logic:

```sh
swift test --package-path Core
```

App presentation logic:

```sh
xcodegen generate
xcodebuild -project Decaf.xcodeproj -scheme Decaf -configuration Debug \
  -destination 'platform=macOS' -only-testing:DecafAppTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

For a UI change, inspect light and dark appearances, an empty ledger, and the minimum window width. Render the real statistics views and share-card PNGs with example data:

```sh
docs/assets/render/build.sh
docs/assets/render/.build/release/DecafRender docs/assets --usage
```

That renderer does not launch the live app or copy anything onto your clipboard. It writes documentation images.

## Good places to start

- Improve a label or first-run instruction that confused you.
- Reproduce a counting problem using a small synthetic log fixture.
- Check keyboard navigation, VoiceOver or window layout.
- Explain a real workflow that needs more reliable activity detection.

Check existing issues before starting a large integration. Describe the problem you want to solve so the design can stay small. Keep pull requests focused, explain the resulting behavior, and include relevant checks. Before/after images help for UI changes.

[Architecture](docs/architecture.md) covers detection, power assertions, local usage accounting and data boundaries. New log formats should preserve deduplication, separate provider ledgers and local calendar-day behavior.

Release publishing is maintained separately from contributions. A documentation or UI change does not require a version bump, tag, signed archive or release.
