#!/usr/bin/env python3
"""Colour-tag passthrough check.

The output must carry the source's colour primaries, transfer function and
YCbCr matrix; BT.709 is only a fallback for sources that do not say. The sRGB
aerials (filenames containing "_sRGB_", transfer iec61966-2-1) are the reason
this matters: an output wrongly retagged BT.709 renders about 10/255 off in
brightness through a colour-managed pipeline.

The second half measures that: source and output frames are interpreted with
**the source's** transfer function (the tags are asserted separately above) and
rendered to sRGB display codes. Code values must survive the re-encode, so the
delta stays at re-encode noise. The old hardcoded-BT.709 version failed here
too: VideoToolbox saw sRGB attachments on the pixel buffers next to a BT.709
session and actually converted the luma, so the output came out about 10/255
darker than the source (measured -8.8/255 on the synthetic scene).

Usage: check_color.py <source.mov> <output.mov> [times...]
"""
import json
import subprocess
import sys

import numpy as np

from common import grab_plane

DEFAULT_TIMES = [3.0, 7.0]
MAX_DISPLAY_DELTA = 1.0  # 8-bit code values


def stream_color(path):
    raw = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=color_range,color_space,color_transfer,color_primaries",
         "-of", "json", path],
        stdout=subprocess.PIPE, check=True).stdout
    stream = json.loads(raw)["streams"][0]
    return {key: stream.get(key, "unknown")
            for key in ("color_range", "color_space", "color_transfer", "color_primaries")}


def normalize(tag):
    if tag in ("iec61966-2-1", "srgb", "IEC_sRGB"):
        return "srgb"
    if tag in ("bt709", "ITU_R_709_2"):
        return "bt709"
    if tag in (None, "unknown", "unspecified"):
        return None
    return tag


def eotf(values, transfer):
    values = np.clip(values, 0.0, 1.0)
    if transfer == "srgb":
        return np.where(values <= 0.04045, values / 12.92, ((values + 0.055) / 1.055) ** 2.4)
    return np.where(values < 0.081, values / 4.5, ((values + 0.099) / 1.099) ** (1.0 / 0.45))


def srgb_oetf(values):
    values = np.clip(values, 0.0, 1.0)
    return np.where(values <= 0.0031308, values * 12.92,
                    1.055 * values ** (1.0 / 2.4) - 0.055)


def display_luma_mean(path, time_seconds, transfer):
    """Mean sRGB display code of the frame, linearised with the given transfer."""
    y = grab_plane(path, time_seconds, "y").astype(np.float32)
    u = np.repeat(np.repeat(grab_plane(path, time_seconds, "u").astype(np.float32), 2, 0), 2, 1)
    v = np.repeat(np.repeat(grab_plane(path, time_seconds, "v").astype(np.float32), 2, 0), 2, 1)
    yp = (y - 64.0) / 876.0  # 10-bit tv range
    cb = (u - 512.0) / 896.0
    cr = (v - 512.0) / 896.0
    red = eotf(yp + 1.5748 * cr, transfer)
    green = eotf(yp - 0.1873 * cb - 0.4681 * cr, transfer)
    blue = eotf(yp + 1.8556 * cb, transfer)
    linear_luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    return float(255.0 * srgb_oetf(linear_luma).mean())


def main(source, output, times):
    source_tags = stream_color(source)
    output_tags = stream_color(output)

    failures = 0
    expected = {}
    for key, label in (("color_primaries", "primaries"),
                       ("color_transfer", "transfer"),
                       ("color_space", "matrix")):
        want = normalize(source_tags[key]) or "bt709"
        got = normalize(output_tags[key])
        expected[key] = want
        status = "ok" if got == want else "MISMATCH"
        if got != want:
            failures += 1
        print("%-9s source=%-12s expected=%-6s output=%-10s %s"
              % (label, source_tags[key], want, output_tags[key], status))

    transfer = normalize(source_tags["color_transfer"]) or "bt709"
    worst = 0.0
    for time_seconds in times:
        source_mean = display_luma_mean(source, time_seconds, transfer)
        output_mean = display_luma_mean(output, time_seconds, transfer)
        delta = output_mean - source_mean
        worst = max(worst, abs(delta))
        print("t=%.1fs code-value delta under the source transfer (output - source): %+.3f/255"
              % (time_seconds, delta))
    if worst > MAX_DISPLAY_DELTA:
        print("FAIL: output differs by %.3f/255 (limit %.1f) — the colour either was "
              "converted or is interpreted differently" % (worst, MAX_DISPLAY_DELTA))
        failures += 1
    else:
        print("SUCCESS: output code values match the source within %.3f/255" % worst)

    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    times = [float(value) for value in sys.argv[3:]] or DEFAULT_TIMES
    raise SystemExit(main(sys.argv[1], sys.argv[2], times))
