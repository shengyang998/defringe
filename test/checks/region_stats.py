#!/usr/bin/env python3
"""Per-region chroma statistics for the synthetic test scene.

For every region reports the mean Cb/Cr in 10-bit code units (source vs output,
plus the delta) and the chroma high-frequency energy measured as the mean
absolute deviation from a 3x3 box mean, also in 10-bit code units.

The high-frequency column is deliberately NOT a "was the fringe removed" score:
it counts the real colour of thin structures as high frequency too. Use it only
to see that the guided filter preserved structure (stays near the source) and
that smooth regions moved by less than a code or two.

Usage: region_stats.py <source.mov> <output.mov> [times...]
"""
import sys

import numpy as np

from common import grab_plane

# x0, y0, x1, y1 in the 4096x2160 frame. Sized so the +/-24 px pan never walks
# the feature out of its region.
REGIONS = {
    "sky": (200, 80, 1200, 300),
    "tower": (1300, 380, 1420, 1040),
    "cables": (1600, 340, 2620, 820),
    "water": (2600, 1500, 3900, 2100),
    "deck": (300, 1095, 1200, 1185),
}


def box3x3_mean(values):
    padded = np.pad(values, 1, mode="edge")
    return (padded[:-2, :-2] + padded[:-2, 1:-1] + padded[:-2, 2:]
            + padded[1:-1, :-2] + padded[1:-1, 1:-1] + padded[1:-1, 2:]
            + padded[2:, :-2] + padded[2:, 1:-1] + padded[2:, 2:]) / 9.0


def high_frequency_energy(plane, region):
    x0, y0, x1, y1 = region
    crop = plane[y0:y1, x0:x1].astype(np.float32)
    return float(np.mean(np.abs(crop - box3x3_mean(crop))))


def chroma_region(region):
    """Luma-space region -> chroma-plane coordinates (4:2:0 halves both axes)."""
    x0, y0, x1, y1 = region
    return (x0 // 2, y0 // 2, x1 // 2, y1 // 2)


def main(source, output, times):
    stats = {name: {"u_src": [], "u_out": [], "v_src": [], "v_out": [],
                    "hfu_src": [], "hfu_out": [], "hfv_src": [], "hfv_out": []}
             for name in REGIONS}

    for time_seconds in times:
        source_u = grab_plane(source, time_seconds, "u")
        source_v = grab_plane(source, time_seconds, "v")
        output_u = grab_plane(output, time_seconds, "u")
        output_v = grab_plane(output, time_seconds, "v")
        for name, region in REGIONS.items():
            chroma = chroma_region(region)
            x0, y0, x1, y1 = chroma
            entry = stats[name]
            entry["u_src"].append(source_u[y0:y1, x0:x1].mean())
            entry["u_out"].append(output_u[y0:y1, x0:x1].mean())
            entry["v_src"].append(source_v[y0:y1, x0:x1].mean())
            entry["v_out"].append(output_v[y0:y1, x0:x1].mean())
            entry["hfu_src"].append(high_frequency_energy(source_u, chroma))
            entry["hfu_out"].append(high_frequency_energy(output_u, chroma))
            entry["hfv_src"].append(high_frequency_energy(source_v, chroma))
            entry["hfv_out"].append(high_frequency_energy(output_v, chroma))

    print("%-7s %8s %8s %7s %8s %8s %7s | %7s %7s %7s %7s"
          % ("region", "U src", "U out", "dU", "V src", "V out", "dV",
             "hfU src", "hfU out", "hfV src", "hfV out"))
    for name in REGIONS:
        entry = stats[name]
        u_src = float(np.mean(entry["u_src"]))
        u_out = float(np.mean(entry["u_out"]))
        v_src = float(np.mean(entry["v_src"]))
        v_out = float(np.mean(entry["v_out"]))
        print("%-7s %8.2f %8.2f %7.2f %8.2f %8.2f %7.2f | %7.2f %7.2f %7.2f %7.2f"
              % (name, u_src, u_out, u_out - u_src, v_src, v_out, v_out - v_src,
                 float(np.mean(entry["hfu_src"])), float(np.mean(entry["hfu_out"])),
                 float(np.mean(entry["hfv_src"])), float(np.mean(entry["hfv_out"]))))
    print("(all values are 10-bit code units; mean of %d frames)" % len(times))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    times = [float(value) for value in sys.argv[3:]] or [1.0, 3.0, 5.0, 7.0, 9.0]
    raise SystemExit(main(sys.argv[1], sys.argv[2], times))
