#!/usr/bin/env bash
# Visual comparisons that avoid the side-by-side illusion ("the seam must be a
# colour step"):
#   NAME_flip.gif     source and output crops alternating every 0.6 s
#   NAME_stack.png    source crop above the output crop
#   diff_chroma_x10.png / diff_luma_x10.png are converted too when present
#   (amplify_diff.py writes them as PPM).
#
# Usage: compare.sh <source.mov> <output.mov> <time> <x> <y> <w> <h> <outdir> [zoom=4] [name=crop]
set -euo pipefail

SOURCE="$1"; OUTPUT="$2"; TIME="$3"; X="$4"; Y="$5"; WIDTH="$6"; HEIGHT="$7"; OUTDIR="$8"; ZOOM="${9:-4}"; NAME="${10:-crop}"

mkdir -p "$OUTDIR"
CROP="crop=${WIDTH}:${HEIGHT}:${X}:${Y},scale=iw*${ZOOM}:ih*${ZOOM}:flags=neighbor"

ffmpeg -y -v error -ss "$TIME" -i "$SOURCE" -frames:v 1 -vf "$CROP" "$OUTDIR/tmp_src.png"
ffmpeg -y -v error -ss "$TIME" -i "$OUTPUT" -frames:v 1 -vf "$CROP" "$OUTDIR/tmp_out.png"

ffmpeg -y -v error -i "$OUTDIR/tmp_src.png" -i "$OUTDIR/tmp_out.png" \
  -filter_complex vstack "$OUTDIR/${NAME}_stack.png"

cp "$OUTDIR/tmp_src.png" "$OUTDIR/tmp_flip_1.png"
cp "$OUTDIR/tmp_out.png" "$OUTDIR/tmp_flip_2.png"
ffmpeg -y -v error -framerate 1.6666667 -i "$OUTDIR/tmp_flip_%d.png" -loop 0 "$OUTDIR/${NAME}_flip.gif"
rm -f "$OUTDIR/tmp_src.png" "$OUTDIR/tmp_out.png" "$OUTDIR/tmp_flip_1.png" "$OUTDIR/tmp_flip_2.png"

for diff_name in diff_chroma_x10 diff_luma_x10; do
  if [ -f "$OUTDIR/$diff_name.ppm" ]; then
    ffmpeg -y -v error -i "$OUTDIR/$diff_name.ppm" "$OUTDIR/$diff_name.png"
  fi
done

echo "wrote $OUTDIR/${NAME}_flip.gif, $OUTDIR/${NAME}_stack.png"
