#!/usr/bin/env bash
# End-to-end verification of defringe on the synthetic 10 s source.
#
# Usage: test/verify.sh [--regenerate] [source.mov] [output.mov]
#
#   --regenerate   re-encode the synthetic source instead of reusing it
#
# Steps: build, source, run, container contract (ffprobe + tscl/tsas scan),
# frame alignment, region chroma stats, amplified difference maps.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUTDIR="$HERE/out"
REGENERATE=0
SOURCE_ARG=""
OUTPUT_ARG=""
for argument in "$@"; do
  if [ "$argument" = "--regenerate" ]; then
    REGENERATE=1
  elif [ -z "$SOURCE_ARG" ]; then
    SOURCE_ARG="$argument"
  elif [ -z "$OUTPUT_ARG" ]; then
    OUTPUT_ARG="$argument"
  fi
done
SOURCE="${SOURCE_ARG:-$OUTDIR/source.mov}"
OUTPUT="${OUTPUT_ARG:-$OUTDIR/filtered.mov}"
TIMES="1 3 5 7 9"
CHECKS="$HERE/checks"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

step "0/6 preflight"
for tool in ffmpeg ffprobe python3 swiftc; do
  command -v "$tool" >/dev/null || { say "missing required tool: $tool"; exit 1; }
done
python3 -c "import numpy" 2>/dev/null || { say "python3 needs numpy for the checks"; exit 1; }
say "tools: ffmpeg $(ffmpeg -version | head -1 | awk '{print $3}'), python3 $(python3 -c 'import sys;print(sys.version.split()[0])'), swiftc $(swiftc --version | head -1 | awk '{print $4}')"

step "1/6 build"
bash "$ROOT/build.sh"
DEFRINGE="$ROOT/defringe"

step "2/6 synthetic source"
if [ "$REGENERATE" = 1 ] || [ ! -f "$SOURCE" ]; then
  bash "$HERE/make_synthetic_source.sh" "$SOURCE" 10
else
  say "reusing $SOURCE (pass --regenerate to re-encode)"
fi

step "3/6 run defringe"
mkdir -p "$OUTDIR"
"$DEFRINGE" "$SOURCE" "$OUTPUT" 40 3 4 2>&1 | tee "$OUTDIR/run.log"

step "4/6 container contract"
SOURCE_INFO="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate,duration,nb_frames -of csv=p=0 "$SOURCE")"
OUTPUT_INFO="$(ffprobe -v error -select_streams v:0 -show_entries stream=profile,pix_fmt,color_space,color_range,width,height,avg_frame_rate,duration,nb_frames -of default=nw=1 "$OUTPUT")"
say "source (ffprobe csv width,height,fps,duration,frames):"
say "  $SOURCE_INFO"
say "output:"
printf '  %s\n' "$OUTPUT_INFO" | tr '\n' ' ' | sed 's/  */ /g'; say ""

CONTRACT_FAILURES=0
grep -q "^profile=Main 10$" <<<"$OUTPUT_INFO" || { say "FAIL: profile is not Main 10"; CONTRACT_FAILURES=$((CONTRACT_FAILURES+1)); }
grep -q "^pix_fmt=yuv420p10le$" <<<"$OUTPUT_INFO" || { say "FAIL: pix_fmt is not yuv420p10le"; CONTRACT_FAILURES=$((CONTRACT_FAILURES+1)); }
grep -q "^color_range=tv$" <<<"$OUTPUT_INFO" || { say "FAIL: color_range is not tv"; CONTRACT_FAILURES=$((CONTRACT_FAILURES+1)); }
grep -q "^color_space=bt709$" <<<"$OUTPUT_INFO" || { say "FAIL: color_space is not bt709"; CONTRACT_FAILURES=$((CONTRACT_FAILURES+1)); }
python3 - "$SOURCE" "$OUTPUT" <<'PY' || CONTRACT_FAILURES=$((CONTRACT_FAILURES+1))
import json, subprocess, sys

def probe(path):
    entries = "stream=width,height,avg_frame_rate,duration,nb_frames"
    raw = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", entries, "-of", "json", path],
                         check=True, stdout=subprocess.PIPE).stdout
    stream = json.loads(raw)["streams"][0]
    return (stream["width"], stream["height"], stream["avg_frame_rate"],
            stream["duration"], stream["nb_frames"])

source, output = probe(sys.argv[1]), probe(sys.argv[2])
ok = source == output
print("SUCCESS: output matches source on width/height/fps/duration/frames: %s" % (source,) if ok
      else "FAIL: source %s != output %s (width/height/fps/duration/frames)" % (source, output))
sys.exit(0 if ok else 1)
PY

python3 - "$OUTPUT" <<'PY' || CONTRACT_FAILURES=$((CONTRACT_FAILURES+1))
import os, sys
path = sys.argv[1]
size = os.path.getsize(path)
data = open(path, "rb").read()[-min(size, 80_000_000):]
counts = {name.decode(): data.count(name) for name in (b"tscl", b"tsas", b"sgpd", b"cslg")}
print("sample groups in the tail: %s" % counts)
ok = counts["tscl"] >= 1 and counts["tsas"] >= 1
print("SUCCESS: temporal sub-layer sample groups present (tscl/tsas)" if ok
      else "FAIL: tscl/tsas missing — the lock-screen slow-motion ramp needs them")
sys.exit(0 if ok else 1)
PY
say "container contract failures: $CONTRACT_FAILURES"

step "5/6 frame alignment (luma MAD, zero shift vs best shift)"
python3 "$CHECKS/check_alignment.py" "$SOURCE" "$OUTPUT" $TIMES || CONTRACT_FAILURES=$((CONTRACT_FAILURES+1))

step "6/6 region chroma stats and amplified differences"
python3 "$CHECKS/region_stats.py" "$SOURCE" "$OUTPUT" $TIMES
python3 "$CHECKS/amplify_diff.py" "$SOURCE" "$OUTPUT" 5 "$OUTDIR"
# Tower rim / cable crop used by the visual comparisons: 4x zoom, neighbour
# scaling so the very artifacts being inspected are not smoothed away.
bash "$HERE/compare.sh" "$SOURCE" "$OUTPUT" 5 1300 380 200 660 "$OUTDIR" 4 tower
bash "$HERE/compare.sh" "$SOURCE" "$OUTPUT" 5 1600 340 1020 480 "$OUTDIR" 4 cables

say ""
if [ "$CONTRACT_FAILURES" -eq 0 ]; then
  say "== PASS: hard contract checks passed (see $OUTDIR for run.log and comparison images) =="
else
  say "== FAIL: $CONTRACT_FAILURES contract check group(s) failed =="
fi
exit "$CONTRACT_FAILURES"
