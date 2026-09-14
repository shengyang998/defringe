#!/usr/bin/env bash
# Same end-to-end verification as verify.sh, but against the sRGB-tagged
# stand-in source. This is the regression test for colour-tag passthrough: the
# output must keep transfer=iec61966-2-1 and must not pick up an extra
# transfer-function round trip. What the passthrough buys is the skipped round
# trip and metadata identical to the source — not a visible brightness
# difference (that claim was a measurement trap; see README).
#
# Usage: test/verify_srgb.sh [--regenerate]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/out/source_srgb.mov"
OUTPUT="$HERE/out/filtered_srgb.mov"

if [ "${1:-}" = "--regenerate" ] || [ ! -f "$SOURCE" ]; then
  bash "$HERE/make_srgb_source.sh" "$SOURCE" 10
fi

exec bash "$HERE/verify.sh" "$SOURCE" "$OUTPUT"
