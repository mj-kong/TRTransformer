//
//  ILABReverseVideoExporter.m
//
//  Created by Jon Gilkison on 8/15/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//  Copyright © 2017 chrissung. All rights reserved.
//

#import "ILABReverseVideoExportSession.h"
#import "ILABAudioTrackExporter.h"

@interface ILABReverseVideoExportSession()
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
@property (nonatomic, strong) AVAsset * reversingVideoAsset;
@property (nonatomic, strong) AVAsset * reversedAudioAsset;
@property (nonatomic, strong) AVAssetExportSession * exportSession;

@property (nonatomic) BOOL availableHDR;
@property (nonatomic, readonly) NSDictionary <NSString *, id> * videoOutputSettings;
@property (nonatomic, readonly) NSDictionary <NSString *, id> * videoCompressionProperties;
@end

typedef void(^ILABGenerateAssetBlock)(BOOL isSuccess, AVAsset *asset, NSError *error);

@implementation ILABReverseVideoExportSession

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
        self.samplesPerPass = 40;

        AVAssetTrack *track = [sourceAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVMutableComposition *videoComposition = [AVMutableComposition composition];
        AVMutableCompositionTrack *vTrack = [videoComposition
                                             addMutableTrackWithMediaType:AVMediaTypeVideo
                                             preferredTrackID:kCMPersistentTrackID_Invalid];
        [vTrack insertTimeRange:timeRange ofTrack:track atTime:kCMTimeZero error:nil];
        self.reversingVideoAsset = videoComposition;
        
        [self configureSourceMeta];

        if (@available(iOS 14.0, *)) {
            if (AVPlayer.eligibleForHDRPlayback &&
                [track hasMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo]) {
                self.availableHDR = YES;
            }
        } else {
            self.availableHDR = NO;
        }
    }
    return self;
}

+(instancetype)exportSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL {
    ILABReverseVideoExportSession *session = [[[self class] alloc] initWithURL:sourceVideoURL];
    session.outputURL = outputURL;
    return session;
}

+(instancetype)exportSessionWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange outputURL:(NSURL *)outputURL {
    ILABReverseVideoExportSession *session = [[[self class] alloc] initWithAsset:sourceAsset timeRange:timeRange];
    session.outputURL = outputURL;
    return session;
}

-(NSDictionary *)videoCompressionProperties {
    static const NSInteger fullHDProportion = 1920 * 1080;
    
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    [settings setObject:@(self.sourceEstimatedDataRate)
                 forKey:AVVideoAverageBitRateKey];
    [settings setObject:self.sourceSize.width * self.sourceSize.height > fullHDProportion ? @(YES) : @(NO)
                 forKey:AVVideoAllowFrameReorderingKey];
    if (@available(iOS 14.0, *)) {
        if (self.availableHDR) {
            [settings setObject:(__bridge NSString*)kVTHDRMetadataInsertionMode_Auto
                         forKey:(__bridge NSString*)kVTCompressionPropertyKey_HDRMetadataInsertionMode];
            [settings setObject:(__bridge NSString*)kVTProfileLevel_HEVC_Main10_AutoLevel
                         forKey:AVVideoProfileLevelKey];
        } else {
            if (self.sourceSize.width * self.sourceSize.height > fullHDProportion) {
                [settings setObject:AVVideoProfileLevelH264HighAutoLevel
                             forKey:AVVideoProfileLevelKey];
                [settings setObject:AVVideoH264EntropyModeCABAC
                             forKey:AVVideoH264EntropyModeKey];
            } else {
                [settings setObject:AVVideoProfileLevelH264MainAutoLevel
                             forKey:AVVideoProfileLevelKey];
            }
        }
    } else {
        if (self.sourceSize.width * self.sourceSize.height > fullHDProportion) {
            [settings setObject:AVVideoProfileLevelH264HighAutoLevel
                         forKey:AVVideoProfileLevelKey];
            [settings setObject:AVVideoH264EntropyModeCABAC
                         forKey:AVVideoH264EntropyModeKey];
        } else {
            [settings setObject:AVVideoProfileLevelH264MainAutoLevel
                         forKey:AVVideoProfileLevelKey];
        }
    }
    return settings;
}

