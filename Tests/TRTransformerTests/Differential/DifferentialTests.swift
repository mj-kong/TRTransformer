import AVFoundation
import TRTransformer
import TRTransformerOracle
import VideoToolbox
import XCTest

/// Runs each scenario against the shipping implementation (`Impl.current`) and the frozen ObjC oracle (`Impl.oracle`)
/// on the same source file, records the same measurements the pinned tests use, and requires the two records to match.
/// Every scenario prints one `[DIFF] <name>: MATCH|MISMATCH compared=N` line (plus one line per mismatch).
class DifferentialTestCase: TRTestCase {

    func differential(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                      _ body: (Impl) throws -> Fields) rethrows {
        let current = try body(.current)
        let oracle = try body(.oracle)
        let (n, mismatches) = Fields.compare(current, oracle)
        print("[DIFF] \(name): \(mismatches.isEmpty ? "MATCH" : "MISMATCH") compared=\(n) mismatches=\(mismatches.count)")
        for m in mismatches { print("[DIFF]   \(name) \(m)") }
        XCTAssertGreaterThan(n, 0, "\(name): nothing compared", file: file, line: line)
        XCTAssertTrue(mismatches.isEmpty, "\(name): \(mismatches.prefix(20).joined(separator: "; "))", file: file, line: line)
    }

    func run(_ s: SessionHandle, cancelAfterFirstProgress: Bool = false) -> Outcome {
        drive(timeout: 120) { o, done in
            s.start({ op, v in
                o.progress.append((op, v, Thread.isMainThread))
                if cancelAfterFirstProgress && o.progress.count == 1 { s.cancel() }
            }, { ok, e in done(ok, e) })
        }
    }

    func fullRange(_ src: URL) -> CMTimeRange { CMTimeRange(start: .zero, duration: AVURLAsset(url: src).duration) }

    /// Transcode with the same init choice as the pinned tests' `transcode(...)` helper.
    func transcodeRecord(_ impl: Impl, _ src: URL, video: Int? = nil, audio: Int? = nil, range: CMTimeRange? = nil,
                         out name: String = "out.mov", config: TranscodeConfig = TranscodeConfig(),
                         cancelAfterFirstProgress: Bool = false) -> Fields {
        let out = url("\(impl.rawValue)-\(name)")
        let s = impl.transcode(AVURLAsset(url: src), range: range ?? fullRange(src), video: video, audio: audio, out: out, configure: config)
        let o = run(s, cancelAfterFirstProgress: cancelAfterFirstProgress)
        var f = Record.outcome(o, impl: impl, progress: !cancelAfterFirstProgress)
        for (k, v) in s.meta.sorted(by: { $0.key < $1.key }) { f.exact("meta." + k, v) }
        f.merge("out.", Record.file(out))
        return f
    }

    func reverseRecord(_ impl: Impl, _ src: URL, video: Int? = nil, audio: Int? = nil, range: CMTimeRange? = nil,
                       out name: String = "out.mov", cancelAfterFirstProgress: Bool = false) -> Fields {
        let out = url("\(impl.rawValue)-\(name)")
        let s = impl.reverse(AVURLAsset(url: src), range: range ?? fullRange(src), video: video, audio: audio, out: out)
        let o = run(s, cancelAfterFirstProgress: cancelAfterFirstProgress)
        var f = Record.outcome(o, impl: impl, progress: !cancelAfterFirstProgress)
        f.merge("out.", Record.file(out))
        return f
    }

    enum ExportKind { case m4a, reverseWav }

    func exportRecord(_ impl: Impl, _ src: URL, index: Int, range: CMTimeRange? = nil, kind: ExportKind, out name: String,
                      windows: [(Double, Double)] = []) -> Fields {
        let e = impl.audioExporter(AVURLAsset(url: src), trackIndex: index, range: range)
        let out = url("\(impl.rawValue)-\(name)")
        let o = drive(timeout: 60) { _, done in
            switch kind {
            case .m4a: e.m4a(out, done)
            case .reverseWav: e.reverse(out, done)
            }
        }
        var f = Fields()
        f.exact("trackIndex", e.trackIndex == impl.audioTrackIndexAll ? "All" : "\(e.trackIndex)")
        f.merge("", Record.outcome(o, impl: impl, progress: false))
        f.merge("out.", Record.file(out))
        if !windows.isEmpty { f.merge("out.", Record.audioWindows(out, windows: windows)) }
        return f
    }
}

// MARK: - Transcode

final class DifferentialTranscodeTests: DifferentialTestCase {

