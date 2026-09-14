// defringe — strip purple/green chroma fringing from Apple aerial wallpapers
// while preserving the encoding contract the wallpaper pipeline requires:
// HEVC Main 10, 4:2:0, 10-bit biplanar video range, BT.709, native frame rate,
// and — critically — the HEVC temporal sub-layer sample groups (tscl/tsas) that
// the lock-screen slow-motion ramp depends on.
//
// Build:  swiftc -O main.swift -o defringe
// Usage:  defringe <in.mov> <out.mov> [bitrateMbps=40] [sigma=3.0] [rangeSigma=4.0]
//
// The filter is a luma-guided joint bilateral (separable: one horizontal pass,
// one vertical pass, no iteration) that rewrites the chroma plane only. The
// luma plane is passed through bit for bit.
//
// Why the pipeline looks the way it does:
//   * ffmpeg / avconvert / x265 cannot produce the tscl/tsas sample groups, so
//     the only way to keep them is VTCompressionSession (hardware HEVC, with
//     kVTCompressionPropertyKey_AllowTemporalCompression) handing encoded
//     samples to AVAssetWriterInput with nil outputSettings (passthrough).
//     The writer then serialises the temporal-level attachments VT puts on the
//     samples into tscl/tsas sample groups.
//   * The writer input needs the *encoded* format description as
//     sourceFormatHint, which only exists after the first frame comes back from
//     VT, so the input is created lazily inside the VT callback.
//   * kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange stores 10-bit codes
//     left-aligned in 16-bit containers (code << 6). Anything that needs real
//     luma values shifts right by 6 first — skipping that silently breaks the
//     range-kernel scale and the filter does nothing useful.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

// MARK: - errors and logging

struct DefringeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func logLine(_ message: String) {
    print(message)
    fflush(stdout)
}

func logWarning(_ message: String) {
    logLine("defringe: warning: \(message)")
}

func formatSeconds(_ seconds: Double) -> String {
    if seconds.isFinite { return String(format: "%.1fs", seconds) }
    return "n/a"
}

// MARK: - options

struct Options {
    var input: URL
    var output: URL
    var bitrateMbps: Double = 40
    var sigma: Double = 3.0
    var rangeSigma: Double = 4.0
}

let usageText = """
usage: defringe <in.mov> <out.mov> [bitrateMbps=40] [sigma=3.0] [rangeSigma=4.0]

  bitrateMbps  average bit rate of the HEVC Main 10 output (default 40)
  sigma        spatial sigma of the bilateral kernel, in chroma samples
               (default 3.0; must be > 0 and <= 10)
  rangeSigma   luma-difference sigma of the bilateral kernel, in 8-bit luma
               units (default 4.0; must be > 0)
"""

func parseOptions(_ args: [String]) throws -> Options {
    guard args.count >= 2 && args.count <= 5 else {
        throw DefringeError("expected 2 to 5 arguments\n\n\(usageText)")
    }
    let input = URL(fileURLWithPath: args[0])
    let output = URL(fileURLWithPath: args[1])
    guard FileManager.default.fileExists(atPath: input.path) else {
        throw DefringeError("input not found: \(input.path)")
    }
    guard input.standardizedFileURL != output.standardizedFileURL else {
        throw DefringeError("input and output must be different files")
    }
    var options = Options(input: input, output: output)
    if args.count > 2 {
        guard let value = Double(args[2]), value > 0 else {
            throw DefringeError("bitrateMbps must be a positive number, got '\(args[2])'")
        }
        options.bitrateMbps = value
    }
    if args.count > 3 {
        guard let value = Double(args[3]), value > 0, value <= 10 else {
            throw DefringeError("sigma must be in (0, 10], got '\(args[3])'")
        }
        options.sigma = value
    }
    if args.count > 4 {
        guard let value = Double(args[4]), value > 0 else {
            throw DefringeError("rangeSigma must be > 0, got '\(args[4])'")
        }
        options.rangeSigma = value
    }
    return options
}

// MARK: - source probe

struct SourceInfo {
    var width: Int
    var height: Int
    var frameRate: Double
    var duration: CMTime
    var transform: CGAffineTransform
    var estimatedFrames: Int
    /// Colour tags from the source track's format description, passed through
    /// to the encoder so the output carries the same colour space. nil means
    /// the source does not say; BT.709 is used then.
    var colorPrimaries: String?
    var transferFunction: String?
    var yCbCrMatrix: String?
}

