//
//  ILABReverseVideoExportSession.swift
//
//  Created by Jon Gilkison on 8/15/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//  Copyright © 2017 chrissung. All rights reserved.
//

import AVFoundation
import UIKit
import VideoToolbox

private struct ReversePass {
    var passStartTime: CMTime
    var passEndTime: CMTime
    var timeStartIndex: Int
    var timeEndIndex: Int
    var frameStartIndex: Int
    var frameEndIndex: Int
}

/**
 Utility class for reversing videos
 */
@objc(ILABReverseVideoExportSession)
@objcMembers
open class ILABReverseVideoExportSession: NSObject {

    open private(set) var sourceReady: Bool = false                              /**< Source is loaded and ready to be reversed */
    open private(set) var sourceVideoTracks: Int = 0                             /**< Number of video tracks on source asset, anything beyond the 1st will be ignored/skipped */
    open private(set) var sourceAudioTracks: Int = 0                             /**< Number of audio tracks on source asset */
    open private(set) var sourceDuration: CMTime = CMTime()                      /**< Duration of source asset */
    open private(set) var sourceDurationSeconds: TimeInterval = 0                /**< Duration in seconds of the source asset */
    open private(set) var sourceFPS: Float = 0                                   /**< Maximum FPS of the source asset */
    open private(set) var sourceTransform: CGAffineTransform = zeroAffineTransform /**< Source transform */
    open private(set) var sourceSize: CGSize = CGSize.zero                       /**< Natural size of the source asset */
    open private(set) var videoTrackIndex: Int = 0                               /**< 0-based index into the source's video tracks to use, default 0 */
    open private(set) var audioTrackIndex: Int = 0                               /**< 0-based audio track to reverse, default 0; ILABAudioTrackIndexAll is treated as 0 */

    open var showDebug: Bool = false                       /**< Show debug output messages when reversing */
    open var samplesPerPass: Int = 0                       /**< Samples per pass when reversing video */
    open var skipAudio: Bool = false                       /**< Skip the processing of audio */
    open var outputURL: URL! = nil                         /**< URL to output reverse video to */
    open var deleteCacheFile: Bool = false                 /**< After finishing reverse work, delete temporary files in the Library/Caches, default value is YES */

    private var sourceEstimatedDataRate: Float = 0
    private var timeRange: CMTimeRange = CMTimeRange()
    private var lastError: Error?
    private var isCanceled: Bool = false

    private var sourceAsset: AVAsset?
    private var reversingVideoAsset: AVAsset?
    private var reversedAudioAsset: AVAsset?
    private var exportSession: AVAssetExportSession?
    private var audioExporter: ILABAudioTrackExporter?

    private var containsHDRVideo: Bool = false
    private var isProResType: Bool = false
    private var isDolbyVisionType: Bool = false
    private var containsAlphaChannel: Bool = false
    private var sourceCodecType: CMVideoCodecType = 0

    // MARK: - Init/Dealloc

    public override init() {
        super.init()
    }

    /**
     Create a new instance

     @param sourceVideoURL The URL for the source video
     @return The new instance
     */
    @objc(initWithURL:)
    public convenience init!(url sourceVideoURL: URL!) {
        if !((sourceVideoURL?.path).map { FileManager.default.fileExists(atPath: $0) } ?? false) {
            NSException(name: NSExceptionName("Invalid input file."),
                        reason: String(format: "The file '%@' could not be located.", ((sourceVideoURL?.path).map { $0 as NSString } ?? "(null)") as NSString),
                        userInfo: nil).raise()
        }

        self.init(asset: AVURLAsset(url: sourceVideoURL))
    }

    /**
     Create a new instance

     @param sourceAsset The source AVAsset to reverse
     @prarm timeRange The time range of the asset to be reversed.
     @return The new instance
     */
    public convenience init!(asset sourceAsset: AVAsset!, timeRange: CMTimeRange) {
        self.init(asset: sourceAsset, timeRange: timeRange, videoTrackIndex: 0, audioTrackIndex: 0)
    }

