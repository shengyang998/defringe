#!/usr/bin/env python3
"""Frame alignment: source and output must show the same picture at the same
timestamp (the filter must not move or retime anything).

Reports the gray MAD at zero shift and the best (dx, dy) over +/-20 pixels.

Usage: check_alignment.py <source.mov> <output.mov> [times...]
"""
import sys

import numpy as np

from common import grab_gray

SEARCH_RADIUS = 20
COARSE_STEP = 4


def mad(a, b):
    return float(np.mean(np.abs(a - b)))


def shifted_mad(a, b, dx, dy):
    """MAD over the overlap after shifting b by (dx, dy)."""
    height, width = a.shape
    ax0, ax1 = max(0, -dx), width - max(0, dx)
    ay0, ay1 = max(0, -dy), height - max(0, dy)
    bx0, bx1 = max(0, dx), width - max(0, -dx)
    by0, by1 = max(0, dy), height - max(0, -dy)
    return mad(a[ay0:ay1, ax0:ax1], b[by0:by1, bx0:bx1])


def best_shift(a, b):
    best = (0, 0, shifted_mad(a, b, 0, 0))
    for dy in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1, COARSE_STEP):
        for dx in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1, COARSE_STEP):
            value = shifted_mad(a, b, dx, dy)
            if value < best[2]:
                best = (dx, dy, value)
    for dy in range(best[1] - COARSE_STEP + 1, best[1] + COARSE_STEP):
        for dx in range(best[0] - COARSE_STEP + 1, best[0] + COARSE_STEP):
            value = shifted_mad(a, b, dx, dy)
            if value < best[2]:
                best = (dx, dy, value)
    return best


def main(source, output, times):
    worst_zero = 0.0
    misaligned = []
    print("%8s %10s %12s %12s" % ("time(s)", "zero MAD", "best dx,dy", "best MAD"))
    for time_seconds in times:
        a = grab_gray(source, time_seconds)
        b = grab_gray(output, time_seconds)
        zero = mad(a, b)
        dx, dy, best = best_shift(a, b)
        worst_zero = max(worst_zero, zero)
        if (dx, dy) != (0, 0):
            misaligned.append((time_seconds, dx, dy))
        print("%8.3f %10.3f %12s %12.3f" % (time_seconds, zero, "(%d, %d)" % (dx, dy), best))
    print("worst zero-shift MAD: %.3f/255 (contract: <= 1.0, best shift must be (0, 0))" % worst_zero)
    if misaligned:
        print("FAIL: nonzero best shift at %s" % (misaligned,))
        return 1
    return 0 if worst_zero <= 1.0 else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    times = [float(value) for value in sys.argv[3:]] or [1.0, 3.0, 5.0, 7.0, 9.0]
    raise SystemExit(main(sys.argv[1], sys.argv[2], times))
