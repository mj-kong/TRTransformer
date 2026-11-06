//
//  ILABTranscodeSession.swift
//
//  Created by MJ.KONG-MAC on 2021/08/11.
//  Copyright © 2021 Jon Gilkison. All rights reserved.
//

import AVFoundation
import UIKit
import VideoToolbox

// nil when out of range, so an invalid index never throws or falls back to another stream.
func ILABTrackAtIndex(_ tracks: [AVAssetTrack]?, _ index: Int) -> AVAssetTrack? {
    let tracks = tracks ?? []
    return (index >= 0 && index < tracks.count) ? tracks[index] : nil
}

@objc(ILABTranscodeSession)
@objcMembers
open class ILABTranscodeSession: NSObject {

    open private(set) var sourceReady: Bool = false                              /**< Source is loaded and ready to be */
    open private(set) var sourceVideoTracks: Int = 0                             /**< Number of video tracks on source asset, anything beyond the 1st will be ignored/skipped */
    open private(set) var sourceAudioTracks: Int = 0                             /**< Number of audio tracks on source asset */
    open private(set) var sourceDuration: CMTime = CMTime()                      /**< Duration of source asset */
    open private(set) var sourceDurationSeconds: TimeInterval = 0                /**< Duration in seconds of the source asset */
    open private(set) var sourceFPS: Float = 0                                   /**< Maximum FPS of the source asset */
    open private(set) var sourceEstimatedDataRate: Float = 0                     /**< Source estimated data rate, in bits per second */
    open private(set) var sourceTransform: CGAffineTransform = zeroAffineTransform /**< Source transform */
    open private(set) var sourceSize: CGSize = CGSize.zero                       /**< Natural size of the source asset */
    open private(set) var videoTrackIndex: Int = 0                               /**< 0-based index into the source's video tracks to use, default 0 */
    open private(set) var audioTrackIndex: Int = 0                               /**< 0-based audio track to use alone, or ILABAudioTrackIndexAll (default) to mix every audio track */

    open var showDebug: Bool = false                       /**< Show debug output messages when reversing */
    // Declared nonnull in the ObjC header but nil until set; the storage keeps that nil so the missing-URL check still works.
    private var _outputURL: URL?
    // Swift type stays `URL` as the ObjC header imported; an unset read traps in Swift, as bridging nil did with the ObjC class.
    @nonobjc open var outputURL: URL {                     /**< URL to output transcoded video to */
        get { return _outputURL! }
        set { _outputURL = newValue }
    }
    // ObjC selector/KVC reads of an unset URL return nil, as the ObjC getter did.
    @objc(outputURL) var objcOutputURL: URL? {
        get { return _outputURL }
        set { _outputURL = newValue }
    }

    open var size: CGSize = CGSize.zero                    /**< transcoding video size. If it is not set, source size */
    private var _frameRate: CGFloat = 0
    open var frameRate: CGFloat {                          /**< transcoding frame rate. If it is not set, source frame rate */
        get { return _frameRate }
        set {
            _frameRate = newValue
            if CGFloat(self.sourceFPS) < newValue {
                _frameRate = CGFloat(self.sourceFPS)
            }
        }
    }
    open var estimatedDataRate: CGFloat = 0                /**< the estimated data rate of the media data, in units of bits per second */

    open var deleteCacheFile: Bool = false                 /**< After finishing transcode work, delete temporary files in the Library/Caches, default value is YES */

    private var timeRange: CMTimeRange = CMTimeRange()
    private var lastError: Error?
    private var isCanceled: Bool = false

    private var sourceAsset: AVAsset?
    private var transcodingVideoAsset: AVAsset?
    private var transcodedAudioAsset: AVAsset?
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

     @param sourceVideoURL The source URL
     @return The new instance
     */
    @objc(initWithURL:)
    public convenience init(url sourceVideoURL: URL) {
        if !FileManager.default.fileExists(atPath: sourceVideoURL.path) {
            NSException(name: NSExceptionName("Invalid input file."),
                        reason: String(format: "The file '%@' could not be located.", sourceVideoURL.path),
                        userInfo: nil).raise()
        }

        self.init(asset: AVURLAsset(url: sourceVideoURL))
    }