    /**
     Create a new instance that reverses the given video and audio streams (0-based, per media type) instead of the first ones.
     ILABAudioTrackIndexAll is treated as audio stream 0 (reverse never mixed). An out-of-range index fails the export with ILABSessionErrorInvalidTrackIndex.
     */
    public init!(asset sourceAsset: AVAsset!, timeRange: CMTimeRange, videoTrackIndex: Int, audioTrackIndex: Int) {
        super.init()
        var timeRange = timeRange
        let endTime = CMTimeAdd(timeRange.start, timeRange.duration)
        let sourceEndTime = CMTimeAdd(CMTime.zero, sourceAsset?.duration ?? CMTime())

        if CMTimeCompare(endTime, sourceEndTime) > 0 {
            let value = CMTimeSubtract(endTime, sourceEndTime)
            let duration = CMTimeSubtract(timeRange.duration, value)
            timeRange = CMTimeRangeMake(start: timeRange.start, duration: duration)
        }

        self.timeRange = timeRange
        self.sourceAsset = sourceAsset
        self.videoTrackIndex = videoTrackIndex
        self.audioTrackIndex = audioTrackIndex
        self.exportSession = nil
        self.audioExporter = nil
        self.deleteCacheFile = true
        self.showDebug = false
        self.samplesPerPass = 40

        let track = ILABTrackAtIndex(sourceAsset?.tracks(withMediaType: AVMediaType.video), videoTrackIndex)
        let videoComposition = AVMutableComposition()
        let vTrack = videoComposition.addMutableTrack(withMediaType: AVMediaType.video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        if let track = track {
            try? vTrack?.insertTimeRange(timeRange, of: track, at: CMTime.zero)
        }
        self.reversingVideoAsset = videoComposition

        self.configureSourceMeta()

        if AVPlayer.eligibleForHDRPlayback &&
            (track?.hasMediaCharacteristic(AVMediaCharacteristic.containsHDRVideo) ?? false) {
            self.containsHDRVideo = true
        }
        self.isProResType = TRTransformer.isProResType(track)
        self.isDolbyVisionType = TRTransformer.isDolbyVisionType(track)
        if let first = track?.formatDescriptions.first {
            let ref = first as! CMFormatDescription
            self.sourceCodecType = CMFormatDescriptionGetMediaSubType(ref)
            self.containsAlphaChannel = CMFormatDescriptionGetExtension(ref, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) != nil
        }
    }

    /**
     Creates a new instance

     @param sourceAsset The source AVAsset to reverse
     @return The new instance
     */
    public convenience init!(asset sourceAsset: AVAsset!) {
        self.init(asset: sourceAsset, timeRange: CMTimeRangeMake(start: CMTime.zero, duration: sourceAsset?.duration ?? CMTime()))
    }

    /**
     Creates a new export session

     @param sourceVideoURL The URL for the source video
     @param outputURL URL to output reverse video to
     @return The new instance
     */
    public convenience init!(url sourceVideoURL: URL!, outputURL: URL!) {
        self.init(url: sourceVideoURL)
        self.outputURL = outputURL
    }

    /**
     Creates a new export session

     @param sourceAsset The source AVAsset to reverse
     @prarm timeRange The time range of the asset to be reversed.
     @param outputURL URL to output reverse video to
     @return The new instance
     */
    public convenience init!(asset sourceAsset: AVAsset!, timeRange: CMTimeRange, outputURL: URL!) {
        self.init(asset: sourceAsset, timeRange: timeRange)
        self.outputURL = outputURL
    }

    /**
     Creates a new export session that reverses the given video and audio streams (0-based, per media type).
     */
    public convenience init!(asset sourceAsset: AVAsset!, timeRange: CMTimeRange, videoTrackIndex: Int, audioTrackIndex: Int, outputURL: URL!) {
        self.init(asset: sourceAsset, timeRange: timeRange, videoTrackIndex: videoTrackIndex, audioTrackIndex: audioTrackIndex)
        self.outputURL = outputURL
    }

    private func configureSourceMeta() {
        let loadSemi = DispatchSemaphore(value: 0)
        weak var weakSelf = self
        // ObjC: [nil loadValuesAsynchronously...] was a no-op, so the wait below never ended; same here.
        self.sourceAsset?.loadValuesAsynchronously(forKeys: ["duration", "tracks", "metadata"],
                                                   completionHandler: {
            var error: NSError? = nil

            let status: AVKeyValueStatus = weakSelf?.sourceAsset?.statusOfValue(forKey: "duration", error: &error) ?? AVKeyValueStatus.unknown
            if status != AVKeyValueStatus.loaded {
                loadSemi.signal()
                return
            }

            let videos: [AVAssetTrack]? = weakSelf?.sourceAsset?.tracks(withMediaType: AVMediaType.video)
            let audios: [AVAssetTrack]? = weakSelf?.sourceAsset?.tracks(withMediaType: AVMediaType.audio)
            let video = ILABTrackAtIndex(videos, weakSelf?.videoTrackIndex ?? 0)

            weakSelf?.sourceDuration = weakSelf?.sourceAsset?.duration ?? CMTime()
            weakSelf?.sourceVideoTracks = videos?.count ?? 0
            weakSelf?.sourceAudioTracks = audios?.count ?? 0
            weakSelf?.sourceFPS = video?.nominalFrameRate ?? 0
            weakSelf?.sourceEstimatedDataRate = video?.estimatedDataRate ?? 0
            weakSelf?.sourceTransform = video?.preferredTransform ?? zeroAffineTransform

            let naturalSize: CGSize = video?.naturalSize ?? CGSize.zero
            let width: CGFloat = (cInt32(Double(naturalSize.width)) % 2 == 0) ?
                naturalSize.width : naturalSize.width - 1
            let height: CGFloat = (cInt32(Double(naturalSize.height)) % 2 == 0) ?
                naturalSize.height : naturalSize.height - 1
            weakSelf?.sourceSize = CGSize(width: width, height: height)
            weakSelf?.sourceReady = (videos?.count ?? 0) > 0 || (audios?.count ?? 0) > 0

            loadSemi.signal()
        })
        while loadSemi.wait(timeout: DispatchTime.now()) == .timedOut {
            RunLoop.main.run(until: Date())
        }
    }

    // MARK: - Queue

    private static let reverseCancelQueue = DispatchQueue(label: "cancel queue")

    private static let reverseQueue = DispatchQueue(label: "reverse queue")

    private static let reverseGenerateQueue = DispatchQueue(label: "reverse generate queue")

    private static let conversionGenerationQueue = DispatchQueue(label: "conversion generate queue")

    // MARK: - Reverse Session

    // Video index 0 and sources without audio keep the legacy paths (no video track / no-audio output).
    private func hasValidTrackIndexes() -> Bool {
        let videoValid = self.videoTrackIndex == 0 || (self.videoTrackIndex > 0 && self.videoTrackIndex < self.sourceVideoTracks)
        let audioValid = self.sourceAudioTracks == 0 || self.audioTrackIndex == ILABAudioTrackIndexAll || (self.audioTrackIndex >= 0 && self.audioTrackIndex < self.sourceAudioTracks)
        return videoValid && audioValid
    }

    /**
     Start the export process asynchronously

     @param progressBlock Block to call to report progress of export
     @param completeBlock Block to call when export has completed
     */
    open func exportAsynchronously(_ progressBlock: ILABProgressBlock!, complete completeBlock: ILABCompleteBlock!) {
        let progressBlock: ILABProgressBlock? = progressBlock
        let completeBlock: ILABCompleteBlock? = completeBlock
        // Make sure the output URL has been specified
        guard let outputURL = self.outputURL else {
            if let completeBlock = completeBlock {
                completeBlock(false, NSError.ilabSessionError(ILABSessionErrorMissingOutputURL))
            }
            return
        }

        // Remove any existing files at the output URL
        var error: Error? = nil
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do { try FileManager.default.removeItem(at: outputURL) } catch let e { error = e }
            if let error = error {
                if let completeBlock = completeBlock {
                    completeBlock(false, error)
                }
                return
            }
        }
        if !self.hasValidTrackIndexes() {
            if let completeBlock = completeBlock {
                completeBlock(false, NSError.ilabSessionError(ILABSessionErrorInvalidTrackIndex))
            }
            return
        }
        if self.showDebug {
            NSLog("reverse containsHDRVideo: %d, isProResType: %d", self.containsHDRVideo ? 1 : 0, self.isProResType ? 1 : 0)
        }
        self.doReverse(progressBlock, complete: completeBlock)
    }

