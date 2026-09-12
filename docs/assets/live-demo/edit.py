"""Trim pauses from a real capture using logged UI-action times. No UI frames are synthesized."""
import argparse, json, subprocess
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('raw', type=Path)
p.add_argument('actions', type=Path)
p.add_argument('recording_start', type=float)
p.add_argument('output', type=Path)
a = p.parse_args()
events = {item['event']: item['t'] - a.recording_start for item in map(json.loads, a.actions.read_text().splitlines())}
# Retain the actual state changes at normal speed; only pauses between actions are cut.
steps = [('run_agent_clicked', .65, 3), ('working_status_shown', .65, 4),
         ('monthly_usage_opened', .95, 3), ('codex_filter_selected', .95, 3),
         ('both_filters_selected', .95, 3)]
filters = []
for i, (event, lead, duration) in enumerate(steps):
    start = max(0, events[event] - lead)
    filters.append(f'[0:v]trim=start={start}:duration={duration},setpts=PTS-STARTPTS[v{i}]')
# The system status strip is excluded from the public edit.
# The app windows below it are untouched; no statuses or totals are overlaid.
filters.append(''.join(f'[v{i}]' for i in range(len(steps))) + f'concat=n={len(steps)}:v=1:a=0,'
    'crop=iw:ih-30:0:30,scale=1280:-2[out]')
a.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y','-i',str(a.raw),
    '-filter_complex',';'.join(filters),'-map','[out]','-r','30','-c:v','libx264',
    '-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(a.output)],check=True)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y','-i',str(a.output),
    '-filter_complex','[0:v]fps=8,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle',
    '-loop','0',str(a.output.with_suffix('.gif'))],check=True)