func probeSource(_ asset: AVAsset) throws -> (AVAssetTrack, SourceInfo) {
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw DefringeError("no video track in input")
    }
    guard let rawFormat = track.formatDescriptions.first else {
        throw DefringeError("video track has no format description")
    }
    let format = rawFormat as! CMVideoFormatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)

    // Carry the source's colour tags into the encode. Hardcoding BT.709 made
    // VideoToolbox convert the pixel data of sRGB aerials (filenames containing
    // "_sRGB_") from the buffers' colour space into BT.709: an extra
    // transfer-function round trip, and metadata that disagreed with the
    // source. (Comparing raw code values across two transfer tags exaggerates
    // that — ffmpeg converts the matrix but not the transfer curve; through the
    // system colour-management path old and new output are within 0.3/255. The
    // passthrough is about skipping the round trip and keeping the metadata
    // identical, not about a visible brightness bug.)
    let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
    let colorPrimaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
    let transferFunction = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
    let yCbCrMatrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String

    var frameRate = Double(track.nominalFrameRate)
    if !(frameRate > 0) {
        let minFrameDuration = track.minFrameDuration
        if minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            frameRate = 1.0 / minFrameDuration.seconds
        }
    }
    guard frameRate > 0, frameRate <= 1000 else {
        throw DefringeError("cannot determine the source frame rate")
    }

    let duration = asset.duration
    let estimatedFrames = Int((duration.seconds * frameRate).rounded())

    let info = SourceInfo(
        width: Int(dimensions.width),
        height: Int(dimensions.height),
        frameRate: frameRate,
        duration: duration,
        transform: track.preferredTransform,
        estimatedFrames: estimatedFrames,
        colorPrimaries: colorPrimaries,
        transferFunction: transferFunction,
        yCbCrMatrix: yCbCrMatrix
    )
    return (track, info)
}

// MARK: - chroma filters

protocol ChromaFilter: AnyObject {
    var name: String { get }
    /// Rewrites plane 1 (CbCr) guided by plane 0 (luma). Plane 0 must not change.
    func apply(to pixelBuffer: CVPixelBuffer) throws
}

/// Plain-CPU fallback, used only when Metal is unavailable (or forced with
/// DEFRINGE_FILTER=cpu). Range weights come from a 1024-entry LUT indexed by the
/// absolute 10-bit luma difference, which replaces one exp() per tap and keeps
/// this within a few times of the GPU regardless of sigma. Same taps and weights
/// as the kernels, so both backends agree numerically.
final class CPUChromaFilter: ChromaFilter {
    let name = "cpu"

    private let radius: Int
    private let spatial: [Float]
    private let rangeLUT: [Float]
    private var guide: [Int16] = []
    private var midCb: [Float] = []
    private var midCr: [Float] = []

    init(sigma: Double, rangeSigma: Double) {
        self.radius = Int((3.0 * sigma).rounded())
        var weights = [Float](repeating: 0, count: 2 * self.radius + 1)
        for i in -self.radius...self.radius {
            weights[i + self.radius] = Float(exp(-Double(i * i) / (2.0 * sigma * sigma)))
        }
        self.spatial = weights
        var lut = [Float](repeating: 0, count: 1024)
        for difference in 0..<1024 {
            let eightBitDifference = Double(difference) * 0.25
            lut[difference] = Float(exp(-(eightBitDifference * eightBitDifference) / (2.0 * rangeSigma * rangeSigma)))
        }
        self.rangeLUT = lut
    }

