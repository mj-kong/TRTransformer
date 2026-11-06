import AVFoundation
import ObjectiveC
import TRTransformer
import XCTest

/// What one session run produced, as seen by the caller.
final class Outcome {
    var completionCount = 0
    var succeeded = false
    var error: NSError?
    var completionOnMainThread: Bool?
    /// true when the completion ran before transcodeAsynchronously / exportAsynchronously returned.
    var completedSynchronously = false
    var progress: [(operation: String, value: Float, onMain: Bool)] = []
    var elapsed: TimeInterval = 0

    var progressValues: [Float] { progress.map(\.value) }
}

extension TRTestCase {
    /// Settle time after the completion to catch late progress callbacks (they hop to main asynchronously)
    /// and any second completion call.
    static let settle: TimeInterval = 0.5

    func run(_ session: ILABTranscodeSession, cancelAfterFirstProgress: Bool = false, timeout: TimeInterval = 120) -> Outcome {
        drive(timeout: timeout) { o, done in
            session.transcodeAsynchronously({ op, value in
                o.progress.append((op ?? "", value, Thread.isMainThread))
                if cancelAfterFirstProgress && o.progress.count == 1 { session.cancelTranscode() }
            }, complete: { ok, error in
                done(ok, error as NSError?)
            })
        }
    }

    func run(_ session: ILABReverseVideoExportSession, cancelAfterFirstProgress: Bool = false, timeout: TimeInterval = 120) -> Outcome {
        drive(timeout: timeout) { o, done in
            session.exportAsynchronously({ op, value in
                o.progress.append((op ?? "", value, Thread.isMainThread))
                if cancelAfterFirstProgress && o.progress.count == 1 { session.cancelReverseExport() }
            }, complete: { ok, error in
                done(ok, error as NSError?)
            })
        }
    }

    func drive(timeout: TimeInterval, _ start: (Outcome, @escaping (Bool, NSError?) -> Void) -> Void) -> Outcome {
        let o = Outcome()
        let exp = expectation(description: "completion")
        exp.assertForOverFulfill = false
        let lock = NSLock()
        var returned = false
        let began = Date()
        start(o) { ok, error in
            lock.lock()
            o.completionCount += 1
            if o.completionCount == 1 {
                o.succeeded = ok
                o.error = error
                o.completionOnMainThread = Thread.isMainThread
                o.completedSynchronously = !returned
                o.elapsed = Date().timeIntervalSince(began)
            }
            lock.unlock()
            exp.fulfill()
        }
        lock.lock(); returned = true; lock.unlock()
        wait(for: [exp], timeout: timeout)
        RunLoop.main.run(until: Date().addingTimeInterval(Self.settle))
        return o
    }

    func transcode(_ src: URL, video: Int? = nil, audio: Int? = nil, range: CMTimeRange? = nil, out name: String = "out.mov",
                   configure: (ILABTranscodeSession) -> Void = { _ in }) -> (Outcome, URL) {
        let asset = AVURLAsset(url: src)
        let tr = range ?? CMTimeRange(start: .zero, duration: asset.duration)
        let out = url(name)
        let session: ILABTranscodeSession
        if let v = video, let a = audio {
            session = ILABTranscodeSession(asset: asset, timeRange: tr, videoTrackIndex: v, audioTrackIndex: a, outputURL: out)
        } else {
            session = ILABTranscodeSession(asset: asset, timeRange: tr, outputURL: out)
        }
        configure(session)
        return (run(session), out)
    }

    func reverse(_ src: URL, video: Int? = nil, audio: Int? = nil, range: CMTimeRange? = nil, out name: String = "out.mov") -> (Outcome, URL) {
        let asset = AVURLAsset(url: src)
        let tr = range ?? CMTimeRange(start: .zero, duration: asset.duration)
        let out = url(name)
        let session: ILABReverseVideoExportSession
        if let v = video, let a = audio {
            session = ILABReverseVideoExportSession(asset: asset, timeRange: tr, videoTrackIndex: v, audioTrackIndex: a, outputURL: out)
        } else {
            session = ILABReverseVideoExportSession(asset: asset, timeRange: tr, outputURL: out)
        }
        return (run(session), out)
    }

    func describe(_ o: Outcome) -> String {
        "ok=\(o.succeeded) err=\(o.error.map { "\($0.domain)/\($0.code)" } ?? "nil") calls=\(o.completionCount) " +
        "main=\(String(describing: o.completionOnMainThread)) sync=\(o.completedSynchronously) progress=\(o.progress.count) t=\(String(format: "%.2f", o.elapsed))s"
    }

