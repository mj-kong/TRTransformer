//
//  ILABTranscodeSession.m
//
//  Created by MJ.KONG-MAC on 2021/08/11.
//  Copyright © 2021 Jon Gilkison. All rights reserved.
//

#import "ILABTranscodeSession.h"
#import "ILABAudioTrackExporter.h"
#import "TRTransformAPI.h"

@interface ILABTranscodeSession ()
@property (nonatomic) BOOL sourceReady;
@property (nonatomic) NSInteger sourceVideoTracks;
@property (nonatomic) NSInteger sourceAudioTracks;
@property (nonatomic) CMTime sourceDuration;
@property (nonatomic) NSTimeInterval sourceDurationSeconds;
@property (nonatomic) float sourceFPS;
@property (nonatomic) float sourceEstimatedDataRate;
@property (nonatomic) CGAffineTransform sourceTransform;
@property (nonatomic) CGSize sourceSize;
@property (nonatomic) CMTimeRange timeRange;
@property (nonatomic, strong) NSError * lastError;
@property (nonatomic) BOOL isCanceled;

@property (nonatomic, strong) AVAsset * sourceAsset;
@property (nonatomic, strong) AVAsset * transcodingVideoAsset;
@property (nonatomic, strong) AVAsset * transcodedAudioAsset;
@property (nonatomic, strong) AVAssetExportSession * exportSession;
@property (nonatomic, strong) ILABAudioTrackExporter* audioExporter;

@property (nonatomic) BOOL containsHDRVideo;
@property (nonatomic) BOOL isProResType;
@property (nonatomic) BOOL containsAlphaChannel;
@property (nonatomic) CMVideoCodecType sourceCodecType;
@end

typedef void(^ILABGenerateAssetBlock)(BOOL isSuccess, AVAsset *asset, NSError *error);

@implementation ILABTranscodeSession

#pragma mark - Init/Dealloc

-(instancetype)initWithURL:(NSURL *)sourceVideoURL {
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourceVideoURL.path]) {
        [NSException raise:@"Invalid input file." format:@"The file '%@' could not be located.", sourceVideoURL.path];
    }
    
    return [self initWithAsset:[AVURLAsset assetWithURL:sourceVideoURL]];
}

-(instancetype)initWithAsset:(AVAsset *)sourceAsset {
    return [self initWithAsset:sourceAsset timeRange:CMTimeRangeMake(kCMTimeZero, sourceAsset.duration)];
}

