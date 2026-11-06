//
//  ILABAudioTrackExporter.swift
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

import Accelerate
import AudioToolbox
import AVFoundation

// MARK: - AVAssetTrack (Settings)
extension AVAssetTrack {
    @objc(getLayerTagWithChannelPerFrame:)
    func getLayerTag(withChannelPerFrame channelPerFrame: UInt32) -> AudioChannelLayoutTag {
        if channelPerFrame == 1 { return kAudioChannelLayoutTag_MPEG_1_0 }
        else if channelPerFrame == 2 { return kAudioChannelLayoutTag_MPEG_2_0 }
        else if channelPerFrame == 3 { return kAudioChannelLayoutTag_MPEG_3_0_A }
        else if channelPerFrame == 4 { return kAudioChannelLayoutTag_MPEG_4_0_A }
        else if channelPerFrame == 5 { return kAudioChannelLayoutTag_MPEG_5_0_A }
        else if channelPerFrame == 6 { return kAudioChannelLayoutTag_MPEG_5_1_A }
        else if channelPerFrame == 7 { return kAudioChannelLayoutTag_MPEG_6_1_A }
        else if channelPerFrame == 8 { return kAudioChannelLayoutTag_MPEG_7_1_A }
        // The ObjC fell off the end here; the shipped -Os build returns MPEG_1_0 for these counts.
        return kAudioChannelLayoutTag_MPEG_1_0
    }

    @objc func decompressionAudioSettingForPCMType() -> [String: Any] {
        let descriptionRef = self.formatDescriptions[0] as! CMAudioFormatDescription
        // ObjC dereferenced the returned pointer unconditionally; a NULL crashes in both.
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef)!

        var stereoChannelLayout = AudioChannelLayout()
        stereoChannelLayout.mChannelLayoutTag = self.getLayerTag(withChannelPerFrame: description.pointee.mChannelsPerFrame)
        let settings: NSMutableDictionary = [
            AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM),
            AVNumberOfChannelsKey: NSNumber(value: description.pointee.mChannelsPerFrame),
            AVSampleRateKey: NSNumber(value: description.pointee.mSampleRate),
            AVLinearPCMBitDepthKey: NSNumber(value: Int32(32)),
            AVLinearPCMIsFloatKey: NSNumber(value: true),
            AVLinearPCMIsNonInterleaved: NSNumber(value: true),
            AVLinearPCMIsBigEndianKey: NSNumber(value: false),
            AVChannelLayoutKey: NSData(bytes: &stereoChannelLayout,
                                       length: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!),
        ]

        return settings as! [String: Any]
    }

    @objc func compressionAudioSettingForPCMType() -> [String: Any] {
        let descriptionRef = self.formatDescriptions[0] as! CMAudioFormatDescription
        // ObjC dereferenced the returned pointer unconditionally; a NULL crashes in both.
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef)!

        var stereoChannelLayout = AudioChannelLayout()
        stereoChannelLayout.mChannelLayoutTag = self.getLayerTag(withChannelPerFrame: description.pointee.mChannelsPerFrame)
        let settings: NSMutableDictionary = [
            AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM),
            AVSampleRateKey: NSNumber(value: description.pointee.mSampleRate),
            AVNumberOfChannelsKey: NSNumber(value: description.pointee.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: NSNumber(value: Int32(32)),
            AVLinearPCMIsFloatKey: NSNumber(value: false),
            AVLinearPCMIsNonInterleaved: NSNumber(value: false),
            AVLinearPCMIsBigEndianKey: NSNumber(value: false),
            AVChannelLayoutKey: NSData(bytes: &stereoChannelLayout,
                                       length: MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!),
        ]

        return settings as! [String: Any]
    }
}

// MARK: - ILABAudioTrackExporter

/**
 Utility class for exporting an audio AVAssetTrack to a file quickly
 */
@objc(ILABAudioTrackExporter)
@objcMembers
open class ILABAudioTrackExporter: NSObject {

    open private(set) var exporting: Bool = false            /**< Determines if the exporter is currently exporting */
    open private(set) var trackIndex: Int = 0                /**< The track index being exported */
    open private(set) var sourceAsset: AVAsset! = nil        /**< The source asset the track is being exported from */
    open var isCanceled: Bool = false

    private var exportingAudioAsset: AVAsset?
    private var lastError: Error?

