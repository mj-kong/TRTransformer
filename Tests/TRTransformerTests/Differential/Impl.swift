import AVFoundation
import ObjectiveC
import TRTransformer
import TRTransformerOracle
import XCTest

/// Which implementation a differential scenario runs against.
/// - `current`: the shipping `TRTransformer` module (today ObjC, later the Swift port).
/// - `oracle`: `TRTransformerOracle`, the frozen ObjC v1.12.19 copy with `ORC`-prefixed names (see its ORACLE.md).
///
/// This file is the only place that names either module's API; scenarios go through the handles below.
/// When the Swift port lands, only the `.current` branches here should need to change.
enum Impl: String, CaseIterable {
    case current, oracle

    var errorDomain: String {
        switch self {
        case .current: return kILABReverseVideoExportSessionErrorDomain
        case .oracle: return kORCILABReverseVideoExportSessionErrorDomain
        }
    }

    var audioTrackIndexAll: Int {
        switch self {
        case .current: return ILABAudioTrackIndexAll
        case .oracle: return ORCILABAudioTrackIndexAll
        }
    }

    /// Class whose methods the fault-injection helpers replace.
    var audioExporterClass: AnyClass {
        switch self {
        case .current: return ILABAudioTrackExporter.self
        case .oracle: return ORCILABAudioTrackExporter.self
        }
    }

    // MARK: sessions