-(instancetype)initWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange {
    self = [super init];
    if (self) {
        CMTime endTime = CMTimeAdd(timeRange.start, timeRange.duration);
        CMTime sourceEndTime = CMTimeAdd(kCMTimeZero, sourceAsset.duration);
        
        if (CMTimeCompare(endTime, sourceEndTime) > 0) {
            CMTime value = CMTimeSubtract(endTime, sourceEndTime);
            CMTime duration = CMTimeSubtract(timeRange.duration, value);
            timeRange = CMTimeRangeMake(timeRange.start, duration);
        }
        
        self.timeRange = timeRange;
        self.sourceAsset = sourceAsset;
        self.exportSession = nil;
        self.deleteCacheFile = YES;
        self.showDebug = NO;

        AVAssetTrack *track = [sourceAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVMutableComposition *videoComposition = [AVMutableComposition composition];
        AVMutableCompositionTrack *vTrack = [videoComposition
                                             addMutableTrackWithMediaType:AVMediaTypeVideo
                                             preferredTrackID:kCMPersistentTrackID_Invalid];
        [vTrack insertTimeRange:timeRange ofTrack:track atTime:kCMTimeZero error:nil];
        self.transcodingVideoAsset = videoComposition;
        
        [self configureSourceMeta];

        if (AVPlayer.eligibleForHDRPlayback &&
            [track hasMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo]) {
            self.containsHDRVideo = YES;
        }
        self.isProResType = isProResType(track);
        self.size = self.sourceSize;
        self.frameRate = self.sourceFPS;
        CMFormatDescriptionRef ref = (__bridge CMFormatDescriptionRef)([track.formatDescriptions firstObject]);
        self.sourceCodecType = CMFormatDescriptionGetMediaSubType(ref);
        self.containsAlphaChannel = CMFormatDescriptionGetExtension(ref, kCMFormatDescriptionExtension_ContainsAlphaChannel) != NULL;
    }
    return self;
}

+(instancetype)transcodeSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL {
    ILABTranscodeSession *session = [[[self class] alloc] initWithURL:sourceVideoURL];
    session.outputURL = outputURL;
    return session;
}

+(instancetype)transcodeSessionWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange outputURL:(NSURL *)outputURL {
    ILABTranscodeSession *session = [[[self class] alloc] initWithAsset:sourceAsset timeRange:timeRange];
    session.outputURL = outputURL;
    return session;
}

-(void)configureSourceMeta {
    dispatch_semaphore_t loadSemi = dispatch_semaphore_create(0);
    __weak typeof(self) weakSelf = self;
    [self.sourceAsset loadValuesAsynchronouslyForKeys:@[@"duration", @"tracks", @"metadata"]
                                    completionHandler:^{
        NSError *error = nil;
        
        AVKeyValueStatus status = [weakSelf.sourceAsset statusOfValueForKey:@"duration" error:&error];
        if (status != AVKeyValueStatusLoaded) {
            dispatch_semaphore_signal(loadSemi);
            return;
        }
        
        NSArray<AVAssetTrack *> *videos = [weakSelf.sourceAsset tracksWithMediaType:AVMediaTypeVideo];
        NSArray<AVAssetTrack *> *audios = [weakSelf.sourceAsset tracksWithMediaType:AVMediaTypeAudio];
        AVAssetTrack *video = videos.firstObject;
        
        weakSelf.sourceDuration = weakSelf.sourceAsset.duration;
        weakSelf.sourceVideoTracks = videos.count;
        weakSelf.sourceAudioTracks = audios.count;
        weakSelf.sourceFPS = video.nominalFrameRate;
        weakSelf.sourceEstimatedDataRate = video.estimatedDataRate;
        weakSelf.sourceTransform = video.preferredTransform;
        
        CGFloat width = ((int)video.naturalSize.width % 2 == 0) ?
        video.naturalSize.width : video.naturalSize.width - 1;
        CGFloat height = ((int)video.naturalSize.height % 2 == 0) ?
        video.naturalSize.height : video.naturalSize.height - 1;
        weakSelf.sourceSize = CGSizeMake(width, height);
        weakSelf.sourceReady = videos.count > 0 || audios.count > 0;
        
        dispatch_semaphore_signal(loadSemi);
    }];
    while(dispatch_semaphore_wait(loadSemi, DISPATCH_TIME_NOW)) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
    }
}

-(void)setFrameRate:(CGFloat)frameRate {
    _frameRate = frameRate;
    if (self.sourceFPS < frameRate) {
        _frameRate = self.sourceFPS;
    }
}

#pragma mark - Queue

+(dispatch_queue_t)transcodeCancelQueue {
    static dispatch_queue_t transcodeCancelQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        transcodeCancelQueue = dispatch_queue_create("transcode cancel queue", NULL);
    });
    return transcodeCancelQueue;
}

+(dispatch_queue_t)transcodeQueue {
    static dispatch_queue_t transcodeQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        transcodeQueue = dispatch_queue_create("transcode queue", NULL);
    });
    
    return transcodeQueue;
}

+(dispatch_queue_t)transcodeGenerateQueue {
    static dispatch_queue_t transcodeGenerateQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        transcodeGenerateQueue = dispatch_queue_create("transcode generate queue", NULL);
    });
    
    return transcodeGenerateQueue;
}

#pragma mark - Transcode Session

-(void)transcodeAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {
    // Make sure the output URL has been specified
    if (!self.outputURL) {
        if (completeBlock) {
            completeBlock(NO, [NSError ILABSessionError:ILABSessionErrorMissingOutputURL]);
        }
        return;
    }
    
    // Remove any existing files at the output URL
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.outputURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:self.outputURL error:&error];
        if (error) {
            if (completeBlock) {
                completeBlock(NO, error);
            }
            return;
        }
    }
    if (self.showDebug) {
        NSLog(@"transcode containsHDRVideo: %d, isProResType: %d", self.containsHDRVideo, self.isProResType);
    }
    [self doTranscode:progressBlock complete:completeBlock];
}

