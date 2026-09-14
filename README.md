# defringe

Remove the purple/green chroma fringing from Apple's aerial (dynamic) wallpapers,
and re-encode the result so it can replace the system asset **in place** without
losing the lock-screen slow-motion ramp.

Single-file Swift command-line tool. No third-party dependencies (AVFoundation,
VideoToolbox, Metal, CoreVideo only).

## The problem

Apple's aerial assets are HEVC Main 10, 4:2:0, BT.709, tv range. Thin
structures — bridge cables, tower edges — occupy one or two chroma samples per
line, and the ringing a codec leaves around them survives chroma upsampling as
magenta/cyan outlines. The artifact is in the file, not in the display chain, so
different cables, colour profiles or display scaling cannot remove it.

See it directly: decode a frame, extract the U (Cb) plane
(`-vf "format=yuv420p10le,extractplanes=u"`), and look at a cable. Fine
light/dark ripples along it mean the ringing is in the chroma plane.

## What it does

One pass of a luma-guided joint bilateral filter, split into a horizontal and a
vertical run, applied to the chroma plane only. The weight of a neighbour is

    w(dx, dy) = spatial(dx, dy) * gauss(|Y(neighbour) - Y(centre)|)

with the luma guide built as a 2x2 average of the untouched luma plane on the
chroma grid. The luma plane is never modified, and the filter never iterates: a
second pass spreads already-neutralised samples outward and makes the remaining
fringes wider instead of smaller.

A plain chroma low-pass cannot do this — the ringing and the real colour of a
thin structure live at the same spatial frequency, so a Gaussian blurs the
cables grey. The luma guide is what separates them.

Backends:

* **Metal compute** (default): the shader is compiled at runtime; three
  dispatches per frame (build guide, horizontal pass, vertical pass), and the
  command buffer is waited on before the pixel buffer is handed to the encoder.
* **CPU** (fallback, or `DEFRINGE_FILTER=cpu`): row-parallel, with a 1024-entry
  lookup table for the range weights. The two backends agree to well under a
  code value (measured: mean < 0.7 of a 10-bit code, p99 = 4).

## Output contract

| item | required |
|---|---|
| codec | HEVC Main 10 (`kVTProfileLevel_HEVC_Main10_AutoLevel`) |
| pixel format | `yuv420p10le` (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`), tv range |
| frame rate & duration | identical to the source (aerial: 240 fps, whole frames) |
| temporal sub-layers | `tscl`/`tsas` sample groups present |
| colour tags | primaries / transfer function / YCbCr matrix copied from the source; BT.709 only when the source does not carry them |

**The temporal sub-layer requirement is the easy one to miss.** Apple's aerials
carry HEVC temporal sub-layers; the lock-screen slow-motion ramp uses them, and
an encode without them fails with
`WallpaperExtensionKit.VideoSampleReadingErrors Code=4` (noTemporalInfo) and
shows black.

That requirement decides the pipeline shape. `ffmpeg` (including
`hevc_videotoolbox`), `avconvert` and `x265` do not write those sample groups.
`defringe` therefore:

1. decodes through `AVAssetReader`, explicitly asking for
   `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`alwaysCopiesSampleData = false`);
2. filters the chroma plane of each decoded pixel buffer in place;
3. encodes with `VTCompressionSession` (hardware HEVC) with
   `kVTCompressionPropertyKey_AllowTemporalCompression = true` and
   `kVTCompressionPropertyKey_BaseLayerFrameRate = fps/2` (two layers),
   `RealTime = false`, `AllowFrameReordering = true`,
   `MaxKeyFrameInterval = 5*fps`, `AverageBitRate = bitrateMbps`;
4. hands the encoded samples to `AVAssetWriterInput(mediaType: .video,
   outputSettings: nil, sourceFormatHint: <VT's format description>)` — a
   passthrough, so the temporal-level attachments VT puts on the samples become
   the `tscl`/`tsas` sample groups;
5. caps in-flight frames to 12, because VT is asynchronous.