-(NSDictionary *)videoOutputSettings {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    [settings setObject:@(self.sourceSize.width)
                 forKey:AVVideoWidthKey];
    [settings setObject:@(self.sourceSize.height)
                 forKey:AVVideoHeightKey];
    if (@available(iOS 14.0, *)) {
        if (self.availableHDR) {
            NSDictionary *colorProperties = @{
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            };
            [settings setObject:AVVideoCodecTypeHEVC
                         forKey:AVVideoCodecKey];
            [settings setObject:colorProperties
                         forKey:AVVideoColorPropertiesKey];
        } else {
            [settings setObject:AVVideoCodecH264
                         forKey:AVVideoCodecKey];
        }
    } else {
        [settings setObject:AVVideoCodecH264
                     forKey:AVVideoCodecKey];
    }
    [settings setObject:self.videoCompressionProperties
                 forKey:AVVideoCompressionPropertiesKey];

    return settings;
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

#pragma mark - Queue

+(dispatch_queue_t)reverseCancelQueue {
    static dispatch_queue_t reverseCancelQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reverseCancelQueue = dispatch_queue_create("cancel queue", NULL);
    });
    return reverseCancelQueue;
}

+(dispatch_queue_t)reverseQueue {
    static dispatch_queue_t reverseQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reverseQueue = dispatch_queue_create("reverse queue", NULL);
    });
    
    return reverseQueue;
}

+(dispatch_queue_t)reverseGenerateQueue {
    static dispatch_queue_t reverseGenerateQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reverseGenerateQueue = dispatch_queue_create("reverse generate queue", NULL);
    });
    
    return reverseGenerateQueue;
}

+(dispatch_queue_t)conversionGenerationQueue {
    static dispatch_queue_t conversionGenerationQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        conversionGenerationQueue = dispatch_queue_create("conversion generate queue", NULL);
    });
    
    return conversionGenerationQueue;
}

#pragma mark - Reverse Session

-(void)exportAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {
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
        if (self.availableHDR) {
            NSLog(@"reverse availableHDR: YES");
        }
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async([[self class] reverseQueue], ^{
        [weakSelf doReverse:progressBlock complete:completeBlock];
    });
}

-(void)doReverse:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    
    NSURL *audioDestionationURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-tempAudio.m4a",[[NSUUID UUID] UUIDString]]];
    NSURL *videoDestinationURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-tempVideo.mov",[[NSUUID UUID] UUIDString]]];
    
    __weak typeof(self) weakSelf = self;
    
    [self reverseAudioDestinationURL:audioDestionationURL
                       completeBlcok:completeBlock];
    
    [self reverseVideoAtDestinationURL:videoDestinationURL
                              progress:progressBlock
                         completeBlock:^(BOOL isSuccess, AVAsset *reversedVideoAsset, NSError *error) {
        if (!reversedVideoAsset) {
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
                               videoAsset:reversedVideoAsset
                               audioAsset:weakSelf.reversedAudioAsset
                            progressBlock:progressBlock
                                 complete:completeBlock
         ];
        //
        if (self.deleteCacheFile) {
            [[NSFileManager defaultManager] removeItemAtURL:audioDestionationURL error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:videoDestinationURL error:nil];
        }
    }];
}

