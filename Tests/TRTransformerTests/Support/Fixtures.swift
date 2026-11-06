import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest

/// Synthetic media generated in code (no binary fixtures in the repo).
///
/// Every video frame is split in two:
/// - top half: the track's identifying colour (alpha 0 in the top-right quarter when `alpha` is set),
/// - bottom half: an opaque gray whose level encodes the frame number (`Fixture.gray(forFrame:)`).
/// Audio tracks are pure sines; frequency + amplitude identify the stream, `start` lets a tone begin late.
enum Fixture {
    struct RGB: Equatable { var r: UInt8; var g: UInt8; var b: UInt8 }

    static let red = RGB(r: 230, g: 20, b: 20)
    static let green = RGB(r: 20, g: 230, b: 20)
    static let blue = RGB(r: 20, g: 20, b: 230)

    /// Frame number → gray level. 3 levels per frame keeps 60 frames inside 30...207.
    static let grayBase = 30.0
    static let grayStep = 3.0
    static func gray(forFrame i: Int) -> UInt8 { UInt8(grayBase + grayStep * Double(i)) }
    static func frame(forGray g: Double) -> Int { Int(((g - grayBase) / grayStep).rounded()) }

    struct Video {
        var width: Int
        var height: Int
        var color: RGB
        var transform: CGAffineTransform = .identity
        var codec: AVVideoCodecType = .h264
        var alpha: Bool = false
        var hdrHLG: Bool = false
    }

    struct Audio {
        var frequency: Double
        var amplitude: Double
        var start: Double = 0
        var duration: Double
        var sampleRate: Double = 44100
        var channels: Int = 1
        /// When set, the second half of the tone uses this frequency (lets tests see sample order).
        var secondHalfFrequency: Double? = nil
    }

    struct Spec {
        var videos: [Video]
        var audios: [Audio]
        var fps: Int = 20
        var frames: Int = 60
        var fileType: AVFileType = .mov
        var duration: Double { Double(frames) / Double(fps) }
    }

    enum Failure: Error, CustomStringConvertible {
        case writer(String)
        var description: String { switch self { case .writer(let s): return s } }
    }

