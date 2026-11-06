import AVFoundation
import TRTransformer
import XCTest

/// Public surface and callback contract. The first test only has to COMPILE: it spells the API exactly the way
/// the app (Shared/NexEditorMediaCreator.swift) and the v1.12.19 stream-selection callers use it.
final class APIContractTests: TRTestCase {

    // MARK: compile-only

    func testAppCallSites_compile() {
        let never: (AVAsset, CMTimeRange, URL) -> Void = { avasset, timeRange, url in
            // VideoTransform.Transcode.perform
            let session: ILABTranscodeSession = .init(
                asset: avasset,
                timeRange: timeRange,
                outputURL: url
            )
            session.size = CGSize(width: 1280, height: 720)
            session.frameRate = CGFloat(30)
            session.estimatedDataRate = CGFloat(1_000_000)
            session.transcodeAsynchronously { message, value in
                _ = (message, value as Float)
            } complete: { succeeded, error in
                _ = succeeded as Bool
                if let error = error {
                    if let avError = error as? AVError, avError.code == .diskFull { return }
                    else if error._code == ILABSessionErrorUserCancel.rawValue { return }
                }
            }
            session.cancelTranscode()

            // VideoTransform.Reverse.perform
            let reverse: ILABReverseVideoExportSession = .init(
                asset: avasset,
                timeRange: timeRange,
                outputURL: url
            )
            reverse.exportAsynchronously { message, value in
                _ = (message, value as Float)
            } complete: { succeeded, error in
                _ = succeeded as Bool
                if let error = error, error._code == ILABSessionErrorUserCancel.rawValue { return }
            }
            reverse.cancelReverseExport()

            // v1.12.19 stream selection
            let t2: ILABTranscodeSession = .init(asset: avasset, timeRange: timeRange, videoTrackIndex: 1, audioTrackIndex: ILABAudioTrackIndexAll, outputURL: url)
            let r2: ILABReverseVideoExportSession = .init(asset: avasset, timeRange: timeRange, videoTrackIndex: 1, audioTrackIndex: 0, outputURL: url)
            let t3 = ILABTranscodeSession(asset: avasset, timeRange: timeRange, videoTrackIndex: 0, audioTrackIndex: 1)
            let r3 = ILABReverseVideoExportSession(asset: avasset, timeRange: timeRange, videoTrackIndex: 0, audioTrackIndex: 1)
            let e = ILABAudioTrackExporter(asset: avasset, trackIndex: ILABAudioTrackIndexAll)
            let e2 = ILABAudioTrackExporter(asset: avasset, trackIndex: 0, timeRange: timeRange)
            let code: Int = ILABSessionErrorInvalidTrackIndex.rawValue
            let all: Int = ILABAudioTrackIndexAll
            _ = (t2.videoTrackIndex, t2.audioTrackIndex, r2.videoTrackIndex, r2.audioTrackIndex, t3, r3, e, e2, code, all)
        }
        _ = never
    }

    // MARK: constants

    func testErrorCodeRawValues_andConstants() {
        let expected: [(ILABSessionError, Int)] = [
            (ILABSessionErrorMissingOutputURL, -101),
            (ILABSessionErrorAVAssetReaderStartReading, -102),
            (ILABSessionErrorVideoNoSamples, -103),
            (ILABSessionErrorAVAssetWriterStartWriting, -104),
            (ILABSessionErrorVideoUnableToWirteFrame, -105),
            (ILABSessionErrorUserCancel, -106),
            (ILABSessionErrorAVAssetReaderReading, -107),
            (ILABSessionErrorAVAssetExportSessionCompatibility, -108),
            (ILABSessionErrorInsertTrack, -109),
            (ILABSessionErrorAVAssetExportSessionCreate, -110),
            (ILABSessionErrorAudioInvalidTrackIndex, -201),
            (ILABSessionErrorAudioCannotAddInput, -202),
            (ILABSessionErrorAudioCanAddOutput, -203),
            (ILABSessionErrorNoCompleteAudioExport, -204),
            (ILABSessionErrorInvalidTrackIndex, -301),
        ]
        for (e, raw) in expected { XCTAssertEqual(e.rawValue, raw) }
        XCTAssertEqual(ILABAudioTrackIndexAll, -1)
        XCTAssertEqual(kILABReverseVideoExportSessionErrorDomain, "kILABReverseVideoExportSessionErrorDomain")
    }

