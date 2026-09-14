#!/usr/bin/env bash
# Same end-to-end verification as verify.sh, but against the sRGB-tagged
# stand-in source. This is the regression test for colour-tag passthrough:
# an output retagged BT.709 instead of iec61966-2-1 renders about 10/255 off
# in brightness through a colour-managed pipeline.
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