#pragma mark - Reverse Methods

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
        NSLog(@"result -> reversed videoTrack duration: %f, audioTrack duration: %f, duration: %f",
              CMTimeGetSeconds(videoTrack.timeRange.duration),
              CMTimeGetSeconds(audioTrack == nil? kCMTimeZero : audioTrack.timeRange.duration),
              CMTimeGetSeconds(muxComp.duration)
        );
        NSLog(@"result -> source video info: size %@, frameRate (%.3f), estimatedDateRate (%.3f)",
              NSStringFromCGSize(self.sourceSize),
              self.sourceFPS,
              self.sourceEstimatedDataRate
        );
        NSLog(@"result -> reversed video info: size %@ frameRate (%.3f), estimatedDateRate (%.3f)",
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
        if (progressBlock) {
            [weakSelf updateProgressBlock:progressBlock
                            operation:@"Finishing Up"
                             progress:INFINITY];
        }
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

-(void)reversingAudioAtDestinationURL:(NSURL *)destinationURL completBlock:(ILABGenerateAssetBlock)resultsBlock {
    __weak typeof(self) weakSelf = self;
    
    dispatch_async([[self class] reverseGenerateQueue], ^{
        ILABAudioTrackExporter *audioExporter = [[ILABAudioTrackExporter alloc] initWithAsset:weakSelf.sourceAsset trackIndex:0 timeRange:weakSelf.timeRange];
        
        [audioExporter exportReverseToURL:destinationURL complete:^(BOOL isSuccess, NSError *error) {
            if (error) {
                weakSelf.lastError = error;
            }
            if (isSuccess) {
                resultsBlock(YES, [AVURLAsset assetWithURL:destinationURL], nil);
            } else {
                resultsBlock(NO, nil, weakSelf.lastError);
            }
        }];
        
    });
}

-(AVAsset *)convertToMA4TypeAtDestinationURL:(NSURL *)destinationURL asset:(AVAsset *)asset {
    ILABAudioTrackExporter *audioExporter = [[ILABAudioTrackExporter alloc] initWithAsset:asset trackIndex:0];
    
    __block AVAsset *convertedAsset = nil;
    
    dispatch_semaphore_t audioSema = dispatch_semaphore_create(0);
    dispatch_async([[self class] conversionGenerationQueue], ^{
        [audioExporter exportToURL:destinationURL complete:^(BOOL isSuccess, NSError *error) {
            if (isSuccess) {
                convertedAsset = [AVURLAsset assetWithURL:destinationURL];
                dispatch_semaphore_signal(audioSema);
            }
        }];
    });
    dispatch_semaphore_wait(audioSema, DISPATCH_TIME_FOREVER);
    return convertedAsset;
}

-(void)reverseAudioDestinationURL:(NSURL *)destinationURL completeBlcok:(ILABCompleteBlock)completeBlock {
    if (self.sourceAudioTracks== 0) return;
    
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *tempAudioFileURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-tempAudio.wav",[[NSUUID UUID] UUIDString]]];
    
    __weak typeof(self) weakSelf = self;
    __block AVAsset *asset = nil;
    
    dispatch_semaphore_t audioSema = dispatch_semaphore_create(0);
    [self reversingAudioAtDestinationURL:tempAudioFileURL
                            completBlock:^(BOOL isSuccess, AVAsset *reversedAudioAsset, NSError *error) {
        if (isSuccess) {
            asset = [weakSelf convertToMA4TypeAtDestinationURL:destinationURL
                                                         asset:reversedAudioAsset];
        } else if (error) {
            weakSelf.lastError = error;
        }
        dispatch_semaphore_signal(audioSema);
    }];
    
    dispatch_semaphore_wait(audioSema, DISPATCH_TIME_FOREVER);
    
    [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];
    
    if (self.lastError || asset == nil) {
        if (completeBlock) {
            completeBlock(NO, self.lastError);
        }
        return;
    }
    self.reversedAudioAsset = asset;
}

-(void)reverseVideoAtDestinationURL:(NSURL *)destinationURL progress:(ILABProgressBlock)progressBlock completeBlock:(ILABGenerateAssetBlock)resultsBlock {
    __weak typeof(self) weakSelf = self;
    dispatch_async([[self class] reverseGenerateQueue], ^{
        
        // Setup the reader
        NSError *error = nil;
        AVAssetReader *assetReader = [AVAssetReader
                                      assetReaderWithAsset:weakSelf.reversingVideoAsset
                                      error:&error];
        if (error) {
            weakSelf.lastError = error;
            resultsBlock(NO, nil, error);
            return;
        }
        
        // Setup the reader output
        AVAssetReaderTrackOutput *assetReaderOutput = [AVAssetReaderTrackOutput
                                                       assetReaderTrackOutputWithTrack:[weakSelf.reversingVideoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject
                                                       outputSettings:@{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
        assetReaderOutput.supportsRandomAccess = YES;
        [assetReader addOutput:assetReaderOutput];
        
        if (![assetReader startReading]) {
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderStartReading];
            resultsBlock(NO, nil, weakSelf.lastError);
            return;
        }
        
        // Fetch the sample times for the source video
        NSMutableArray<NSValue *> *revSampleTimes = [NSMutableArray new];
        CMSampleBufferRef sample;
        NSInteger localCount = 0;
        while ((sample = [assetReaderOutput copyNextSampleBuffer])) {
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
            if (weakSelf.showDebug) {
                NSLog(@"configure presentation time: %f", CMTimeGetSeconds(presentationTime));
            }

            if (CMTimeCompare(CMTimeAdd(kCMTimeZero, weakSelf.reversingVideoAsset.duration), presentationTime) == 0) {
                if (weakSelf.showDebug) {
                    NSLog(@"reverse last frame skip: %.3f", CMTimeGetSeconds(presentationTime));
                }
                CFRelease(sample); sample = NULL;
                continue;
            }

            [revSampleTimes addObject:[NSValue valueWithCMTime:presentationTime]];
            
            if ([weakSelf isCanceledReverseExport]) {
                weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
                resultsBlock(NO, nil, weakSelf.lastError);
                CFRelease(sample);
                sample = NULL;
                return;
            }
            if (progressBlock) {
                [weakSelf updateProgressBlock:progressBlock
                                    operation:@"Analyzing Source Video"
                                     progress:(CMTimeGetSeconds(presentationTime) / CMTimeGetSeconds(weakSelf.sourceDuration)) * 0.5];
            }
            
            CFRelease(sample);
            sample = NULL;
            
            localCount++;
        }
        
        if(assetReader.status == AVAssetReaderStatusFailed) {
            if (weakSelf.showDebug) {
                NSLog(@"%@", assetReader.error.localizedDescription);
            }
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderReading];
            resultsBlock(NO, nil, weakSelf.lastError);
            return;
        }

        // No samples, no bueno
        if (revSampleTimes.count == 0) {
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorVideoNoSamples];
            resultsBlock(NO, nil, weakSelf.lastError);
            return;
        }
        
        // Generate the pass data
        NSMutableArray *passDicts = [NSMutableArray new];
        
        CMTime initEventTime = revSampleTimes.firstObject.CMTimeValue;
        CMTime passStartTime = initEventTime;
        CMTime passEndTime = initEventTime;
        CMTime timeEventTime = initEventTime;
        
        NSInteger timeStartIndex = -1;
        NSInteger timeEndIndex = -1;
        NSInteger frameStartIndex = -1;
        NSInteger frameEndIndex = -1;
        
        NSInteger totalPasses = ceil((float)revSampleTimes.count / (float)weakSelf.samplesPerPass);
        
        BOOL initNewPass = NO;
        for(NSInteger i=0; i<revSampleTimes.count; i++) {
            timeEventTime = revSampleTimes[i].CMTimeValue;
            
            timeEndIndex = i;
            frameEndIndex = (revSampleTimes.count - 1) - i;
            
            passEndTime = timeEventTime;
            
            if (i % weakSelf.samplesPerPass == 0) {
                if (i > 0) {
                    [passDicts addObject:@{
                        @"passStartTime": [NSValue valueWithCMTime:passStartTime],
                        @"passEndTime": [NSValue valueWithCMTime:passEndTime],
                        @"timeStartIndex": @(timeStartIndex),
                        @"timeEndIndex": @(timeEndIndex),
                        @"frameStartIndex": @(frameStartIndex),
                        @"frameEndIndex": @(frameEndIndex)
                    }];
                }
                
                initNewPass = YES;
            }
            
            if (initNewPass) {
                passStartTime = timeEventTime;
                timeStartIndex = i;
                frameStartIndex = ((revSampleTimes.count - 1) - i);
                initNewPass = NO;
            }
        }
        
        if ((passDicts.count < totalPasses) || ((revSampleTimes.count % weakSelf.samplesPerPass) != 0)) {
            [passDicts addObject:@{
                @"passStartTime": [NSValue valueWithCMTime:passStartTime],
                @"passEndTime": [NSValue valueWithCMTime:passEndTime],
                @"timeStartIndex": @(timeStartIndex),
                @"timeEndIndex": @(timeEndIndex),
                @"frameStartIndex": @(frameStartIndex),
                @"frameEndIndex": @(frameEndIndex)
            }];
        }
        
        // Create the writer
        AVAssetWriter *assetWriter = [AVAssetWriter
                                      assetWriterWithURL:destinationURL
                                      fileType:AVFileTypeQuickTimeMovie
                                      error:&error];
        if (error) {
            weakSelf.lastError = error;
            resultsBlock(NO, nil, weakSelf.lastError);
            return;
        }
        
        AVAssetWriterInput *assetWriterInput =[AVAssetWriterInput
                                               assetWriterInputWithMediaType:AVMediaTypeVideo
                                               outputSettings:weakSelf.videoOutputSettings];
        assetWriterInput.expectsMediaDataInRealTime = NO;
        assetWriterInput.transform = weakSelf.sourceTransform;
        
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
                                                         assetWriterInputPixelBufferAdaptorWithAssetWriterInput:assetWriterInput
                                                         sourcePixelBufferAttributes:nil];
        [assetWriter addInput:assetWriterInput];
        
        if (![assetWriter startWriting]) {
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetWriterStartWriting];
            resultsBlock(NO, nil, weakSelf.lastError);
            return;
        }
        
        [assetWriter startSessionAtSourceTime:initEventTime];
        
        NSInteger frameCount = 0;
        
        for(NSInteger z=passDicts.count - 1; z>=0; z--) {
            NSDictionary *dict = passDicts[z];
            
            passStartTime = [dict[@"passStartTime"] CMTimeValue];
            passEndTime = [dict[@"passEndTime"] CMTimeValue];
            
            CMTime passDuration = CMTimeSubtract(passEndTime, passStartTime);
            if(CMTimeCompare(kCMTimeZero, passDuration) == 0) {
                continue;
            }
            
            timeStartIndex = [dict[@"timeStartIndex"] longValue];
            timeEndIndex = [dict[@"timeEndIndex"] longValue];
            
            frameStartIndex = [dict[@"frameStartIndex"] longValue];
            frameEndIndex = [dict[@"frameEndIndex"] longValue];
            
            [assetReaderOutput resetForReadingTimeRanges:@[[NSValue valueWithCMTimeRange:CMTimeRangeMake(passStartTime, passDuration)]]];
            
            NSMutableArray *samples = [NSMutableArray new];
            while((sample = [assetReaderOutput copyNextSampleBuffer])) {
                [samples addObject:(__bridge id)sample];
                CFRelease(sample);
            }
            
            if(assetReader.status == AVAssetReaderStatusFailed) {
                if (weakSelf.showDebug) {
                    NSLog(@"%@", assetReader.error.localizedDescription);
                }
                weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorAVAssetReaderReading];
                resultsBlock(NO, nil, weakSelf.lastError);
                return;
            }

            for(NSInteger i=0; i<samples.count; i++) {
                if (frameCount >= revSampleTimes.count) {
                    break;
                }
                
                CMTime eventTime = revSampleTimes[frameCount].CMTimeValue;
                
                CVPixelBufferRef imageBufferRef = CMSampleBufferGetImageBuffer((__bridge  CMSampleBufferRef)samples[(samples.count - 1) - i]);
                
                BOOL didAppend = NO;
                NSInteger missCount = 0;
                while(!didAppend && (missCount <= 45)) {
                    if (!adaptor.assetWriterInput.readyForMoreMediaData) {
                        do {
                            [NSThread sleepForTimeInterval:1. / 15.];
                        } while (!assetWriterInput.isReadyForMoreMediaData);
                    }
                    didAppend = [adaptor appendPixelBuffer:imageBufferRef withPresentationTime:eventTime];
                    if (!didAppend) {
                        weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorVideoUnableToWirteFrame];
                        resultsBlock(NO, nil, weakSelf.lastError);
                        return;
                    }
                    if (weakSelf.showDebug) {
                        NSLog(@"reverse append presentationTime: %f", CMTimeGetSeconds(eventTime));
                    }

                    missCount++;
                }
                frameCount++;
                
                if ([weakSelf isCanceledReverseExport]) {
                    weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
                    resultsBlock(NO, nil, weakSelf.lastError);
                    samples = nil;
                    return;
                }
                if(progressBlock) {
                    [weakSelf updateProgressBlock:progressBlock
                                        operation:@"Reversing Video"
                                         progress:0.5 + (((float)frameCount/(float)revSampleTimes.count) * 0.5)];
                }
            }
            
            samples = nil;
        }
        
        [assetWriterInput markAsFinished];
        
        if ([self isCanceledReverseExport]) {
            weakSelf.lastError = [NSError ILABSessionError:ILABSessionErrorUserCancel];
            resultsBlock(NO, nil, weakSelf.lastError);
            return;
        }
        if (progressBlock) {
            [weakSelf updateProgressBlock:progressBlock
                                operation:@"Saving Reversed Video"
                                 progress:1.0];
        }
        
        [assetWriter finishWritingWithCompletionHandler:^{
            resultsBlock(YES, [AVURLAsset assetWithURL:destinationURL], nil);
        }];
    });
}

#pragma mark - Cancel

-(void)cancelReverseExport {
    dispatch_barrier_sync([[self class] reverseCancelQueue], ^{
        self.isCanceled = YES;
        [self.exportSession cancelExport];
    });
}

-(BOOL)isCanceledReverseExport {
    __block BOOL _isCanceled;
    dispatch_sync([[self class] reverseCancelQueue], ^{
        _isCanceled = self.isCanceled;
    });
    return _isCanceled;}

@end