    func log(_ label: String, _ out: URL) {
        let v = Measure.videoTracks(out).map { "[\($0.codec) \(Int($0.naturalSize.width))x\(Int($0.naturalSize.height)) rot=\($0.rotationDegrees) fps=\($0.nominalFPS) alpha=\($0.containsAlpha)]" }
        let a = (0..<Measure.audioTrackCount(out)).compactMap { Measure.audio(out, track: $0) }.map {
            String(format: "[a dur=%.3f rms=%.3f on=%@ off=%@ a440=%.3f a1000=%.3f]", $0.duration, $0.rms,
                   $0.onset.map { String(format: "%.3f", $0) } ?? "nil", $0.offset.map { String(format: "%.3f", $0) } ?? "nil", $0.amp440, $0.amp1000)
        }
        let f = Measure.frames(out).map(\.index)
        print("[TRT] \(label): frames=\(f.count) first=\(f.first ?? -1) last=\(f.last ?? -1) dur=\(String(format: "%.3f", Measure.duration(out))) \(v.joined()) \(a.joined())")
    }
}

// MARK: - Method replacement (test-scoped)

/// Replaces an instance method's IMP for the duration of `body`, then restores it.
func withReplacedMethod<T>(_ cls: AnyClass, _ selector: Selector, block: Any, _ body: () throws -> T) rethrows -> T {
    guard let method = class_getInstanceMethod(cls, selector) else { fatalError("no method \(selector) on \(cls)") }
    let original = method_getImplementation(method)
    let replacement = imp_implementationWithBlock(block)
    method_setImplementation(method, replacement)
    defer {
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
    }
    return try body()
}

/// Makes every `-[ILABAudioTrackExporter exportInM4ATo:completion:]` fail (as an AVAssetExportSession failure would),
/// asynchronously like the real export does.
/// `error` nil reproduces an export that fails without an NSError.
func withFailingM4AExport<T>(error: NSError? = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.exportFailed.rawValue, userInfo: nil),
                             _ body: () throws -> T) rethrows -> T {
    try withFailingAudioExporter("exportInM4ATo:completion:", error: error, body)
}

/// Same for `-[ILABAudioTrackExporter exportReverseToURL:complete:]` (the WAV reversal stage of reverse).
func withFailingReverseAudioExport<T>(error: NSError? = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.exportFailed.rawValue, userInfo: nil),
                                      _ body: () throws -> T) rethrows -> T {
    try withFailingAudioExporter("exportReverseToURL:complete:", error: error, body)
}

private func withFailingAudioExporter<T>(_ selector: String, error: NSError?, _ body: () throws -> T) rethrows -> T {
    let block: @convention(block) (AnyObject, NSURL, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void = { _, _, completion in
        DispatchQueue.global().async { completion(false, error) }
    }
    return try withReplacedMethod(ILABAudioTrackExporter.self, NSSelectorFromString(selector), block: block, body)
}

/// Makes `-[AVAssetWriter startWriting]` return NO for writers with an HEVC / HEVC-with-alpha video input,
/// i.e. what a device without an HEVC encoder does. Other writers run the real implementation.
/// `rejected` counts the refused attempts.
func withHEVCEncoderUnavailable<T>(rejected: Atomic<Int>, _ body: () throws -> T) rethrows -> T {
    let sel = #selector(AVAssetWriter.startWriting)
    let method = class_getInstanceMethod(AVAssetWriter.self, sel)!
    typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
    let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
    let block: @convention(block) (AVAssetWriter) -> Bool = { writer in
        let hevc = writer.inputs.contains { input in
            guard input.mediaType == .video, let codec = input.outputSettings?[AVVideoCodecKey] as? String else { return false }
            return codec == AVVideoCodecType.hevc.rawValue || codec == AVVideoCodecType.hevcWithAlpha.rawValue
        }
        if hevc { rejected.mutate { $0 += 1 }; return false }
        return original(writer, sel)
    }
    return try withReplacedMethod(AVAssetWriter.self, sel, block: block, body)
}

/// Runs the real `exportInM4ATo:completion:` and records what it reported (complete, error) for each call.
func withRecordedM4AExport<T>(_ calls: Atomic<[(Bool, NSError?)]>, _ body: () throws -> T) rethrows -> T {
    let sel = NSSelectorFromString("exportInM4ATo:completion:")
    let method = class_getInstanceMethod(ILABAudioTrackExporter.self, sel)!
    typealias Completion = @convention(block) (Bool, NSError?) -> Void
    typealias Fn = @convention(c) (AnyObject, Selector, NSURL, @escaping Completion) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
    let block: @convention(block) (AnyObject, NSURL, @escaping Completion) -> Void = { obj, url, completion in
        original(obj, sel, url, { ok, error in
            calls.mutate { $0.append((ok, error)) }
            completion(ok, error)
        })
    }
    return try withReplacedMethod(ILABAudioTrackExporter.self, sel, block: block, body)
}
