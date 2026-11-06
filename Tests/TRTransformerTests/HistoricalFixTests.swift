import AVFoundation
import TRTransformer
import VideoToolbox
import XCTest

/// Cases behind past fixes. Sources whose encoder is unavailable on the running platform are skipped (never faked).
///
/// - v1.12.14 (6840094): device without an HEVC encoder → writer start fails → retry with H.264 default settings.
/// - v1.12.16 (ca06b84): alpha video → ARGB reader + HEVC-with-alpha writer.
/// - v1.12.17 (c71e68f): ProRes source → HEVC Main profile (not Main10).
/// - v1.12.18 (38a08bd): HEVC / Dolby Vision profile selection (Main vs Main10), Dolby Vision codec → HEVC.
final class HistoricalFixTests: TRTestCase {

    private func spec(codec: AVVideoCodecType, alpha: Bool = false, hdr: Bool = false) -> Fixture.Spec {
        Fixture.Spec(videos: [Fixture.Video(width: 320, height: 240, color: Fixture.red, codec: codec, alpha: alpha, hdrHLG: hdr)],
                     audios: [Fixture.Audio(frequency: 440, amplitude: 0.2, duration: 3.0)])
    }

    private func both(_ src: URL) -> [(String, Outcome, URL)] {
        let (t, tu) = transcode(src, out: "t.mov")
        let (r, ru) = reverse(src, out: "r.mov")
        return [("transcode", t, tu), ("reverse", r, ru)]
    }

    // MARK: v1.12.16 alpha

    func testAlphaHEVC_v1_12_16_keepsAlpha_inTranscodeAndReverse() throws {
        let src = try makeSource(spec(codec: .hevcWithAlpha, alpha: true), skipReason: "HEVC-with-alpha encoder unavailable on this platform")
        let srcTrack = try XCTUnwrap(Measure.videoTracks(src).first)
        print("[TRT] alpha source codec=\(srcTrack.codec) alpha=\(srcTrack.containsAlpha)")
        try XCTSkipUnless(srcTrack.containsAlpha, "fixture writer did not mark the HEVC track as containing alpha")
        for (label, o, out) in both(src) {
            log("H alpha \(label)", out)
            XCTAssertTrue(o.succeeded, "\(label): \(describe(o))")
            let v = try XCTUnwrap(Measure.videoTracks(out).first)
            // HEVC-with-alpha is stored as 'hvc1' + the ContainsAlphaChannel extension (not a separate FourCC).
            XCTAssertEqual(v.codec, "hvc1", label)
            XCTAssertTrue(v.containsAlpha, "\(label): HEVC with alpha")
            let f = try XCTUnwrap(Measure.frames(out).first)
            XCTAssertLessThan(f.topRightAlpha, 30, "\(label): transparent region stays transparent")
            XCTAssertGreaterThan(f.top.a, 220, "\(label): opaque region stays opaque")
        }
    }

    func testAlphaProRes4444_v1_12_16_becomesHEVCWithAlpha() throws {
        let src = try makeSource(spec(codec: .proRes4444, alpha: true), skipReason: "ProRes 4444 encoder unavailable on this platform")
        let srcTrack = try XCTUnwrap(Measure.videoTracks(src).first)
        print("[TRT] prores4444 source codec=\(srcTrack.codec) alpha=\(srcTrack.containsAlpha)")
        for (label, o, out) in both(src) {
            log("H prores4444 \(label)", out)
            XCTAssertTrue(o.succeeded, "\(label): \(describe(o))")
            let v = try XCTUnwrap(Measure.videoTracks(out).first)
            XCTAssertEqual(v.codec, "hvc1", label)
            XCTAssertEqual(v.containsAlpha, srcTrack.containsAlpha, label)
            if srcTrack.containsAlpha {
                let f = try XCTUnwrap(Measure.frames(out).first)
                XCTAssertLessThan(f.topRightAlpha, 30, label)
            }
        }
    }

    // MARK: v1.12.17 ProRes

