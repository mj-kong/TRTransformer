//
//  ORCILABAudioTrackExporter.m
//  ORCILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ORCILABAudioTrackExporter.h"
@import Accelerate;

#pragma mark - AVAssetTrack (ORCSettings)
@interface AVAssetTrack (ORCSettings)
-(NSDictionary *)orc_decompressionAudioSettingForPCMType;
-(NSDictionary *)orc_compressionAudioSettingForPCMType;
@end

@implementation AVAssetTrack (ORCSettings)
-(AudioChannelLayoutTag)orc_getLayerTagWithChannelPerFrame:(UInt32)channelPerFrame {
    if (channelPerFrame == 1) { return kAudioChannelLayoutTag_MPEG_1_0; }
    else if (channelPerFrame == 2) { return kAudioChannelLayoutTag_MPEG_2_0; }
    else if (channelPerFrame == 3) { return kAudioChannelLayoutTag_MPEG_3_0_A; }
    else if (channelPerFrame == 4) { return kAudioChannelLayoutTag_MPEG_4_0_A; }
    else if (channelPerFrame == 5) { return kAudioChannelLayoutTag_MPEG_5_0_A; }
    else if (channelPerFrame == 6) { return kAudioChannelLayoutTag_MPEG_5_1_A; }
    else if (channelPerFrame == 7) { return kAudioChannelLayoutTag_MPEG_6_1_A; }
    else if (channelPerFrame == 8) { return kAudioChannelLayoutTag_MPEG_7_1_A; }
}
                                    
-(NSDictionary *)orc_decompressionAudioSettingForPCMType {
    CMAudioFormatDescriptionRef descriptionRef = (__bridge CMAudioFormatDescriptionRef)(self.formatDescriptions[0]);
    const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef);

    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = [self orc_getLayerTagWithChannelPerFrame:description->mChannelsPerFrame],
    };
    NSMutableDictionary *settings = [@{
        AVFormatIDKey:@(kAudioFormatLinearPCM),
        AVNumberOfChannelsKey:@(description->mChannelsPerFrame),
        AVSampleRateKey:@(description->mSampleRate),
        AVLinearPCMBitDepthKey:@32,
        AVLinearPCMIsFloatKey:@YES,
        AVLinearPCMIsNonInterleaved:@YES,
        AVLinearPCMIsBigEndianKey:@NO,
        AVChannelLayoutKey:[NSData dataWithBytes:&stereoChannelLayout
                                          length:offsetof(AudioChannelLayout, mChannelDescriptions)]
    } mutableCopy];
    
    return settings;
}

-(NSDictionary *)orc_compressionAudioSettingForPCMType {
    CMAudioFormatDescriptionRef descriptionRef = (__bridge CMAudioFormatDescriptionRef)(self.formatDescriptions[0]);
    const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef);

    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = [self orc_getLayerTagWithChannelPerFrame:description->mChannelsPerFrame],
    };
    NSMutableDictionary *settings = [@{
        AVFormatIDKey:@(kAudioFormatLinearPCM),
        AVSampleRateKey:@(description->mSampleRate),
        AVNumberOfChannelsKey:@(description->mChannelsPerFrame),
        AVLinearPCMBitDepthKey:@32,
        AVLinearPCMIsFloatKey:@NO,
        AVLinearPCMIsNonInterleaved:@NO,
        AVLinearPCMIsBigEndianKey:@NO,
        AVChannelLayoutKey:[NSData dataWithBytes:&stereoChannelLayout
                                          length:offsetof(AudioChannelLayout, mChannelDescriptions)]
    } mutableCopy];
    
    return settings;
}
@end

#pragma mark - ORCILABAudioTrackExporter
@interface ORCILABAudioTrackExporter ()
@property (nonatomic, strong) AVAsset *exportingAudioAsset;
@property (nonatomic, strong) NSError * lastError;

@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *assetReaderOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterInput;
@property (nonatomic, strong) AVAssetExportSession *exportSession;

@property (nonatomic) NSInteger trackIndex;
@end

@implementation ORCILABAudioTrackExporter
#pragma mark - Init/Dealloc
-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex {
    return [self initWithAsset:sourceAsset
                    trackIndex:trackIndex
                     timeRange:CMTimeRangeMake(kCMTimeZero, sourceAsset.duration)];
}