    /// The default multi-stream source used by most tests.
    /// video 0: red 320x240, video 1: green 240x160 rotated 90°, video 2: blue 160x96
    /// audio 0: 440 Hz amp 0.2 for the whole clip, audio 1: 1000 Hz amp 0.5 from 0.5 s to 1.5 s (late start, early end).
    static let multiStream = Spec(
        videos: [
            Video(width: 320, height: 240, color: red),
            Video(width: 240, height: 160, color: green, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0)),
            Video(width: 160, height: 96, color: blue),
        ],
        audios: [
            Audio(frequency: 440, amplitude: 0.2, start: 0, duration: 3.0),
            Audio(frequency: 1000, amplitude: 0.5, start: 0.5, duration: 1.0, sampleRate: 48000, channels: 2),
        ]
    )

    static let videoOnly = Spec(videos: [Video(width: 320, height: 240, color: red)], audios: [])

    /// Single video + single late tone: the reverse late-audio case.
    static let lateAudio = Spec(
        videos: [Video(width: 320, height: 240, color: red)],
        audios: [Audio(frequency: 1000, amplitude: 0.5, start: 0.5, duration: 1.0)]
    )

    // MARK: - Writer

    static func write(_ spec: Spec, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)

        var vInputs: [(AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor, Video)] = []
        for v in spec.videos {
            var settings: [String: Any] = [AVVideoCodecKey: v.codec, AVVideoWidthKey: v.width, AVVideoHeightKey: v.height]
            var compression: [String: Any] = [:]
            if v.codec == .h264 {
                compression[AVVideoAverageBitRateKey] = 4_000_000
                compression[AVVideoMaxKeyFrameIntervalKey] = 10
            } else if v.codec == .hevc || v.codec == .hevcWithAlpha {
                compression[AVVideoAverageBitRateKey] = 4_000_000
                compression[AVVideoMaxKeyFrameIntervalKey] = 10
            }
            if v.hdrHLG {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                settings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ]
            }
            if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw Failure.writer("cannot apply video settings \(v.codec.rawValue)")
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.transform = v.transform
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: v.hdrHLG ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: v.width, kCVPixelBufferHeightKey as String: v.height,
            ])
            guard writer.canAdd(input) else { throw Failure.writer("cannot add video input \(v.codec.rawValue)") }
            writer.add(input)
            vInputs.append((input, adaptor, v))
        }

        var aInputs: [(AVAssetWriterInput, Audio)] = []
        for a in spec.audios {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: a.sampleRate,
                AVNumberOfChannelsKey: a.channels, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.writer("cannot add audio input") }
            writer.add(input)
            aInputs.append((input, a))
        }

        guard writer.startWriting() else {
            throw Failure.writer("startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let failed = Atomic(false)

        for (k, (input, adaptor, v)) in vInputs.enumerated() {
            group.enter()
            var f = 0
            var left = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.v\(k)")) {
                while input.isReadyForMoreMediaData && f < spec.frames {
                    guard let pb = makeFrame(v, index: f, pool: adaptor.pixelBufferPool) else { failed.set(true); f = spec.frames; break }
                    if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(spec.fps))) {
                        failed.set(true); f = spec.frames; break
                    }
                    f += 1
                }
                if f >= spec.frames && !left { left = true; input.markAsFinished(); group.leave() }
            }
        }

        for (k, (input, a)) in aInputs.enumerated() {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: a.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * a.channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * a.channels),
                mChannelsPerFrame: UInt32(a.channels), mBitsPerChannel: 16, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
            let total = Int(a.sampleRate * a.duration)
            let first = Int(a.sampleRate * a.start)
            var pos = 0
            var left = false
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.a\(k)")) {
                while input.isReadyForMoreMediaData && pos < total {
                    let n = min(1024, total - pos)
                    var samples = [Int16](repeating: 0, count: n * a.channels)
                    for i in 0..<n {
                        let hz = (a.secondHalfFrequency != nil && pos + i >= total / 2) ? a.secondHalfFrequency! : a.frequency
                        let v = Int16(a.amplitude * 32767 * sin(2 * .pi * hz * Double(pos + i) / a.sampleRate))
                        for c in 0..<a.channels { samples[i * a.channels + c] = v }
                    }
                    let bytes = n * a.channels * 2
                    var block: CMBlockBuffer?
                    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                       flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
                    var sb: CMSampleBuffer?
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: n,
                        presentationTimeStamp: CMTime(value: CMTimeValue(first + pos), timescale: CMTimeScale(a.sampleRate)),
                        packetDescriptions: nil, sampleBufferOut: &sb)
                    if !input.append(sb!) { failed.set(true); pos = total; break }
                    pos += n
                }
                if pos >= total && !left { left = true; input.markAsFinished(); group.leave() }
            }
        }

        if group.wait(timeout: .now() + 60) == .timedOut {
            writer.cancelWriting()
            throw Failure.writer("fixture write timed out")
        }
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if failed.get() || writer.status != .completed {
            throw Failure.writer("fixture failed: status \(writer.status.rawValue) \(String(describing: writer.error))")
        }
    }

    private static func makeFrame(_ v: Video, index: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        let format = v.hdrHLG ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        if pb == nil { CVPixelBufferCreate(nil, v.width, v.height, format, nil, &pb) }
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if v.hdrHLG {
            // 10-bit video-range 4:2:0, gray only (luma = frame number, neutral chroma); values live in the high 10 bits.
            let y10 = UInt16(64 + Double(gray(forFrame: index)) * 876 / 255) << 6
            let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<v.height {
                let row = UnsafeMutableRawPointer(yBase + y * yStride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<v.width { row[x] = y10 }
            }
            let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in 0..<(v.height / 2) {
                let row = UnsafeMutableRawPointer(cBase + y * cStride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<v.width { row[x] = 512 << 6 }
            }
            return buffer
        }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let g = gray(forFrame: index)
        for y in 0..<v.height {
            for x in 0..<v.width {
                let p = base + y * stride + x * 4
                if y < v.height / 2 {
                    let transparent = v.alpha && x >= v.width / 2
                    if transparent {
                        p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0   // premultiplied-friendly fully transparent
                    } else {
                        p[0] = v.color.b; p[1] = v.color.g; p[2] = v.color.r; p[3] = 255
                    }
                } else {
                    p[0] = g; p[1] = g; p[2] = g; p[3] = 255
                }
            }
        }
        return buffer
    }
}

/// Minimal lock-protected box.
final class Atomic<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

/// Per-test temp directory, removed in tearDown.
class TRTestCase: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp = tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    func url(_ name: String) -> URL { tmp.appendingPathComponent(name) }

    /// Writes a fixture; an encoder that is unavailable on this platform skips the test.
    func makeSource(_ spec: Fixture.Spec, name: String = "src.mov", skipReason: String? = nil) throws -> URL {
        let u = url(name)
        do {
            try Fixture.write(spec, to: u)
        } catch {
            if let reason = skipReason { throw XCTSkip("\(reason): \(error)") }
            throw error
        }
        return u
    }
}