    func apply(to pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw DefringeError("CVPixelBufferLockBaseAddress failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2
        guard let lumaRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw DefringeError("pixel buffer has no plane 0/1")
        }
        let luma = lumaRaw.assumingMemoryBound(to: UInt16.self)
        let chroma = chromaRaw.assumingMemoryBound(to: UInt16.self)

        let count = chromaWidth * chromaHeight
        if guide.count != count {
            guide = [Int16](repeating: 0, count: count)
            midCb = [Float](repeating: 0, count: count)
            midCr = [Float](repeating: 0, count: count)
        }

        let radius = self.radius
        let spatial = self.spatial
        let rangeLUT = self.rangeLUT

        guide.withUnsafeMutableBufferPointer { guideBuffer in
            midCb.withUnsafeMutableBufferPointer { midCbBuffer in
                midCr.withUnsafeMutableBufferPointer { midCrBuffer in
                    let guidePointer = guideBuffer.baseAddress!
                    let midCbPointer = midCbBuffer.baseAddress!
                    let midCrPointer = midCrBuffer.baseAddress!

                    // Guide: 2x2 average of 10-bit luma on the chroma grid.
                    DispatchQueue.concurrentPerform(iterations: chromaHeight) { y in
                        let row0 = luma + (2 * y) * lumaStride
                        let row1 = luma + (2 * y + 1) * lumaStride
                        let out = guidePointer + y * chromaWidth
                        for x in 0..<chromaWidth {
                            let x0 = 2 * x
                            let x1 = min(x0 + 1, lumaStride - 1)
                            let sum = Int(row0[x0] >> 6) + Int(row0[x1] >> 6)
                                    + Int(row1[x0] >> 6) + Int(row1[x1] >> 6)
                            out[x] = Int16(sum >> 2)
                        }
                    }

                    // Horizontal pass: chroma + guide -> midpoint buffers.
                    DispatchQueue.concurrentPerform(iterations: chromaHeight) { y in
                        let chromaRow = chroma + y * chromaStride
                        let guideRow = guidePointer + y * chromaWidth
                        let outCb = midCbPointer + y * chromaWidth
                        let outCr = midCrPointer + y * chromaWidth
                        for x in 0..<chromaWidth {
                            let g0 = Int(guideRow[x])
                            var sumCb: Float = 0
                            var sumCr: Float = 0
                            var sumWeight: Float = 0
                            for i in -radius...radius {
                                let sx = min(max(x + i, 0), chromaWidth - 1)
                                let range = rangeLUT[abs(Int(guideRow[sx]) - g0)]
                                let weight = spatial[i + radius] * range
                                sumCb += Float(chromaRow[sx * 2] >> 6) * weight
                                sumCr += Float(chromaRow[sx * 2 + 1] >> 6) * weight
                                sumWeight += weight
                            }
                            outCb[x] = sumCb / sumWeight
                            outCr[x] = sumCr / sumWeight
                        }
                    }

                    // Vertical pass: midpoint buffers + guide -> plane 1.
                    DispatchQueue.concurrentPerform(iterations: chromaHeight) { y in
                        let guideRow = guidePointer + y * chromaWidth
                        let chromaRow = chroma + y * chromaStride
                        for x in 0..<chromaWidth {
                            let g0 = Int(guideRow[x])
                            var sumCb: Float = 0
                            var sumCr: Float = 0
                            var sumWeight: Float = 0
                            for i in -radius...radius {
                                let sy = min(max(y + i, 0), chromaHeight - 1)
                                let index = sy * chromaWidth + x
                                let range = rangeLUT[abs(Int(guidePointer[index]) - g0)]
                                let weight = spatial[i + radius] * range
                                sumCb += midCbPointer[index] * weight
                                sumCr += midCrPointer[index] * weight
                                sumWeight += weight
                            }
                            let cb = min(max(sumCb / sumWeight, 0), 1023)
                            let cr = min(max(sumCr / sumWeight, 0), 1023)
                            chromaRow[x * 2] = UInt16(cb.rounded()) << 6
                            chromaRow[x * 2 + 1] = UInt16(cr.rounded()) << 6
                        }
                    }
                }
            }
        }
    }
}