The writer input can only be created once the first frame has come back from VT
(the encoded format description does not exist before that), so it is created
lazily inside the encode callback; the writer is started and the session opened
at the first sample's presentation time. PTS and duration are passed through
untouched.

**Colour tags are passed through, not assumed.** The sRGB aerials (filenames
containing `_sRGB_`, `color_transfer=iec61966-2-1`) are the reason. With the
encoder session hardcoded to BT.709, VideoToolbox sees the sRGB attachments on
the decoded pixel buffers, converts the image to BT.709 and writes a BT.709
tag: a colour-managed pipeline then renders the result about 10/255 darker
than the original (measured −8.8/255, and the mean luma 30 codes of 1024 lower,
on the synthetic scene). `defringe` reads
`kCMFormatDescriptionExtension_ColorPrimaries`,
`kCMFormatDescriptionExtension_TransferFunction` and
`kCMFormatDescriptionExtension_YCbCrMatrix` from the source track and sets the
encoder to the same values; BT.709 is used only when the source says nothing.

One storage detail worth knowing if you touch the code:
`420YpCbCr10BiPlanarVideoRange` keeps the 10-bit code left-aligned in a 16-bit
container (code `<< 6`). Anything that needs a real luma value has to shift
right by 6 first; skipping that silently breaks the range-kernel scale and the
filter then does nothing useful.

## Build

    ./build.sh                    # or: swiftc -O main.swift -o defringe

The AVFoundation deprecation warnings are expected: the synchronous accessors
(`asset.tracks`, `track.nominalFrameRate`, …) still work and keep this a single
straightforward file.

## Usage

    defringe <in.mov> <out.mov> [bitrateMbps=40] [sigma=3.0] [rangeSigma=4.0]

* `bitrateMbps` — average bit rate of the output. Default 40 (a 5-minute 4K
  aerial is roughly 1.5 GB).
* `sigma` — spatial sigma of the bilateral kernel, in chroma samples
  (two luma pixels). Must be `> 0` and `<= 10`; radius is `round(3*sigma)`.
* `rangeSigma` — luma-difference sigma, in 8-bit luma units. Must be `> 0`.

Invalid values are rejected, not silently clamped. Logging: one line at start
(resolution / frame rate / frame count / bitrate / sigma / rangeSigma / backend),
one progress line per 30 seconds of source material (frames done/total, fps,
elapsed, eta), and a final line with elapsed time, throughput and file size.
Logs go to stdout, errors to stderr.

Environment: `DEFRINGE_FILTER=cpu|metal` forces a backend.

## Replacing a system wallpaper

Back up the original first; the manifest keeps pointing at the same path.

    AERIAL="$HOME/Library/Application Support/com.apple.wallpaper/aerials/videos/<uuid>.mov"
    cp "$AERIAL" "$AERIAL.original.mov"
    cp out.mov "$AERIAL"
    pkill WallpaperAgent

The asset is read when the wallpaper is (re)loaded; `pkill WallpaperAgent`
triggers that. Keep the backup until the lock-screen ramp has been checked —
`tscl`/`tsas` being present is currently the only offline proxy for it.

## Verification

`test/verify.sh` builds the tool, generates a synthetic 10-second stand-in
source, runs defringe and checks the whole contract. Real aerial assets cannot
be redistributed, so the source is a scene built from the same hard parts —
smooth sky and water, a deck, a tower with coloured rims, 1–2 px cables — and
encoded at a low bit rate to create the chroma ringing.

    test/verify.sh                 # reuse test/out/source.mov
    test/verify.sh --regenerate    # re-encode the source first
    test/verify_srgb.sh            # the same run on the sRGB-tagged source

The sRGB run is the regression test for the colour-tag passthrough: the source
is tagged `iec61966-2-1` with the `hevc_metadata` bitstream filter (applied
after the encode, because `hevc_videotoolbox` writes no transfer/primaries
VUI), and the output must keep that tag and the same code values.

What it checks:

* ffprobe contract fields, and identical width/height/fps/duration/frame count
  between source and output;