-(void)doTranscode:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    
    __weak typeof(self) weakSelf = self;
    
    NSURL *audioDestionationURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-tempAudio.m4a",[[NSUUID UUID] UUIDString]]];
    NSURL *videoDestinationURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-tempVideo.mov",[[NSUUID UUID] UUIDString]]];
    
    [self transcodeAudioAtDestinationURL:audioDestionationURL completeBlock:^(BOOL complete, NSError *error) {
        [weakSelf transcodeVideoAtDestinationURL:videoDestinationURL
                                    progress:progressBlock
                               completeBlock:^(BOOL isSuccess, AVAsset *transcodedVideoAsset, NSError *error) {
            if (!transcodedVideoAsset) {
                if (completeBlock) {
                    completeBlock(NO, error);
                }
                //
                if (weakSelf.deleteCacheFile) {
                    [[NSFileManager defaultManager] removeItemAtURL:audioDestionationURL error:nil];
                    [[NSFileManager defaultManager] removeItemAtURL:videoDestinationURL error:nil];
                }
                return;
            }
            
            [weakSelf exportAtDestinationURL:weakSelf.outputURL
                                   videoAsset:transcodedVideoAsset
                                   audioAsset:weakSelf.transcodedAudioAsset
                                progressBlock:progressBlock
                                     complete:completeBlock
             ];
            //
            if (weakSelf.deleteCacheFile) {
                [[NSFileManager defaultManager] removeItemAtURL:audioDestionationURL error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:videoDestinationURL error:nil];
            }
        }];

    }];
}

#pragma mark - Transcode Methods

-(void)updateProgressBlock:(ILABProgressBlock)progressBlock operation:(NSString *)operation progress:(float)progress {
    if (!progressBlock) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        progressBlock(operation, progress);
    });
}

-(void)exportAtDestinationURL:(NSURL *)destinationURL videoAsset:(AVAsset *)videoAsset audioAsset:(AVAsset *)audioAsset progressBlock:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {
    
    AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;

    AVMutableComposition *muxComp = [AVMutableComposition composition];
    
    AVMutableCompositionTrack *compVideoTrack = [muxComp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                     preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *compAudioTrack = [muxComp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                     preferredTrackID:kCMPersistentTrackID_Invalid];
    
    compVideoTrack.preferredTransform = videoTrack.preferredTransform;
    
    NSError *error = nil;
    if (videoTrack != nil) {
        [compVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration)
                                ofTrack:videoTrack
                                 atTime:kCMTimeZero
                                  error:&error];
    }
    if (audioTrack != nil) {
        [compAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioAsset.duration)
                                ofTrack:audioTrack
                                 atTime:kCMTimeZero
                                  error:&error];
    }
    if (error != nil) {
        completeBlock(NO, [NSError ILABSessionError:ILABSessionErrorInsertTrack]);
        return;
    }

    if (self.showDebug) {
        NSLog(@"result -> transcoded videoTrack duration: %.3f, audioTrack duration: %.3f, duration: %.3f, inputed timeRange(start: %.3f, duration: %.3f)",
              CMTimeGetSeconds(videoTrack.timeRange.duration),
              CMTimeGetSeconds(audioTrack == nil? kCMTimeZero : audioTrack.timeRange.duration),
              CMTimeGetSeconds(muxComp.duration),
              CMTimeGetSeconds(self.timeRange.start),
              CMTimeGetSeconds(self.timeRange.duration)
              );
        NSLog(@"result -> source video info: size %@, frameRate (%.3f), estimatedDateRate (%.3f)",
              NSStringFromCGSize(self.sourceSize),
              self.sourceFPS,
              self.sourceEstimatedDataRate
              );
        NSLog(@"result -> transcoded video info: size %@ frameRate (%.3f), estimatedDateRate (%.3f)",
              NSStringFromCGSize(videoTrack.naturalSize),
              videoTrack.nominalFrameRate,
              videoTrack.estimatedDataRate
              );
    }
    
    __weak typeof(self) weakSelf = self;
    
    NSString *preset = AVAssetExportPresetPassthrough;
    AVFileType outputType = AVFileTypeQuickTimeMovie;
    
    [AVAssetExportSession determineCompatibilityOfExportPreset:preset
                                                     withAsset:muxComp
                                                outputFileType:outputType
                                             completionHandler:^(BOOL compatible) {
        if (compatible) {
            weakSelf.exportSession = [AVAssetExportSession exportSessionWithAsset:muxComp
                                                                       presetName:preset];
            if (weakSelf.exportSession == nil) {
                completeBlock(NO, [NSError ILABSessionError:ILABSessionErrorAVAssetExportSessionCreate]);
                return;
            }
            weakSelf.exportSession.outputFileType = outputType;
            weakSelf.exportSession.outputURL = destinationURL;

            [weakSelf.exportSession exportAsynchronouslyWithCompletionHandler:^{
                if (weakSelf.isCanceled) {
                    weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
                } else if (weakSelf.exportSession.status != AVAssetExportSessionStatusCompleted) {
                    weakSelf.lastError = weakSelf.exportSession.error;
                }
                if (completeBlock) {
                    completeBlock((weakSelf.lastError == nil), weakSelf.lastError);
                }
            }];
        } else {
            completeBlock(NO, [NSError ILABSessionError:ILABSessionErrorAVAssetExportSessionCompatibility]);
        }
    }];
}