    func testProRes422_v1_12_17_transcodesAndReversesToHEVC() throws {
        let src = try makeSource(spec(codec: .proRes422), skipReason: "ProRes 422 encoder unavailable on this platform")
        XCTAssertEqual(Measure.videoTracks(src).first?.codec, "apcn")
        for (label, o, out) in both(src) {
            log("H prores422 \(label)", out)
            XCTAssertTrue(o.succeeded, "\(label): \(describe(o))")
            XCTAssertEqual(Measure.videoTracks(out).first?.codec, "hvc1", label)
            let f = Measure.frames(out)
            XCTAssertEqual(f.count, 60, accuracy: 1, label)
            XCTAssertEqual(f.first?.top.r ?? 0, Double(Fixture.red.r), accuracy: 40, label)
        }
    }

    // MARK: v1.12.18 HEVC profile / Dolby Vision

    func testHEVC_v1_12_18_transcodesAndReversesToHEVC() throws {
        let src = try makeSource(spec(codec: .hevc), skipReason: "HEVC encoder unavailable on this platform")
        for (label, o, out) in both(src) {
            log("H hevc \(label)", out)
            XCTAssertTrue(o.succeeded, "\(label): \(describe(o))")
            XCTAssertEqual(Measure.videoTracks(out).first?.codec, "hvc1", label)
            XCTAssertEqual(Measure.frames(out).count, 60, accuracy: 1, label)
        }
    }

    /// HLG 10-bit HEVC. Whether the HDR branch (10-bit reader, BT.2020/HLG writer) is taken depends on
    /// AVPlayer.eligibleForHDRPlayback on the running platform; both outcomes must succeed.
    func testHDRHLG_HEVC_transcodesAndReverses() throws {
        let src = try makeSource(spec(codec: .hevc, hdr: true), skipReason: "HEVC Main10 HLG encoder unavailable on this platform")
        let srcHDR = Measure.asset(src).tracks(withMediaType: .video).first?.hasMediaCharacteristic(.containsHDRVideo) ?? false
        print("[TRT] HDR source containsHDR=\(srcHDR) eligibleForHDRPlayback=\(AVPlayer.eligibleForHDRPlayback)")
        for (label, o, out) in both(src) {
            log("H hdr \(label)", out)
            XCTAssertTrue(o.succeeded, "\(label): \(describe(o))")
            XCTAssertEqual(Measure.videoTracks(out).first?.codec, "hvc1", label)
            let outHDR = Measure.asset(out).tracks(withMediaType: .video).first?.hasMediaCharacteristic(.containsHDRVideo) ?? false
            if srcHDR && AVPlayer.eligibleForHDRPlayback {
                XCTAssertTrue(outHDR, "\(label): HDR branch keeps HLG")
            }
            print("[TRT] HDR \(label) out containsHDR=\(outHDR)")
        }
    }

    // MARK: v1.12.14 HEVC encoder unavailable

    /// Simulates a device without an HEVC encoder: `-[AVAssetWriter startWriting]` returns NO for HEVC writers.
    /// The session must retry with the H.264 default settings and succeed.
    func testHEVCEncoderUnavailable_v1_12_14_fallsBackToH264() throws {
        let src = try makeSource(spec(codec: .hevc), skipReason: "HEVC encoder unavailable to build the HEVC fixture")
        let rejected = Atomic(0)
        let results = withHEVCEncoderUnavailable(rejected: rejected) { both(src) }
        XCTAssertGreaterThanOrEqual(rejected.get(), 2, "one refused HEVC attempt per session")
        for (label, o, out) in results {
            log("H no-hevc \(label)", out)
            XCTAssertTrue(o.succeeded, "\(label): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertEqual(Measure.videoTracks(out).first?.codec, "avc1", "\(label): H.264 fallback")
            XCTAssertEqual(Measure.frames(out).count, 60, accuracy: 1, label)
        }
    }

    /// Same fallback with a ProRes source (first try is HEVC for ProRes too).
    func testHEVCEncoderUnavailable_ProResSource_fallsBackToH264() throws {
        let src = try makeSource(spec(codec: .proRes422), skipReason: "ProRes 422 encoder unavailable on this platform")
        let rejected = Atomic(0)
        let (o, out) = withHEVCEncoderUnavailable(rejected: rejected) { transcode(src) }
        XCTAssertGreaterThanOrEqual(rejected.get(), 1)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.videoTracks(out).first?.codec, "avc1")
    }

