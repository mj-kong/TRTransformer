import AVFoundation
import XCTest

/// Local-only differential run (current vs oracle) over real media.
/// Skipped unless `TRT_CORPUS` is set to a directory of media files (non-recursive, sorted by name).
/// Also skipped if that directory can't be read or has no files after filtering; an unreadable file is logged and passed over.
/// `TRT_CORPUS=documents` means `<app home>/Documents/corpus`; `TRT_CORPUS=bundle` means `<test bundle>/corpus`.
/// Optional: `TRT_CORPUS_SELF=1` (current vs current noise floor), `TRT_CORPUS_ONLY=03,17` (name prefixes), `TRT_CORPUS_FROM=17` (resume after a crash).
/// Output: `[CORPUS] <file> | <scenario>: MATCH|MISMATCH|TIMEOUT ...` lines, plus `[CORPUS]   <field>` per mismatch,
/// and `[CORPUS] <file> | skipped: <reason>` for files that can't be accessed. Only MISMATCH fails the test.
final class CorpusDifferentialTests: TRTestCase {

    static let scenarioTimeout: TimeInterval = 180

    func testCorpus() throws {
        guard let raw = ProcessInfo.processInfo.environment["TRT_CORPUS"], !raw.isEmpty else {
            throw XCTSkip("TRT_CORPUS not set")
        }
        let dir: URL
        switch raw {
        case "documents": dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/corpus")
        // device: files copied into the built .xctest bundle (outside the repo) and the bundle re-signed
        case "bundle": dir = Bundle(for: Self.self).bundleURL.appendingPathComponent("corpus")
        default: dir = URL(fileURLWithPath: raw)
        }
        print("[CORPUS] home=\(NSHomeDirectory()) tmp=\(FileManager.default.temporaryDirectory.path)")
        let env = ProcessInfo.processInfo.environment
        let only = env["TRT_CORPUS_ONLY"].map { $0.split(separator: ",").map(String.init) } ?? []
        let from = env["TRT_CORPUS_FROM"] ?? ""
        // the corpus is optional local data: an unreachable folder is a skip, not a failure
        let all: [String]
        do {
            all = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw XCTSkip("corpus not accessible at \(dir.path): \(error.localizedDescription)")
        }
        let names = all
            .filter { !$0.hasPrefix(".") }.sorted()
            .filter { only.isEmpty || only.contains(where: $0.hasPrefix) }
            .filter { from.isEmpty || $0 >= from }
        print("[CORPUS] dir=\(dir.path) files=\(names.count)")
        if names.isEmpty {
            throw XCTSkip("no corpus files in \(dir.path) (TRT_CORPUS_ONLY/FROM applied)")
        }
        let began = Date()
        var counts = (match: 0, mismatch: 0, timeout: 0, skipped: 0)
        for name in names {
            let src = dir.appendingPathComponent(name)
            if let reason = accessProblem(src) {
                print("[CORPUS] \(name) | skipped: \(reason)")
                counts.skipped += 1
                continue
            }
            let fileBegan = Date()
            for r in scenarios(src) {
                switch scenario(name, r) {
                case .match: counts.match += 1
                case .mismatch: counts.mismatch += 1
                case .timeout: counts.timeout += 1
                }
            }
            print(String(format: "[CORPUS] %@ | file done in %.1fs", name, Date().timeIntervalSince(fileBegan)))
        }
        print(String(format: "[CORPUS] SUMMARY match=%d mismatch=%d timeout=%d skipped=%d elapsed=%.0fs",
                     counts.match, counts.mismatch, counts.timeout, counts.skipped, Date().timeIntervalSince(began)))
    }

