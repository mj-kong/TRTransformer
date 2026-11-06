import AVFoundation
import TRTransformer
import XCTest

/// ILABReverseVideoExportSession output, measured from the produced file. Source: `Fixture.multiStream` unless noted.
final class ReverseTests: TRTestCase {

    // MARK: stream selection

    /// Legacy init `init(asset:timeRange:outputURL:)` (what the app calls): video stream 0 reversed, audio stream 0 ONLY (never mixed).
    func testLegacyInit_reversesVideo0_andUsesAudioStream0Only() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src)
        log("R legacy", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(Measure.videoTracks(out).count, 1)
        XCTAssertEqual(v.naturalSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(v.codec, "avc1")
        assertColor(out, Fixture.red)
        assertReversedFrames(out, count: 60)
        XCTAssertEqual(Measure.duration(out), 2.95, accuracy: 0.02, "59 frames @ 20 fps")

        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05, "stream 0")
        XCTAssertLessThan(a.amp1000, 0.02, "stream 1 not mixed in")
    }

    func testIndexedInit_video1_audio1_usesOnlyThoseStreams() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 1, audio: 1)
        log("R v1 a1", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(v.naturalSize, CGSize(width: 240, height: 160))
        XCTAssertEqual(v.rotationDegrees, 90, "preferredTransform of the selected stream is kept")
        assertColor(out, Fixture.green)
        assertReversedFrames(out, count: 60)

        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertLessThan(a.amp440, 0.02, "stream 0 absent")
        XCTAssertGreaterThan(a.amp1000, 0.3, "stream 1 only")
    }

    func testIndexedInit_video2_audio0() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 2, audio: 0)
        log("R v2 a0", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.videoTracks(out).first?.naturalSize, CGSize(width: 160, height: 96))
        assertColor(out, Fixture.blue)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05)
        XCTAssertLessThan(a.amp1000, 0.02)
    }

    /// ILABAudioTrackIndexAll is treated as stream 0 for reverse (no mixing).
    func testIndexedInit_audioAll_usesStream0() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 0, audio: ILABAudioTrackIndexAll)
        log("R all", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05)
        XCTAssertLessThan(a.amp1000, 0.02)
    }

    // MARK: invalid indexes / no audio

    func testOutOfRangeIndexes_failWithInvalidTrackIndex_once() throws {
        let src = try makeSource(Fixture.multiStream)
        for (v, a) in [(3, 0), (-1, 0), (0, 2), (0, -2), (0, 5)] {
            let (o, out) = reverse(src, video: v, audio: a, out: "bad-\(v)-\(a).mov")
            XCTAssertFalse(o.succeeded, "v=\(v) a=\(a)")
            XCTAssertEqual(o.error?.code, ILABSessionErrorInvalidTrackIndex.rawValue, "v=\(v) a=\(a): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1, "v=\(v) a=\(a)")
            XCTAssertTrue(o.completedSynchronously)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    func testSourceWithoutAudio_ignoresAudioIndex() throws {
        let src = try makeSource(Fixture.videoOnly)
        for a in [0, 5, ILABAudioTrackIndexAll, -7] {
            let (o, out) = reverse(src, video: 0, audio: a, out: "noaudio\(a).mov")
            XCTAssertTrue(o.succeeded, "a=\(a): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertEqual(Measure.audioTrackCount(out), 0, "a=\(a)")
            assertReversedFrames(out, count: 60)
        }
    }

    // MARK: time range

    func testTimeRange_reversesOnlyTheRange() throws {
        let src = try makeSource(Fixture.multiStream)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        let (o, out) = reverse(src, video: 0, audio: 0, range: range)
        log("R trim 1..2", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.duration(out), 1.0, accuracy: 0.1)
        let f = Measure.frames(out)
        XCTAssertEqual(f.count, 19, "PINNED: last frame of the range (source 39) dropped")
        XCTAssertEqual(f.first?.index ?? -99, 38, accuracy: 1, "starts at the second-to-last frame of the range")
        XCTAssertEqual(f.last?.index ?? -99, 20, accuracy: 1, "ends at the first frame of the range")
        assertNonIncreasing(f.map(\.index))
    }

    // MARK: pinned bugs

    /// PINNED BUG (a): the late tone (0.5...1.5 s in a 3 s clip) should land at 1.5...2.5 s after reversing;
    /// the reversed audio is instead pulled to start at 0 s.
    func testPinnedBug_lateAudio_reversedAudioStartsAtZero() throws {
        let src = try makeSource(Fixture.lateAudio)
        let srcAudio = try XCTUnwrap(Measure.audio(src))
        XCTAssertEqual(try XCTUnwrap(srcAudio.onset), 0.5, accuracy: 0.06, "fixture: tone starts late")

        let (o, out) = reverse(src)
        log("R late audio", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.duration(out), 2.95, accuracy: 0.02)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.duration, 1.45, accuracy: 0.06, "audio track only as long as the stream's media end (1.5 s), not the clip")
        XCTAssertEqual(try XCTUnwrap(a.onset), 0.0, accuracy: 0.06, "PINNED BUG: correct would be 1.5 s")
        XCTAssertEqual(try XCTUnwrap(a.offset), 1.0, accuracy: 0.08, "PINNED BUG: correct would be 2.5 s")
        XCTAssertGreaterThan(a.amp1000, 0.3)
    }

    /// Same pinned bug through the multi-stream index path (audio 1 is the late tone).
    func testPinnedBug_lateAudio_indexedStream_startsAtZero() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 0, audio: 1)
        log("R late audio idx", out)
        XCTAssertTrue(o.succeeded, describe(o))
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(try XCTUnwrap(a.onset), 0.0, accuracy: 0.06, "PINNED BUG: correct would be 1.5 s")
    }

    /// PINNED BUG (b) in reverse: a failing M4A conversion stage is swallowed even WITH an NSError
    /// (that step never stores lastError) → success, output without audio.
    func testPinnedBug_failingM4AStage_withError_stillCompletesAsSuccess_withoutAudio() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingM4AExport { reverse(src, video: 0, audio: 0) }
        log("R audio-fail", out)
        XCTAssertTrue(o.succeeded, "PINNED: audio failure is swallowed: \(describe(o))")
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
        assertReversedFrames(out, count: 60)
    }

    /// When the WAV reversal stage fails WITH an NSError, that error is stored and the final completion reports it,
    /// after the video-only output has already been written (file left behind).
    func testFailingWavReverseStage_withError_failsWithAudioError_butLeavesVideoOnlyOutput() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingReverseAudioExport { reverse(src, video: 0, audio: 0) }
        log("R wav-fail error", out)
        XCTAssertFalse(o.succeeded, describe(o))
        XCTAssertEqual(o.error?.domain, AVFoundationErrorDomain)
        XCTAssertEqual(o.error?.code, AVError.Code.exportFailed.rawValue)
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "PINNED: output file left behind on failure")
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
    }

    /// WAV reversal stage failing WITHOUT an NSError → swallowed, success without audio.
    func testPinnedBug_failingWavReverseStage_withoutError_completesAsSuccess() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingReverseAudioExport(error: nil) { reverse(src, video: 0, audio: 0) }
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
    }

    // MARK: helpers

    func assertColor(_ out: URL, _ c: Fixture.RGB, file: StaticString = #filePath, line: UInt = #line) {
        guard let f = Measure.frames(out).first else { return XCTFail("no frames", file: file, line: line) }
        XCTAssertEqual(f.top.r, Double(c.r), accuracy: 40, "r", file: file, line: line)
        XCTAssertEqual(f.top.g, Double(c.g), accuracy: 40, "g", file: file, line: line)
        XCTAssertEqual(f.top.b, Double(c.b), accuracy: 40, "b", file: file, line: line)
    }

    /// PINNED BUG: the reversal never writes the source's last frame (each pass reads [passStart, passEnd) and the final
    /// pass ends AT the last sample time), so a 60-frame source gives 59 frames starting at source frame 58.
    func assertReversedFrames(_ out: URL, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let f = Measure.frames(out)
        XCTAssertEqual(f.count, count - 1, "PINNED: last source frame dropped", file: file, line: line)
        XCTAssertEqual(f.first?.index ?? -99, count - 2, accuracy: 1, "first output frame = second-to-last source frame", file: file, line: line)
        XCTAssertEqual(f.last?.index ?? -99, 0, accuracy: 1, "last output frame = first source frame", file: file, line: line)
        XCTAssertEqual(f.first?.pts ?? -1, 0, accuracy: 0.01, file: file, line: line)
        assertNonIncreasing(f.map(\.index), file: file, line: line)
    }
}