    // MARK: settings helpers (TRTransformAPI.h, pure functions)

    private func profile(_ d: NSDictionary) -> String? { d[AVVideoProfileLevelKey] as? String }

    func testCompressionProperties_profileSelection() {
        let small = CGSize(width: 1280, height: 720), big = CGSize(width: 3840, height: 2160)
        let main10 = kVTProfileLevel_HEVC_Main10_AutoLevel as String, hevcMain = kVTProfileLevel_HEVC_Main_AutoLevel as String

        // v1.12.18: Dolby Vision → Main10, whatever the codec
        XCTAssertEqual(profile(makeCompressionProperties(small, 1e6, kCMVideoCodecType_HEVC, false, true) as NSDictionary), main10)
        // v1.12.17: ProRes (any flavour) and HEVC → HEVC Main, also with HDR
        for c in [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
                  kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
                  kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha] {
            XCTAssertEqual(profile(makeCompressionProperties(small, 1e6, c, false, false) as NSDictionary), hevcMain, Measure.fourCC(c))
            XCTAssertEqual(profile(makeCompressionProperties(small, 1e6, c, true, false) as NSDictionary), hevcMain, "HDR " + Measure.fourCC(c))
        }
        // H.264 sources: Main ≤ 1080p, High + CABAC above
        let h = makeCompressionProperties(small, 2e6, kCMVideoCodecType_H264, false, false) as NSDictionary
        XCTAssertEqual(profile(h), AVVideoProfileLevelH264MainAutoLevel)
        XCTAssertEqual(h[AVVideoAverageBitRateKey] as? Double, 2e6)
        XCTAssertEqual(h[AVVideoAllowFrameReorderingKey] as? Bool, false)
        XCTAssertNil(h[AVVideoH264EntropyModeKey])
        let hb = makeCompressionProperties(big, 2e6, kCMVideoCodecType_H264, false, false) as NSDictionary
        XCTAssertEqual(profile(hb), AVVideoProfileLevelH264HighAutoLevel)
        XCTAssertEqual(hb[AVVideoH264EntropyModeKey] as? String, AVVideoH264EntropyModeCABAC)
        XCTAssertEqual(hb[AVVideoAllowFrameReorderingKey] as? Bool, true)
        // HDR adds metadata insertion
        let hdr = makeCompressionProperties(small, 1e6, kCMVideoCodecType_HEVC, true, false) as NSDictionary
        XCTAssertEqual(hdr[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] as? String, kVTHDRMetadataInsertionMode_Auto as String)
        XCTAssertNil((makeCompressionProperties(small, 1e6, kCMVideoCodecType_HEVC, false, false) as NSDictionary)[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String])
    }