    /**
     Creates a new instance

     @param sourceAsset The source AVAsset
     @return The new instance
     */
    public convenience init(asset sourceAsset: AVAsset) {
        self.init(asset: sourceAsset, timeRange: CMTimeRangeMake(start: CMTime.zero, duration: sourceAsset.duration))
    }

    /**
     Create a new instance

     @param sourceAsset The source AVAsset
     @prarm timeRange The time range
     @return The new instance
     */
    public convenience init(asset sourceAsset: AVAsset, timeRange: CMTimeRange) {
        self.init(asset: sourceAsset, timeRange: timeRange, videoTrackIndex: 0, audioTrackIndex: ILABAudioTrackIndexAll)
    }

    /**
     Create a new instance that reads the given video and audio streams (0-based, per media type); an audio index uses only that stream,
     ILABAudioTrackIndexAll mixes every audio stream (what the other inits do). An out-of-range index fails the transcode with ILABSessionErrorInvalidTrackIndex.
     */
    public init(asset sourceAsset: AVAsset, timeRange: CMTimeRange, videoTrackIndex: Int, audioTrackIndex: Int) {
        super.init()
        var timeRange = timeRange
        let endTime = CMTimeAdd(timeRange.start, timeRange.duration)
        let sourceEndTime = CMTimeAdd(CMTime.zero, sourceAsset.duration)

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
        self.deleteCacheFile = true
        self.showDebug = false

        let track = ILABTrackAtIndex(sourceAsset.tracks(withMediaType: AVMediaType.video), videoTrackIndex)
        let videoComposition = AVMutableComposition()
        let vTrack = videoComposition.addMutableTrack(withMediaType: AVMediaType.video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        if let track = track {
            try? vTrack?.insertTimeRange(timeRange, of: track, at: CMTime.zero)
        }
        self.transcodingVideoAsset = videoComposition

        self.configureSourceMeta()

        if AVPlayer.eligibleForHDRPlayback &&
            (track?.hasMediaCharacteristic(AVMediaCharacteristic.containsHDRVideo) ?? false) {
            self.containsHDRVideo = true
        }
        self.isProResType = TRTransformer.isProResType(track)
        self.isDolbyVisionType = TRTransformer.isDolbyVisionType(track)
        self.size = self.sourceSize
        self.frameRate = CGFloat(self.sourceFPS)
        if let first = track?.formatDescriptions.first {
            let ref = first as! CMFormatDescription
            self.sourceCodecType = CMFormatDescriptionGetMediaSubType(ref)
            self.containsAlphaChannel = CMFormatDescriptionGetExtension(ref, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) != nil
        }
    }

    /**
     Creates a new session

     @param sourceVideoURL The source URL
     @param outputURL URL to output video to
     @return The new instance
     */
    public convenience init(url sourceVideoURL: URL, outputURL: URL) {
        self.init(url: sourceVideoURL)
        self.outputURL = outputURL
    }

    /**
     Creates a new session

     @param sourceAsset The source AVAsset to reverse
     @prarm timeRange The time range
     @param outputURL URL to output video to
     @return The new instance
     */
    public convenience init(asset sourceAsset: AVAsset, timeRange: CMTimeRange, outputURL: URL) {
        self.init(asset: sourceAsset, timeRange: timeRange)
        self.outputURL = outputURL
    }

    /**
     Creates a new session that reads the given video and audio streams (0-based, per media type, or ILABAudioTrackIndexAll).
     */
    public convenience init(asset sourceAsset: AVAsset, timeRange: CMTimeRange, videoTrackIndex: Int, audioTrackIndex: Int, outputURL: URL) {
        self.init(asset: sourceAsset, timeRange: timeRange, videoTrackIndex: videoTrackIndex, audioTrackIndex: audioTrackIndex)
        self.outputURL = outputURL
    }

    private func configureSourceMeta() {
        let loadSemi = DispatchSemaphore(value: 0)
        weak var weakSelf = self
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

    private static let transcodeCancelQueue = DispatchQueue(label: "transcode cancel queue")

    private static let transcodeQueue = DispatchQueue(label: "transcode queue")

    private static let transcodeGenerateQueue = DispatchQueue(label: "transcode generate queue")

    // MARK: - Transcode Session

    // Video index 0 and sources without audio keep the legacy paths (no video track / no-audio output).
    private func hasValidTrackIndexes() -> Bool {
        let videoValid = self.videoTrackIndex == 0 || (self.videoTrackIndex > 0 && self.videoTrackIndex < self.sourceVideoTracks)
        let audioValid = self.sourceAudioTracks == 0 || self.audioTrackIndex == ILABAudioTrackIndexAll || (self.audioTrackIndex >= 0 && self.audioTrackIndex < self.sourceAudioTracks)
        return videoValid && audioValid
    }

    /**
     Start the transcode process asynchronously

     @param progressBlock Block to call to report progress of transcode
     @param completeBlock Block to call when export has completed
     */
    open func transcodeAsynchronously(_ progressBlock: @escaping ILABProgressBlock, complete completeBlock: @escaping ILABCompleteBlock) {
        let progressBlock: ILABProgressBlock? = progressBlock
        let completeBlock: ILABCompleteBlock? = completeBlock
        // Make sure the output URL has been specified
        guard let outputURL = self._outputURL else {
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
            NSLog("transcode containsHDRVideo: %d, isProResType: %d", self.containsHDRVideo ? 1 : 0, self.isProResType ? 1 : 0)
        }
        self.doTranscode(progressBlock, complete: completeBlock)
    }

    private func doTranscode(_ progressBlock: ILABProgressBlock?, complete completeBlock: ILABCompleteBlock?) {
        let cachePath: String? = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first

        weak var weakSelf = self

        // ObjC: [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:...]] — a nil path raised there and traps here.
        let audioDestionationURL = URL(fileURLWithPath: cachePath! + "/" + UUID().uuidString + "-tempAudio.m4a")
        let videoDestinationURL = URL(fileURLWithPath: cachePath! + "/" + UUID().uuidString + "-tempVideo.mov")

        self.transcodeAudio(atDestinationURL: audioDestionationURL, completeBlock: { complete, error in
            weakSelf?.transcodeVideo(atDestinationURL: videoDestinationURL,
                                     progress: progressBlock,
                                     completeBlock: { isSuccess, transcodedVideoAsset, error in
                guard let transcodedVideoAsset = transcodedVideoAsset else {
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

                // ObjC sent this to weakSelf with weakSelf.outputURL as an argument (nil when weakSelf is nil → no-op).
                if let strongSelf = weakSelf {
                    strongSelf.export(atDestinationURL: strongSelf._outputURL,
                                      videoAsset: transcodedVideoAsset,
                                      audioAsset: strongSelf.transcodedAudioAsset,
                                      progressBlock: progressBlock,
                                      complete: completeBlock)
                }
                //
                if weakSelf?.deleteCacheFile ?? false {
                    try? FileManager.default.removeItem(at: audioDestionationURL)
                    try? FileManager.default.removeItem(at: videoDestinationURL)
                }
            })
        })
    }

    // MARK: - Transcode Methods

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
            NSLog("result -> transcoded videoTrack duration: %.3f, audioTrack duration: %.3f, duration: %.3f, inputed timeRange(start: %.3f, duration: %.3f)",
                  CMTimeGetSeconds(videoTrack?.timeRange.duration ?? CMTime()),
                  CMTimeGetSeconds(audioTrack == nil ? CMTime.zero : audioTrack!.timeRange.duration),
                  CMTimeGetSeconds(muxComp.duration),
                  CMTimeGetSeconds(self.timeRange.start),
                  CMTimeGetSeconds(self.timeRange.duration)
            )
            NSLog("result -> source video info: size %@, frameRate (%.3f), estimatedDateRate (%.3f)",
                  NSCoder.string(for: self.sourceSize),
                  self.sourceFPS,
                  self.sourceEstimatedDataRate
            )
            NSLog("result -> transcoded video info: size %@ frameRate (%.3f), estimatedDateRate (%.3f)",
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

    private func transcodingAudio(atDestinationURL destinationURL: URL, completBlock resultsBlock: @escaping ILABGenerateAssetBlock) {
        weak var weakSelf = self

        self.audioExporter = ILABAudioTrackExporter(asset: self.sourceAsset, trackIndex: self.audioTrackIndex, timeRange: self.timeRange)

        ILABTranscodeSession.transcodeGenerateQueue.async {
            weakSelf?.audioExporter?.exportInM4A(to: destinationURL,
                                                 completion: { complete, error in
                weakSelf?.audioExporter = nil
                if let error = error {
                    weakSelf?.lastError = error
                }
                if complete {
                    resultsBlock(true, AVURLAsset(url: destinationURL), nil)
                } else {
                    resultsBlock(false, nil, weakSelf?.lastError)
                }
            })
        }
    }

    private func transcodeAudio(atDestinationURL destinationURL: URL, completeBlock: ILABCompleteBlock?) {
        if self.sourceAudioTracks == 0 {
            completeBlock!(true, nil)
            return
        }

        weak var weakSelf = self
        self.transcodingAudio(atDestinationURL: destinationURL,
                              completBlock: { isSuccess, transcodedAudioAsset, error in
            if isSuccess {
                weakSelf?.transcodedAudioAsset = transcodedAudioAsset
                if let completeBlock = completeBlock {
                    completeBlock(true, nil)
                }
            } else {
                if let completeBlock = completeBlock {
                    completeBlock(false, error)
                }
            }
        })
    }

    private func transcodeVideo(atDestinationURL destinationURL: URL, progress progressBlock: ILABProgressBlock?, completeBlock: @escaping ILABGenerateAssetBlock) {
        weak var weakSelf = self

        ILABTranscodeSession.transcodeGenerateQueue.async {
            // The ObjC block also used `self` directly (strong capture), so weakSelf is never nil while it runs.
            var error: Error? = nil

            // AVAssetReader
            var assetReaderOrNil: AVAssetReader? = nil
            do {
                assetReaderOrNil = try AVAssetReader(asset: weakSelf!.transcodingVideoAsset!)
            } catch let e {
                error = e
            }
            if let error = error {
                weakSelf?.lastError = error
                completeBlock(false, nil, error)
                return
            }
            let assetReader = assetReaderOrNil!
            let outputSettings = makeVideoReaderSettings(self.containsHDRVideo, self.containsAlphaChannel, self.isProResType)
            // ObjC passed `firstObject` (nil raised NSInvalidArgumentException); the composition always carries a video track.
            let assetReaderOutput = AVAssetReaderTrackOutput(
                track: weakSelf!.transcodingVideoAsset!.tracks(withMediaType: AVMediaType.video).first!,
                outputSettings: outputSettings as? [String: Any])
            assetReaderOutput.supportsRandomAccess = true
            assetReader.add(assetReaderOutput)

            if !assetReader.startReading() {
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderStartReading)
                completeBlock(false, nil, weakSelf?.lastError)
                return
            }

            var assetWriter: AVAssetWriter?
            var assetWriterInput: AVAssetWriterInput

            var writerEnable = false
            var firstTry = true

            repeat {
                let estimatedDataRate: CGFloat = ((self.size.width * self.size.height * self.frameRate * 0.17) / 1024) * 1000
                let compressionProperties = makeCompressionProperties(
                    self.sourceSize,
                    estimatedDataRate,
                    self.sourceCodecType,
                    self.containsHDRVideo,
                    self.isDolbyVisionType
                )
                let outputSettings = makeVideoOutputSettings(
                    self.size,
                    self.sourceCodecType,
                    self.containsHDRVideo,
                    self.containsAlphaChannel,
                    compressionProperties
                )
                let defaultCompressionProperties = makeDefaultCompressionProperties(self.sourceSize, estimatedDataRate)
                let defaultSettings = makeVideoDefaultSettings(self.size, defaultCompressionProperties)
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

                writerEnable = assetWriter?.startWriting() ?? false
                if writerEnable == false {
                    firstTry = false
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            } while writerEnable == false

            assetWriter?.startSession(atSourceTime: CMTime.zero)

            var readFrameCount: Int = 0

            // Go Transcoding
            var lastPresentationTime = CMTime.zero
            let frameIntervalTime = CMTimeMake(value: cInt64(Double(weakSelf!.frameRate)), timescale: 1000)

            while let sample = assetReaderOutput.copyNextSampleBuffer() {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)

                if assetReader.status == AVAssetReader.Status.failed {
                    weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderReading)
                    completeBlock(false, nil, weakSelf?.lastError)
                    return
                }
                if weakSelf?.isCanceledTranscodeExport() ?? false {
                    weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                    completeBlock(false, nil, weakSelf?.lastError)
                    return
                }

                if readFrameCount != 0 &&
                    CGFloat(weakSelf!.sourceFPS) != weakSelf!.frameRate &&
                    CMTimeCompare(CMTimeSubtract(presentationTime, lastPresentationTime), frameIntervalTime) == -1 {
                    if weakSelf?.showDebug ?? false {
                        NSLog("transcode skip: %.3f", CMTimeGetSeconds(presentationTime))
                    }
                    continue
                }
                if CMTimeCompare(CMTimeAdd(CMTime.zero, weakSelf!.transcodingVideoAsset!.duration), presentationTime) == 0 {
                    if weakSelf?.showDebug ?? false {
                        NSLog("transcode last frame skip: %.3f", CMTimeGetSeconds(presentationTime))
                    }
                    continue
                }

                lastPresentationTime = CMTimeMake(value: Int64(readFrameCount), timescale: cInt32(Double(weakSelf!.frameRate)))
                readFrameCount += 1

                if !assetWriterInput.isReadyForMoreMediaData {
                    repeat {
                        Thread.sleep(forTimeInterval: 1.0 / 15.0)
                    } while !assetWriterInput.isReadyForMoreMediaData
                }
                if assetWriterInput.append(sample) == false {
                    weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorVideoUnableToWirteFrame)
                    completeBlock(false, nil, weakSelf?.lastError)
                    return
                }
                if weakSelf?.showDebug ?? false {
                    NSLog("transcode append presentationTime: %.3f", CMTimeGetSeconds(presentationTime))
                }
                if progressBlock != nil {
                    weakSelf?.updateProgressBlock(progressBlock,
                                                  operation: "Transcoding Video",
                                                  progress: Float(CMTimeGetSeconds(presentationTime) / CMTimeGetSeconds(weakSelf!.timeRange.duration)))
                }
            }

            if assetReader.status == AVAssetReader.Status.failed {
                if weakSelf?.showDebug ?? false {
                    NSLog("%@", (assetReader.error?.localizedDescription ?? "(null)") as NSString)
                }
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderReading)
                completeBlock(false, nil, weakSelf?.lastError)
                return
            }

            assetWriterInput.markAsFinished()

            if self.isCanceledTranscodeExport() {
                weakSelf?.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                completeBlock(false, nil, weakSelf?.lastError)
                return
            }
            if progressBlock != nil {
                weakSelf?.updateProgressBlock(progressBlock,
                                              operation: "Saving Transcoded Video",
                                              progress: 1.0)
            }

            assetWriter?.finishWriting(completionHandler: {
                completeBlock(true, AVURLAsset(url: destinationURL), nil)
            })
        }
    }

    // MARK: - Cancel

    /**
     Cancel the transcode process
     */
    open func cancelTranscode() {
        ILABTranscodeSession.transcodeCancelQueue.sync(flags: .barrier) {
            self.isCanceled = true
            self.exportSession?.cancelExport()
        }
    }

    private func isCanceledTranscodeExport() -> Bool {
        var _isCanceled = false
        ILABTranscodeSession.transcodeCancelQueue.sync {
            _isCanceled = self.isCanceled
        }
        return _isCanceled
    }
}