    /// `+[NSError ILABSessionError:]` domain/code/description per code.
    func testErrorFactory_domainCodeAndDescription() {
        let expected: [(ILABSessionError, String)] = [
            (ILABSessionErrorMissingOutputURL, "Missing Output URL."),
            (ILABSessionErrorUserCancel, "User cancel."),
            (ILABSessionErrorAVAssetReaderReading, "Cannot decode."),
            (ILABSessionErrorAudioInvalidTrackIndex, "The specified track index is invalid."),
            (ILABSessionErrorInvalidTrackIndex, "The requested video or audio track index is out of range."),
        ]
        for (code, text) in expected {
            let e = NSError.ilabSessionError(code)! as NSError
            XCTAssertEqual(e.domain, kILABReverseVideoExportSessionErrorDomain)
            XCTAssertEqual(e.code, code.rawValue)
            XCTAssertEqual(e.localizedDescription, text)
        }
    }

    // MARK: init-time state

    func testInitState_legacyDefaults_andSourceMeta() throws {
        let src = try makeSource(Fixture.multiStream)
        let asset = AVURLAsset(url: src)
        let full = CMTimeRange(start: .zero, duration: asset.duration)

        let t = ILABTranscodeSession(asset: asset, timeRange: full, outputURL: url("t.mov"))
        XCTAssertEqual(t.videoTrackIndex, 0)
        XCTAssertEqual(t.audioTrackIndex, ILABAudioTrackIndexAll, "legacy transcode init mixes")
        XCTAssertTrue(t.sourceReady)
        XCTAssertEqual(t.sourceVideoTracks, 3)
        XCTAssertEqual(t.sourceAudioTracks, 2)
        XCTAssertEqual(t.sourceFPS, 20, accuracy: 0.01)
        XCTAssertEqual(t.sourceSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(t.sourceDuration.seconds, 3.0, accuracy: 0.05)
        XCTAssertEqual(t.sourceDurationSeconds, 0, "PINNED: declared but never assigned")
        XCTAssertEqual(t.size, t.sourceSize)
        XCTAssertEqual(t.frameRate, 20, accuracy: 0.01)
        XCTAssertTrue(t.deleteCacheFile)
        XCTAssertFalse(t.showDebug)

        let r: ILABReverseVideoExportSession = ILABReverseVideoExportSession(asset: asset, timeRange: full, outputURL: url("r.mov"))
        XCTAssertEqual(r.videoTrackIndex, 0)
        XCTAssertEqual(r.audioTrackIndex, 0, "legacy reverse init uses stream 0")
        XCTAssertEqual(r.samplesPerPass, 40)
        XCTAssertTrue(r.deleteCacheFile)
        XCTAssertFalse(r.skipAudio)
        XCTAssertEqual(r.sourceDurationSeconds, 0, "PINNED: declared but never assigned")

        // Source meta follows the selected video stream.
        let t1 = ILABTranscodeSession(asset: asset, timeRange: full, videoTrackIndex: 1, audioTrackIndex: 0, outputURL: url("t1.mov"))
        XCTAssertEqual(t1.sourceSize, CGSize(width: 240, height: 160))
        XCTAssertEqual(t1.sourceTransform, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0))
        let r2: ILABReverseVideoExportSession = ILABReverseVideoExportSession(asset: asset, timeRange: full, videoTrackIndex: 2, audioTrackIndex: ILABAudioTrackIndexAll, outputURL: url("r2.mov"))
        XCTAssertEqual(r2.sourceSize, CGSize(width: 160, height: 96))
        XCTAssertEqual(r2.audioTrackIndex, ILABAudioTrackIndexAll, "stored as given; treated as 0 when exporting")

        // Out-of-range index: init still succeeds, meta falls back to zero (failure is reported by the export call).
        let bad = ILABTranscodeSession(asset: asset, timeRange: full, videoTrackIndex: 9, audioTrackIndex: 0, outputURL: url("bad.mov"))
        XCTAssertEqual(bad.sourceSize, .zero)
        XCTAssertEqual(bad.sourceVideoTracks, 3)
    }

