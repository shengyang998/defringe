#!/usr/bin/env bash
# Build the defringe binary from the single Swift source file.
#
# The deprecated-API warnings are expected: the synchronous AVFoundation
# accessors (asset.tracks, track.nominalFrameRate, ...) still work and keep the
# tool a single straightforward file.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O main.swift -o defringe
echo "built $(pwd)/defringe"