    func testLegacyInit() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("T legacy") { transcodeRecord($0, src) }
    }

    func testIndexedInits() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("T v1 a0") { transcodeRecord($0, src, video: 1, audio: 0) }
        differential("T v2 a1") { transcodeRecord($0, src, video: 2, audio: 1) }
        differential("T v0 All") { transcodeRecord($0, src, video: 0, audio: $0.audioTrackIndexAll) }
    }

    func testOutOfRangeIndexes() throws {
        let src = try makeSource(Fixture.multiStream)
        for (v, a) in [(3, 0), (-1, 0), (0, 2), (0, -2), (7, -1)] {
            differential("T out-of-range v=\(v) a=\(a)") { transcodeRecord($0, src, video: v, audio: a, out: "bad-\(v)-\(a).mov") }
        }
    }

    func testSourceWithoutAudio() throws {
        let src = try makeSource(Fixture.videoOnly)
        for a in [0, 5, -1, -7] {
            differential("T no-audio a=\(a)") { transcodeRecord($0, src, video: 0, audio: a, out: "noaudio\(a).mov") }
        }
    }

    func testTrim() throws {
        let src = try makeSource(Fixture.multiStream)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        differential("T trim 1..2 a1") { transcodeRecord($0, src, video: 0, audio: 1, range: range) }
        differential("T trim 1..2 legacy") { transcodeRecord($0, src, range: range, out: "legacy.mov") }
    }

    func testTrimPastEnd() throws {
        let src = try makeSource(Fixture.videoOnly)
        let range = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 10, timescale: 1))
        differential("T trim past end") { transcodeRecord($0, src, video: 0, audio: 0, range: range) }
    }

    func testSizeFrameRateDataRate() throws {
        let src = try makeSource(Fixture.videoOnly)
        differential("T 160x120 10fps 500k") {
            transcodeRecord($0, src, config: TranscodeConfig(size: CGSize(width: 160, height: 120), frameRate: 10, estimatedDataRate: 500_000))
        }
        differential("T frameRate above source") { transcodeRecord($0, src, out: "60.mov", config: TranscodeConfig(frameRate: 60)) }
    }

    func testOddDimensions() throws {
        var spec = Fixture.videoOnly
        spec.videos[0].width = 321; spec.videos[0].height = 241
        let src = try makeSource(spec, skipReason: "H.264 encoder refused odd dimensions for the fixture")
        differential("T odd dimensions init(asset:)") { impl in
            let out = url("\(impl.rawValue)-odd.mov")
            let s = impl.transcode(AVURLAsset(url: src), range: nil, video: nil, audio: nil, out: out)
            var f = Record.outcome(run(s), impl: impl)
            for (k, v) in s.meta.sorted(by: { $0.key < $1.key }) { f.exact("meta." + k, v) }
            f.merge("out.", Record.file(out))
            return f
        }
    }

    func testMissingOutputURL() throws {
        let src = try makeSource(Fixture.videoOnly)
        differential("T missing outputURL") { impl in
            Record.outcome(run(impl.transcode(AVURLAsset(url: src), range: nil, video: nil, audio: nil, out: nil)), impl: impl)
        }
    }

    func testCancel() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("T cancel during run") { transcodeRecord($0, src, out: "c.mov", cancelAfterFirstProgress: true) }
        differential("T cancel before start") { impl in
            let out = url("\(impl.rawValue)-c0.mov")
            let s = impl.transcode(AVURLAsset(url: src), range: fullRange(src), video: nil, audio: nil, out: out)
            s.cancel()
            var f = Record.outcome(run(s), impl: impl)
            f.merge("out.", Record.file(out))
            return f
        }
    }

    // pinned bugs

    func testPinnedBug_audioStageFails_withoutError() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("T audio stage fails (nil error)") { impl in
            withFailingAudioStage(impl, "exportInM4ATo:completion:", error: nil) { transcodeRecord(impl, src, video: 0, audio: 0) }
        }
    }

    func testPinnedBug_audioStageFails_withError() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("T audio stage fails (error)") { impl in
            withFailingAudioStage(impl, "exportInM4ATo:completion:") { transcodeRecord(impl, src, video: 0, audio: 0) }
        }
    }

    func testAudioStreamEmptyInRange() throws {
        let src = try makeSource(Fixture.lateAudio)
        let range = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        differential("T empty audio in range") { impl in
            let calls = Atomic<[(Bool, NSError?)]>([])
            var f = withRecordedM4AStage(impl, calls) { transcodeRecord(impl, src, video: 0, audio: 0, range: range) }
            f.exact("m4aStage", calls.get().map { "ok=\($0.0) err=\($0.1.map { "\($0.domain)/\($0.code)" } ?? "nil")" })
            return f
        }
    }
}