-(void)transcodingAudioAtDestinationURL:(NSURL *)destinationURL completBlock:(ILABGenerateAssetBlock)resultsBlock {
    __weak typeof(self) weakSelf = self;
    __block BOOL result = NO;
    __block NSError *_error = nil;
    
    self.audioExporter = [[ILABAudioTrackExporter alloc] initWithAsset:self.sourceAsset trackIndex:0 timeRange:self.timeRange];
    
    dispatch_async([[self class] transcodeGenerateQueue], ^{
        [weakSelf.audioExporter exportInM4ATo:destinationURL
                                   completion:^(BOOL complete, NSError *error) {
            weakSelf.audioExporter = nil;
            if (error) {
                weakSelf.lastError = error;
            }
            if (complete) {
                resultsBlock(YES, [AVURLAsset assetWithURL:destinationURL], nil);
            } else {
                resultsBlock(NO, nil, weakSelf.lastError);
            }
        }];
    });
}

-(void)transcodeAudioAtDestinationURL:(NSURL *)destinationURL completeBlock:(ILABCompleteBlock)completeBlock {
    if (self.sourceAudioTracks== 0) {
        completeBlock(YES, nil);
        return;
    };
    
    __weak typeof(self) weakSelf = self;
    [self transcodingAudioAtDestinationURL:destinationURL
                              completBlock:^(BOOL isSuccess, AVAsset *transcodedAudioAsset, NSError *error) {
        if (isSuccess) {
            weakSelf.transcodedAudioAsset = transcodedAudioAsset;
            if (completeBlock) {
                completeBlock(YES, nil);
            }
        } else {
            if (completeBlock) {
                completeBlock(NO, error);
            }
        }
    }];
}

