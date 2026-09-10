# docs

Usage, implementation details and reproducible artwork for Decaf.

| | |
|---|---|
| [`usage.md`](usage.md) · [`中文`](usage.zh-CN.md) | Installation, upgrades, first use, statistics, Your brew, data boundaries and uninstall instructions. |
| [`architecture.md`](architecture.md) | How Decaf is put together: modules, the three detection layers, the power assertion engine, the socket, usage metering. Every constant cites the file it was read from. |
| [`assets/`](assets/) | The images the top-level README renders, plus [`assets/CAPTURE.md`](assets/CAPTURE.md) — how each one was produced, and the three known limits of the offscreen renderer. |
| [`assets/render/`](assets/render/) | The offscreen render harness itself: a small Swift package that draws the real shipping SwiftUI views into PNGs, so the screenshots can be regenerated rather than re-shot by hand. |

## Regenerating the screenshots

```bash
cd docs/assets/render && ./build.sh && ./.build/release/DecafRender ..
```

It writes into its working directory, which is why the `..` matters. Getting
that wrong produces a run that reports success while writing the files
somewhere you are not looking.

## The app icon

`assets/icon-256.png` and the shipped icon set are written together by
`Scripts/install-appicon-png.py`, so the two cannot drift apart. Rebuild after
changing it — actool compiles the asset catalog at build time, so an existing
bundle keeps showing the old icon.

## Daily usage and receipt images

Run `docs/assets/render/build.sh`, then `docs/assets/render/.build/release/DecafRender docs/assets --usage` to render light/dark statistics windows, a narrow window, an empty state and the exact share-card PNG export. All use example data. The `usage-*.png` screenshots show the v0.2.0 statistics interface.

The same `--usage` renderer also produces `usage-monthly-light.png` and `usage-monthly-dark.png`, monthly receipt images, and current-month, narrow-window and empty-month previews using example data. Monthly totals and filters use the production statistics model.

## Your brew profile images

Run `docs/assets/render/build.sh`, then `docs/assets/render/.build/release/DecafRender docs/assets --profile`. It renders the actual profile and settings views, light/dark monthly cards with and without token totals, previous-month pages/cards, mixed app/card appearances, and narrow, loading, empty and partial-history examples. Names and usage are synthetic; no real profile preferences are read or changed. `--measure` also checks the Profile settings tab.

## README artwork and walkthrough

Run `docs/assets/render/marketing.sh` from any directory (requires Xcode/Swift and ffmpeg). It builds the native renderer, writes light/dark README artwork and the 1280×640 social cover, then encodes a 12-second GIF and MP4. Temporary frames are removed. For PNG frames alone, use `DecafRender <output-directory> --marketing` after building.

`Marketing.swift` composes the production statistics views and menu status excerpts. The walkthrough focuses on detected activity, idle after activity ends, combined daily usage, monthly totals and per-tool filtering. The status panel uses the production menu icon and status sentence; it is not a screenshot of the complete macOS menu. Every input is synthetic; the harness starts no agent detector or power assertion and reads no conversation logs. The video is a staged native UI walkthrough, not a live interaction recording. README provides a static alternative for reduced-motion preferences.

The social cover is a separate repository setting; changing its PNG or README does not upload it to GitHub. No release is needed to update documentation.

The README now embeds a separate [real interaction recording](assets/live-demo/README.md):
an actual Codex run, native menu, monthly statistics and PNG save. The monthly
history is example data and pauses are cut. The staged assets above remain
reproducible references.