    private func doReverse(_ progressBlock: ILABProgressBlock?, complete completeBlock: ILABCompleteBlock?) {
        let cachePath: String? = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first

        // ObjC: [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:...]] — a nil path raised there and traps here.
        let audioDestionationURL = URL(fileURLWithPath: cachePath! + "/" + UUID().uuidString + "-tempAudio.m4a")
        let videoDestinationURL = URL(fileURLWithPath: cachePath! + "/" + UUID().uuidString + "-tempVideo.mov")

        weak var weakSelf = self

        // The inner ObjC block read `self.deleteCacheFile` (strong), so both blocks retain self; kept as-is.
        self.reverseAudioDestinationURL(audioDestionationURL, completeBlock: { complete, error in
            weakSelf?.reverseVideo(atDestinationURL: videoDestinationURL,
                                   progress: progressBlock,
                                   completeBlock: { isSuccess, reversedVideoAsset, error in
                guard let reversedVideoAsset = reversedVideoAsset else {
                    if let completeBlock = completeBlock {
                        completeBlock(false, error)
                    }
                    //
                    if weakSelf?.deleteCacheFile ?? false {
                        try? FileManager.default.removeItem(at: audioDestionationURL)
                        try? FileManager.default.removeItem(at: videoDestinationURL)
                    }
                    return
                }

                if let strongSelf = weakSelf {
                    strongSelf.export(atDestinationURL: strongSelf.outputURL,
                                      videoAsset: reversedVideoAsset,
                                      audioAsset: strongSelf.reversedAudioAsset,
                                      progressBlock: progressBlock,
                                      complete: completeBlock)
                }
                //
                if self.deleteCacheFile {
                    try? FileManager.default.removeItem(at: audioDestionationURL)
                    try? FileManager.default.removeItem(at: videoDestinationURL)
                }
            })
        })
    }

