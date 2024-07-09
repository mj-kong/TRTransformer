//
//  ILABAudioTrackExporter.m
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ILABAudioTrackExporter.h"
@import Accelerate;

#pragma mark - AVAssetTrack (Settings)
@interface AVAssetTrack (Settings)
-(NSDictionary *)decompressionAudioSettingForPCMType;
-(NSDictionary *)compressionAudioSettingForPCMType;
@end

@implementation AVAssetTrack (Settings)
-(AudioChannelLayoutTag)getLayerTagWithChannelPerFrame:(UInt32)channelPerFrame {
    if (channelPerFrame == 1) { return kAudioChannelLayoutTag_MPEG_1_0; }
    else if (channelPerFrame == 2) { return kAudioChannelLayoutTag_MPEG_2_0; }
    else if (channelPerFrame == 3) { return kAudioChannelLayoutTag_MPEG_3_0_A; }
    else if (channelPerFrame == 4) { return kAudioChannelLayoutTag_MPEG_4_0_A; }
    else if (channelPerFrame == 5) { return kAudioChannelLayoutTag_MPEG_5_0_A; }
    else if (channelPerFrame == 6) { return kAudioChannelLayoutTag_MPEG_5_1_A; }
    else if (channelPerFrame == 7) { return kAudioChannelLayoutTag_MPEG_6_1_A; }
    else if (channelPerFrame == 8) { return kAudioChannelLayoutTag_MPEG_7_1_A; }
}
                                    
-(NSDictionary *)decompressionAudioSettingForPCMType {
    CMAudioFormatDescriptionRef descriptionRef = (__bridge CMAudioFormatDescriptionRef)(self.formatDescriptions[0]);
    const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef);

    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = [self getLayerTagWithChannelPerFrame:description->mChannelsPerFrame],
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

-(NSDictionary *)compressionAudioSettingForPCMType {
    CMAudioFormatDescriptionRef descriptionRef = (__bridge CMAudioFormatDescriptionRef)(self.formatDescriptions[0]);
    const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef);

    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = [self getLayerTagWithChannelPerFrame:description->mChannelsPerFrame],
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

#pragma mark - ILABAudioTrackExporter
@interface ILABAudioTrackExporter ()
@property (nonatomic, strong) AVAsset *exportingAudioAsset;
@property (nonatomic, strong) NSError * lastError;

@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *assetReaderOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterInput;
@property (nonatomic, strong) AVAssetExportSession *exportSession;

@property (nonatomic) NSInteger trackIndex;
@end

@implementation ILABAudioTrackExporter
#pragma mark - Init/Dealloc
-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex {
    return [self initWithAsset:sourceAsset
                    trackIndex:0
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
- (void)exportInM4ATo:(NSURL *)outputURL completion:(ILABCompleteBlock)completion {
    self.exportSession = [[AVAssetExportSession alloc] initWithAsset:self.exportingAudioAsset
                                                          presetName:AVAssetExportPresetAppleM4A];
    self.exportSession.outputURL = outputURL;
    self.exportSession.outputFileType = AVFileTypeAppleM4A;
    self.exportSession.timeRange = CMTimeRangeMake(kCMTimeZero, [self.exportingAudioAsset duration]);
    
    __weak typeof(self) weakSelf = self;
    [self.exportSession exportAsynchronouslyWithCompletionHandler:^{
        if (weakSelf.exportSession.status == AVAssetExportSessionStatusFailed) {
            completion(NO, weakSelf.exportSession.error);
        } else {
            completion(YES, nil);
        }
    }];
}

-(void)exportReverseToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock {
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

-(void)exportingToURL:(NSURL *)destinationURL complete:(ILABCompleteBlock)completeBlock {
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
    AVAssetTrack *track = [self.exportingAudioAsset tracksWithMediaType:AVMediaTypeAudio][self.trackIndex];

    self.assetReaderOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                                        outputSettings:[track decompressionAudioSettingForPCMType]];
    [self.assetReader addOutput:self.assetReaderOutput];
    
    if (![self.assetReader startReading]) {
        self.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderStartReading];
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
                                                               outputSettings:[track compressionAudioSettingForPCMType]];
    [self.assetWriter addInput:self.assetWriterInput];
    
    if (![self.assetWriter startWriting]) {
        self.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetWriterStartWriting];
        completeBlock(NO, self.lastError);
        return;
    }
    
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    [self.assetWriterInput requestMediaDataWhenReadyOnQueue:[[self class] audioExportGenerateQueue] usingBlock:^{
        while ([self.assetWriterInput isReadyForMoreMediaData]) {
            CMSampleBufferRef nextSampleBuffer = [self.assetReaderOutput copyNextSampleBuffer];
            if (self.isCanceled) {
                self.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
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
                    complete:(ILABCompleteBlock)completeBlock {
    // set up input file
    AudioFileID inputAudioFile;
    OSStatus theErr = AudioFileOpenURL((__bridge CFURLRef)tmpAudioFileURL,
                                       kAudioFileReadPermission, 0, &inputAudioFile);
    if (theErr != noErr) {
        self.lastError = [NSError errorWithAudioFileStatusCode:theErr];
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
        self.lastError = [NSError errorWithAudioFileStatusCode:theErr];
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
        self.lastError = [NSError errorWithAudioFileStatusCode:theErr];
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
        self.lastError = [NSError errorWithAudioFileStatusCode:theErr];
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
        self.lastError = [NSError errorWithAudioFileStatusCode:theErr];
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
        self.lastError = [NSError errorWithAudioFileStatusCode:theErr];
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

