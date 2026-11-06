import AVFoundation
import XCTest

/// A flat measurement record: ordered key → value, each value either compared exactly (by its description)
/// or numerically within a tolerance. Two records match when they have the same keys and every value matches.
struct Fields {
    enum Value {
        case exact(String)
        case num(Double, tol: Double)
    }
    private(set) var items: [(key: String, value: Value)] = []

    mutating func exact(_ key: String, _ value: Any?) {
        items.append((key, .exact(value.map { "\($0)" } ?? "nil")))
    }

    /// nil is recorded as an exact "nil" so nil vs value is a mismatch.
    mutating func num(_ key: String, _ value: Double?, tol: Double) {
        guard let v = value else { return exact(key, nil) }
        items.append((key, .num(v, tol: tol)))
    }

    mutating func merge(_ prefix: String, _ other: Fields) {
        for (k, v) in other.items { items.append((prefix + k, v)) }
    }

    /// (number of keys compared, human-readable mismatches)
    static func compare(_ a: Fields, _ b: Fields, names: (String, String) = ("current", "oracle")) -> (Int, [String]) {
        var mismatches: [String] = []
        let bByKey = Dictionary(b.items.map { ($0.key, $0.value) }, uniquingKeysWith: { x, _ in x })
        let aKeys = Set(a.items.map(\.key))
        for (k, va) in a.items {
            guard let vb = bByKey[k] else { mismatches.append("\(k): only in \(names.0) (\(va))"); continue }
            switch (va, vb) {
            case let (.exact(x), .exact(y)) where x == y: break
            case let (.num(x, t1), .num(y, t2)) where abs(x - y) <= max(t1, t2): break
            default: mismatches.append("\(k): \(names.0)=\(va) \(names.1)=\(vb)")
            }
        }
        for (k, vb) in b.items where !aKeys.contains(k) { mismatches.append("\(k): only in \(names.1) (\(vb))") }
        return (a.items.count, mismatches)
    }
}

extension Fields.Value: CustomStringConvertible {
    var description: String {
        switch self {
        case .exact(let s): return s
        case .num(let v, _): return String(format: "%.5g", v)
        }
    }
}

/// Tolerances between two runs of (supposedly) identical code. Tighter than the absolute expectations of the
/// pinned tests; they only absorb decoder / encoder noise.
enum Tol {
    static let seconds = 0.02
    static let edge = 0.03          // onset / offset
    static let amplitude = 0.03
    static let level = 0.02         // rms
    static let peak = 0.05
    static let pixel = 12.0
    static let frameIndex = 1.0     // ±1 decode noise, same as the pinned tests
    static let fps = 0.5
    static let progress = 1e-4
}

enum Record {
    /// Callback contract of one run. `progress: false` skips the progress shape (for timing-dependent runs such as a
    /// cancel triggered from the first progress callback).
    static func outcome(_ o: Outcome, impl: Impl, progress: Bool = true) -> Fields {
        var f = Fields()
        f.exact("ok", o.succeeded)
        f.exact("error.domain", o.error.map { $0.domain == impl.errorDomain ? "<TR domain>" : $0.domain })
        f.exact("error.code", o.error?.code)
        f.exact("error.description", o.error?.localizedDescription)
        f.exact("completion.count", o.completionCount)
        f.exact("completion.onMain", o.completionOnMainThread)
        f.exact("completion.sync", o.completedSynchronously)
        guard progress else { return f }
        let p = o.progress
        f.exact("progress.count", p.count)
        f.exact("progress.allOnMain", p.allSatisfy(\.onMain))
        f.exact("progress.monotonic", zip(p, p.dropFirst()).allSatisfy { $0.value <= $1.value })
        var ops: [String] = []
        for x in p where ops.last != x.operation { ops.append(x.operation) }
        f.exact("progress.ops", ops)
        for (i, x) in p.enumerated() {
            f.exact("progress[\(i)].op", x.operation)
            f.num("progress[\(i)].value", Double(x.value), tol: Tol.progress)
        }
        return f
    }

    /// Everything the pinned tests measure on a produced file (and a bit more: every frame index, every track).
    static func file(_ url: URL) -> Fields {
        var f = Fields()
        let exists = FileManager.default.fileExists(atPath: url.path)
        f.exact("exists", exists)
        guard exists else { return f }
        f.num("duration", Measure.duration(url), tol: Tol.seconds)

        let videos = Measure.videoTracks(url)
        f.exact("video.count", videos.count)
        for (i, v) in videos.enumerated() {
            let k = "video[\(i)]."
            f.exact(k + "size", v.naturalSize)
            f.exact(k + "codec", v.codec)
            f.exact(k + "rotation", v.rotationDegrees)
            f.exact(k + "alpha", v.containsAlpha)
            f.num(k + "fps", Double(v.nominalFPS), tol: Tol.fps)
            f.num(k + "start", v.timeRange.start.seconds, tol: Tol.seconds)
            f.num(k + "trackDuration", v.timeRange.duration.seconds, tol: Tol.seconds)
        }
        let frames = Measure.frames(url)
        f.exact("frames.count", frames.count)
        for (i, fr) in frames.enumerated() {
            f.num("frames[\(i)].index", Double(fr.index), tol: Tol.frameIndex)
        }
        if let first = frames.first {
            f.num("frames.first.pts", first.pts, tol: 0.005)
            f.num("frames.first.r", first.top.r, tol: Tol.pixel)
            f.num("frames.first.g", first.top.g, tol: Tol.pixel)
            f.num("frames.first.b", first.top.b, tol: Tol.pixel)
            f.num("frames.first.a", first.top.a, tol: Tol.pixel)
            f.num("frames.first.topRightAlpha", first.topRightAlpha, tol: Tol.pixel)
        }
        if let last = frames.last { f.num("frames.last.pts", last.pts, tol: 0.005) }

        let audioCount = Measure.audioTrackCount(url)
        f.exact("audio.count", audioCount)
        for i in 0..<audioCount {
            let k = "audio[\(i)]."
            guard let a = Measure.audio(url, track: i) else { f.exact(k + "decoded", false); continue }
            f.num(k + "duration", a.duration, tol: Tol.seconds)
            f.num(k + "rms", a.rms, tol: Tol.level)
            f.num(k + "peak", a.peak, tol: Tol.peak)
            f.num(k + "onset", a.onset, tol: Tol.edge)
            f.num(k + "offset", a.offset, tol: Tol.edge)
            f.num(k + "amp440", a.amp440, tol: Tol.amplitude)
            f.num(k + "amp1000", a.amp1000, tol: Tol.amplitude)
        }
        return f
    }

    /// 440 / 1000 Hz amplitude in fixed windows of the decoded audio timeline (sample-order check).
    static func audioWindows(_ url: URL, windows: [(Double, Double)]) -> Fields {
        var f = Fields()
        guard let x = Measure.timeline(url) else { f.exact("timeline", nil); return f }
        let r = Measure.audioRate
        for (s, e) in windows {
            let lo = min(x.count, Int(s * r)), hi = min(x.count, Int(e * r))
            let seg = Array(x[lo..<hi])
            f.num("window[\(s)-\(e)].amp440", Measure.goertzelAmplitude(seg, frequency: 440, rate: r), tol: Tol.amplitude)
            f.num("window[\(s)-\(e)].amp1000", Measure.goertzelAmplitude(seg, frequency: 1000, rate: r), tol: Tol.amplitude)
        }
        return f
    }
}