// MARK: - Reverse

final class DifferentialReverseTests: DifferentialTestCase {

    func testLegacyInit() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("R legacy") { reverseRecord($0, src) }
    }

    func testIndexedInits() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("R v1 a1") { reverseRecord($0, src, video: 1, audio: 1) }
        differential("R v2 a0") { reverseRecord($0, src, video: 2, audio: 0) }
        differential("R v0 All") { reverseRecord($0, src, video: 0, audio: $0.audioTrackIndexAll) }
    }

    func testOutOfRangeIndexes() throws {
        let src = try makeSource(Fixture.multiStream)
        for (v, a) in [(3, 0), (-1, 0), (0, 2), (0, -2), (0, 5)] {
            differential("R out-of-range v=\(v) a=\(a)") { reverseRecord($0, src, video: v, audio: a, out: "bad-\(v)-\(a).mov") }
        }
    }

    func testSourceWithoutAudio() throws {
        let src = try makeSource(Fixture.videoOnly)
        for a in [0, 5, -1, -7] {
            differential("R no-audio a=\(a)") { reverseRecord($0, src, video: 0, audio: a, out: "noaudio\(a).mov") }
        }
    }

    func testTrim() throws {
        let src = try makeSource(Fixture.multiStream)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        differential("R trim 1..2") { reverseRecord($0, src, video: 0, audio: 0, range: range) }
    }

    func testMissingOutputURL() throws {
        let src = try makeSource(Fixture.videoOnly)
        differential("R missing outputURL") { impl in
            Record.outcome(run(impl.reverse(AVURLAsset(url: src), range: nil, video: nil, audio: nil, out: nil)), impl: impl)
        }
    }

    func testCancel() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("R cancel during run") { reverseRecord($0, src, out: "c.mov", cancelAfterFirstProgress: true) }
        differential("R cancel before start") { impl in
            let out = url("\(impl.rawValue)-c0.mov")
            let s = impl.reverse(AVURLAsset(url: src), range: fullRange(src), video: nil, audio: nil, out: out)
            s.cancel()
            var f = Record.outcome(run(s), impl: impl)
            f.merge("out.", Record.file(out))
            return f
        }
    }

    // pinned bugs

    func testPinnedBug_lateAudio() throws {
        let late = try makeSource(Fixture.lateAudio, name: "late.mov")
        differential("R late audio (legacy)") { reverseRecord($0, late) }
        let multi = try makeSource(Fixture.multiStream)
        differential("R late audio (v0 a1)") { reverseRecord($0, multi, video: 0, audio: 1, out: "idx.mov") }
    }

    func testPinnedBug_m4aStageFails_withError() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("R m4a stage fails (error)") { impl in
            withFailingAudioStage(impl, "exportInM4ATo:completion:") { reverseRecord(impl, src, video: 0, audio: 0) }
        }
    }

    func testWavStageFails() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("R wav stage fails (error)") { impl in
            withFailingAudioStage(impl, "exportReverseToURL:complete:") { reverseRecord(impl, src, video: 0, audio: 0) }
        }
        differential("R wav stage fails (nil error)") { impl in
            withFailingAudioStage(impl, "exportReverseToURL:complete:", error: nil) { reverseRecord(impl, src, video: 0, audio: 0, out: "nil.mov") }
        }
    }
}

// MARK: - Audio track exporter

final class DifferentialAudioExporterTests: DifferentialTestCase {