-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex timeRange:(CMTimeRange)timeRange {
    if (self = [super init]) {
        self.trackIndex = trackIndex;

        AVMutableComposition *audioComp = [AVMutableComposition composition];
        for(AVAssetTrack *track in [sourceAsset tracksWithMediaType:AVMediaTypeAudio]) {
            AVMutableCompositionTrack *atrack = [audioComp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                       preferredTrackID:kCMPersistentTrackID_Invalid];
            [atrack insertTimeRange:timeRange
                            ofTrack:track
                             atTime:kCMTimeZero error:nil];
        }
        self.exportingAudioAsset = audioComp;
    }
    return self;
}

#pragma mark - Queue
+(dispatch_queue_t)audioExportQueue {
    static dispatch_queue_t audioExportQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExportQueue = dispatch_queue_create("audioExport queue", NULL);
    });
    
    return audioExportQueue;
}

+(dispatch_queue_t)audioExportGenerateQueue {
    static dispatch_queue_t audioExportGenerateQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExportGenerateQueue = dispatch_queue_create("audioExport generate queue", NULL);
    });
    
    return audioExportGenerateQueue;
}


#pragma mark - Audio Export Methods
- (void)exportInM4ATo:(NSURL *)outputURL completion:(ORCILABCompleteBlock)completion {
    AVAsset *asset = self.exportingAudioAsset;
    // ORCILABAudioTrackIndexAll exports the composition of every audio track (mixed); an index exports only that track.
    if (self.trackIndex != ORCILABAudioTrackIndexAll) {
        NSArray<AVAssetTrack *> *tracks = [self.exportingAudioAsset tracksWithMediaType:AVMediaTypeAudio];
        if (self.trackIndex < 0 || self.trackIndex >= (NSInteger)tracks.count) {
            completion(NO, [NSError ORCILABSessionError:ORCILABSessionErrorAudioInvalidTrackIndex]);
            return;
        }
        AVAssetTrack *track = tracks[self.trackIndex];
        AVMutableComposition *singleComp = [AVMutableComposition composition];
        [[singleComp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid]
         insertTimeRange:track.timeRange ofTrack:track atTime:kCMTimeZero error:nil];
        asset = singleComp;
    }
    self.exportSession = [[AVAssetExportSession alloc] initWithAsset:asset
                                                          presetName:AVAssetExportPresetAppleM4A];
    self.exportSession.outputURL = outputURL;
    self.exportSession.outputFileType = AVFileTypeAppleM4A;
    self.exportSession.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
    
    __weak typeof(self) weakSelf = self;
    [self.exportSession exportAsynchronouslyWithCompletionHandler:^{
        if (weakSelf.exportSession.status == AVAssetExportSessionStatusFailed) {
            completion(NO, weakSelf.exportSession.error);
        } else {
            completion(YES, nil);
        }
    }];
}

-(void)exportReverseToURL:(NSURL *)outputURL complete:(ORCILABCompleteBlock)completeBlock {
    NSURL *tmpAudioFileURL = [[outputURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"exported-audio.wav"];

    __weak typeof(self) weakSelf = self;
    
    [self exportingToURL:tmpAudioFileURL complete:^(BOOL complete, NSError *error) {
        if (error) {
            weakSelf.lastError = error;
            if (completeBlock) {
                completeBlock(NO, error);
            }
            return;
        } else {
            [self exportingReverseToURL:outputURL tmpAudioFileURL:tmpAudioFileURL complete:completeBlock];
        }
    }];
}

-(void)exportingToURL:(NSURL *)destinationURL complete:(ORCILABCompleteBlock)completeBlock {
    [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
    
    NSError *error = nil;
    
    // AVAssetReader
    self.assetReader = [AVAssetReader assetReaderWithAsset:self.exportingAudioAsset
                                                     error:&error];
    if (error) {
        self.lastError = error;
        completeBlock(NO, error);
        return;
    }
    NSArray<AVAssetTrack *> *tracks = [self.exportingAudioAsset tracksWithMediaType:AVMediaTypeAudio];
    if (self.trackIndex < 0 || self.trackIndex >= (NSInteger)tracks.count) {
        self.lastError = [NSError ORCILABSessionError:ORCILABSessionErrorAudioInvalidTrackIndex];
        completeBlock(NO, self.lastError);
        return;
    }
    AVAssetTrack *track = tracks[self.trackIndex];

    self.assetReaderOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                                        outputSettings:[track orc_decompressionAudioSettingForPCMType]];
    [self.assetReader addOutput:self.assetReaderOutput];
    
    if (![self.assetReader startReading]) {
        self.lastError = [NSError ORCILABSessionError:ORCILABSessionErrorAVAssetReaderStartReading];
        completeBlock(NO, self.lastError);
        return;
    }

    // AVAssetWriter
    self.assetWriter = [AVAssetWriter assetWriterWithURL:destinationURL
                                                fileType:AVFileTypeWAVE
                                                   error:&error];
    if (error) {
        self.lastError = error;
        completeBlock(NO, self.lastError);
        return;
    }
    self.assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                               outputSettings:[track orc_compressionAudioSettingForPCMType]];
    [self.assetWriter addInput:self.assetWriterInput];
    
    if (![self.assetWriter startWriting]) {
        self.lastError = [NSError ORCILABSessionError:ORCILABSessionErrorAVAssetWriterStartWriting];
        completeBlock(NO, self.lastError);
        return;
    }
    
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    [self.assetWriterInput requestMediaDataWhenReadyOnQueue:[[self class] audioExportGenerateQueue] usingBlock:^{
        while ([self.assetWriterInput isReadyForMoreMediaData]) {
            CMSampleBufferRef nextSampleBuffer = [self.assetReaderOutput copyNextSampleBuffer];
            if (self.isCanceled) {
                self.lastError = [NSError ORCILABSessionError:ORCILABSessionErrorUserCancel];
                completeBlock(NO, self.lastError);
                CFRelease(nextSampleBuffer); nextSampleBuffer = NULL;
                return;
            }
            if (nextSampleBuffer) {
                [self.assetWriterInput appendSampleBuffer:nextSampleBuffer];
                CFRelease(nextSampleBuffer); nextSampleBuffer = NULL;
            } else {
                [self.assetWriterInput markAsFinished];
                [self.assetWriter finishWritingWithCompletionHandler:^{
                    completeBlock(YES, nil);
                }];
                break;
            }
        }
    }];
}