/// Metal compute implementation: the one that has to be fast. Three dispatches
/// per frame (build guide -> horizontal -> vertical), synchronous wait so the
/// encoder observes the written chroma.
final class MetalChromaFilter: ChromaFilter {
    let name = "metal"

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void build_guide(texture2d<float, access::read> luma [[texture(0)]],
                            texture2d<float, access::write> guide [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint lw = luma.get_width();
        uint lh = luma.get_height();
        uint2 p = gid * 2u;
        uint2 q = uint2(min(p.x + 1u, lw - 1u), min(p.y + 1u, lh - 1u));
        float sum = luma.read(uint2(p.x, p.y)).r
                  + luma.read(uint2(q.x, p.y)).r
                  + luma.read(uint2(p.x, q.y)).r
                  + luma.read(q).r;
        guide.write(sum * 0.25f, gid);
    }

    kernel void bilateral_h(texture2d<float, access::read> guide [[texture(0)]],
                            texture2d<float, access::read> chroma [[texture(1)]],
                            texture2d<float, access::write> outTex [[texture(2)]],
                            constant float *spatial [[buffer(0)]],
                            constant float &rangeScale [[buffer(1)]],
                            constant int &radius [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = int(chroma.get_width());
        float g0 = guide.read(gid).r;
        float2 sum = 0.0f;
        float weightSum = 0.0f;
        for (int i = -radius; i <= radius; ++i) {
            int x = clamp(int(gid.x) + i, 0, w - 1);
            uint2 q = uint2(uint(x), gid.y);
            float d = (guide.read(q).r - g0) * rangeScale;
            float weight = spatial[i + radius] * fast::exp(-0.5f * d * d);
            sum += chroma.read(q).rg * weight;
            weightSum += weight;
        }
        outTex.write(float4(sum / weightSum, 0.0f, 1.0f), gid);
    }

    kernel void bilateral_v(texture2d<float, access::read> guide [[texture(0)]],
                            texture2d<float, access::read> midTex [[texture(1)]],
                            texture2d<float, access::write> chromaOut [[texture(2)]],
                            constant float *spatial [[buffer(0)]],
                            constant float &rangeScale [[buffer(1)]],
                            constant int &radius [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int h = int(midTex.get_height());
        float g0 = guide.read(gid).r;
        float2 sum = 0.0f;
        float weightSum = 0.0f;
        for (int i = -radius; i <= radius; ++i) {
            int y = clamp(int(gid.y) + i, 0, h - 1);
            uint2 q = uint2(gid.x, uint(y));
            float d = (guide.read(q).r - g0) * rangeScale;
            float weight = spatial[i + radius] * fast::exp(-0.5f * d * d);
            sum += midTex.read(q).rg * weight;
            weightSum += weight;
        }
        chromaOut.write(float4(sum / weightSum, 0.0f, 1.0f), gid);
    }
    """

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let guidePipeline: MTLComputePipelineState
    private let horizontalPipeline: MTLComputePipelineState
    private let verticalPipeline: MTLComputePipelineState

    private let radius: Int
    private let spatial: [Float]
    private let rangeScale: Float

    private var guideTexture: MTLTexture?
    private var midTexture: MTLTexture?

    init(device: MTLDevice, sigma: Double, rangeSigma: Double) throws {
        guard let queue = device.makeCommandQueue() else {
            throw DefringeError("Metal: cannot create a command queue")
        }
        self.device = device
        self.commandQueue = queue
        self.radius = Int((3.0 * sigma).rounded())
        var weights = [Float](repeating: 0, count: 2 * self.radius + 1)
        for i in -self.radius...self.radius {
            weights[i + self.radius] = Float(exp(-Double(i * i) / (2.0 * sigma * sigma)))
        }
        self.spatial = weights
        // plane 0 is 10-bit left-aligned in 16 bits: value/65535 = code/1023.98,
        // so a code difference of 1 is ~1/1024 here, and 8-bit luma is code/4.
        self.rangeScale = Float(1024.0 / 4.0 / rangeSigma)

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalChromaFilter.shaderSource, options: nil)
        } catch {
            throw DefringeError("Metal: shader compilation failed: \(error)")
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw DefringeError("Metal: missing kernel \(name)")
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.guidePipeline = try pipeline("build_guide")
        self.horizontalPipeline = try pipeline("bilateral_h")
        self.verticalPipeline = try pipeline("bilateral_v")

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let created = cache else {
            throw DefringeError("Metal: CVMetalTextureCacheCreate failed (\(cacheStatus))")
        }
        self.textureCache = created
    }

    func apply(to pixelBuffer: CVPixelBuffer) throws {
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        try ensurePrivateTextures(width: chromaWidth, height: chromaHeight)

        let usage: [String: Any] = [
            kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        ]
        let (lumaHolder, lumaTexture) = try makeTexture(from: pixelBuffer, plane: 0,
                                                         format: .r16Unorm,
                                                         width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                                                         height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                                                         attributes: usage)
        let (chromaHolder, chromaTexture) = try makeTexture(from: pixelBuffer, plane: 1,
                                                             format: .rg16Unorm,
                                                             width: chromaWidth,
                                                             height: chromaHeight,
                                                             attributes: usage)

        guard let guideTexture = guideTexture, let midTexture = midTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DefringeError("Metal: cannot create a command buffer")
        }

        let grid = MTLSize(width: chromaWidth, height: chromaHeight, depth: 1)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)

        // 1. Downsample luma to the chroma grid, in 10-bit code units.
        guard let guideEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DefringeError("Metal: cannot create a compute encoder")
        }
        guideEncoder.setComputePipelineState(guidePipeline)
        guideEncoder.setTexture(lumaTexture, index: 0)
        guideEncoder.setTexture(guideTexture, index: 1)
        guideEncoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        guideEncoder.endEncoding()

        // 2. Horizontal bilateral pass into the private midpoint texture.
        try encodeBilateral(into: commandBuffer, pipeline: horizontalPipeline,
                            guide: guideTexture, source: chromaTexture, destination: midTexture,
                            grid: grid, threadsPerGroup: threadsPerGroup)

        // 3. Vertical bilateral pass back into plane 1.
        try encodeBilateral(into: commandBuffer, pipeline: verticalPipeline,
                            guide: guideTexture, source: midTexture, destination: chromaTexture,
                            grid: grid, threadsPerGroup: threadsPerGroup)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The textures are owned by their CVMetalTexture wrappers; keep both
        // alive until the GPU has definitely finished reading them.
        withExtendedLifetime(lumaHolder) {}
        withExtendedLifetime(chromaHolder) {}
        if let error = commandBuffer.error {
            throw DefringeError("Metal: command buffer failed: \(error)")
        }
    }

    private func encodeBilateral(into commandBuffer: MTLCommandBuffer,
                                 pipeline: MTLComputePipelineState,
                                 guide: MTLTexture,
                                 source: MTLTexture,
                                 destination: MTLTexture,
                                 grid: MTLSize,
                                 threadsPerGroup: MTLSize) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DefringeError("Metal: cannot create a compute encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(guide, index: 0)
        encoder.setTexture(source, index: 1)
        encoder.setTexture(destination, index: 2)
        spatial.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        var radiusValue = Int32(radius)
        var rangeScaleValue = rangeScale
        encoder.setBytes(&rangeScaleValue, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&radiusValue, length: MemoryLayout<Int32>.size, index: 2)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    private func ensurePrivateTextures(width: Int, height: Int) throws {
        func texture(_ format: MTLPixelFormat, _ existing: MTLTexture?) throws -> MTLTexture {
            if let existing, existing.width == width, existing.height == height { return existing }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let created = device.makeTexture(descriptor: descriptor) else {
                throw DefringeError("Metal: cannot allocate a private texture")
            }
            return created
        }
        guideTexture = try texture(.r32Float, guideTexture)
        midTexture = try texture(.rg16Unorm, midTexture)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer,
                             plane: Int,
                             format: MTLPixelFormat,
                             width: Int,
                             height: Int,
                             attributes: [String: Any]) throws -> (CVMetalTexture, MTLTexture) {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, attributes as CFDictionary,
            format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw DefringeError("Metal: cannot wrap pixel buffer plane \(plane) (status \(status))")
        }
        return (cvTexture, texture)
    }
}

func makeChromaFilter(sigma: Double, rangeSigma: Double) -> ChromaFilter {
    let forced = ProcessInfo.processInfo.environment["DEFRINGE_FILTER"]?.lowercased()
    if forced == "cpu" {
        return CPUChromaFilter(sigma: sigma, rangeSigma: rangeSigma)
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
        logWarning("no Metal device; using the CPU fallback (slow)")
        return CPUChromaFilter(sigma: sigma, rangeSigma: rangeSigma)
    }
    do {
        return try MetalChromaFilter(device: device, sigma: sigma, rangeSigma: rangeSigma)
    } catch {
        logWarning("Metal filter unavailable (\(error)); using the CPU fallback (slow)")
        return CPUChromaFilter(sigma: sigma, rangeSigma: rangeSigma)
    }
}

// MARK: - HEVC writer (VT encode -> AVAssetWriter passthrough)

final class HEVCWriter {
    /// In-flight frames. VT is asynchronous; without a cap the reader can run
    /// tens of frames ahead of the encoder and blow up memory.
    static let maxInFlight = 12

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon = refcon else { return }
        let writer = Unmanaged<HEVCWriter>.fromOpaque(refcon).takeUnretainedValue()
        writer.didEncode(status: status, sampleBuffer: sampleBuffer)
    }

    private let outputURL: URL
    private let width: Int
    private let height: Int
    private let frameRate: Double
    private let bitrateMbps: Double
    private let transform: CGAffineTransform
    private let mediaTimeScale: CMTimeScale
    private let sourceColorPrimaries: String?
    private let sourceTransferFunction: String?
    private let sourceYCbCrMatrix: String?

    private let writer: AVAssetWriter
    private var session: VTCompressionSession?
    private var input: AVAssetWriterInput?

    private let condition = NSCondition()
    private var pendingFrames = 0
    private var encodedFrames = 0
    private var firstError: String?

    init(outputURL: URL,
         width: Int,
         height: Int,
         frameRate: Double,
         bitrateMbps: Double,
         transform: CGAffineTransform,
         colorPrimaries: String?,
         transferFunction: String?,
         yCbCrMatrix: String?) throws {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateMbps = bitrateMbps
        self.transform = transform
        self.mediaTimeScale = CMTimeScale(max(600.0, (frameRate * 100.0).rounded()))
        self.sourceColorPrimaries = colorPrimaries
        self.sourceTransferFunction = transferFunction
        self.sourceYCbCrMatrix = yCbCrMatrix

        try? FileManager.default.removeItem(at: outputURL)
        do {
            self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw DefringeError("cannot create output file: \(error)")
        }
    }

    var framesEncoded: Int {
        condition.lock()
        defer { condition.unlock() }
        return encodedFrames
    }

    func start() throws {
        let specification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]
        // Tell VT the buffers it receives are the 10-bit biplanar video-range
        // ones our reader produces (and our filter rewrites in place).
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: HEVCWriter.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            throw DefringeError("VTCompressionSessionCreate failed (\(status))")
        }
        self.session = session

        func setProperty(_ key: CFString, _ value: CFTypeRef, required: Bool, _ label: String) throws {
            let propertyStatus = VTSessionSetProperty(session, key: key, value: value)
            if propertyStatus != noErr {
                if required {
                    throw DefringeError("VideoToolbox rejected \(label) (\(propertyStatus))")
                }
                logWarning("VideoToolbox rejected \(label) (\(propertyStatus)); continuing")
            }
        }

        try setProperty(kVTCompressionPropertyKey_ProfileLevel,
                        kVTProfileLevel_HEVC_Main10_AutoLevel,
                        required: true, "profile level HEVC Main10")
        // The temporal sub-layers are the whole point: base layer at half the
        // frame rate gives the two-layer hierarchy Apple's aerial uses.
        try setProperty(kVTCompressionPropertyKey_AllowTemporalCompression,
                        kCFBooleanTrue, required: true, "AllowTemporalCompression")
        try setProperty(kVTCompressionPropertyKey_BaseLayerFrameRate,
                        NSNumber(value: frameRate / 2.0),
                        required: true, "BaseLayerFrameRate")
        try setProperty(kVTCompressionPropertyKey_AllowFrameReordering,
                        kCFBooleanTrue, required: false, "AllowFrameReordering")
        try setProperty(kVTCompressionPropertyKey_RealTime,
                        kCFBooleanFalse, required: false, "RealTime=false")
        try setProperty(kVTCompressionPropertyKey_ExpectedFrameRate,
                        NSNumber(value: frameRate), required: false, "ExpectedFrameRate")
        try setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval,
                        NSNumber(value: Int((frameRate * 5.0).rounded())),
                        required: false, "MaxKeyFrameInterval")
        try setProperty(kVTCompressionPropertyKey_AverageBitRate,
                        NSNumber(value: bitrateMbps * 1_000_000.0),
                        required: true, "AverageBitRate")
        // Colour: pass the source's tags through; fall back to BT.709 only when
        // the source does not carry them. This is what keeps sRGB aerials sRGB.
        let primaries = sourceColorPrimaries ?? (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        let transfer = sourceTransferFunction ?? (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        let matrix = sourceYCbCrMatrix ?? (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        try setProperty(kVTCompressionPropertyKey_ColorPrimaries, primaries as CFString,
                        required: false,
                        "ColorPrimaries \(primaries)\(sourceColorPrimaries == nil ? " (BT.709 fallback)" : "")")
        try setProperty(kVTCompressionPropertyKey_TransferFunction, transfer as CFString,
                        required: false,
                        "TransferFunction \(transfer)\(sourceTransferFunction == nil ? " (BT.709 fallback)" : "")")
        try setProperty(kVTCompressionPropertyKey_YCbCrMatrix, matrix as CFString,
                        required: false,
                        "YCbCrMatrix \(matrix)\(sourceYCbCrMatrix == nil ? " (BT.709 fallback)" : "")")

        VTCompressionSessionPrepareToEncodeFrames(session)

        if let hardware = copyBoolProperty(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) {
            logLine("defringe: video encoder: \(hardware ? "hardware HEVC" : "software HEVC")")
        }
    }

    private func copyBoolProperty(_ session: VTCompressionSession, _ key: CFString) -> Bool? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault,
                                  valueOut: UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    func append(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime) throws {
        condition.lock()
        while pendingFrames >= HEVCWriter.maxInFlight && firstError == nil {
            condition.wait()
        }
        if let error = firstError {
            condition.unlock()
            throw DefringeError(error)
        }
        pendingFrames += 1
        condition.unlock()

        let status = VTCompressionSessionEncodeFrame(
            session!,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            condition.lock()
            pendingFrames -= 1
            condition.broadcast()
            condition.unlock()
            throw DefringeError("VTCompressionSessionEncodeFrame failed (\(status))")
        }
    }

    private func didEncode(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        condition.lock()
        pendingFrames -= 1
        defer {
            condition.broadcast()
            condition.unlock()
        }
        if status != noErr {
            if firstError == nil { firstError = "VideoToolbox encode failed (\(status))" }
            return
        }
        guard let sampleBuffer = sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        do {
            try write(sampleBuffer)
            encodedFrames += 1
        } catch {
            if firstError == nil { firstError = "\(error)" }
        }
    }

    /// Creates the passthrough input from the first encoded sample's format
    /// description. With nil outputSettings AVAssetWriter copies the encoded
    /// samples verbatim — including the temporal-level attachments that become
    /// the tscl/tsas sample groups.
    private func write(_ sampleBuffer: CMSampleBuffer) throws {
        if input == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw DefringeError("encoded sample has no format description")
            }
            let newInput = AVAssetWriterInput(mediaType: .video,
                                              outputSettings: nil,
                                              sourceFormatHint: format)
            newInput.expectsMediaDataInRealTime = false
            newInput.mediaTimeScale = mediaTimeScale
            newInput.transform = transform
            guard writer.canAdd(newInput) else {
                throw DefringeError("AVAssetWriter cannot add the video input")
            }
            writer.add(newInput)
            guard writer.startWriting() else {
                throw DefringeError("AVAssetWriter.startWriting failed: \(String(describing: writer.error))")
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            input = newInput
        }
        guard let input = input else {
            throw DefringeError("AVAssetWriterInput does not exist yet")
        }
        // With a passthrough writer isReadyForMoreMediaData can go false while
        // the writer drains to disk; wait for it instead of dropping the frame.
        var waited = 0.0
        while !input.isReadyForMoreMediaData {
            if waited >= 30.0 {
                throw DefringeError("AVAssetWriterInput stayed busy for 30s")
            }
            Thread.sleep(forTimeInterval: 0.002)
            waited += 0.002
        }
        guard input.append(sampleBuffer) else {
            throw DefringeError("AVAssetWriterInput.append failed: \(String(describing: writer.error))")
        }
    }

    func finish() throws {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
        condition.lock()
        while pendingFrames > 0 {
            condition.wait()
        }
        let error = firstError
        condition.unlock()
        if let error = error {
            throw DefringeError(error)
        }
        guard input != nil else {
            throw DefringeError("no frames were encoded")
        }
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw DefringeError("AVAssetWriter failed: \(String(describing: writer.error))")
        }
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
}

// MARK: - pipeline

func makeReader(asset: AVAsset, track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        throw DefringeError("cannot create AVAssetReader: \(error)")
    }
    // Explicitly ask for the 10-bit biplanar video-range format: the filter and
    // the encoder both operate on exactly the pixels the contract calls for.
    let settings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw DefringeError("AVAssetReader cannot add the video output")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw DefringeError("AVAssetReader failed to start: \(String(describing: reader.error))")
    }
    return (reader, output)
}

func runDefringe(_ options: Options) throws {
    let asset = AVURLAsset(url: options.input)
    let (track, info) = try probeSource(asset)

    var filter = makeChromaFilter(sigma: options.sigma, rangeSigma: options.rangeSigma)

    logLine(String(
        format: "defringe: %dx%d @ %.4g fps | ~%d frames (%.3fs) | %.4g Mbps | sigma %.4g | rangeSigma %.4g | filter %@ | HEVC Main 10 + temporal sub-layers (base %.4g fps)",
        info.width, info.height, info.frameRate, info.estimatedFrames,
        info.duration.seconds, options.bitrateMbps, options.sigma, options.rangeSigma,
        filter.name, info.frameRate / 2.0))
    logLine("defringe: colour: primaries \(info.colorPrimaries ?? "ITU_R_709_2 (fallback)") | transfer \(info.transferFunction ?? "ITU_R_709_2 (fallback)") | matrix \(info.yCbCrMatrix ?? "ITU_R_709_2 (fallback)")")

    let writer = try HEVCWriter(outputURL: options.output,
                                width: info.width,
                                height: info.height,
                                frameRate: info.frameRate,
                                bitrateMbps: options.bitrateMbps,
                                transform: info.transform,
                                colorPrimaries: info.colorPrimaries,
                                transferFunction: info.transferFunction,
                                yCbCrMatrix: info.yCbCrMatrix)
    try writer.start()

    let (reader, readerOutput) = try makeReader(asset: asset, track: track)

    let startTime = Date()
    var presented = 0
    var nextProgressTime = 30.0 // report every 30 seconds of source material
    var filterSeconds = 0.0

    while let sample = readerOutput.copyNextSampleBuffer() {
        try autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw DefringeError("decoded sample has no image buffer")
            }
            let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)

            let filterStart = Date()
            do {
                try filter.apply(to: pixelBuffer)
            } catch {
                // A texture wrapping failure must not crash the run; drop to
                // the CPU for the rest of the file (and for this frame).
                guard filter is MetalChromaFilter else { throw error }
                logWarning("Metal filter failed (\(error)); continuing on the CPU fallback")
                let cpu = CPUChromaFilter(sigma: options.sigma, rangeSigma: options.rangeSigma)
                try cpu.apply(to: pixelBuffer)
                filter = cpu
            }
            filterSeconds += Date().timeIntervalSince(filterStart)

            try writer.append(pixelBuffer, presentationTimeStamp: presentationTimeStamp, duration: duration)
            presented += 1

            let sourceSeconds = CMTimeGetSeconds(presentationTimeStamp)
            if sourceSeconds >= nextProgressTime {
                nextProgressTime += 30.0
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = elapsed > 0 ? Double(presented) / elapsed : 0
                let remaining = info.estimatedFrames > presented ? Double(info.estimatedFrames - presented) / max(rate, 0.001) : 0
                logLine(String(format: "[progress] %d/%d frames | %.1f fps | elapsed %@ | eta %@",
                               presented, info.estimatedFrames, rate,
                               formatSeconds(elapsed), formatSeconds(remaining)))
            }
        }
    }

    if reader.status == .failed {
        throw DefringeError("AVAssetReader failed: \(String(describing: reader.error))")
    }

    try writer.finish()

    let elapsed = Date().timeIntervalSince(startTime)
    let rate = elapsed > 0 ? Double(presented) / elapsed : 0
    var size = 0.0
    if let attributes = try? FileManager.default.attributesOfItem(atPath: options.output.path),
       let fileSize = attributes[.size] as? NSNumber {
        size = fileSize.doubleValue
    }
    logLine(String(format: "defringe: wrote %@ | %d frames | elapsed %@ | %.1f fps | filter %@ | mean filter %.2f ms/frame | %.1f MB (%.1f Mbps average over %.3fs of media)",
                   options.output.path, presented, formatSeconds(elapsed), rate, filter.name,
                   presented > 0 ? filterSeconds / Double(presented) * 1000.0 : 0,
                   size / 1_000_000.0,
                   info.duration.seconds > 0 ? size * 8.0 / 1_000_000.0 / info.duration.seconds : 0,
                   info.duration.seconds))
}

// MARK: - entry point

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let options = try parseOptions(arguments)
    try runDefringe(options)
} catch let error as DefringeError {
    FileHandle.standardError.write(("defringe: \(error.description)\n").data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write(("defringe: \(error)\n").data(using: .utf8)!)
    exit(1)
}
