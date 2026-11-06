import AVFoundation
import CoreVideo

/// Read-back of produced files. Everything here only measures; no expectations live here.
enum Measure {
    struct VideoTrack {
        var naturalSize: CGSize
        var transform: CGAffineTransform
        var nominalFPS: Float
        var codec: String           // FourCC, e.g. "avc1", "hvc1", "muxa"
        var timeRange: CMTimeRange
        var containsAlpha: Bool
        var rotationDegrees: Int { Int((atan2(transform.b, transform.a) * 180 / .pi).rounded()) }
    }

    struct Frame {
        var pts: Double
        var top: (r: Double, g: Double, b: Double, a: Double)       // top-left quarter: identifying colour
        var topRightAlpha: Double                                   // top-right quarter alpha (transparent in alpha fixtures)
        var gray: Double                                            // bottom half: frame-number gray
        var index: Int { Fixture.frame(forGray: gray) }
    }

    struct AudioTrack {
        var duration: Double        // track timeRange duration
        var rms: Double             // over the whole decoded signal
        var onset: Double?          // first |x| > threshold (seconds, presentation time)
        var offset: Double?         // last |x| > threshold
        var amp440: Double          // sine amplitude estimate at 440 Hz over the active region
        var amp1000: Double         // ... at 1000 Hz
        var peak: Double
    }

    static func asset(_ url: URL) -> AVURLAsset { AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }

    static func duration(_ url: URL) -> Double { asset(url).duration.seconds }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }

    static func videoTracks(_ url: URL) -> [VideoTrack] {
        asset(url).tracks(withMediaType: .video).map { t in
            let desc = t.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let codec = desc.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            let alpha = desc.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) } != nil
            return VideoTrack(naturalSize: t.naturalSize, transform: t.preferredTransform, nominalFPS: t.nominalFrameRate,
                              codec: codec, timeRange: t.timeRange, containsAlpha: alpha)
        }
    }

    /// Decodes every frame of a video track as BGRA and samples the fixture regions (natural, untransformed orientation).
    static func frames(_ url: URL, track index: Int = 0) -> [Frame] {
        let a = asset(url)
        let tracks = a.tracks(withMediaType: .video)
        guard index < tracks.count, let reader = try? AVAssetReader(asset: a) else { return [] }
        let out = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var result: [Frame] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            func avg(_ cx: Int, _ cy: Int) -> (Double, Double, Double, Double) {
                var s = (0.0, 0.0, 0.0, 0.0); var n = 0.0
                for y in max(0, cy - 3)...min(h - 1, cy + 3) {
                    for x in max(0, cx - 3)...min(w - 1, cx + 3) {
                        let p = base + y * stride + x * 4
                        s.0 += Double(p[2]); s.1 += Double(p[1]); s.2 += Double(p[0]); s.3 += Double(p[3]); n += 1
                    }
                }
                return (s.0 / n, s.1 / n, s.2 / n, s.3 / n)
            }
            let tl = avg(w / 4, h / 4)
            let tr = avg(w * 3 / 4, h / 4)
            let bottom = avg(w / 2, h * 3 / 4)
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            result.append(Frame(pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds,
                                top: (tl.0, tl.1, tl.2, tl.3), topRightAlpha: tr.3,
                                gray: (bottom.0 + bottom.1 + bottom.2) / 3))
        }
        return result
    }

    static func audioTrackCount(_ url: URL) -> Int { asset(url).tracks(withMediaType: .audio).count }

    static let audioRate = 44100.0

    /// Decodes an audio track to mono float @44.1 kHz, presentation-time aligned (leading empty edits become a later first PTS).
    static func audio(_ url: URL, track index: Int = 0, threshold: Float = 0.05) -> AudioTrack? {
        guard let timeline = timeline(url, track: index) else { return nil }
        let rate = audioRate
        let tracks = asset(url).tracks(withMediaType: .audio)
        return analyse(timeline, rate: rate, duration: tracks[index].timeRange.duration.seconds, threshold: threshold)
    }

    static func timeline(_ url: URL, track index: Int = 0) -> [Float]? {
        let a = asset(url)
        let tracks = a.tracks(withMediaType: .audio)
        guard index < tracks.count, let reader = try? AVAssetReader(asset: a) else { return nil }
        let rate = audioRate
        let out = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(out)
        guard reader.startReading() else { return nil }
        // Place samples on a timeline so a late first PTS shows as a late onset.
        var timeline: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            var data = [Float](repeating: 0, count: len / 4)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            let start = max(0, Int((pts * rate).rounded()))
            if timeline.count < start { timeline.append(contentsOf: [Float](repeating: 0, count: start - timeline.count)) }
            for (i, v) in data.enumerated() {
                let k = start + i
                if k < timeline.count { timeline[k] = v } else { timeline.append(v) }
            }
        }
        return timeline
    }

    static func analyse(_ timeline: [Float], rate: Double, duration: Double, threshold: Float) -> AudioTrack {
        var sum = 0.0, peak = 0.0
        var first: Int?, last: Int?
        for (i, v) in timeline.enumerated() {
            sum += Double(v * v); peak = max(peak, Double(abs(v)))
            if abs(v) > threshold { if first == nil { first = i }; last = i }
        }
        let rms = timeline.isEmpty ? 0 : sqrt(sum / Double(timeline.count))
        var a440 = 0.0, a1000 = 0.0
        if let f = first, let l = last, l > f {
            // skip edges (codec ramps) and measure the steady part
            let margin = min(2048, (l - f) / 4)
            let seg = Array(timeline[(f + margin)...(l - margin)])
            a440 = goertzelAmplitude(seg, frequency: 440, rate: rate)
            a1000 = goertzelAmplitude(seg, frequency: 1000, rate: rate)
        }
        return AudioTrack(duration: duration, rms: rms,
                          onset: first.map { Double($0) / rate }, offset: last.map { Double($0) / rate },
                          amp440: a440, amp1000: a1000, peak: peak)
    }

    /// Single-bin DFT magnitude normalised to sine amplitude.
    static func goertzelAmplitude(_ x: [Float], frequency: Double, rate: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let w = 2 * Double.pi * frequency / rate
        var re = 0.0, im = 0.0
        for (n, v) in x.enumerated() {
            re += Double(v) * cos(w * Double(n))
            im -= Double(v) * sin(w * Double(n))
        }
        return 2 * sqrt(re * re + im * im) / Double(x.count)
    }
}
