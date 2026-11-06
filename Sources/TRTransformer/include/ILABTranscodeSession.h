//
//  ILABTranscodeSession.h
//
//  Created by MJ.KONG-MAC on 2021/08/11.
//  Copyright © 2021 Jon Gilkison. All rights reserved.
//

#import "ILABReverseVideoDefs.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface ILABTranscodeSession : NSObject

@property (readonly) BOOL sourceReady;                              /**< Source is loaded and ready to be */
@property (readonly) NSInteger sourceVideoTracks;                   /**< Number of video tracks on source asset, anything beyond the 1st will be ignored/skipped */
@property (readonly) NSInteger sourceAudioTracks;                   /**< Number of audio tracks on source asset */
@property (readonly) CMTime sourceDuration;                         /**< Duration of source asset */
@property (readonly) NSTimeInterval sourceDurationSeconds;          /**< Duration in seconds of the source asset */
@property (readonly) float sourceFPS;                               /**< Maximum FPS of the source asset */
@property (readonly) float sourceEstimatedDataRate;                 /**< Source estimated data rate, in bits per second */
@property (readonly) CGAffineTransform sourceTransform;             /**< Source transform */
@property (readonly) CGSize sourceSize;                             /**< Natural size of the source asset */
@property (readonly) NSInteger videoTrackIndex;                     /**< 0-based index into the source's video tracks to use, default 0 */
@property (readonly) NSInteger audioTrackIndex;                     /**< 0-based audio track to use alone, or ILABAudioTrackIndexAll (default) to mix every audio track */

@property (assign, nonatomic) BOOL showDebug;                       /**< Show debug output messages when reversing */
@property (nonatomic, strong) NSURL *outputURL;                     /**< URL to output transcoded video to */

@property (nonatomic) CGSize size;                      /**< transcoding video size. If it is not set, source size */
@property (nonatomic) CGFloat frameRate;                /**< transcoding frame rate. If it is not set, source frame rate */
@property (nonatomic) CGFloat estimatedDataRate;        /**< the estimated data rate of the media data, in units of bits per second */

@property (nonatomic) BOOL deleteCacheFile;                         /**< After finishing transcode work, delete temporary files in the Library/Caches, default value is YES */

/**
 Create a new instance

 @param sourceVideoURL The source URL
 @return The new instance
 */
-(instancetype)initWithURL:(NSURL *)sourceVideoURL;

/**
 Creates a new instance

 @param sourceAsset The source AVAsset
 @return The new instance
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset;

/**
 Create a new instance
 
 @param sourceAsset The source AVAsset
 @prarm timeRange The time range
 @return The new instance
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange;

/**
 Create a new instance that reads the given video and audio streams (0-based, per media type); an audio index uses only that stream,
 ILABAudioTrackIndexAll mixes every audio stream (what the other inits do). An out-of-range index fails the transcode with ILABSessionErrorInvalidTrackIndex.
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange videoTrackIndex:(NSInteger)videoTrackIndex audioTrackIndex:(NSInteger)audioTrackIndex;

/**
 Creates a new session

 @param sourceVideoURL The source URL
 @param outputURL URL to output video to
 @return The new instance
 */
+(instancetype)transcodeSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL;

/**
 Creates a new session

 @param sourceAsset The source AVAsset to reverse
 @prarm timeRange The time range
 @param outputURL URL to output video to
 @return The new instance
 */
+(instancetype)transcodeSessionWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange outputURL:(NSURL *)outputURL;

/**
 Creates a new session that reads the given video and audio streams (0-based, per media type, or ILABAudioTrackIndexAll).
 */
+(instancetype)transcodeSessionWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange videoTrackIndex:(NSInteger)videoTrackIndex audioTrackIndex:(NSInteger)audioTrackIndex outputURL:(NSURL *)outputURL;

/**
 Start the transcode process asynchronously

 @param progressBlock Block to call to report progress of transcode
 @param completeBlock Block to call when export has completed
 */
-(void)transcodeAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock;

/**
 Cancel the transcode process
 */
-(void)cancelTranscode;

@end

NS_ASSUME_NONNULL_END
