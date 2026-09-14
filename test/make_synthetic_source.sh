#!/usr/bin/env bash
# Build the synthetic 10 s test source: 4096x2160, 240 fps, HEVC Main 10,
# 4:2:0, tv range, BT.709 — the same contract as an Apple aerial asset, but
# with content we are allowed to redistribute.
#
# A real aerial video cannot be published, so this scene (thin cables, a tower
# with coloured rims, smooth sky/water) is rendered once with numpy and encoded
# at a deliberately low bit rate; the 4:2:0 chroma ringing around the thin
# structures is what defringe removes.
#
# Usage: make_synthetic_source.sh [out.mov] [seconds]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out/source.mov}"
SECONDS_TO_ENCODE="${2:-10}"

mkdir -p "$(dirname "$OUT")"
SCENE="$(dirname "$OUT")/scene.ppm"

if [ ! -f "$SCENE" ]; then
  python3 "$HERE/make_scene.py" "$SCENE"
fi

# The pan keeps every frame slightly different, so the encoder cannot just copy
# the I-frame; the ringing is refreshed instead of decaying away.
ffmpeg -y -v error \
  -loop 1 -framerate 240 -i "$SCENE" -t "$SECONDS_TO_ENCODE" \
  -vf "crop=4096:2160:x='mod(t*37,24)':y='mod(t*23,24)',format=yuv420p10le" \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -b:v 12M \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
  -tag:v hvc1 "$OUT"

ffprobe -v error -select_streams v:0 \
  -show_entries stream=profile,pix_fmt,color_primaries,color_transfer,color_space,color_range,width,height,avg_frame_rate,nb_frames,duration \
  -of default=nw=1 "$OUT"
echo "wrote $OUT"