* `tscl`/`tsas`/`sgpd`/`cslg` sample groups in the output;
* frame alignment: gray MAD between source and output at zero shift, plus a
  search over ±20 px to prove zero really is the best shift;
* per-region chroma means and high-frequency energy (sky, tower, cables, water,
  deck);
* colour tags: the output must carry the source's primaries/transfer/matrix and
  its code values must survive the re-encode (no hidden transfer conversion);
* ×10 amplified difference maps: smooth regions must be black, only edges may
  light up;
* flip (0.6 s alternation) and stacked comparisons of crops.

Two measurement traps the checks deliberately avoid:

* **Side-by-side crops of the same gradient are an illusion machine** — the seam
  itself reads as a colour step. Use the flip GIF, the stacked crop whose seam
  crosses a feature, and the ×10 difference map (smooth regions must be pure
  black).
* **`ffmpeg -ss X -t Y -c copy` keeps the source's first-PTS offset**, so a
  10-second excerpt can report a duration slightly over 10 s and an odd
  `avg_frame_rate` (e.g. 24040/101). That is not a bug and must not be "fixed"
  in the tool; only a full-file run is exact.

Also note that aggregate "chroma high-frequency energy" counts the real colour
of thin structures as high frequency. It is useful for comparing against a plain
low-pass, but it is not a fringe-removal score.

## Measured

Apple M2 Pro, 32 GB, macOS 26.4.1, Xcode toolchain; 10 s synthetic
4096x2160@240 source. (The reference figures in the original brief were taken
on an M4 Pro, which reaches roughly 56 fps.)

| check | result |
|---|---|
| ffprobe | Main 10 / yuv420p10le / tv / bt709 / 4096x2160 / 240 fps / 10.000000 s / 2400 frames — identical to source |
| sample groups | `tscl` 2, `tsas` 2, `sgpd` 3, `cslg` 1 |
| frame alignment | worst zero-shift MAD 0.367/255; best shift (0, 0) at every sampled time |
| colour tags, untagged source | falls back to BT.709; code-value delta +0.014/255 |
| colour tags, sRGB source | output keeps `iec61966-2-1`; code-value delta +0.018/255 (pre-fix: retagged BT.709, −8.8/255 and mean luma 30/1024 lower) |
| sky ΔCb/ΔCr | −0.46 / −0.48 (10-bit codes) |
| tower ΔCb/ΔCr | −0.41 / −0.13 |
| cables ΔCb/ΔCr | −0.36 / −0.56 |
| water ΔCb/ΔCr | −0.23 / −0.52 |
| deck ΔCb/ΔCr | −0.24 / −0.45 |
| cable chroma high-frequency | source 1.79 / 2.57 → output 1.82 / 2.63 (structure preserved) |
| water chroma high-frequency | source 0.75 / 0.40 → output 0.31 / 0.19 (ripple ringing smoothed) |
| ×10 chroma difference | mean 1.27, p99 9, max 131 of 255; sky/deck essentially black |
| ×10 luma difference | mean 0.67, max 29 of 255 (re-encode residue; the luma plane is untouched) |
| throughput | **48.9 fps** end to end; filter 4.0–5.7 ms/frame |
| CPU fallback | ~27 ms/frame, ~36 fps end to end |

The hardware HEVC encoder on this M2 Pro tops out at ~48.6 fps for 4K input
(measured separately with `ffmpeg -c:v hevc_videotoolbox`), so at default
settings the filter is not the bottleneck — the encoder is.

Re-encoding adds a little of the ringing back; 40 Mbps is the default because it
keeps that below the original level at a reasonable file size. On this synthetic
content the hardware encoder undershoots the target (40 Mbps asked, ~33 Mbps
produced); real aerial footage lands closer to the target.

## Limits

* Video only: any audio track in the source is dropped (aerial assets have none).
* The whole file is decoded, filtered and re-encoded. Expect roughly one minute
  per minute of 4K/240 material on an M2 Pro.
* The filter is tuned for the aerial look (thin structures over smooth
  backgrounds); large flat chroma regions are left essentially untouched by
  design.

## License

MIT — see [LICENSE](LICENSE).