    // MARK: - Reverse Methods

    private func updateProgressBlock(_ progressBlock: ILABProgressBlock?, operation: String, progress: Float) {
        guard let progressBlock = progressBlock else {
            return
        }

        DispatchQueue.main.async {
            progressBlock(operation, progress)
        }
    }

    private func export(atDestinationURL destinationURL: URL?, videoAsset: AVAsset, audioAsset: AVAsset?, progressBlock: ILABProgressBlock?, complete completeBlock: ILABCompleteBlock?) {

        let videoTrack: AVAssetTrack? = videoAsset.tracks(withMediaType: AVMediaType.video).first
        let audioTrack: AVAssetTrack? = audioAsset?.tracks(withMediaType: AVMediaType.audio).first

        let muxComp = AVMutableComposition()

        let compVideoTrack = muxComp.addMutableTrack(withMediaType: AVMediaType.video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        let compAudioTrack = muxComp.addMutableTrack(withMediaType: AVMediaType.audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)

        compVideoTrack?.preferredTransform = videoTrack?.preferredTransform ?? zeroAffineTransform

        var error: Error? = nil
        if let videoTrack = videoTrack {
            do {
                try compVideoTrack?.insertTimeRange(CMTimeRangeMake(start: CMTime.zero, duration: videoAsset.duration),
                                                    of: videoTrack,
                                                    at: CMTime.zero)
            } catch let e { error = e }
        }
        if let audioTrack = audioTrack {
            do {
                try compAudioTrack?.insertTimeRange(CMTimeRangeMake(start: CMTime.zero, duration: audioAsset?.duration ?? CMTime()),
                                                    of: audioTrack,
                                                    at: CMTime.zero)
            } catch let e { error = e }
        }

        if error != nil {
            completeBlock!(false, NSError.ilabSessionError(ILABSessionErrorInsertTrack))
            return
        }

        if self.showDebug {
            NSLog("result -> reversed videoTrack duration: %f, audioTrack duration: %f, duration: %f",
                  CMTimeGetSeconds(videoTrack?.timeRange.duration ?? CMTime()),
                  CMTimeGetSeconds(audioTrack == nil ? CMTime.zero : audioTrack!.timeRange.duration),
                  CMTimeGetSeconds(muxComp.duration)
            )
            NSLog("result -> source video info: size %@, frameRate (%.3f), estimatedDateRate (%.3f)",
                  NSCoder.string(for: self.sourceSize),
                  self.sourceFPS,
                  self.sourceEstimatedDataRate
            )
            NSLog("result -> reversed video info: size %@ frameRate (%.3f), estimatedDateRate (%.3f)",
                  NSCoder.string(for: videoTrack?.naturalSize ?? CGSize.zero),
                  videoTrack?.nominalFrameRate ?? 0,
                  videoTrack?.estimatedDataRate ?? 0
            )
        }

        weak var weakSelf = self

        let preset: String = AVAssetExportPresetPassthrough
        let outputType: AVFileType = AVFileType.mov

        AVAssetExportSession.determineCompatibility(ofExportPreset: preset,
                                                    with: muxComp,
                                                    outputFileType: outputType,
                                                    completionHandler: { compatible in
            if compatible {
                let created = AVAssetExportSession(asset: muxComp,
                                                   presetName: preset)
                weakSelf?.exportSession = created
                if weakSelf?.exportSession == nil {
                    completeBlock!(false, NSError.ilabSessionError(ILABSessionErrorAVAssetExportSessionCreate))
                    return
                }
                weakSelf?.exportSession?.outputFileType = outputType
                weakSelf?.exportSession?.outputURL = destinationURL

                weakSelf?.exportSession?.exportAsynchronously(completionHandler: {
                    if weakSelf?.isCanceled ?? false {
                        weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                    } else if (weakSelf?.exportSession?.status ?? AVAssetExportSession.Status.unknown) != AVAssetExportSession.Status.completed {
                        weakSelf?.lastError = weakSelf?.exportSession?.error
                    }
                    if let completeBlock = completeBlock {
                        completeBlock((weakSelf?.lastError == nil), weakSelf?.lastError)
                    }
                })
            } else {
                completeBlock!(false, NSError.ilabSessionError(ILABSessionErrorAVAssetExportSessionCompatibility))
            }
        })
    }

    private func reversingAudio(atDestinationURL destinationURL: URL, completBlock resultsBlock: @escaping ILABGenerateAssetBlock) {
        weak var weakSelf = self

        self.audioExporter = ILABAudioTrackExporter(asset: self.sourceAsset,
                                                    trackIndex: (self.audioTrackIndex == ILABAudioTrackIndexAll ? 0 : self.audioTrackIndex),
                                                    timeRange: self.timeRange)

        ILABReverseVideoExportSession.reverseGenerateQueue.async {

            weakSelf?.audioExporter?.exportReverse(to: destinationURL,
                                                   complete: { isSuccess, error in
                weakSelf?.audioExporter = nil
                if let error = error {
                    weakSelf?.lastError = error
                }
                if isSuccess {
                    resultsBlock(true, AVURLAsset(url: destinationURL), nil)
                } else {
                    resultsBlock(false, nil, weakSelf?.lastError)
                }
            })

        }
    }

    private func convertToM4AType(atDestinationURL destinationURL: URL, asset: AVAsset?, completeBlcok completeBlock: @escaping ILABCompleteBlock) {
        // asset is the single-track reversed WAV; All keeps the previous whole-composition M4A export.
        self.audioExporter = ILABAudioTrackExporter(asset: asset, trackIndex: ILABAudioTrackIndexAll)

        weak var weakSelf = self
        self.audioExporter?.exportInM4A(to: destinationURL,
                                        completion: { complete, error in
            weakSelf?.audioExporter = nil
            completeBlock(complete, error)
            return
        })
    }

    private func reverseAudioDestinationURL(_ destinationURL: URL, completeBlock: ILABCompleteBlock?) {
        if self.sourceAudioTracks == 0 {
            completeBlock!(true, nil)
            return
        }

        let cachePath: String? = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
        let tempAudioFileURL = URL(fileURLWithPath: cachePath! + "/" + UUID().uuidString + "-tempAudio.wav")

        weak var weakSelf = self

        self.reversingAudio(atDestinationURL: tempAudioFileURL,
                            completBlock: { isSuccess, reversedAudioAsset, error in
            if isSuccess {
                weakSelf?.convertToM4AType(atDestinationURL: destinationURL, asset: reversedAudioAsset, completeBlcok: { complete, error in
                    try? FileManager.default.removeItem(at: tempAudioFileURL)
                    if complete {
                        let asset = AVURLAsset(url: destinationURL)
                        weakSelf?.reversedAudioAsset = asset
                        if let completeBlock = completeBlock {
                            completeBlock(true, nil)
                        }
                    } else {
                        if let completeBlock = completeBlock {
                            completeBlock(false, error)
                        }
                    }
                })
            } else {
                try? FileManager.default.removeItem(at: tempAudioFileURL)
                if let completeBlock = completeBlock {
                    completeBlock(false, error)
                }
            }
        })
    }

    private func reverseVideo(atDestinationURL destinationURL: URL, progress progressBlock: ILABProgressBlock?, completeBlock resultsBlock: @escaping ILABGenerateAssetBlock) {
        weak var weakSelf = self
        ILABReverseVideoExportSession.reverseGenerateQueue.async {
            // The ObjC block also used `self` directly (strong capture), so weakSelf is never nil while it runs.

            // Setup the reader
            var error: Error? = nil
            var assetReaderOrNil: AVAssetReader? = nil
            do {
                assetReaderOrNil = try AVAssetReader(asset: weakSelf!.reversingVideoAsset!)
            } catch let e {
                error = e
            }
            if let error = error {
                weakSelf?.lastError = error
                resultsBlock(false, nil, error)
                return
            }
            let assetReader = assetReaderOrNil!

            let outputSettings = makeVideoReaderSettings(self.containsHDRVideo, self.containsAlphaChannel, self.isProResType)
            // ObjC passed `firstObject` (nil raised NSInvalidArgumentException); the composition always carries a video track.
            let assetReaderOutput = AVAssetReaderTrackOutput(
                track: weakSelf!.reversingVideoAsset!.tracks(withMediaType: AVMediaType.video).first!,
                outputSettings: outputSettings as? [String: Any])
            assetReaderOutput.supportsRandomAccess = true
            assetReader.add(assetReaderOutput)

            if !assetReader.startReading() {
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderStartReading)
                resultsBlock(false, nil, weakSelf?.lastError)
                return
            }

            // Fetch the sample times for the source video
            var revSampleTimes: [CMTime] = []
            var localCount: Int = 0
            while let sample = assetReaderOutput.copyNextSampleBuffer() {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if weakSelf?.showDebug ?? false {
                    NSLog("configure presentation time: %f", CMTimeGetSeconds(presentationTime))
                }

                if CMTimeCompare(CMTimeAdd(CMTime.zero, weakSelf!.reversingVideoAsset!.duration), presentationTime) == 0 {
                    if weakSelf?.showDebug ?? false {
                        NSLog("reverse last frame skip: %.3f", CMTimeGetSeconds(presentationTime))
                    }
                    continue
                }

                revSampleTimes.append(presentationTime)

                if weakSelf?.isCanceledReverseExport() ?? false {
                    weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                    resultsBlock(false, nil, weakSelf?.lastError)
                    return
                }
                if progressBlock != nil {
                    weakSelf?.updateProgressBlock(progressBlock,
                                                  operation: "Analyzing Source Video",
                                                  progress: Float((CMTimeGetSeconds(presentationTime) / CMTimeGetSeconds(weakSelf!.sourceDuration)) * 0.5))
                }
                localCount += 1
            }

            if assetReader.status == AVAssetReader.Status.failed {
                if weakSelf?.showDebug ?? false {
                    NSLog("%@", (assetReader.error?.localizedDescription ?? "(null)") as NSString)
                }
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderReading)
                resultsBlock(false, nil, weakSelf?.lastError)
                return
            }

            // No samples, no bueno
            if revSampleTimes.count == 0 {
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorVideoNoSamples)
                resultsBlock(false, nil, weakSelf?.lastError)
                return
            }

