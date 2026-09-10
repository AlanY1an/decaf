#!/bin/bash
# Reproduce the README hero, social cover and labeled 12-second UI walkthrough.
# Only synthetic fixtures are rendered. No agent logs, app preferences or clipboard are read.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$(cd "$HERE/.." && pwd)"
command -v ffmpeg >/dev/null || { echo 'Install ffmpeg to encode the walkthrough.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/decaf-marketing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
"$HERE/build.sh"
"$HERE/.build/release/DecafRender" "$WORK" --marketing
cp "$WORK/readme-hero-light.png" "$WORK/readme-hero-dark.png" "$WORK/repo-social-preview.png" "$ASSETS/"
# Relative paths keep the concat manifest independent of the temporary directory name.
cat > "$WORK/frames.txt" <<'FRAMES'
file 'walkthrough-1.png'
duration 3
file 'walkthrough-2.png'
duration 2
file 'walkthrough-3.png'
duration 2
file 'walkthrough-4.png'
duration 3
file 'walkthrough-5.png'
duration 2
file 'walkthrough-5.png'
FRAMES
ffmpeg -hide_banner -loglevel warning -y -f concat -safe 0 -i "$WORK/frames.txt" \
  -t 12 -vf fps=12 -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart \
  "$ASSETS/decaf-walkthrough.mp4"
ffmpeg -hide_banner -loglevel warning -y -i "$ASSETS/decaf-walkthrough.mp4" \
  -filter_complex '[0:v]fps=6,scale=840:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle' \
  -loop 0 "$ASSETS/decaf-walkthrough.gif"
echo "Wrote hero, social cover, GIF and MP4 to $ASSETS"
