import AVFoundation
import TRTransformer
import XCTest

/// ILABTranscodeSession output, measured from the produced file.
/// Source: `Fixture.multiStream` (3 video streams told apart by colour/size/rotation, 2 audio streams by frequency/loudness;
/// audio 1 = 1000 Hz from 0.5 s to 1.5 s).
final class TranscodeTests: TRTestCase {

    // MARK: stream selection

    /// Legacy init `init(asset:timeRange:outputURL:)` (what the app calls): video stream 0, ALL audio streams mixed into one track.
    func testLegacyInit_usesVideo0_andMixesAllAudioIntoOneTrack() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = transcode(src)
        log("T legacy", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = Measure.videoTracks(out)
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v.first?.naturalSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(v.first?.codec, "avc1")
        assertColor(out, Fixture.red)
        assertForwardFrames(out, count: 60)
        XCTAssertEqual(Measure.duration(out), 3.0, accuracy: 0.1)

        XCTAssertEqual(Measure.audioTrackCount(out), 1, "mixed into a single output track")
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertGreaterThan(a.amp440, 0.1, "stream 0 (440 Hz) present")
        XCTAssertGreaterThan(a.amp1000, 0.15, "stream 1 (1000 Hz) present")
    }

    /// New init with audio index 0: only stream 0 is used.
    func testIndexedInit_video1_audio0_usesOnlyThoseStreams() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = transcode(src, video: 1, audio: 0)
        log("T v1 a0", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(v.naturalSize, CGSize(width: 240, height: 160))
        XCTAssertEqual(v.rotationDegrees, 90, "preferredTransform of the selected stream is kept")
        assertColor(out, Fixture.green)
        assertForwardFrames(out, count: 60)

        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05, "stream 0 only")
        XCTAssertLessThan(a.amp1000, 0.02, "stream 1 absent")
        XCTAssertEqual(try XCTUnwrap(a.onset), 0, accuracy: 0.05)
    }

    /// New init with audio index 1: only stream 1 (late tone) is used and its late onset is kept.
    func testIndexedInit_video2_audio1_usesOnlyThoseStreams_andKeepsLateOnset() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = transcode(src, video: 2, audio: 1)
        log("T v2 a1", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(v.naturalSize, CGSize(width: 160, height: 96))
        XCTAssertEqual(v.rotationDegrees, 0)
        assertColor(out, Fixture.blue)

        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertLessThan(a.amp440, 0.02, "stream 0 absent")
        XCTAssertGreaterThan(a.amp1000, 0.3, "stream 1 only")
        XCTAssertEqual(try XCTUnwrap(a.onset), 0.5, accuracy: 0.06, "late tone keeps its 0.5 s onset")
        XCTAssertEqual(try XCTUnwrap(a.offset), 1.5, accuracy: 0.06)
    }

    /// New init with ILABAudioTrackIndexAll: mixes like the legacy init.
    func testIndexedInit_audioAll_mixes() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = transcode(src, video: 0, audio: ILABAudioTrackIndexAll)
        log("T v0 all", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertGreaterThan(a.amp440, 0.1)
        XCTAssertGreaterThan(a.amp1000, 0.15)
        XCTAssertEqual(try XCTUnwrap(a.onset), 0, accuracy: 0.05)
    }

    // MARK: invalid indexes

    func testOutOfRangeIndexes_failWithInvalidTrackIndex_once() throws {
        let src = try makeSource(Fixture.multiStream)
        for (v, a) in [(3, 0), (-1, 0), (0, 2), (0, -2), (7, ILABAudioTrackIndexAll)] {
            let (o, out) = transcode(src, video: v, audio: a, out: "bad-\(v)-\(a).mov")
            XCTAssertFalse(o.succeeded, "v=\(v) a=\(a)")
            XCTAssertEqual(o.error?.code, ILABSessionErrorInvalidTrackIndex.rawValue, "v=\(v) a=\(a): \(describe(o))")
            XCTAssertEqual(o.error?.domain, kILABReverseVideoExportSessionErrorDomain)
            XCTAssertEqual(o.completionCount, 1, "v=\(v) a=\(a)")
            XCTAssertTrue(o.completedSynchronously, "index validation completes before transcodeAsynchronously returns")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    /// A source without audio takes the no-audio path whatever audio index is asked for.
    func testSourceWithoutAudio_ignoresAudioIndex() throws {
        let src = try makeSource(Fixture.videoOnly)
        for a in [0, 5, ILABAudioTrackIndexAll, -7] {
            let (o, out) = transcode(src, video: 0, audio: a, out: "noaudio\(a).mov")
            XCTAssertTrue(o.succeeded, "a=\(a): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertEqual(Measure.audioTrackCount(out), 0, "a=\(a)")
            XCTAssertEqual(Measure.videoTracks(out).count, 1)
        }
    }

    // MARK: time range / size / frame rate

    func testTimeRange_trimsVideoAndAudio() throws {
        let src = try makeSource(Fixture.multiStream)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        let (o, out) = transcode(src, video: 0, audio: 1, range: range)
        log("T trim 1..2 a1", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.duration(out), 1.0, accuracy: 0.1)
        let f = Measure.frames(out)
        XCTAssertEqual(f.count, 20)
        XCTAssertEqual(f.first?.index ?? -99, 20, accuracy: 1, "first frame is source frame 20 (t = 1 s)")
        XCTAssertEqual(f.first?.pts ?? -1, 0, accuracy: 0.01, "re-based to 0")
        // audio 1 lives in 0.5...1.5 → in the trimmed output it is 0...0.5
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(try XCTUnwrap(a.onset), 0, accuracy: 0.06)
        XCTAssertEqual(try XCTUnwrap(a.offset), 0.5, accuracy: 0.06)
    }

    /// A time range running past the end is clamped to the source end.
    func testTimeRangePastEnd_isClamped() throws {
        let src = try makeSource(Fixture.videoOnly)
        let range = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 10, timescale: 1))
        let (o, out) = transcode(src, video: 0, audio: 0, range: range)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.duration(out), 1.0, accuracy: 0.1)
        XCTAssertEqual(Measure.frames(out).first?.index ?? -99, 40, accuracy: 1)
    }

    /// App sets size / frameRate / estimatedDataRate. Lower frame rate drops frames; output size follows `size`.
    func testFrameRateAndSize_settings() throws {
        let src = try makeSource(Fixture.videoOnly)
        let (o, out) = transcode(src, configure: { s in
            s.size = CGSize(width: 160, height: 120)
            s.frameRate = 10
            s.estimatedDataRate = 500_000
        })
        log("T 10fps 160x120", out)
        XCTAssertTrue(o.succeeded, describe(o))
        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(v.naturalSize, CGSize(width: 160, height: 120))
        let f = Measure.frames(out)
        // Measured: 31 of 60 frames kept (first and last source frames both kept), nominal ≈10.16 fps, duration 3.05 s.
        XCTAssertEqual(f.count, 31, "frame-skip logic keeps 31 of 60")
        XCTAssertEqual(f.first?.index ?? -99, 0, accuracy: 1)
        XCTAssertEqual(f.last?.index ?? -99, 59, accuracy: 1)
        XCTAssertEqual(Double(v.nominalFPS), 10, accuracy: 0.5)
        assertNonDecreasing(f.map(\.index))
    }

    /// frameRate above the source fps is clamped to the source fps (no frames dropped).
    func testFrameRateAboveSource_isClamped() throws {
        let src = try makeSource(Fixture.videoOnly)
        var captured: CGFloat = 0
        let (o, out) = transcode(src, configure: { s in s.frameRate = 60; captured = s.frameRate })
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(captured, 20, accuracy: 0.01)
        XCTAssertEqual(Measure.frames(out).count, 60, accuracy: 1)
    }

    /// Odd source dimensions are rounded down to even.
    func testOddDimensions_roundedDownToEven() throws {
        var spec = Fixture.videoOnly
        spec.videos[0].width = 321; spec.videos[0].height = 241
        let src = try makeSource(spec, skipReason: "H.264 encoder refused odd dimensions for the fixture")
        let session = ILABTranscodeSession(asset: AVURLAsset(url: src))
        XCTAssertEqual(session.sourceSize, CGSize(width: 320, height: 240))
        session.outputURL = url("odd.mov")
        let o = run(session)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.videoTracks(url("odd.mov")).first?.naturalSize, CGSize(width: 320, height: 240))
    }

    // MARK: pinned bug

    /// PINNED BUG (b): the audio stage's result flag is ignored. When the audio exporter fails WITHOUT an NSError,
    /// transcode reports success and the output silently has no audio.
    /// Injected: `-[ILABAudioTrackExporter exportInM4ATo:completion:]` calls completion(NO, nil).
    func testPinnedBug_failingAudioStage_withoutError_completesAsSuccess_withoutAudio() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingM4AExport(error: nil) { transcode(src, video: 0, audio: 0) }
        log("T audio-fail nil-error", out)
        XCTAssertTrue(o.succeeded, "PINNED BUG: audio failure is swallowed: \(describe(o))")
        XCTAssertNil(o.error)
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0, "output has no audio although the source had audio")
        XCTAssertEqual(Measure.videoTracks(out).count, 1)
    }

    /// Measured (differs from the handoff's "(b) still completes as success"): when the audio exporter fails WITH an NSError,
    /// the error is kept in `lastError` and the final completion reports failure with THAT audio error, after the
    /// video-only file has already been written at outputURL (the file is left behind).
    func testPinnedBug_failingAudioStage_withError_failsWithAudioError_butLeavesVideoOnlyOutput() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingM4AExport { transcode(src, video: 0, audio: 0) }
        log("T audio-fail error", out)
        XCTAssertFalse(o.succeeded, describe(o))
        XCTAssertEqual(o.error?.domain, AVFoundationErrorDomain, "the audio stage's error is what the caller gets")
        XCTAssertEqual(o.error?.code, AVError.Code.exportFailed.rawValue)
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "PINNED: output file left behind on failure")
        XCTAssertEqual(Measure.videoTracks(out).count, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
    }

    /// Real (non-injected) case: the only audio stream has no media inside the time range.
    /// Measured: the M4A stage reports success (ok, nil error) and the output has no audio track.
    func testAudioStreamEmptyInRange_completesAsSuccess_withoutAudioTrack() throws {
        let src = try makeSource(Fixture.lateAudio)   // audio only in 0.5...1.5
        let range = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        let m4a = Atomic<[(Bool, NSError?)]>([])
        let (o, out) = withRecordedM4AExport(m4a) { transcode(src, video: 0, audio: 0, range: range) }
        log("T empty-audio-range", out)
        print("[TRT] empty-audio-range m4a stage: \(m4a.get().map { "ok=\($0.0) err=\(String(describing: $0.1))" })")
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.duration(out), 1.0, accuracy: 0.1)
        XCTAssertEqual(m4a.get().count, 1)
        XCTAssertEqual(m4a.get().first?.0, true, "M4A stage itself succeeds")
        XCTAssertNil(m4a.get().first?.1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
        let tone = (0..<Measure.audioTrackCount(out)).compactMap { Measure.audio(out, track: $0) }.contains { $0.peak > 0.05 }
        XCTAssertFalse(tone, "no audible audio in the output")
    }

    // MARK: helpers

    func assertColor(_ out: URL, _ c: Fixture.RGB, file: StaticString = #filePath, line: UInt = #line) {
        guard let f = Measure.frames(out).first else { return XCTFail("no frames", file: file, line: line) }
        XCTAssertEqual(f.top.r, Double(c.r), accuracy: 40, "r", file: file, line: line)
        XCTAssertEqual(f.top.g, Double(c.g), accuracy: 40, "g", file: file, line: line)
        XCTAssertEqual(f.top.b, Double(c.b), accuracy: 40, "b", file: file, line: line)
    }

    func assertForwardFrames(_ out: URL, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let f = Measure.frames(out)
        XCTAssertEqual(f.count, count, "frame count", file: file, line: line)
        XCTAssertEqual(f.first?.index ?? -99, 0, accuracy: 1, "first frame", file: file, line: line)
        XCTAssertEqual(f.last?.index ?? -99, count - 1, accuracy: 1, "last frame", file: file, line: line)
        assertNonDecreasing(f.map(\.index), file: file, line: line)
    }
}

/// Indexes must go up (±1 decode noise allowed).
func assertNonDecreasing(_ xs: [Int], file: StaticString = #filePath, line: UInt = #line) {
    for i in 1..<max(1, xs.count) where xs[i] < xs[i - 1] - 1 {
        return XCTFail("not forward at \(i): \(xs)", file: file, line: line)
    }
}

/// Indexes must go down (±1 decode noise allowed).
func assertNonIncreasing(_ xs: [Int], file: StaticString = #filePath, line: UInt = #line) {
    for i in 1..<max(1, xs.count) where xs[i] > xs[i - 1] + 1 {
        return XCTFail("not reversed at \(i): \(xs)", file: file, line: line)
    }
}