    func testOutputSettings_codecMapping() {
        func codec(_ c: CMVideoCodecType, alpha: Bool) -> String? {
            (makeVideoOutputSettings(CGSize(width: 64, height: 64), c, false, alpha, [:]) as NSDictionary)[AVVideoCodecKey] as? String
        }
        XCTAssertEqual(codec(kCMVideoCodecType_H264, alpha: false), AVVideoCodecType.h264.rawValue)
        XCTAssertEqual(codec(kCMVideoCodecType_H264, alpha: true), AVVideoCodecType.h264.rawValue, "alpha only matters for HEVC/ProRes sources")
        XCTAssertEqual(codec(kCMVideoCodecType_HEVC, alpha: false), AVVideoCodecType.hevc.rawValue)
        XCTAssertEqual(codec(kCMVideoCodecType_HEVC, alpha: true), AVVideoCodecType.hevcWithAlpha.rawValue)
        XCTAssertEqual(codec(kCMVideoCodecType_HEVCWithAlpha, alpha: false), AVVideoCodecType.hevcWithAlpha.rawValue)
        XCTAssertEqual(codec(kCMVideoCodecType_DolbyVisionHEVC, alpha: false), AVVideoCodecType.hevc.rawValue, "v1.12.18")
        XCTAssertEqual(codec(kCMVideoCodecType_AppleProRes4444XQ, alpha: false), AVVideoCodecType.hevcWithAlpha.rawValue)
        for c in [kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422,
                  kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy] {
            XCTAssertEqual(codec(c, alpha: false), AVVideoCodecType.hevc.rawValue, Measure.fourCC(c))
            XCTAssertEqual(codec(c, alpha: true), AVVideoCodecType.hevcWithAlpha.rawValue, Measure.fourCC(c))
        }
        XCTAssertEqual(codec(kCMVideoCodecType_AppleProResRAW, alpha: false), AVVideoCodecType.h264.rawValue, "RAW is not mapped → H.264")

        let hdr = makeVideoOutputSettings(CGSize(width: 64, height: 48), kCMVideoCodecType_HEVC, true, false, [:]) as NSDictionary
        XCTAssertEqual(hdr[AVVideoWidthKey] as? Double, 64)
        XCTAssertEqual(hdr[AVVideoHeightKey] as? Double, 48)
        let color = hdr[AVVideoColorPropertiesKey] as? [String: String]
        XCTAssertEqual(color?[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(color?[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_2020)
        XCTAssertEqual(color?[AVVideoYCbCrMatrixKey], AVVideoYCbCrMatrix_ITU_R_2020)

        // v1.12.14 fallback settings are always H.264
        let def = makeVideoDefaultSettings(CGSize(width: 64, height: 48), makeDefaultCompressionProperties(CGSize(width: 64, height: 48), 1e6)) as NSDictionary
        XCTAssertEqual(def[AVVideoCodecKey] as? String, AVVideoCodecType.h264.rawValue)
        XCTAssertEqual(profile(def[AVVideoCompressionPropertiesKey] as! NSDictionary), AVVideoProfileLevelH264MainAutoLevel)
    }

    func testReaderSettings_pixelFormatPriority() {
        func fmt(_ hdr: Bool, _ alpha: Bool, _ prores: Bool) -> UInt32? {
            (makeVideoReaderSettings(hdr, alpha, prores) as NSDictionary)[kCVPixelBufferPixelFormatTypeKey as String] as? UInt32
        }
        XCTAssertEqual(fmt(true, true, true), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "HDR wins")
        XCTAssertEqual(fmt(false, true, true), kCVPixelFormatType_32ARGB, "then alpha (v1.12.16)")
        XCTAssertEqual(fmt(false, false, true), kCVPixelFormatType_4444AYpCbCr16, "then ProRes")
        XCTAssertEqual(fmt(false, false, false), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    func testCodecPredicates() throws {
        XCTAssertTrue(isProResCodec(kCMVideoCodecType_AppleProRes422))
        XCTAssertTrue(isProResCodec(kCMVideoCodecType_AppleProResRAWHQ))
        XCTAssertFalse(isProResCodec(kCMVideoCodecType_HEVC))
        // Track-level predicates on a real H.264 track
        let src = try makeSource(Fixture.videoOnly)
        let track = try XCTUnwrap(Measure.asset(src).tracks(withMediaType: .video).first)
        XCTAssertFalse(isProResType(track))
        XCTAssertFalse(isDolbyVisionType(track))
    }

    func testDolbyVisionPredicate_onPlainHEVCTrack_isFalse() throws {
        let src = try makeSource(spec(codec: .hevc), skipReason: "HEVC encoder unavailable on this platform")
        let track = try XCTUnwrap(Measure.asset(src).tracks(withMediaType: .video).first)
        XCTAssertFalse(isDolbyVisionType(track), "HEVC with extensions but no dvvC atom is not Dolby Vision")
    }
}
