import AVFoundation
import TRTransformer
import XCTest

/// ILABAudioTrackExporter on `Fixture.multiStream` (audio 0 = 440 Hz amp 0.2 whole clip, audio 1 = 1000 Hz amp 0.5 at 0.5...1.5 s).
final class AudioTrackExporterTests: TRTestCase {

    private func exportM4A(_ src: URL, index: Int, name: String) -> (Bool, NSError?, Int, URL) {
        let exporter: ILABAudioTrackExporter = ILABAudioTrackExporter(asset: AVURLAsset(url: src), trackIndex: index)
        XCTAssertEqual(exporter.trackIndex, index)
        let out = url(name)
        var result: (Bool, NSError?) = (false, nil)
        let o = drive(timeout: 60) { _, done in
            exporter.exportInM4A(to: out, completion: { ok, error in done(ok, error as NSError?) })
        }
        result = (o.succeeded, o.error)
        return (result.0, result.1, o.completionCount, out)
    }

    private func exportReverse(_ src: URL, index: Int, name: String) -> (Outcome, URL) {
        let exporter: ILABAudioTrackExporter = ILABAudioTrackExporter(asset: AVURLAsset(url: src), trackIndex: index)
        let out = url(name)
        let o = drive(timeout: 60) { _, done in
            exporter.exportReverse(to: out, complete: { ok, error in done(ok, error as NSError?) })
        }
        return (o, out)
    }

    func testM4A_index0_exportsOnlyStream0() throws {
        let src = try makeSource(Fixture.multiStream)
        let (ok, err, calls, out) = exportM4A(src, index: 0, name: "a0.m4a")
        log("E m4a 0", out)
        XCTAssertTrue(ok, "\(String(describing: err))"); XCTAssertEqual(calls, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        XCTAssertEqual(Measure.videoTracks(out).count, 0)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05)
        XCTAssertLessThan(a.amp1000, 0.02)
        XCTAssertEqual(Measure.duration(out), 3.0, accuracy: 0.1)
    }

    func testM4A_index1_exportsOnlyStream1_keepingLateOnset() throws {
        let src = try makeSource(Fixture.multiStream)
        let (ok, err, calls, out) = exportM4A(src, index: 1, name: "a1.m4a")
        log("E m4a 1", out)
        XCTAssertTrue(ok, "\(String(describing: err))"); XCTAssertEqual(calls, 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertLessThan(a.amp440, 0.02)
        XCTAssertGreaterThan(a.amp1000, 0.3)
        XCTAssertEqual(try XCTUnwrap(a.onset), 0.5, accuracy: 0.06)
    }

    func testM4A_all_mixesEveryStreamIntoOneTrack() throws {
        let src = try makeSource(Fixture.multiStream)
        let (ok, err, calls, out) = exportM4A(src, index: ILABAudioTrackIndexAll, name: "all.m4a")
        log("E m4a all", out)
        XCTAssertTrue(ok, "\(String(describing: err))"); XCTAssertEqual(calls, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertGreaterThan(a.amp440, 0.1)
        XCTAssertGreaterThan(a.amp1000, 0.15)
    }

    func testM4A_outOfRange_failsWithAudioInvalidTrackIndex_once_synchronously() throws {
        let src = try makeSource(Fixture.multiStream)
        for index in [2, 5, -2] {
            let exporter: ILABAudioTrackExporter = ILABAudioTrackExporter(asset: AVURLAsset(url: src), trackIndex: index)
            let o = drive(timeout: 10) { _, done in
                exporter.exportInM4A(to: url("bad\(index).m4a"), completion: { ok, error in done(ok, error as NSError?) })
            }
            XCTAssertFalse(o.succeeded, "index \(index)")
            XCTAssertEqual(o.error?.code, ILABSessionErrorAudioInvalidTrackIndex.rawValue, "index \(index)")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertTrue(o.completedSynchronously)
        }
    }

    /// The WAV reversal of a single stream. Same late-onset behaviour as pinned bug (a): reversed tone starts at 0.
    func testReverseWav_index1_onlyThatStream_reversedToneStartsAtZero() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = exportReverse(src, index: 1, name: "rev1.wav")
        log("E rev 1", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertLessThan(a.amp440, 0.02)
        XCTAssertGreaterThan(a.amp1000, 0.3)
        XCTAssertEqual(try XCTUnwrap(a.onset), 0, accuracy: 0.06, "PINNED BUG (a): leading silence is dropped")
        // The stream's media ends at 1.5 s: the WAV covers 0...1.5 (leading 0.5 s silence + tone), reversed → tone then silence.
        // The clip's remaining 1.5...3.0 s (where the stream has no media) is not represented at all.
        XCTAssertEqual(Measure.duration(out), 1.5, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(a.offset), 1.0, accuracy: 0.06)
    }

    func testReverseWav_index0_onlyStream0() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = exportReverse(src, index: 0, name: "rev0.wav")
        log("E rev 0", out)
        XCTAssertTrue(o.succeeded, describe(o))
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05)
        XCTAssertLessThan(a.amp1000, 0.02)
        XCTAssertEqual(Measure.duration(out), 3.0, accuracy: 0.1)
    }

    /// Reverse WAV does not support "All": ILABAudioTrackIndexAll and out-of-range both fail with -201.
    func testReverseWav_allOrOutOfRange_failsWithAudioInvalidTrackIndex() throws {
        let src = try makeSource(Fixture.multiStream)
        for index in [ILABAudioTrackIndexAll, 2] {
            let (o, out) = exportReverse(src, index: index, name: "rbad\(index).wav")
            XCTAssertFalse(o.succeeded, "index \(index)")
            XCTAssertEqual(o.error?.code, ILABSessionErrorAudioInvalidTrackIndex.rawValue, "index \(index): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    /// Sample order really is reversed: a tone that is 440 Hz in its first half and 1000 Hz in its second half
    /// comes out 1000 Hz first.
    func testReverseWav_reversesSampleOrder() throws {
        let spec = Fixture.Spec(videos: [Fixture.Video(width: 64, height: 64, color: Fixture.red)],
                                audios: [Fixture.Audio(frequency: 440, amplitude: 0.4, duration: 2.0, secondHalfFrequency: 1000)],
                                fps: 20, frames: 40)
        let src = try makeSource(spec)
        let (o, out) = exportReverse(src, index: 0, name: "order.wav")
        log("E rev order", out)
        XCTAssertTrue(o.succeeded, describe(o))
        let x = try XCTUnwrap(Measure.timeline(out))
        let r = Measure.audioRate
        let firstHalf = Array(x[Int(0.2 * r)..<Int(0.8 * r)]), secondHalf = Array(x[Int(1.2 * r)..<Int(1.8 * r)])
        XCTAssertGreaterThan(Measure.goertzelAmplitude(firstHalf, frequency: 1000, rate: r), 0.3, "starts with the source's end (1000 Hz)")
        XCTAssertLessThan(Measure.goertzelAmplitude(firstHalf, frequency: 440, rate: r), 0.05)
        XCTAssertGreaterThan(Measure.goertzelAmplitude(secondHalf, frequency: 440, rate: r), 0.3, "ends with the source's start (440 Hz)")
        XCTAssertLessThan(Measure.goertzelAmplitude(secondHalf, frequency: 1000, rate: r), 0.05)
    }
}
