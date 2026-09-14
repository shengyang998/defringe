#!/usr/bin/env python3
"""x10 amplified difference images between source and output.

Writing:
  diff_chroma_x10.ppm  brightness = 10 * max(|dCb|, |dCr|), 10-bit code units.
                       Smooth sky/water/deck must be black; only the structures
                       the filter acted on (fringes around edges, thin cables)
                       may light up.
  diff_luma_x10.ppm    brightness = 10 * |dY|. Near black everywhere: defringe
                       must not touch the luma plane (the small residue is the
                       40 Mbps re-encode of the same luma samples).

Side-by-side crops of the same gradient are an illusion machine: the seam
itself reads as a colour step. These difference maps are the honest check.

Usage: amplify_diff.py <source.mov> <output.mov> <time> <outdir>
"""
import os
import sys

import numpy as np

from common import HEIGHT, WIDTH, grab_plane


def write_ppm(path, gray):
    with open(path, "wb") as handle:
        handle.write(b"P6\n%d %d\n255\n" % (gray.shape[1], gray.shape[0]))
        handle.write(np.dstack([gray, gray, gray]).astype(np.uint8).tobytes())


def amplify(values, factor=10.0):
    return np.clip(values * factor, 0.0, 255.0).astype(np.uint8)


def main(source, output, time_seconds, outdir):
    os.makedirs(outdir, exist_ok=True)
    source_u = grab_plane(source, time_seconds, "u")
    source_v = grab_plane(source, time_seconds, "v")
    output_u = grab_plane(output, time_seconds, "u")
    output_v = grab_plane(output, time_seconds, "v")
    source_y = grab_plane(source, time_seconds, "y")
    output_y = grab_plane(output, time_seconds, "y")

    chroma = np.maximum(np.abs(output_u - source_u), np.abs(output_v - source_v))
    luma = np.abs(output_y - source_y)

    chroma_path = os.path.join(outdir, "diff_chroma_x10.ppm")
    luma_path = os.path.join(outdir, "diff_luma_x10.ppm")
    write_ppm(chroma_path, amplify(chroma))
    write_ppm(luma_path, amplify(luma))

    print("wrote %s (mean %.3f, p99 %.1f, max %d)" %
          (chroma_path, chroma.mean(), np.percentile(chroma, 99), chroma.max()))
    print("wrote %s (mean %.3f, max %d)" % (luma_path, luma.mean(), luma.max()))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    raise SystemExit(main(sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]))