    // MARK: completion / progress contract

    func testTranscode_completionOnce_offMain_progressOnMain_monotonic_reachesOne() throws {
        let src = try makeSource(Fixture.multiStream)
        let s = ILABTranscodeSession(asset: AVURLAsset(url: src), timeRange: CMTimeRange(start: .zero, duration: AVURLAsset(url: src).duration), outputURL: url("p.mov"))
        let o = run(s)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(o.completionOnMainThread, false, "success completion arrives on a background queue")
        XCTAssertFalse(o.completedSynchronously)
        XCTAssertFalse(o.progress.isEmpty)
        XCTAssertTrue(o.progress.allSatisfy(\.onMain), "progress is delivered on the main queue")
        assertMonotonic(o.progressValues)
        XCTAssertEqual(o.progress.last?.value ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(o.progress.last?.operation, "Saving Transcoded Video")
        XCTAssertEqual(Set(o.progress.dropLast().map(\.operation)), ["Transcoding Video"])
        XCTAssertTrue(o.progressValues.allSatisfy { $0 >= 0 && $0 <= 1 })
        print("[TRT] transcode progress count=\(o.progress.count) first=\(o.progressValues.first ?? -1)")
    }

    func testReverse_completionOnce_offMain_progressOnMain_monotonic_reachesOne() throws {
        let src = try makeSource(Fixture.multiStream)
        let s: ILABReverseVideoExportSession = ILABReverseVideoExportSession(asset: AVURLAsset(url: src), timeRange: CMTimeRange(start: .zero, duration: AVURLAsset(url: src).duration), outputURL: url("p.mov"))
        let o = run(s)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(o.completionOnMainThread, false)
        XCTAssertTrue(o.progress.allSatisfy(\.onMain))
        assertMonotonic(o.progressValues)
        XCTAssertEqual(o.progress.last?.value ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(o.progress.last?.operation, "Saving Reversed Video")
        let analyzing = o.progress.filter { $0.operation == "Analyzing Source Video" }.map(\.value)
        let reversing = o.progress.filter { $0.operation == "Reversing Video" }.map(\.value)
        XCTAssertFalse(analyzing.isEmpty); XCTAssertFalse(reversing.isEmpty)
        XCTAssertTrue(analyzing.allSatisfy { $0 >= 0 && $0 <= 0.5 }, "analysis phase maps to 0...0.5")
        XCTAssertTrue(reversing.allSatisfy { $0 > 0.5 && $0 <= 1.0 }, "reversal phase maps to 0.5...1")
        // PINNED: the reversal phase tops out at 0.5 + 0.5 * 59/60 because the last source frame is never written
        // (see ReverseTests pinned frame-drop); only the "Saving Reversed Video" step reports 1.0.
        XCTAssertEqual(reversing.last ?? 0, 0.5 + 0.5 * 59.0 / 60.0, accuracy: 0.0001)
    }

    func testMissingOutputURL_failsSynchronously_once() throws {
        let src = try makeSource(Fixture.videoOnly)
        let t = ILABTranscodeSession(asset: AVURLAsset(url: src))
        let o1 = run(t)
        XCTAssertEqual(o1.error?.code, ILABSessionErrorMissingOutputURL.rawValue)
        XCTAssertEqual(o1.completionCount, 1); XCTAssertTrue(o1.completedSynchronously); XCTAssertEqual(o1.completionOnMainThread, true)

        let r: ILABReverseVideoExportSession = ILABReverseVideoExportSession(asset: AVURLAsset(url: src))
        let o2 = run(r)
        XCTAssertEqual(o2.error?.code, ILABSessionErrorMissingOutputURL.rawValue)
        XCTAssertEqual(o2.completionCount, 1); XCTAssertTrue(o2.completedSynchronously)
    }

    func testInvalidIndex_completesOnCallerThread() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, _) = transcode(src, video: 5, audio: 0)
        XCTAssertEqual(o.completionOnMainThread, true)
        let (o2, _) = reverse(src, video: 0, audio: 9)
        XCTAssertEqual(o2.completionOnMainThread, true)
    }

