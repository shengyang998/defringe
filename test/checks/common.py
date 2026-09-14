"""Shared helpers for the defringe checks: frame/plane extraction via ffmpeg.

Only ffmpeg, ffprobe and the Python standard library (plus numpy, which the
scene generator already needs) are used — no virtualenv, no pip install.
"""
import subprocess

import numpy as np

WIDTH, HEIGHT = 4096, 2160
CHROMA_WIDTH, CHROMA_HEIGHT = WIDTH // 2, HEIGHT // 2


def _run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise RuntimeError("%s failed:\n%s" % (" ".join(args), result.stderr.decode()))
    return result.stdout


def grab_plane(path, time_seconds, plane):
    """Return a plane of the frame at time_seconds as 10-bit code values.

    ffmpeg's yuv420p10le stores each 10-bit code in a 16-bit little-endian word
    (LSB-aligned), unlike CVPixelBuffer, which left-aligns it. The checks all
    work in 10-bit code units, so no shifting happens here.
    """
    raw = _run([
        "ffmpeg", "-v", "error", "-ss", "%.6f" % time_seconds, "-i", path,
        "-frames:v", "1", "-vf", "format=yuv420p10le,extractplanes=%s" % plane,
        "-f", "rawvideo", "-",
    ])
    values = np.frombuffer(raw, dtype="<u2")
    width, height = (WIDTH, HEIGHT) if plane == "y" else (CHROMA_WIDTH, CHROMA_HEIGHT)
    if values.size != width * height:
        raise RuntimeError("unexpected %s plane size: %d values for %dx%d" % (plane, values.size, width, height))
    return values.reshape(height, width).astype(np.int32)


def grab_gray(path, time_seconds):
    """Return the frame at time_seconds as 8-bit gray (luma-derived)."""
    raw = _run([
        "ffmpeg", "-v", "error", "-ss", "%.6f" % time_seconds, "-i", path,
        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ])
    if len(raw) != WIDTH * HEIGHT:
        raise RuntimeError("unexpected gray frame size: %d bytes" % len(raw))
    return np.frombuffer(raw, dtype=np.uint8).reshape(HEIGHT, WIDTH).astype(np.float32)