    private var assetReader: AVAssetReader?
    private var assetReaderOutput: AVAssetReaderOutput?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var exportSession: AVAssetExportSession?

    // MARK: - Init/Dealloc

    public override init() {
        super.init()
    }

    /**
     Create a new instance for the track exporter

     @param sourceAsset The `AVAsset` to export the audio from.
     @param trackIndex The index of the audio track to export, or ILABAudioTrackIndexAll to mix every track (M4A export only)
     @return The new instance
     */
    public convenience init!(asset sourceAsset: AVAsset!, trackIndex: Int) {
        self.init(asset: sourceAsset,
                  trackIndex: trackIndex,
                  timeRange: CMTimeRangeMake(start: CMTime.zero, duration: sourceAsset?.duration ?? CMTime()))
    }

    /**
     Create a new instance for the track exporter

     @param sourceAsset The `AVAsset` to export the audio from.
     @param trackIndex The index of the audio track to export, or ILABAudioTrackIndexAll to mix every track (M4A export only)
     @prarm timeRange The time range of the asset to be reversed.
     @return The new instance
     */
    public init!(asset sourceAsset: AVAsset!, trackIndex: Int, timeRange: CMTimeRange) {
        super.init()
        self.trackIndex = trackIndex

        let audioComp = AVMutableComposition()
        for track in sourceAsset?.tracks(withMediaType: AVMediaType.audio) ?? [] {
            let atrack = audioComp.addMutableTrack(withMediaType: AVMediaType.audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
            try? atrack?.insertTimeRange(timeRange,
                                         of: track,
                                         at: CMTime.zero)
        }
        self.exportingAudioAsset = audioComp
    }

    // MARK: - Queue
    private static let audioExportQueue = DispatchQueue(label: "audioExport queue")

    private static let audioExportGenerateQueue = DispatchQueue(label: "audioExport generate queue")

    // MARK: - Audio Export Methods

    /**
     Exports the audio track to a .m4a audio file

     @param outputURL The URL to export to
     @param completion The block that is called when the operation is complete
     */
    @objc(exportInM4ATo:completion:)
    open dynamic func exportInM4A(to outputURL: URL!, completion: ILABCompleteBlock!) {
        var asset: AVAsset? = self.exportingAudioAsset
        // ILABAudioTrackIndexAll exports the composition of every audio track (mixed); an index exports only that track.
        if self.trackIndex != ILABAudioTrackIndexAll {
            let tracks: [AVAssetTrack] = self.exportingAudioAsset?.tracks(withMediaType: AVMediaType.audio) ?? []
            if self.trackIndex < 0 || self.trackIndex >= tracks.count {
                completion(false, NSError.ilabSessionError(ILABSessionErrorAudioInvalidTrackIndex))
                return
            }
            let track = tracks[self.trackIndex]
            let singleComp = AVMutableComposition()
            try? singleComp.addMutableTrack(withMediaType: AVMediaType.audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(track.timeRange, of: track, at: CMTime.zero)
            asset = singleComp
        }
        // ObjC `initWithAsset:nil` is only reachable after a plain `init()`; nil propagates as a nil session.
        self.exportSession = asset.flatMap { AVAssetExportSession(asset: $0, presetName: AVAssetExportPresetAppleM4A) }
        self.exportSession?.outputURL = outputURL
        self.exportSession?.outputFileType = AVFileType.m4a
        self.exportSession?.timeRange = CMTimeRangeMake(start: CMTime.zero, duration: asset?.duration ?? CMTime())

        weak var weakSelf = self
        self.exportSession?.exportAsynchronously(completionHandler: {
            if (weakSelf?.exportSession?.status ?? AVAssetExportSession.Status(rawValue: 0)!) == AVAssetExportSession.Status.failed {
                completion(false, weakSelf?.exportSession?.error)
            } else {
                completion(true, nil)
            }
        })
    }

    /**
     Exports the audio track to a .m4a audio file (the async form Swift synthesized from the ObjC completion method)
     */
    @nonobjc
    open func exportInM4A(to outputURL: URL!) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            self.exportInM4A(to: outputURL, completion: { complete, error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: complete) }
            })
        }
    }

    /**
     Exports the reversed version of the audio track to a .wav file

     @param outputURL The URL to export to
     @param completeBlock The block that is called when the operation is complete
     */
    @objc(exportReverseToURL:complete:)
    open dynamic func exportReverse(to outputURL: URL!, complete completeBlock: ILABCompleteBlock!) {
        // ObjC: [[outputURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:] (NSURL: no file-system probe)
        let tmpAudioFileURL: URL! = (outputURL as NSURL?)?.deletingLastPathComponent?.appendingPathComponent("exported-audio.wav")

        weak var weakSelf = self

        self.exporting(to: tmpAudioFileURL, complete: { complete, error in
            if let error = error {
                weakSelf?.lastError = error
                if let completeBlock = completeBlock {
                    completeBlock(false, error)
                }
                return
            } else {
                self.exportingReverse(to: outputURL, tmpAudioFileURL: tmpAudioFileURL, complete: completeBlock)
            }
        })
    }

    @objc(exportingToURL:complete:)
    func exporting(to destinationURL: URL!, complete completeBlock: ILABCompleteBlock!) {
        try? FileManager.default.removeItem(at: destinationURL)

        var error: Error? = nil

        // AVAssetReader
        do {
            // ObjC `assetReaderWithAsset:nil` is only reachable after a plain `init()`.
            self.assetReader = try AVAssetReader(asset: self.exportingAudioAsset!)
        } catch let e {
            self.assetReader = nil
            error = e
        }
        if let error = error {
            self.lastError = error
            completeBlock(false, error)
            return
        }
        let tracks: [AVAssetTrack] = self.exportingAudioAsset?.tracks(withMediaType: AVMediaType.audio) ?? []
        if self.trackIndex < 0 || self.trackIndex >= tracks.count {
            self.lastError = NSError.ilabSessionError(ILABSessionErrorAudioInvalidTrackIndex)
            completeBlock(false, self.lastError)
            return
        }
        let track = tracks[self.trackIndex]

        self.assetReaderOutput = AVAssetReaderTrackOutput(track: track,
                                                          outputSettings: track.decompressionAudioSettingForPCMType())
        self.assetReader?.add(self.assetReaderOutput!)

        if !(self.assetReader?.startReading() ?? false) {
            self.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetReaderStartReading)
            completeBlock(false, self.lastError)
            return
        }

        // AVAssetWriter
        do {
            self.assetWriter = try AVAssetWriter(outputURL: destinationURL,
                                                 fileType: AVFileType.wav)
        } catch let e {
            self.assetWriter = nil
            error = e
        }
        if error != nil {
            self.lastError = error
            completeBlock(false, self.lastError)
            return
        }
        self.assetWriterInput = AVAssetWriterInput(mediaType: AVMediaType.audio,
                                                   outputSettings: track.compressionAudioSettingForPCMType())
        self.assetWriter?.add(self.assetWriterInput!)

        if !(self.assetWriter?.startWriting() ?? false) {
            self.lastError = NSError.ilabSessionError(ILABSessionErrorAVAssetWriterStartWriting)
            completeBlock(false, self.lastError)
            return
        }

        self.assetWriter?.startSession(atSourceTime: CMTime.zero)

        self.assetWriterInput?.requestMediaDataWhenReady(on: ILABAudioTrackExporter.audioExportGenerateQueue, using: {
            while self.assetWriterInput?.isReadyForMoreMediaData ?? false {
                var nextSampleBuffer: CMSampleBuffer? = self.assetReaderOutput?.copyNextSampleBuffer()
                if self.isCanceled {
                    self.lastError = NSError.ilabSessionError(ILABSessionErrorUserCancel)
                    completeBlock(false, self.lastError)
                    nextSampleBuffer = nil
                    return
                }
                if let sampleBuffer = nextSampleBuffer {
                    _ = self.assetWriterInput?.append(sampleBuffer)
                    nextSampleBuffer = nil
                } else {
                    self.assetWriterInput?.markAsFinished()
                    self.assetWriter?.finishWriting(completionHandler: {
                        completeBlock(true, nil)
                    })
                    break
                }
            }
        })
    }

    @objc(exportingReverseToURL:tmpAudioFileURL:complete:)
    func exportingReverse(to outputURL: URL!,
                          tmpAudioFileURL: URL!,
                          complete completeBlock: ILABCompleteBlock!) {
        // set up input file
        var inputAudioFileRef: AudioFileID? = nil
        var theErr: OSStatus = AudioFileOpenURL(tmpAudioFileURL as CFURL,
                                                AudioFilePermissions.readPermission, 0, &inputAudioFileRef)
        if theErr != noErr {
            self.lastError = NSError.errorWithAudioFileStatusCode(theErr)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }
        let inputAudioFile: AudioFileID = inputAudioFileRef!  // non-NULL once AudioFileOpenURL returned noErr

        var theFileFormat = AudioStreamBasicDescription()
        var thePropertySize: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyDataFormat, &thePropertySize, &theFileFormat)
        if theErr != noErr {
            AudioFileClose(inputAudioFile)
            self.lastError = NSError.errorWithAudioFileStatusCode(theErr)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }

        var fileDataSize: UInt64 = 0
        thePropertySize = UInt32(MemoryLayout<UInt64>.size)
        theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyAudioDataByteCount, &thePropertySize, &fileDataSize)
        if theErr != noErr {
            AudioFileClose(inputAudioFile)
            self.lastError = NSError.errorWithAudioFileStatusCode(theErr)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }

        var outputAudioFileRef: AudioFileID? = nil
        theErr = AudioFileCreateWithURL(outputURL as CFURL,
                                        kAudioFileWAVEType,
                                        &theFileFormat,
                                        AudioFileFlags.eraseFile,
                                        &outputAudioFileRef)
        if theErr != noErr {
            AudioFileClose(inputAudioFile)
            self.lastError = NSError.errorWithAudioFileStatusCode(theErr)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }
        let outputAudioFile: AudioFileID = outputAudioFileRef!  // non-NULL once AudioFileCreateWithURL returned noErr

        let dataSize: UInt64 = fileDataSize
        // ObjC: SInt32* theData = malloc((UInt32)dataSize);  — byte count truncated to 32 bits
        let byteCount32: UInt32 = UInt32(truncatingIfNeeded: dataSize)
        guard let theDataRaw: UnsafeMutableRawPointer = malloc(Int(byteCount32)) else {
            // TODO: Set lastError to "Could not allocate audio pointer"
            AudioFileClose(inputAudioFile)
            AudioFileClose(outputAudioFile)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }

        var bytesRead: UInt32 = UInt32(truncatingIfNeeded: dataSize)
        theErr = AudioFileReadBytes(inputAudioFile, false, 0, &bytesRead, theDataRaw)
        if theErr != noErr {
            AudioFileClose(inputAudioFile)
            AudioFileClose(outputAudioFile)
            self.lastError = NSError.errorWithAudioFileStatusCode(theErr)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }

        guard let floatDataRaw: UnsafeMutableRawPointer = malloc(Int(UInt32(truncatingIfNeeded: dataSize))) else {
            free(theDataRaw)
            // TODO: Set lastError to "Could not allocate audio pointer"
            AudioFileClose(inputAudioFile)
            AudioFileClose(outputAudioFile)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }

        // ObjC: (UInt32)dataSize/sizeof(Float32) — UInt32 promoted to size_t, then divided by 4
        let sampleCount: vDSP_Length = vDSP_Length(UInt32(truncatingIfNeeded: dataSize)) / vDSP_Length(MemoryLayout<Float32>.size)
        let theData: UnsafeMutablePointer<Int32> = theDataRaw.bindMemory(to: Int32.self, capacity: Int(sampleCount))
        let floatData: UnsafeMutablePointer<Float32> = floatDataRaw.bindMemory(to: Float32.self, capacity: Int(sampleCount))

        vDSP_vflt32(theData, 1, floatData, 1, sampleCount)
        vDSP_vrvrs(floatData, 1, sampleCount)
        vDSP_vfix32(floatData, 1, theData, 1, sampleCount)

        var bytesWritten: UInt32 = UInt32(truncatingIfNeeded: dataSize)
        theErr = AudioFileWriteBytes(outputAudioFile, false, 0, &bytesWritten, theDataRaw)
        if theErr != noErr {
            free(theDataRaw)
            free(floatDataRaw)

            AudioFileClose(inputAudioFile)
            AudioFileClose(outputAudioFile)
            self.lastError = NSError.errorWithAudioFileStatusCode(theErr)
            if let completeBlock = completeBlock {
                completeBlock(false, self.lastError)
            }
            return
        }

        free(theDataRaw)
        free(floatDataRaw)
        AudioFileClose(inputAudioFile)
        AudioFileClose(outputAudioFile)

        try? FileManager.default.removeItem(at: tmpAudioFileURL)

        if let completeBlock = completeBlock {
            completeBlock(true, nil)
        }
    }
}
