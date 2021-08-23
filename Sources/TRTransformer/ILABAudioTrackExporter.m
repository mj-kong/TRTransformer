//
//  ILABAudioTrackExporter.m
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ILABAudioTrackExporter.h"
@import Accelerate;

@interface ILABAudioTrackExporter ()
@property (nonatomic, strong) AVAsset *sourceAsset;
@property (nonatomic, strong) AVAsset *exportingAudioAsset;
@property (nonatomic, strong) NSError * lastError;

@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *assetReaderOutput;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterInput;

@property (nonatomic) NSInteger trackIndex;

@property (nonatomic) Float64 sourceSampleRate;
@property (nonatomic) UInt32 sourceEstimatedDataRate;
@property (nonatomic) UInt32 sourceChannel;
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
        self.sourceAsset = sourceAsset;
        self.trackIndex = trackIndex;
        
        AVAssetTrack *audioTrack = [sourceAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        CMAudioFormatDescriptionRef descriptionRef = (__bridge CMAudioFormatDescriptionRef)(audioTrack.formatDescriptions[0]);
        const AudioStreamBasicDescription *description = CMAudioFormatDescriptionGetStreamBasicDescription(descriptionRef);
        
        self.sourceSampleRate = description->mSampleRate;
        self.sourceChannel = description->mChannelsPerFrame;
        self.sourceEstimatedDataRate = audioTrack.estimatedDataRate;

        AVMutableComposition *audioComp = [AVMutableComposition composition];
        for(AVAssetTrack *track in [sourceAsset tracksWithMediaType:AVMediaTypeAudio]) {
            AVMutableCompositionTrack *atrack = [audioComp
                                                 addMutableTrackWithMediaType:AVMediaTypeAudio
                                                 preferredTrackID:kCMPersistentTrackID_Invalid];
            [atrack insertTimeRange:timeRange ofTrack:track atTime:kCMTimeZero error:nil];
        }
        self.exportingAudioAsset = audioComp;
    }
    return self;
}

-(NSDictionary *)decompressionAudioSettingForPCMType {
    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = self.sourceChannel == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono,
    };
    NSMutableDictionary *settings = [@{
        AVFormatIDKey:@(kAudioFormatLinearPCM),
        AVNumberOfChannelsKey:@(self.sourceChannel),
        AVSampleRateKey:@(self.sourceSampleRate),
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
    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = self.sourceChannel == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono,
    };
    NSMutableDictionary *settings = [@{
        AVFormatIDKey:@(kAudioFormatLinearPCM),
        AVNumberOfChannelsKey:@(self.sourceChannel),
        AVSampleRateKey:@(self.sourceSampleRate),
        AVLinearPCMBitDepthKey:@32,
        AVLinearPCMIsFloatKey:@NO,
        AVLinearPCMIsNonInterleaved:@NO,
        AVLinearPCMIsBigEndianKey:@NO,
        AVChannelLayoutKey:[NSData dataWithBytes:&stereoChannelLayout
                                          length:offsetof(AudioChannelLayout, mChannelDescriptions)]
    } mutableCopy];
    
    return settings;
}

-(NSDictionary *)decompressionAudioSettingForM4AType {
    NSMutableDictionary *settings = [@{
        AVFormatIDKey:@(kAudioFormatLinearPCM),
    } mutableCopy];
    
    return settings;
}