    /// Same init choice as the existing tests' helpers:
    /// `range == nil && video == nil` → `init(asset:)` (+ `outputURL` if given), `video/audio` set → indexed factory,
    /// otherwise the legacy factory `(asset:timeRange:outputURL:)` the app calls.
    func transcode(_ asset: AVAsset, range: CMTimeRange?, video: Int?, audio: Int?, out: URL?,
                   configure: TranscodeConfig = TranscodeConfig()) -> SessionHandle {
        switch self {
        case .current:
            let s: ILABTranscodeSession
            if let range = range, let v = video, let a = audio, let out = out {
                s = ILABTranscodeSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a, outputURL: out)
            } else if let range = range, let out = out {
                s = ILABTranscodeSession(asset: asset, timeRange: range, outputURL: out)
            } else {
                s = ILABTranscodeSession(asset: asset)
                if let out = out { s.outputURL = out }
            }
            if let v = configure.size { s.size = v }
            if let v = configure.frameRate { s.frameRate = v }
            if let v = configure.estimatedDataRate { s.estimatedDataRate = v }
            return SessionHandle(object: s, meta: [
                "sourceSize": "\(s.sourceSize)", "size": "\(s.size)", "frameRate": "\(s.frameRate)",
            ], start: { p, c in
                s.transcodeAsynchronously({ op, v in p(op ?? "", v) }, complete: { ok, e in c(ok, e as NSError?) })
            }, cancel: { s.cancelTranscode() })
        case .oracle:
            let s: ORCILABTranscodeSession
            if let range = range, let v = video, let a = audio, let out = out {
                s = ORCILABTranscodeSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a, outputURL: out)
            } else if let range = range, let out = out {
                s = ORCILABTranscodeSession(asset: asset, timeRange: range, outputURL: out)
            } else {
                s = ORCILABTranscodeSession(asset: asset)
                if let out = out { s.outputURL = out }
            }
            if let v = configure.size { s.size = v }
            if let v = configure.frameRate { s.frameRate = v }
            if let v = configure.estimatedDataRate { s.estimatedDataRate = v }
            return SessionHandle(object: s, meta: [
                "sourceSize": "\(s.sourceSize)", "size": "\(s.size)", "frameRate": "\(s.frameRate)",
            ], start: { p, c in
                s.transcodeAsynchronously({ op, v in p(op ?? "", v) }, complete: { ok, e in c(ok, e as NSError?) })
            }, cancel: { s.cancelTranscode() })
        }
    }

    func reverse(_ asset: AVAsset, range: CMTimeRange?, video: Int?, audio: Int?, out: URL?) -> SessionHandle {
        switch self {
        case .current:
            let s: ILABReverseVideoExportSession
            if let range = range, let v = video, let a = audio, let out = out {
                s = ILABReverseVideoExportSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a, outputURL: out)
            } else if let range = range, let out = out {
                s = ILABReverseVideoExportSession(asset: asset, timeRange: range, outputURL: out)
            } else {
                s = ILABReverseVideoExportSession(asset: asset)
                if let out = out { s.outputURL = out }
            }
            return SessionHandle(object: s, meta: [:], start: { p, c in
                s.exportAsynchronously({ op, v in p(op ?? "", v) }, complete: { ok, e in c(ok, e as NSError?) })
            }, cancel: { s.cancelReverseExport() })
        case .oracle:
            let s: ORCILABReverseVideoExportSession
            if let range = range, let v = video, let a = audio, let out = out {
                s = ORCILABReverseVideoExportSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a, outputURL: out)
            } else if let range = range, let out = out {
                s = ORCILABReverseVideoExportSession(asset: asset, timeRange: range, outputURL: out)
            } else {
                s = ORCILABReverseVideoExportSession(asset: asset)
                if let out = out { s.outputURL = out }
            }
            return SessionHandle(object: s, meta: [:], start: { p, c in
                s.exportAsynchronously({ op, v in p(op ?? "", v) }, complete: { ok, e in c(ok, e as NSError?) })
            }, cancel: { s.cancelReverseExport() })
        }
    }

    /// `range == nil` → `init(asset:trackIndex:)`, otherwise `init(asset:trackIndex:timeRange:)`.
    func audioExporter(_ asset: AVAsset, trackIndex: Int, range: CMTimeRange? = nil) -> ExporterHandle {
        switch self {
        case .current:
            let e: ILABAudioTrackExporter
            if let range = range { e = ILABAudioTrackExporter(asset: asset, trackIndex: trackIndex, timeRange: range) }
            else { e = ILABAudioTrackExporter(asset: asset, trackIndex: trackIndex) }
            return ExporterHandle(object: e, trackIndex: e.trackIndex,
                                  m4a: { u, c in e.exportInM4A(to: u, completion: { ok, err in c(ok, err as NSError?) }) },
                                  reverse: { u, c in e.exportReverse(to: u, complete: { ok, err in c(ok, err as NSError?) }) })
        case .oracle:
            let e: ORCILABAudioTrackExporter
            if let range = range { e = ORCILABAudioTrackExporter(asset: asset, trackIndex: trackIndex, timeRange: range) }
            else { e = ORCILABAudioTrackExporter(asset: asset, trackIndex: trackIndex) }
            return ExporterHandle(object: e, trackIndex: e.trackIndex,
                                  m4a: { u, c in e.exportInM4A(to: u, completion: { ok, err in c(ok, err as NSError?) }) },
                                  reverse: { u, c in e.exportReverse(to: u, complete: { ok, err in c(ok, err as NSError?) }) })
        }
    }

    // MARK: init-time state

    func transcodeInitState(_ asset: AVAsset, range: CMTimeRange, video: Int?, audio: Int?) -> Fields {
        var f = Fields()
        switch self {
        case .current:
            let s: ILABTranscodeSession
            if let v = video, let a = audio { s = ILABTranscodeSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a) }
            else { s = ILABTranscodeSession(asset: asset, timeRange: range) }
            f.exact("videoTrackIndex", s.videoTrackIndex); f.exact("audioTrackIndex", s.audioTrackIndex)
            f.exact("sourceReady", s.sourceReady); f.exact("sourceVideoTracks", s.sourceVideoTracks); f.exact("sourceAudioTracks", s.sourceAudioTracks)
            f.num("sourceDuration", s.sourceDuration.seconds, tol: 1e-9); f.exact("sourceDurationSeconds", s.sourceDurationSeconds)
            f.num("sourceFPS", Double(s.sourceFPS), tol: 1e-6); f.num("sourceEstimatedDataRate", Double(s.sourceEstimatedDataRate), tol: 1)
            f.exact("sourceTransform", s.sourceTransform); f.exact("sourceSize", s.sourceSize)
            f.exact("size", s.size); f.num("frameRate", Double(s.frameRate), tol: 1e-6); f.exact("estimatedDataRate", s.estimatedDataRate)
            f.exact("deleteCacheFile", s.deleteCacheFile); f.exact("showDebug", s.showDebug)
        case .oracle:
            let s: ORCILABTranscodeSession
            if let v = video, let a = audio { s = ORCILABTranscodeSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a) }
            else { s = ORCILABTranscodeSession(asset: asset, timeRange: range) }
            f.exact("videoTrackIndex", s.videoTrackIndex); f.exact("audioTrackIndex", s.audioTrackIndex)
            f.exact("sourceReady", s.sourceReady); f.exact("sourceVideoTracks", s.sourceVideoTracks); f.exact("sourceAudioTracks", s.sourceAudioTracks)
            f.num("sourceDuration", s.sourceDuration.seconds, tol: 1e-9); f.exact("sourceDurationSeconds", s.sourceDurationSeconds)
            f.num("sourceFPS", Double(s.sourceFPS), tol: 1e-6); f.num("sourceEstimatedDataRate", Double(s.sourceEstimatedDataRate), tol: 1)
            f.exact("sourceTransform", s.sourceTransform); f.exact("sourceSize", s.sourceSize)
            f.exact("size", s.size); f.num("frameRate", Double(s.frameRate), tol: 1e-6); f.exact("estimatedDataRate", s.estimatedDataRate)
            f.exact("deleteCacheFile", s.deleteCacheFile); f.exact("showDebug", s.showDebug)
        }
        return f
    }

    func reverseInitState(_ asset: AVAsset, range: CMTimeRange, video: Int?, audio: Int?) -> Fields {
        var f = Fields()
        switch self {
        case .current:
            let s: ILABReverseVideoExportSession
            if let v = video, let a = audio { s = ILABReverseVideoExportSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a) }
            else { s = ILABReverseVideoExportSession(asset: asset, timeRange: range) }
            f.exact("videoTrackIndex", s.videoTrackIndex); f.exact("audioTrackIndex", s.audioTrackIndex)
            f.exact("sourceReady", s.sourceReady); f.exact("sourceVideoTracks", s.sourceVideoTracks); f.exact("sourceAudioTracks", s.sourceAudioTracks)
            f.num("sourceDuration", s.sourceDuration.seconds, tol: 1e-9); f.exact("sourceDurationSeconds", s.sourceDurationSeconds)
            f.num("sourceFPS", Double(s.sourceFPS), tol: 1e-6)
            f.exact("sourceTransform", s.sourceTransform); f.exact("sourceSize", s.sourceSize)
            f.exact("samplesPerPass", s.samplesPerPass); f.exact("skipAudio", s.skipAudio)
            f.exact("deleteCacheFile", s.deleteCacheFile); f.exact("showDebug", s.showDebug); f.exact("outputURL", s.outputURL)
        case .oracle:
            let s: ORCILABReverseVideoExportSession
            if let v = video, let a = audio { s = ORCILABReverseVideoExportSession(asset: asset, timeRange: range, videoTrackIndex: v, audioTrackIndex: a) }
            else { s = ORCILABReverseVideoExportSession(asset: asset, timeRange: range) }
            f.exact("videoTrackIndex", s.videoTrackIndex); f.exact("audioTrackIndex", s.audioTrackIndex)
            f.exact("sourceReady", s.sourceReady); f.exact("sourceVideoTracks", s.sourceVideoTracks); f.exact("sourceAudioTracks", s.sourceAudioTracks)
            f.num("sourceDuration", s.sourceDuration.seconds, tol: 1e-9); f.exact("sourceDurationSeconds", s.sourceDurationSeconds)
            f.num("sourceFPS", Double(s.sourceFPS), tol: 1e-6)
            f.exact("sourceTransform", s.sourceTransform); f.exact("sourceSize", s.sourceSize)
            f.exact("samplesPerPass", s.samplesPerPass); f.exact("skipAudio", s.skipAudio)
            f.exact("deleteCacheFile", s.deleteCacheFile); f.exact("showDebug", s.showDebug); f.exact("outputURL", s.outputURL)
        }
        return f
    }

    // MARK: errors

    func sessionError(_ code: Int) -> NSError? {
        switch self {
        case .current: return NSError.ilabSessionError(ILABSessionError(rawValue: code)) as NSError?
        case .oracle: return NSError.orcilabSessionError(ORCILABSessionError(rawValue: code)) as NSError?
        }
    }

    /// `+[NSError errorWithAudioFileStatusCode:]` (oracle: `orc_` prefixed), called through the runtime because it is a
    /// category method on a shared Apple class.
    func audioFileStatusError(_ status: OSStatus) -> NSError {
        let name = self == .current ? "errorWithAudioFileStatusCode:" : "orc_errorWithAudioFileStatusCode:"
        let sel = NSSelectorFromString(name)
        guard let m = class_getClassMethod(NSError.self, sel) else { fatalError("missing +[NSError \(name)]") }
        typealias Fn = @convention(c) (AnyClass, Selector, OSStatus) -> NSError
        return unsafeBitCast(method_getImplementation(m), to: Fn.self)(NSError.self, sel, status)
    }

    // MARK: settings helpers (TRTransformAPI)

    func compressionProperties(_ size: CGSize, _ rate: CGFloat, _ codec: CMVideoCodecType, _ hdr: Bool, _ dolby: Bool) -> NSDictionary {
        switch self {
        case .current: return makeCompressionProperties(size, rate, codec, hdr, dolby) as NSDictionary
        case .oracle: return orc_makeCompressionProperties(size, rate, codec, hdr, dolby) as NSDictionary
        }
    }

    func readerSettings(_ hdr: Bool, _ alpha: Bool, _ prores: Bool) -> NSDictionary {
        switch self {
        case .current: return makeVideoReaderSettings(hdr, alpha, prores) as NSDictionary
        case .oracle: return orc_makeVideoReaderSettings(hdr, alpha, prores) as NSDictionary
        }
    }

    func outputSettings(_ size: CGSize, _ codec: CMVideoCodecType, _ hdr: Bool, _ alpha: Bool, _ props: [AnyHashable: Any]) -> NSDictionary {
        switch self {
        case .current: return makeVideoOutputSettings(size, codec, hdr, alpha, props) as NSDictionary
        case .oracle: return orc_makeVideoOutputSettings(size, codec, hdr, alpha, props) as NSDictionary
        }
    }

    func defaultSettings(_ size: CGSize, _ rate: CGFloat) -> NSDictionary {
        switch self {
        case .current: return makeVideoDefaultSettings(size, makeDefaultCompressionProperties(size, rate)) as NSDictionary
        case .oracle: return orc_makeVideoDefaultSettings(size, orc_makeDefaultCompressionProperties(size, rate)) as NSDictionary
        }
    }

    func isProRes(_ codec: CMVideoCodecType) -> Bool {
        switch self {
        case .current: return isProResCodec(codec)
        case .oracle: return orc_isProResCodec(codec)
        }
    }

    func trackPredicates(_ track: AVAssetTrack) -> (proRes: Bool, dolby: Bool) {
        switch self {
        case .current: return (isProResType(track), isDolbyVisionType(track))
        case .oracle: return (orc_isProResType(track), orc_isDolbyVisionType(track))
        }
    }
}