            // Generate the pass data
            var passDicts: [ReversePass] = []

            let initEventTime: CMTime = revSampleTimes.first!
            var passStartTime: CMTime = initEventTime
            var passEndTime: CMTime = initEventTime
            var timeEventTime: CMTime = initEventTime

            var timeStartIndex: Int = -1
            var timeEndIndex: Int = -1
            var frameStartIndex: Int = -1
            var frameEndIndex: Int = -1

            let samplesPerPass: Int = weakSelf!.samplesPerPass
            // ObjC: (NSInteger)ceil((float)count / (float)samplesPerPass)
            let totalPasses: Int = Int(cInt64(ceil(Double(Float(revSampleTimes.count) / Float(samplesPerPass)))))

            var initNewPass = false
            var i = 0
            while i < revSampleTimes.count {
                timeEventTime = revSampleTimes[i]

                timeEndIndex = i
                frameEndIndex = (revSampleTimes.count - 1) - i

                passEndTime = timeEventTime

                if cSRem(i, weakSelf!.samplesPerPass) == 0 {
                    if i > 0 {
                        passDicts.append(ReversePass(
                            passStartTime: passStartTime,
                            passEndTime: passEndTime,
                            timeStartIndex: timeStartIndex,
                            timeEndIndex: timeEndIndex,
                            frameStartIndex: frameStartIndex,
                            frameEndIndex: frameEndIndex
                        ))
                    }

                    initNewPass = true
                }

                if initNewPass {
                    passStartTime = timeEventTime
                    timeStartIndex = i
                    frameStartIndex = ((revSampleTimes.count - 1) - i)
                    initNewPass = false
                }
                i += 1
            }