-(NSDictionary *)compressionAudioSettingsForM4AType {
    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = self.sourceChannel == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono,
    };
    NSMutableDictionary *settings = [@{
        AVFormatIDKey:@(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey:@(self.sourceChannel),
        AVSampleRateKey:@(self.sourceSampleRate),
        AVEncoderBitRateKey:@(self.sourceEstimatedDataRate),
        AVChannelLayoutKey:[NSData dataWithBytes:&stereoChannelLayout
                                          length:offsetof(AudioChannelLayout, mChannelDescriptions)]
    } mutableCopy];
    
    return settings;
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

-(void)exportToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock {
    [self exportingToURL:outputURL isPCMType:NO complete:completeBlock];
}

-(void)exportReverseToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock {
    NSURL *tmpAudioFileURL = [[outputURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"exported-audio.wav"];

    __weak typeof(self) weakSelf = self;
    
    dispatch_semaphore_t audioSema = dispatch_semaphore_create(0);
    [self exportingToURL:tmpAudioFileURL isPCMType:YES complete:^(BOOL complete, NSError *error) {
        if (error) {
            weakSelf.lastError = error;
        }
        dispatch_semaphore_signal(audioSema);
    }];
    dispatch_semaphore_wait(audioSema, DISPATCH_TIME_FOREVER);
    
    if (self.lastError) {
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    
    [self exportingReverseToURL:outputURL tmpAudioFileURL:tmpAudioFileURL complete:completeBlock];
}

-(BOOL)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    return YES;
}

-(void)exportingToURL:(NSURL *)destinationURL isPCMType:(BOOL)isPCMType complete:(ILABCompleteBlock)completeBlock {
    __weak typeof(self) weakSelf = self;
    
    [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
    
    NSError *error = nil;
    
    // AVAssetReader
    weakSelf.assetReader = [AVAssetReader
                            assetReaderWithAsset:weakSelf.exportingAudioAsset
                            error:&error];
    if (error) {
        weakSelf.lastError = error;
        completeBlock(NO, error);
        return;
    }
    AVAssetTrack *track = [weakSelf.exportingAudioAsset tracksWithMediaType:AVMediaTypeAudio][weakSelf.trackIndex];
    weakSelf.assetReaderOutput = [AVAssetReaderTrackOutput
                                  assetReaderTrackOutputWithTrack:track
                                  outputSettings:isPCMType ? [weakSelf decompressionAudioSettingForPCMType] : [weakSelf decompressionAudioSettingForM4AType]];
    [weakSelf.assetReader addOutput:weakSelf.assetReaderOutput];
    
    if (![weakSelf.assetReader startReading]) {
        weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderStartReading];
        completeBlock(NO, weakSelf.lastError);
        return;
    }

    // AVAssetWriter
    weakSelf.assetWriter = [AVAssetWriter
                            assetWriterWithURL:destinationURL
                            fileType:isPCMType ? AVFileTypeWAVE : AVFileTypeAppleM4A
                            error:&error];
    if (error) {
        weakSelf.lastError = error;
        completeBlock(NO, weakSelf.lastError);
        return;
    }
    weakSelf.assetWriterInput = [AVAssetWriterInput
                                 assetWriterInputWithMediaType:AVMediaTypeAudio
                                 outputSettings:isPCMType ? [weakSelf compressionAudioSettingForPCMType] : [weakSelf compressionAudioSettingsForM4AType]];
    [weakSelf.assetWriter addInput:weakSelf.assetWriterInput];
    
    if (![weakSelf.assetWriter startWriting]) {
        weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetWriterStartWriting];
        completeBlock(NO, weakSelf.lastError);
        return;
    }
    
    [weakSelf.assetWriter startSessionAtSourceTime:kCMTimeZero];

    [weakSelf.assetWriterInput requestMediaDataWhenReadyOnQueue:[[self class] audioExportGenerateQueue] usingBlock:^{
        while ([weakSelf.assetWriterInput isReadyForMoreMediaData]) {
            CMSampleBufferRef nextSampleBuffer = [weakSelf.assetReaderOutput copyNextSampleBuffer];
            if (nextSampleBuffer) {
                [weakSelf.assetWriterInput appendSampleBuffer:nextSampleBuffer];
                CFRelease(nextSampleBuffer);
            } else {
                [weakSelf.assetWriterInput markAsFinished];
                [weakSelf.assetWriter finishWritingWithCompletionHandler:^{
                    completeBlock(YES, nil);
                }];
                break;
            }
        }
    }];
}

-(void)exportingReverseToURL:(NSURL *)outputURL tmpAudioFileURL:(NSURL *)tmpAudioFileURL complete:(ILABCompleteBlock)completeBlock {
    
    __weak typeof(self) weakSelf = self;
    
    // set up input file
    AudioFileID inputAudioFile;
    OSStatus theErr = AudioFileOpenURL((__bridge CFURLRef)tmpAudioFileURL,
                                       kAudioFileReadPermission, 0, &inputAudioFile);
    if (theErr != noErr) {
        weakSelf.lastError = [NSError errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, weakSelf.lastError);
        }
        return;
    }
    
    AudioStreamBasicDescription theFileFormat;
    UInt32 thePropertySize = sizeof(theFileFormat);
    theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyDataFormat, &thePropertySize, &theFileFormat);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        weakSelf.lastError = [NSError errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, weakSelf.lastError);
        }
        return;
    }
    
    UInt64 fileDataSize = 0;
    thePropertySize = sizeof(fileDataSize);
    theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyAudioDataByteCount, &thePropertySize, &fileDataSize);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        weakSelf.lastError = [NSError errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, weakSelf.lastError);
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
        weakSelf.lastError = [NSError errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, weakSelf.lastError);
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
            completeBlock(NO, weakSelf.lastError);
        }
        return;
    }

    UInt32 bytesRead=(UInt32)dataSize;
    theErr = AudioFileReadBytes(inputAudioFile, false, 0, &bytesRead, theData);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        weakSelf.lastError = [NSError errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, weakSelf.lastError);
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
            completeBlock(NO, weakSelf.lastError);
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
        weakSelf.lastError = [NSError errorWithAudioFileStatusCode:theErr];
        if (completeBlock) {
            completeBlock(NO, weakSelf.lastError);
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
