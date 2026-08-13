# docs

Facts about the code. Anything that is process rather than fact — plans,
research, review notes, the icon exploration — is kept out of the repository.

| | |
|---|---|
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