    func testExistingOutputFile_isReplaced() throws {
        let src = try makeSource(Fixture.videoOnly)
        let out = url("out.mov")
        try Data("junk".utf8).write(to: out)
        let (o, _) = transcode(src)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.videoTracks(out).count, 1)
        try Data("junk".utf8).write(to: out)
        let (o2, _) = reverse(src)
        XCTAssertTrue(o2.succeeded, describe(o2))
        XCTAssertEqual(Measure.videoTracks(out).count, 1)
    }

    /// deleteCacheFile (default YES) leaves no `*-tempAudio.*` / `*-tempVideo.mov` in Caches.
    func testTempFiles_removedFromCaches() throws {
        let src = try makeSource(Fixture.multiStream)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        func temps() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: caches.path)) ?? []).filter { $0.contains("-tempAudio") || $0.contains("-tempVideo") || $0 == "exported-audio.wav" })
        }
        let before = temps()
        let (o1, _) = transcode(src, out: "a.mov")
        let (o2, _) = reverse(src, out: "b.mov")
        XCTAssertTrue(o1.succeeded && o2.succeeded)
        XCTAssertEqual(temps().subtracting(before), [], "no temp files left behind")
    }

    // MARK: cancellation

    func testTranscode_cancelDuringRun_endsWithUserCancel_once() throws {
        let src = try makeSource(Fixture.multiStream)
        let asset = AVURLAsset(url: src)
        let s = ILABTranscodeSession(asset: asset, timeRange: CMTimeRange(start: .zero, duration: asset.duration), outputURL: url("c.mov"))
        let o = run(s, cancelAfterFirstProgress: true)
        XCTAssertFalse(o.succeeded)
        XCTAssertEqual(o.error?.code, ILABSessionErrorUserCancel.rawValue, describe(o))
        XCTAssertEqual(o.error?.domain, kILABReverseVideoExportSessionErrorDomain)
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("c.mov").path))
    }

    func testTranscode_cancelBeforeStart_endsWithUserCancel_once() throws {
        let src = try makeSource(Fixture.videoOnly)
        let asset = AVURLAsset(url: src)
        let s = ILABTranscodeSession(asset: asset, timeRange: CMTimeRange(start: .zero, duration: asset.duration), outputURL: url("c.mov"))
        s.cancelTranscode()
        let o = run(s)
        XCTAssertEqual(o.error?.code, ILABSessionErrorUserCancel.rawValue, describe(o))
        XCTAssertEqual(o.completionCount, 1)
    }

    func testReverse_cancelDuringRun_endsWithUserCancel_once() throws {
        let src = try makeSource(Fixture.multiStream)
        let asset = AVURLAsset(url: src)
        let s: ILABReverseVideoExportSession = ILABReverseVideoExportSession(asset: asset, timeRange: CMTimeRange(start: .zero, duration: asset.duration), outputURL: url("c.mov"))
        let o = run(s, cancelAfterFirstProgress: true)
        XCTAssertFalse(o.succeeded)
        XCTAssertEqual(o.error?.code, ILABSessionErrorUserCancel.rawValue, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("c.mov").path))
    }

    func testReverse_cancelBeforeStart_endsWithUserCancel_once() throws {
        let src = try makeSource(Fixture.videoOnly)
        let asset = AVURLAsset(url: src)
        let s: ILABReverseVideoExportSession = ILABReverseVideoExportSession(asset: asset, timeRange: CMTimeRange(start: .zero, duration: asset.duration), outputURL: url("c.mov"))
        s.cancelReverseExport()
        let o = run(s)
        XCTAssertEqual(o.error?.code, ILABSessionErrorUserCancel.rawValue, describe(o))
        XCTAssertEqual(o.completionCount, 1)
    }

    private func assertMonotonic(_ xs: [Float], file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<max(1, xs.count) where xs[i] < xs[i - 1] {
            return XCTFail("progress went back at \(i): \(xs[i - 1]) → \(xs[i])", file: file, line: line)
        }
    }
}