            // ObjC compared NSUInteger with NSInteger here, i.e. both sides unsigned.
            if (UInt(passDicts.count) < UInt(bitPattern: totalPasses)) ||
                (cURem(UInt(revSampleTimes.count), UInt(bitPattern: weakSelf!.samplesPerPass)) != 0) {
                passDicts.append(ReversePass(
                    passStartTime: passStartTime,
                    passEndTime: passEndTime,
                    timeStartIndex: timeStartIndex,
                    timeEndIndex: timeEndIndex,
                    frameStartIndex: frameStartIndex,
                    frameEndIndex: frameEndIndex
                ))
            }

            var assetWriter: AVAssetWriter?
            var assetWriterInput: AVAssetWriterInput
            var adaptor: AVAssetWriterInputPixelBufferAdaptor

            var writerEnable = false
            var firstTry = true

            repeat {
                let compressionProperties = makeCompressionProperties(
                    self.sourceSize,
                    CGFloat(self.sourceEstimatedDataRate),
                    self.sourceCodecType,
                    self.containsHDRVideo,
                    self.isDolbyVisionType
                )
                let outputSettings = makeVideoOutputSettings(
                    self.sourceSize,
                    self.sourceCodecType,
                    self.containsHDRVideo,
                    self.containsAlphaChannel,
                    compressionProperties
                )
                let defaultCompressionProperties = makeDefaultCompressionProperties(self.sourceSize, CGFloat(self.sourceEstimatedDataRate))
                let defaultSettings = makeVideoDefaultSettings(self.sourceSize, defaultCompressionProperties)
                do {
                    assetWriter = try AVAssetWriter(outputURL: destinationURL,
                                                    fileType: AVFileType.mov)
                } catch let e {
                    assetWriter = nil
                    error = e
                }
                assetWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video,
                                                      outputSettings: (firstTry ? outputSettings : defaultSettings) as? [String: Any])
                assetWriterInput.expectsMediaDataInRealTime = false
                assetWriterInput.transform = weakSelf!.sourceTransform