    func testM4A() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("E m4a 0") { exportRecord($0, src, index: 0, kind: .m4a, out: "a0.m4a") }
        differential("E m4a 1") { exportRecord($0, src, index: 1, kind: .m4a, out: "a1.m4a") }
        differential("E m4a All") { exportRecord($0, src, index: $0.audioTrackIndexAll, kind: .m4a, out: "all.m4a") }
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        differential("E m4a 1 trim 1..2") { exportRecord($0, src, index: 1, range: range, kind: .m4a, out: "a1t.m4a") }
        differential("E m4a All trim 1..2") { exportRecord($0, src, index: $0.audioTrackIndexAll, range: range, kind: .m4a, out: "allt.m4a") }
    }

    func testM4A_outOfRange() throws {
        let src = try makeSource(Fixture.multiStream)
        for index in [2, 5, -2] {
            differential("E m4a out-of-range \(index)") { exportRecord($0, src, index: index, kind: .m4a, out: "bad\(index).m4a") }
        }
    }

    func testReverseWav() throws {
        let src = try makeSource(Fixture.multiStream)
        differential("E wav 0") { exportRecord($0, src, index: 0, kind: .reverseWav, out: "rev0.wav") }
        differential("E wav 1") { exportRecord($0, src, index: 1, kind: .reverseWav, out: "rev1.wav") }
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        differential("E wav 0 trim 1..2") { exportRecord($0, src, index: 0, range: range, kind: .reverseWav, out: "rev0t.wav") }
        differential("E wav All") { exportRecord($0, src, index: $0.audioTrackIndexAll, kind: .reverseWav, out: "revAll.wav") }
        differential("E wav out-of-range 2") { exportRecord($0, src, index: 2, kind: .reverseWav, out: "rev2.wav") }
    }

    func testReverseWav_sampleOrder() throws {
        let spec = Fixture.Spec(videos: [Fixture.Video(width: 64, height: 64, color: Fixture.red)],
                                audios: [Fixture.Audio(frequency: 440, amplitude: 0.4, duration: 2.0, secondHalfFrequency: 1000)],
                                fps: 20, frames: 40)
        let src = try makeSource(spec)
        differential("E wav sample order") {
            exportRecord($0, src, index: 0, kind: .reverseWav, out: "order.wav", windows: [(0.2, 0.8), (1.2, 1.8)])
        }
    }

    func testNoAudioSource() throws {
        let src = try makeSource(Fixture.videoOnly)
        differential("E m4a no-audio 0") { exportRecord($0, src, index: 0, kind: .m4a, out: "na.m4a") }
        differential("E wav no-audio 0") { exportRecord($0, src, index: 0, kind: .reverseWav, out: "na.wav") }
    }
}

// MARK: - Historical fixes (encoder-dependent sources skip, never faked)

final class DifferentialHistoricalTests: DifferentialTestCase {

    private func spec(codec: AVVideoCodecType, alpha: Bool = false, hdr: Bool = false) -> Fixture.Spec {
        Fixture.Spec(videos: [Fixture.Video(width: 320, height: 240, color: Fixture.red, codec: codec, alpha: alpha, hdrHLG: hdr)],
                     audios: [Fixture.Audio(frequency: 440, amplitude: 0.2, duration: 3.0)])
    }

    private func both(_ label: String, _ src: URL) {
        differential("H \(label) transcode") { transcodeRecord($0, src, out: "t.mov") }
        differential("H \(label) reverse") { reverseRecord($0, src, out: "r.mov") }
    }

    func testHEVC() throws {
        both("hevc", try makeSource(spec(codec: .hevc), skipReason: "HEVC encoder unavailable on this platform"))
    }

    func testAlphaHEVC() throws {
        both("alpha hevc", try makeSource(spec(codec: .hevcWithAlpha, alpha: true), skipReason: "HEVC-with-alpha encoder unavailable on this platform"))
    }

    func testHDRHLG() throws {
        both("hdr hlg", try makeSource(spec(codec: .hevc, hdr: true), skipReason: "HEVC Main10 HLG encoder unavailable on this platform"))
    }

    func testProRes422() throws {
        both("prores422", try makeSource(spec(codec: .proRes422), skipReason: "ProRes 422 encoder unavailable on this platform"))
    }

    func testHEVCEncoderUnavailable_fallsBackToH264() throws {
        let src = try makeSource(spec(codec: .hevc), skipReason: "HEVC encoder unavailable to build the HEVC fixture")
        for kind in ["transcode", "reverse"] {
            differential("H no-hevc \(kind)") { impl in
                let rejected = Atomic(0)
                var f = withHEVCEncoderUnavailable(rejected: rejected) {
                    kind == "transcode" ? transcodeRecord(impl, src, out: "t.mov") : reverseRecord(impl, src, out: "r.mov")
                }
                f.exact("rejectedHEVCStarts", rejected.get())
                return f
            }
        }
    }
}

// MARK: - API surface: init state, error factory, settings helpers

final class DifferentialAPITests: DifferentialTestCase {

    /// Guards the frame itself: the two sides must really be different classes / domains.
    func testImplementationsAreDistinct() {
        XCTAssertFalse(ILABTranscodeSession.self === ORCILABTranscodeSession.self)
        XCTAssertFalse(ILABReverseVideoExportSession.self === ORCILABReverseVideoExportSession.self)
        XCTAssertFalse(ILABAudioTrackExporter.self === ORCILABAudioTrackExporter.self)
        XCTAssertNotEqual(Impl.current.errorDomain, Impl.oracle.errorDomain)
        XCTAssertEqual(Impl.current.audioTrackIndexAll, Impl.oracle.audioTrackIndexAll)
        print("[DIFF] classes: \(NSStringFromClass(ILABTranscodeSession.self)) vs \(NSStringFromClass(ORCILABTranscodeSession.self)); domains: \(Impl.current.errorDomain) vs \(Impl.oracle.errorDomain)")
    }

