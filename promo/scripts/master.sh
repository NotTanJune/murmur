#!/bin/sh
# Two-pass loudness normalisation for the rendered promo: -16 LUFS integrated, -1 dBTP,
# video stream copied. Usage: scripts/master.sh raw.mp4 out.mp4
set -eu
in=$1; out=$2
measure=$(ffmpeg -v info -i "$in" -af loudnorm=I=-16:TP=-1:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
filter=$(printf '%s' "$measure" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print("loudnorm=I=-16:TP=-1:LRA=11:measured_I=%s:measured_TP=%s:measured_LRA=%s:measured_thresh=%s:offset=%s:linear=true"
      % (d["input_i"], d["input_tp"], d["input_lra"], d["input_thresh"], d["target_offset"]))')
ffmpeg -v error -y -i "$in" -c:v copy -af "$filter" -c:a aac -b:a 192k -ar 48000 "$out"
ffmpeg -v info -i "$out" -af ebur128=peak=true -f null - 2>&1 | grep -E '  I:|LRA:|Peak:' | tail -3