                assetWriter?.add(assetWriterInput)

                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: assetWriterInput,
                                                               sourcePixelBufferAttributes: nil)

                writerEnable = assetWriter?.startWriting() ?? false
                if writerEnable == false {
                    firstTry = false
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            } while writerEnable == false

            assetWriter?.startSession(atSourceTime: initEventTime)

            var frameCount: Int = 0

            var z = passDicts.count - 1
            while z >= 0 {
                defer { z -= 1 }
                let dict = passDicts[z]

                passStartTime = dict.passStartTime
                passEndTime = dict.passEndTime

                let passDuration = CMTimeSubtract(passEndTime, passStartTime)
                if CMTimeCompare(CMTime.zero, passDuration) == 0 {
                    continue
                }

                timeStartIndex = dict.timeStartIndex
                timeEndIndex = dict.timeEndIndex

                frameStartIndex = dict.frameStartIndex
                frameEndIndex = dict.frameEndIndex

                assetReaderOutput.reset(forReadingTimeRanges: [NSValue(timeRange: CMTimeRangeMake(start: passStartTime, duration: passDuration))])

                if weakSelf?.showDebug ?? false {
                    NSLog("passStartTime: %f, passDuration: %f", CMTimeGetSeconds(passStartTime), CMTimeGetSeconds(passDuration))
                }

                var samples: [CMSampleBuffer]? = []
                while let sample = assetReaderOutput.copyNextSampleBuffer() {
                    if weakSelf?.showDebug ?? false {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                        NSLog("copy presentationTime: %f", CMTimeGetSeconds(presentationTime))
                    }
                    samples!.append(sample)
                }

                if assetReader.status == AVAssetReader.Status.failed {
                    if weakSelf?.showDebug ?? false {
                        NSLog("%@", (assetReader.error?.localizedDescription ?? "(null)") as NSString)
                    }
                    weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderReading)
                    resultsBlock(false, nil, weakSelf?.lastError)
                    return
                }

                let samplesCount = samples!.count
                for i in 0..<samplesCount {
                    if frameCount >= revSampleTimes.count {
                        break
                    }

                    let eventTime = revSampleTimes[frameCount]

                    // ObjC passed a possibly-NULL image buffer straight to appendPixelBuffer: (which raises on NULL).
                    let imageBufferRef: CVPixelBuffer = CMSampleBufferGetImageBuffer(samples![(samplesCount - 1) - i])!

                    var didAppend = false
                    var missCount: Int = 0
                    while !didAppend && (missCount <= 45) {
                        if !adaptor.assetWriterInput.isReadyForMoreMediaData {
                            repeat {
                                Thread.sleep(forTimeInterval: 1.0 / 15.0)
                            } while !assetWriterInput.isReadyForMoreMediaData
                        }
                        didAppend = adaptor.append(imageBufferRef, withPresentationTime: eventTime)
                        if !didAppend {
                            weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorVideoUnableToWirteFrame)
                            resultsBlock(false, nil, weakSelf?.lastError)
                            return
                        }
                        if weakSelf?.showDebug ?? false {
                            NSLog("reverse append presentationTime: %f", CMTimeGetSeconds(eventTime))
                        }

                        missCount += 1
                    }
                    frameCount += 1

                    if weakSelf?.isCanceledReverseExport() ?? false {
                        weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                        resultsBlock(false, nil, weakSelf?.lastError)
                        samples = nil
                        return
                    }
                    if progressBlock != nil {
                        weakSelf?.updateProgressBlock(progressBlock,
                                                      operation: "Reversing Video",
                                                      progress: Float(0.5 + (Double(Float(frameCount) / Float(revSampleTimes.count)) * 0.5)))
                    }
                }

                samples = nil
            }

            assetWriterInput.markAsFinished()

            if self.isCanceledReverseExport() {
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                resultsBlock(false, nil, weakSelf?.lastError)
                return
            }
            if progressBlock != nil {
                weakSelf?.updateProgressBlock(progressBlock,
                                              operation: "Saving Reversed Video",
                                              progress: 1.0)
            }

            assetWriter?.finishWriting(completionHandler: {
                resultsBlock(true, AVURLAsset(url: destinationURL), nil)
            })
        }
    }

    // MARK: - Cancel

    /**
     Cancel the reverse export process
     */
    open func cancelReverseExport() {
        ILABReverseVideoExportSession.reverseCancelQueue.sync(flags: .barrier) {
            self.isCanceled = true
            self.exportSession?.cancelExport()
        }
    }

    private func isCanceledReverseExport() -> Bool {
        var _isCanceled = false
        ILABReverseVideoExportSession.reverseCancelQueue.sync {
            _isCanceled = self.isCanceled
        }
        return _isCanceled
    }
}
