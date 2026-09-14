#!/usr/bin/env python3
"""Render one still of the synthetic aerial-like test scene used by
make_synthetic_source.sh.

Real aerial wallpapers cannot be redistributed, and this machine has none
installed, so the tests run on a stand-in built from the things that make the
originals hard: a smooth sky gradient, water, a bridge deck and tower, thin
1-2 px cables and a coloured rim on the tower. Encoded at a low bit rate the
thin structures leave exactly the 4:2:0 chroma ringing the filter removes.

The output is a binary PPM (P6). The canvas is 4160x2224, i.e. slightly larger
than the 4096x2160 the encoder crops from it, so the pan below produces genuine
per-frame motion instead of a frozen still.

Usage: make_scene.py <out.ppm>
"""
import sys

import numpy as np

WIDTH, HEIGHT = 4160, 2224
HORIZON = 1150.0


def draw_segment(image, x0, y0, x1, y1, color, half_width=1.0):
    """Draw a hard-edged line segment into image (in place)."""
    margin = 6
    xa = max(0, int(min(x0, x1)) - margin)
    xb = min(WIDTH, int(max(x0, x1)) + margin + 1)
    ya = max(0, int(min(y0, y1)) - margin)
    yb = min(HEIGHT, int(max(y0, y1)) + margin + 1)
    if xa >= xb or ya >= yb:
        return
    dx, dy = x1 - x0, y1 - y0
    length_squared = dx * dx + dy * dy
    xs = np.arange(xa, xb, dtype=np.float32)[None, :]
    ys = np.arange(ya, yb, dtype=np.float32)[:, None]
    px = xs - x0
    py = ys - y0
    t = np.clip((px * dx + py * dy) / length_squared, 0.0, 1.0)
    distance_squared = (px - t * dx) ** 2 + (py - t * dy) ** 2
    image[ya:yb, xa:xb][distance_squared <= half_width * half_width] = color


def main(path):
    ys = np.arange(HEIGHT, dtype=np.float32)[:, None]
    xs = np.arange(WIDTH, dtype=np.float32)[None, :]
    image = np.empty((HEIGHT, WIDTH, 3), np.float32)

    # Sky: light blue at the top fading to haze at the horizon.
    t = np.clip(ys / HORIZON, 0.0, 1.0)
    sky_top = np.array([96.0, 158.0, 232.0], np.float32)
    sky_bottom = np.array([214.0, 229.0, 240.0], np.float32)
    sky = sky_top[None, None, :] + (sky_bottom - sky_top)[None, None, :] * t[:, :, None]
    sky = sky + (6.0 * np.sin(xs / 640.0))[:, :, None]
    image[:] = sky

    # Distant mountains just above the horizon.
    ridge = HORIZON - 250.0 + 92.0 * np.sin(xs / 380.0) + 38.0 * np.sin(xs / 97.0)
    mountain = (ys >= ridge) & (ys < HORIZON)
    mountain_color = np.array([62.0, 78.0, 104.0], np.float32)
    image[mountain] = mountain_color

    # Water: dark blue with fine ripples (high spatial frequency chroma).
    water_t = np.clip((ys - HORIZON) / (HEIGHT - HORIZON), 0.0, 1.0)
    water_top = np.array([86.0, 132.0, 168.0], np.float32)
    water_bottom = np.array([22.0, 48.0, 82.0], np.float32)
    water = water_top[None, None, :] + (water_bottom - water_top)[None, None, :] * water_t[:, :, None]
    ripple = 16.0 * np.sin(ys * 0.85 + 70.0 * np.sin(xs / 210.0)) * (0.35 + 0.65 * water_t)
    water = water + ripple[:, :, None] * np.array([0.7, 0.9, 1.1], np.float32)[None, None, :]
    water_mask = np.broadcast_to(ys > HORIZON, (HEIGHT, WIDTH))
    image[water_mask] = water[water_mask]

    # Bridge deck and shadowed underside.
    deck = (ys >= HORIZON - 60.0) & (ys <= HORIZON + 40.0)
    image[np.broadcast_to(deck, (HEIGHT, WIDTH))] = np.array([128.0, 130.0, 134.0], np.float32)
    underside = (ys > HORIZON + 40.0) & (ys <= HORIZON + 54.0)
    image[np.broadcast_to(underside, (HEIGHT, WIDTH))] = np.array([70.0, 70.0, 74.0], np.float32)

    # Tower: tapered concrete column with a cyan left rim and a magenta right
    # rim (the kind of thin coloured edge the original assets fringing appears
    # around). Body first, rims last so they survive the taper.
    tower_top, tower_bottom = 300.0, HORIZON - 34.0
    half = 44.0 - (ys - tower_top) * 0.012
    tower = (ys >= tower_top) & (ys <= tower_bottom) & (np.abs(xs - 1414.0) <= half)
    image[np.broadcast_to(tower, (HEIGHT, WIDTH))] = np.array([118.0, 120.0, 124.0], np.float32)
    left_rim = (ys >= tower_top) & (ys <= tower_bottom) & (np.abs(xs - (1414.0 - half)) <= 1.1)
    right_rim = (ys >= tower_top) & (ys <= tower_bottom) & (np.abs(xs - (1414.0 + half)) <= 1.1)
    image[np.broadcast_to(left_rim, (HEIGHT, WIDTH))] = np.array([70.0, 200.0, 216.0], np.float32)
    image[np.broadcast_to(right_rim, (HEIGHT, WIDTH))] = np.array([206.0, 74.0, 182.0], np.float32)

    # Main suspension cables sagging from the tower top to deck anchors, plus
    # thin vertical hangers. These are the 1-2 px structures whose chroma
    # ringing shows up as magenta/cyan outlines after a low-bit-rate encode.
    cable_color = np.array([176.0, 92.0, 84.0], np.float32)
    hanger_color = np.array([150.0, 84.0, 78.0], np.float32)
    for anchor_x in (140.0, 4020.0):
        segments = 48
        previous = None
        for step in range(segments + 1):
            s = step / segments
            x = 1414.0 + (anchor_x - 1414.0) * s
            y = tower_top + 30.0 + (HORIZON - tower_top - 64.0) * (s * s * 0.85 + 0.15 * s)
            if previous is not None:
                draw_segment(image, previous[0], previous[1], x, y, cable_color, 1.3)
            previous = (x, y)
    for hanger_x in range(200, 4020, 128):
        if abs(hanger_x - 1414) < 90:
            continue
        s = abs(hanger_x - 1414.0) / (4020.0 - 1414.0)
        cable_y = tower_top + 30.0 + (HORIZON - tower_top - 64.0) * (s * s * 0.85 + 0.15 * s)
        draw_segment(image, hanger_x, cable_y, hanger_x, HORIZON - 34.0, hanger_color, 0.7)

    with open(path, "wb") as handle:
        handle.write(b"P6\n%d %d\n255\n" % (WIDTH, HEIGHT))
        handle.write(np.clip(image, 0.0, 255.0).astype(np.uint8).tobytes())
    print("wrote %s (%dx%d)" % (path, WIDTH, HEIGHT))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "scene.ppm")