struct TranscodeConfig {
    var size: CGSize?
    var frameRate: CGFloat?
    var estimatedDataRate: CGFloat?
}

/// One transcode / reverse session of either implementation.
final class SessionHandle {
    let object: AnyObject
    /// Property values read right after configuration (e.g. a clamped frameRate).
    let meta: [String: String]
    let start: (_ progress: @escaping (String, Float) -> Void, _ complete: @escaping (Bool, NSError?) -> Void) -> Void
    let cancel: () -> Void
    init(object: AnyObject, meta: [String: String],
         start: @escaping (@escaping (String, Float) -> Void, @escaping (Bool, NSError?) -> Void) -> Void,
         cancel: @escaping () -> Void) {
        self.object = object; self.meta = meta; self.start = start; self.cancel = cancel
    }
}

/// One audio track exporter of either implementation.
final class ExporterHandle {
    let object: AnyObject
    let trackIndex: Int
    let m4a: (URL, @escaping (Bool, NSError?) -> Void) -> Void
    let reverse: (URL, @escaping (Bool, NSError?) -> Void) -> Void
    init(object: AnyObject, trackIndex: Int,
         m4a: @escaping (URL, @escaping (Bool, NSError?) -> Void) -> Void,
         reverse: @escaping (URL, @escaping (Bool, NSError?) -> Void) -> Void) {
        self.object = object; self.trackIndex = trackIndex; self.m4a = m4a; self.reverse = reverse
    }
}