- (void)transcodeVideoAtDestinationURL:(NSURL *)destinationURL progress:(ILABProgressBlock)progressBlock completeBlock:(ILABGenerateAssetBlock)completeBlock {
    __weak typeof(self) weakSelf = self;
    
    dispatch_async([[self class] transcodeGenerateQueue], ^{
        NSError *error = nil;
        
        // AVAssetReader
        AVAssetReader *assetReader = [AVAssetReader
                                      assetReaderWithAsset:weakSelf.transcodingVideoAsset
                                      error:&error];
        if (error) {
            weakSelf.lastError = error;
            completeBlock(NO, nil, error);
            return;
        }
        NSDictionary *outputSettings = makeVideoReaderSettings(self.containsHDRVideo, self.containsAlphaChannel, self.isProResType);
        AVAssetReaderTrackOutput *assetReaderOutput = [AVAssetReaderTrackOutput
                                                       assetReaderTrackOutputWithTrack:[weakSelf.transcodingVideoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject
                                                       outputSettings:outputSettings];
        assetReaderOutput.supportsRandomAccess = YES;
        [assetReader addOutput:assetReaderOutput];
        
        if (![assetReader startReading]) {
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderStartReading];
            completeBlock(NO, nil, weakSelf.lastError);
            return;
        }
        
        AVAssetWriter *assetWriter;
        AVAssetWriterInput *assetWriterInput;

        BOOL writerEnable = NO;
        BOOL firstTry = YES;

        do {
            CGFloat estimatedDataRate = ((self.size.width * self.size.height * self.frameRate * 0.17) / 1024) * 1000;
            NSDictionary *compressionProperties = makeCompressionProperties(
                self.sourceSize,
                estimatedDataRate,
                self.sourceCodecType,
                self.containsHDRVideo
            );
            NSDictionary *outputSettings = makeVideoOutputSettings(
                self.size,
                self.sourceCodecType,
                self.containsHDRVideo,
                self.containsAlphaChannel,
                compressionProperties
            );
            NSDictionary *defaultCompressionProperties = makeDefaultCompressionProperties(self.sourceSize, estimatedDataRate);
            NSDictionary *defaultSettings = makeVideoDefaultSettings(self.size, defaultCompressionProperties);
            assetWriter = [AVAssetWriter assetWriterWithURL:destinationURL
                                                   fileType:AVFileTypeQuickTimeMovie
                                                      error:&error];
            assetWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                  outputSettings:firstTry ? outputSettings : defaultSettings];
            assetWriterInput.expectsMediaDataInRealTime = NO;
            assetWriterInput.transform = weakSelf.sourceTransform;
            
            [assetWriter addInput:assetWriterInput];
           
            writerEnable = [assetWriter startWriting];
            if (writerEnable == NO) {
                firstTry = NO;
                [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
            }
        } while (writerEnable == NO);

        [assetWriter startSessionAtSourceTime:kCMTimeZero];
        
        NSInteger readFrameCount = 0;
        
        // Go Transcoding
        CMSampleBufferRef sample = NULL;
        CMTime lastPresentationTime = kCMTimeZero;
        CMTime frameIntervalTime = CMTimeMake(weakSelf.frameRate, 1000);
        
        while ((sample = [assetReaderOutput copyNextSampleBuffer])) {
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
            
            if(assetReader.status == AVAssetReaderStatusFailed) {
                weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderReading];
                completeBlock(NO, nil, weakSelf.lastError);
                CFRelease(sample); sample = NULL;
                return;
            }
            if ([weakSelf isCanceledTranscodeExport]) {
                weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
                completeBlock(NO, nil, weakSelf.lastError);
                CFRelease(sample); sample = NULL;
                return;
            }
            
            if (readFrameCount != 0 &&
                weakSelf.sourceFPS != weakSelf.frameRate &&
                CMTimeCompare(CMTimeSubtract(presentationTime, lastPresentationTime), frameIntervalTime) == -1) {
                if (weakSelf.showDebug) {
                    NSLog(@"transcode skip: %.3f", CMTimeGetSeconds(presentationTime));
                }
                CFRelease(sample); sample = NULL;
                continue;
            }
            if (CMTimeCompare(CMTimeAdd(kCMTimeZero, weakSelf.transcodingVideoAsset.duration), presentationTime) == 0) {
                if (weakSelf.showDebug) {
                    NSLog(@"transcode last frame skip: %.3f", CMTimeGetSeconds(presentationTime));
                }
                CFRelease(sample); sample = NULL;
                continue;
            }
            
            lastPresentationTime = CMTimeMake(readFrameCount++, weakSelf.frameRate);
            
            if (!assetWriterInput.readyForMoreMediaData) {
                do {
                    [NSThread sleepForTimeInterval:1. / 15.];
                } while (!assetWriterInput.isReadyForMoreMediaData);
            }
            if ([assetWriterInput appendSampleBuffer:sample] == NO) {
                weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorVideoUnableToWirteFrame];
                completeBlock(NO, nil, weakSelf.lastError);
                CFRelease(sample); sample = NULL;
                return;
            }
            if (weakSelf.showDebug) {
                NSLog(@"transcode append presentationTime: %.3f", CMTimeGetSeconds(presentationTime));
            }
            if (progressBlock) {
                [weakSelf updateProgressBlock:progressBlock
                                    operation:@"Transcoding Video"
                                     progress:(CMTimeGetSeconds(presentationTime) / CMTimeGetSeconds(weakSelf.timeRange.duration))];
            }
            CFRelease(sample); sample = NULL;
        }

        if(assetReader.status == AVAssetReaderStatusFailed) {
            if (weakSelf.showDebug) {
                NSLog(@"%@", assetReader.error.localizedDescription);
            }
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderReading];
            completeBlock(NO, nil, weakSelf.lastError);
            return;
        }

        [assetWriterInput markAsFinished];
        
        if ([self isCanceledTranscodeExport]) {
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
            completeBlock(NO, nil, weakSelf.lastError);
            return;
        }
        if (progressBlock) {
            [weakSelf updateProgressBlock:progressBlock
                                operation:@"Saving Transcoded Video"
                                 progress:1.0];
        }
        
        [assetWriter finishWritingWithCompletionHandler:^{
            completeBlock(YES, [AVURLAsset assetWithURL:destinationURL], nil);
        }];
    });
}

#pragma mark - Cancel

-(void)cancelTranscode {
    dispatch_barrier_sync([[self class] transcodeCancelQueue], ^{
        self.isCanceled = YES;
        [self.exportSession cancelExport];
    });
}

-(BOOL)isCanceledTranscodeExport {
    __block BOOL _isCanceled;
    dispatch_sync([[self class] transcodeCancelQueue], ^{
        _isCanceled = self.isCanceled;
    });
    return _isCanceled;
}

@end