    func testInitState() throws {
        let src = try makeSource(Fixture.multiStream)
        let asset = AVURLAsset(url: src)
        let full = CMTimeRange(start: .zero, duration: asset.duration)
        let past = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 10, timescale: 1))
        for (v, a) in [(nil, nil), (0, 0), (1, 0), (2, -1), (9, 0), (0, 7)] as [(Int?, Int?)] {
            for (rn, r) in [("full", full), ("past", past)] {
                differential("A init transcode v=\(String(describing: v)) a=\(String(describing: a)) \(rn)") { $0.transcodeInitState(asset, range: r, video: v, audio: a) }
                differential("A init reverse v=\(String(describing: v)) a=\(String(describing: a)) \(rn)") { $0.reverseInitState(asset, range: r, video: v, audio: a) }
            }
        }
    }

    func testErrorFactories() {
        let codes = [-101, -102, -103, -104, -105, -106, -107, -108, -109, -110, -201, -202, -203, -204, -301]
        differential("A +ILABSessionError:") { impl in
            var f = Fields()
            for c in codes {
                let e = impl.sessionError(c)
                f.exact("\(c).domain", e.map { $0.domain == impl.errorDomain ? "<TR domain>" : $0.domain })
                f.exact("\(c).code", e?.code)
                f.exact("\(c).description", e?.localizedDescription)
            }
            return f
        }
        let statuses: [OSStatus] = [kAudioFileUnspecifiedError, kAudioFileUnsupportedFileTypeError, kAudioFileInvalidFileError,
                                    kAudioFileFileNotFoundError, kAudioFileEndOfFileError, 0, -1, 12345]
        differential("A +errorWithAudioFileStatusCode:") { impl in
            var f = Fields()
            for s in statuses {
                let e = impl.audioFileStatusError(s)
                f.exact("\(s).domain", e.domain); f.exact("\(s).code", e.code); f.exact("\(s).description", e.localizedDescription)
            }
            return f
        }
    }

    func testSettingsHelpers() throws {
        let codecs: [CMVideoCodecType] = [
            kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, kCMVideoCodecType_DolbyVisionHEVC,
            kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
            kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
            kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ, kCMVideoCodecType_MPEG4Video, kCMVideoCodecType_JPEG,
        ]
        let sizes = [CGSize(width: 64, height: 48), CGSize(width: 1920, height: 1080), CGSize(width: 1921, height: 1080), CGSize(width: 3840, height: 2160)]
        let bools = [false, true]
        differential("A settings helpers") { impl in
            var f = Fields()
            for c in codecs {
                let cc = Measure.fourCC(c)
                f.exact("isProResCodec(\(cc))", impl.isProRes(c))
                for s in sizes {
                    for hdr in bools {
                        for dolby in bools {
                            f.exact("compression(\(cc),\(s),hdr=\(hdr),dv=\(dolby))", impl.compressionProperties(s, 2e6, c, hdr, dolby))
                        }
                        for alpha in bools {
                            let props = impl.compressionProperties(s, 2e6, c, hdr, false) as! [AnyHashable: Any]
                            f.exact("output(\(cc),\(s),hdr=\(hdr),alpha=\(alpha))", impl.outputSettings(s, c, hdr, alpha, props))
                        }
                    }
                }
            }
            for s in sizes { for r in [5e5, 2e6, 2e7] as [CGFloat] { f.exact("default(\(s),\(r))", impl.defaultSettings(s, r)) } }
            for hdr in bools { for alpha in bools { for prores in bools {
                f.exact("reader(hdr=\(hdr),alpha=\(alpha),prores=\(prores))", impl.readerSettings(hdr, alpha, prores))
            } } }
            return f
        }
        let src = try makeSource(Fixture.multiStream)
        let tracks = Measure.asset(src).tracks
        differential("A track predicates") { impl in
            var f = Fields()
            for (i, t) in tracks.enumerated() {
                let p = impl.trackPredicates(t)
                f.exact("track[\(i)] \(t.mediaType.rawValue) proRes", p.proRes)
                f.exact("track[\(i)] \(t.mediaType.rawValue) dolby", p.dolby)
            }
            return f
        }
    }
}