// MARK: - Fault injection per implementation (same behaviour as Runner.swift's helpers, on the impl's exporter class)

func withFailingAudioStage<T>(_ impl: Impl, _ selector: String,
                              error: NSError? = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.exportFailed.rawValue, userInfo: nil),
                              _ body: () throws -> T) rethrows -> T {
    let block: @convention(block) (AnyObject, NSURL, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void = { _, _, completion in
        DispatchQueue.global().async { completion(false, error) }
    }
    return try withReplacedMethod(impl.audioExporterClass, NSSelectorFromString(selector), block: block, body)
}

func withRecordedM4AStage<T>(_ impl: Impl, _ calls: Atomic<[(Bool, NSError?)]>, _ body: () throws -> T) rethrows -> T {
    let sel = NSSelectorFromString("exportInM4ATo:completion:")
    let method = class_getInstanceMethod(impl.audioExporterClass, sel)!
    typealias Completion = @convention(block) (Bool, NSError?) -> Void
    typealias Fn = @convention(c) (AnyObject, Selector, NSURL, @escaping Completion) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
    let block: @convention(block) (AnyObject, NSURL, @escaping Completion) -> Void = { obj, url, completion in
        original(obj, sel, url, { ok, error in
            calls.mutate { $0.append((ok, error)) }
            completion(ok, error)
        })
    }
    return try withReplacedMethod(impl.audioExporterClass, sel, block: block, body)
}
