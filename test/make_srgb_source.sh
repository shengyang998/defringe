#!/usr/bin/env bash
# Build the 10 s sRGB-tagged stand-in source (regression fixture for the
# colour-tag passthrough: with the encoder session hardcoded to BT.709,
# VideoToolbox converts these files from sRGB into BT.709 — an extra transfer
# round trip and metadata that no longer matches the source. The code-value
# delta that shows up is a round-trip detector, not a brightness measurement;
# through the system colour-management path the difference is ~0.3/255).
#
# hevc_videotoolbox writes no transfer/primaries VUI, so the tag is applied
# afterwards with the hevc_metadata bitstream filter over a stream copy:
# transfer_characteristics=13 is IEC 61966-2-1 (sRGB); 1/1 are BT.709
# primaries/matrix, which is what sRGB video uses.
#
# Usage: make_srgb_source.sh [out.mov] [seconds]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out/source_srgb.mov}"
SECONDS_TO_ENCODE="${2:-10}"

mkdir -p "$(dirname "$OUT")"
SCENE="$(dirname "$OUT")/scene.ppm"
PLAIN="$(dirname "$OUT")/source_srgb_plain.mov"

if [ ! -f "$SCENE" ]; then
  python3 "$HERE/make_scene.py" "$SCENE"
fi

ffmpeg -y -v error \
  -loop 1 -framerate 240 -i "$SCENE" -t "$SECONDS_TO_ENCODE" \
  -vf "crop=4096:2160:x='mod(t*37,24)':y='mod(t*23,24)',format=yuv420p10le" \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -b:v 12M -tag:v hvc1 \
  "$PLAIN"

ffmpeg -y -v error -i "$PLAIN" -c copy \
  -bsf:v hevc_metadata=colour_primaries=1:transfer_characteristics=13:matrix_coefficients=1 \
  "$OUT"
rm -f "$PLAIN"

ffprobe -v error -select_streams v:0 \
  -show_entries stream=profile,pix_fmt,color_primaries,color_transfer,color_space,color_range,width,height,avg_frame_rate,nb_frames,duration \
  -of default=nw=1 "$OUT"
echo "wrote $OUT"