-(void)exportingReverseToURL:(NSURL *)outputURL
             tmpAudioFileURL:(NSURL *)tmpAudioFileURL
                    complete:(ORCILABCompleteBlock)completeBlock {
    // set up input file
    AudioFileID inputAudioFile;
    OSStatus theErr = AudioFileOpenURL((__bridge CFURLRef)tmpAudioFileURL,
                                       kAudioFileReadPermission, 0, &inputAudioFile);
    if (theErr != noErr) {
        self.lastError = [NSError orc_errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    AudioStreamBasicDescription theFileFormat;
    UInt32 thePropertySize = sizeof(theFileFormat);
    theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyDataFormat, &thePropertySize, &theFileFormat);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        self.lastError = [NSError orc_errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    UInt64 fileDataSize = 0;
    thePropertySize = sizeof(fileDataSize);
    theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyAudioDataByteCount, &thePropertySize, &fileDataSize);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        self.lastError = [NSError orc_errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    AudioFileID outputAudioFile;
    theErr = AudioFileCreateWithURL((__bridge CFURLRef)outputURL,
                                    kAudioFileWAVEType,
                                    &theFileFormat,
                                    kAudioFileFlags_EraseFile,
                                    &outputAudioFile);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        self.lastError = [NSError orc_errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    UInt64 dataSize = fileDataSize;
    SInt32* theData = malloc((UInt32)dataSize);
    if (theData == NULL) {
        // TODO: Set lastError to "Could not allocate audio pointer"
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }

    UInt32 bytesRead=(UInt32)dataSize;
    theErr = AudioFileReadBytes(inputAudioFile, false, 0, &bytesRead, theData);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        self.lastError = [NSError orc_errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    Float32 *floatData=malloc((UInt32)dataSize);
    if (floatData == NULL) {
        free(theData);
        // TODO: Set lastError to "Could not allocate audio pointer"
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    vDSP_vflt32((const int *)theData, 1, floatData, 1, (UInt32)dataSize/sizeof(Float32));
    vDSP_vrvrs(floatData, 1, (UInt32)dataSize/sizeof(Float32));
    vDSP_vfix32(floatData, 1, (int *)theData, 1, (UInt32)dataSize/sizeof(Float32));
    
    UInt32 bytesWritten=(UInt32)dataSize;
    theErr=AudioFileWriteBytes(outputAudioFile, false, 0, &bytesWritten, theData);
    if (theErr != noErr) {
        free(theData);
        free(floatData);
        
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        self.lastError = [NSError orc_errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    free(theData);
    free(floatData);
    AudioFileClose(inputAudioFile);
    AudioFileClose(outputAudioFile);
    
    [[NSFileManager defaultManager] removeItemAtURL:tmpAudioFileURL error:nil];
    
    if (completeBlock) {
        completeBlock(YES, nil);
    }
}

@end