    /// Why `src` can't be read at all, or nil. Media that opens but fails to decode is not an access
    /// problem: both implementations erroring on it is a compared scenario.
    func accessProblem(_ src: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir) else { return "not found" }
        if isDir.boolValue { return "not a file" }
        do {
            let h = try FileHandle(forReadingFrom: src)
            defer { try? h.close() }
            _ = try h.read(upToCount: 1)
        } catch {
            return "cannot open: \(Self.describe(error as NSError))"
        }
        final class Box: @unchecked Sendable { var error: NSError? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { _ = try await AVURLAsset(url: src).load(.tracks) } catch { box.error = error as NSError }
            done.signal()
        }
        done.wait()
        if let e = box.error, Self.isAccessError(e) { return "cannot load tracks: \(Self.describe(e))" }
        return nil
    }

    // innermost error: Foundation's top-level text for read failures can say "save"
    static func describe(_ e: NSError) -> String {
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { return describe(u) }
        return "\(e.domain) \(e.code) \(e.localizedDescription)"
    }

    static func isAccessError(_ e: NSError) -> Bool {
        if e.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(e.code) { return true }
        if e.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM), Int(ENOENT)].contains(e.code) { return true }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isAccessError(u) }
        return false
    }

    // MARK: scenarios

    struct Scenario {
        var label: String
        var body: (Impl) -> (Fields, timedOut: Bool, elapsed: TimeInterval)
    }

    enum Verdict { case match, mismatch, timeout }

    func scenarios(_ src: URL) -> [Scenario] {
        let asset = AVURLAsset(url: src)
        let dur = asset.duration.seconds
        let nVideo = asset.tracks(withMediaType: .video).count
        let nAudio = asset.tracks(withMediaType: .audio).count
        let ts: CMTimeScale = 600
        func range(_ s: Double, _ d: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: s, preferredTimescale: ts), duration: CMTime(seconds: d, preferredTimescale: ts))
        }
        let a = dur <= 20 ? CMTimeRange(start: .zero, duration: asset.duration) : range(0, 10)
        let aLabel = dur <= 20 ? "full" : "0..10"
        let b: CMTimeRange
        if dur <= 0.5 {
            b = range(dur * 0.3, dur * 0.7)
        } else {
            let len = min(max(dur * 0.1, 0.5), 5, dur)
            b = range(min(dur * 0.3, dur - len), len)
        }
        let bLabel = String(format: "mid %.2f+%.2f", b.start.seconds, b.duration.seconds)
        print(String(format: "[CORPUS] %@ | source dur=%.3f video=%d audio=%d", src.lastPathComponent, dur, nVideo, nAudio))

        var list: [Scenario] = []
        for (r, l) in [(a, aLabel), (b, bLabel)] {
            list.append(Scenario(label: "T legacy \(l)") { self.transcodeRecord($0, src, range: r, out: "t.mov") })
            list.append(Scenario(label: "R legacy \(l)") { self.reverseRecord($0, src, range: r, out: "r.mov") })
        }
        if nVideo > 1 || nAudio > 1 {
            var pairs: [(Int?, Int?, String)] = []   // nil audio = All
            for v in 0..<max(nVideo, 1) { pairs.append((v, 0, "v\(v) a0")) }
            if nAudio > 1 { for x in 1..<nAudio { pairs.append((0, x, "v0 a\(x)")) } }
            pairs.append((0, nil, "v0 All"))
            for (v, x, l) in pairs {
                list.append(Scenario(label: "T \(l) \(aLabel)") { impl in
                    self.transcodeRecord(impl, src, video: v, audio: x ?? impl.audioTrackIndexAll, range: a, out: "t.mov")
                })
                list.append(Scenario(label: "R \(l) \(aLabel)") { impl in
                    self.reverseRecord(impl, src, video: v, audio: x ?? impl.audioTrackIndexAll, range: a, out: "r.mov")
                })
            }
        }
        if nAudio > 0 {
            list.append(Scenario(label: "E m4a 0 \(aLabel)") { self.exportRecord($0, src, index: 0, range: a, wav: false) })
            list.append(Scenario(label: "E wav 0 \(aLabel)") { self.exportRecord($0, src, index: 0, range: a, wav: true) })
        }
        return list
    }

    func scenario(_ file: String, _ s: Scenario) -> Verdict {
        let c = s.body(.current)
        // TRT_CORPUS_SELF=1: run current twice (noise floor of the measurement, not a differential)
        let o = ProcessInfo.processInfo.environment["TRT_CORPUS_SELF"] == "1" ? s.body(.current) : s.body(.oracle)
        let t = String(format: "t=%.1f/%.1fs", c.elapsed, o.elapsed)
        if c.timedOut || o.timedOut {
            print("[CORPUS] \(file) | \(s.label): TIMEOUT current=\(c.timedOut) oracle=\(o.timedOut) \(t)")
            return .timeout
        }
        let (n, mismatches) = Fields.compare(c.0, o.0)
        let ok = c.0.items.first { $0.key == "ok" }.map { "\($0.value)" } ?? "?"
        let err = c.0.items.first { $0.key == "error.code" }.map { "\($0.value)" } ?? "?"
        print("[CORPUS] \(file) | \(s.label): \(mismatches.isEmpty ? "MATCH" : "MISMATCH") compared=\(n) mismatches=\(mismatches.count) currentOk=\(ok) currentErr=\(err) \(t)")
        for m in mismatches.prefix(40) { print("[CORPUS]   \(file) | \(s.label) | \(m)") }
        if mismatches.count > 40 { print("[CORPUS]   \(file) | \(s.label) | ... \(mismatches.count - 40) more") }
        XCTAssertTrue(mismatches.isEmpty, "\(file) \(s.label): \(mismatches.prefix(10).joined(separator: "; "))")
        return mismatches.isEmpty ? .match : .mismatch
    }

    // MARK: runs (same records as DifferentialTestCase, with a non-failing timeout + cancel)

    func drive(timeout: TimeInterval, cancel: () -> Void, _ start: (Outcome, @escaping (Bool, NSError?) -> Void) -> Void) -> (Outcome, Bool) {
        let o = Outcome()
        let lock = NSLock()
        var returned = false
        var done = false
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
            done = true
            lock.unlock()
        }
        lock.lock(); returned = true; lock.unlock()
        let deadline = began.addingTimeInterval(timeout)
        while true {
            lock.lock(); let d = done; lock.unlock()
            if d { break }
            if Date() > deadline {
                cancel()
                // let the cancel settle so the next run does not compete with it
                let stop = Date().addingTimeInterval(10)
                while Date() < stop { lock.lock(); let d2 = done; lock.unlock(); if d2 { break }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                o.elapsed = Date().timeIntervalSince(began)
                return (o, true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(Self.settle))
        return (o, false)
    }

    func runSession(_ s: SessionHandle) -> (Outcome, Bool) {
        drive(timeout: Self.scenarioTimeout, cancel: s.cancel) { o, done in
            s.start({ op, v in o.progress.append((op, v, Thread.isMainThread)) }, { ok, e in done(ok, e) })
        }
    }

    private func cleanup(_ u: URL) { try? FileManager.default.removeItem(at: u) }

    func transcodeRecord(_ impl: Impl, _ src: URL, video: Int? = nil, audio: Int? = nil, range: CMTimeRange, out name: String) -> (Fields, timedOut: Bool, elapsed: TimeInterval) {
        let out = url("\(impl.rawValue)-\(name)")
        cleanup(out)
        let s = impl.transcode(AVURLAsset(url: src), range: range, video: video, audio: audio, out: out)
        let (o, to) = runSession(s)
        var f = Record.outcome(o, impl: impl)
        for (k, v) in s.meta.sorted(by: { $0.key < $1.key }) { f.exact("meta." + k, v) }
        if !to { f.merge("out.", Record.file(out)) }
        cleanup(out)
        return (f, to, o.elapsed)
    }

    func reverseRecord(_ impl: Impl, _ src: URL, video: Int? = nil, audio: Int? = nil, range: CMTimeRange, out name: String) -> (Fields, timedOut: Bool, elapsed: TimeInterval) {
        let out = url("\(impl.rawValue)-\(name)")
        cleanup(out)
        let s = impl.reverse(AVURLAsset(url: src), range: range, video: video, audio: audio, out: out)
        let (o, to) = runSession(s)
        var f = Record.outcome(o, impl: impl)
        if !to { f.merge("out.", Record.file(out)) }
        cleanup(out)
        return (f, to, o.elapsed)
    }

    func exportRecord(_ impl: Impl, _ src: URL, index: Int, range: CMTimeRange, wav: Bool) -> (Fields, timedOut: Bool, elapsed: TimeInterval) {
        let e = impl.audioExporter(AVURLAsset(url: src), trackIndex: index, range: range)
        let out = url("\(impl.rawValue)-\(wav ? "e.wav" : "e.m4a")")
        cleanup(out)
        let (o, to) = drive(timeout: Self.scenarioTimeout, cancel: {}) { _, done in
            if wav { e.reverse(out, done) } else { e.m4a(out, done) }
        }
        var f = Fields()
        f.exact("trackIndex", e.trackIndex == impl.audioTrackIndexAll ? "All" : "\(e.trackIndex)")
        f.merge("", Record.outcome(o, impl: impl, progress: false))
        if !to { f.merge("out.", Record.file(out)) }
        cleanup(out)
        return (f, to, o.elapsed)
    }
}
