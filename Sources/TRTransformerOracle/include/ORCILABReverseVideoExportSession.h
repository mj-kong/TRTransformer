//
//  ORCILABReverseVideoExportSession.h
//  ORCILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//  Copyright © 2017 chrissung. All rights reserved.
//

#import "ORCILABReverseVideoDefs.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

/**
 Utility class for reversing videos
 */
@interface ORCILABReverseVideoExportSession : NSObject

@property (readonly) BOOL sourceReady;                              /**< Source is loaded and ready to be reversed */
@property (readonly) NSInteger sourceVideoTracks;                   /**< Number of video tracks on source asset, anything beyond the 1st will be ignored/skipped */
@property (readonly) NSInteger sourceAudioTracks;                   /**< Number of audio tracks on source asset */
@property (readonly) CMTime sourceDuration;                         /**< Duration of source asset */
@property (readonly) NSTimeInterval sourceDurationSeconds;          /**< Duration in seconds of the source asset */
@property (readonly) float sourceFPS;                               /**< Maximum FPS of the source asset */
@property (readonly) CGAffineTransform sourceTransform;             /**< Source transform */
@property (readonly) CGSize sourceSize;                             /**< Natural size of the source asset */
@property (readonly) NSInteger videoTrackIndex;                     /**< 0-based index into the source's video tracks to use, default 0 */
@property (readonly) NSInteger audioTrackIndex;                     /**< 0-based audio track to reverse, default 0; ORCILABAudioTrackIndexAll is treated as 0 */

@property (assign, nonatomic) BOOL showDebug;                       /**< Show debug output messages when reversing */
@property (assign, nonatomic) NSInteger samplesPerPass;             /**< Samples per pass when reversing video */
@property (assign, nonatomic) BOOL skipAudio;                       /**< Skip the processing of audio */
@property (copy, nonatomic) NSURL *outputURL;                       /**< URL to output reverse video to */
@property (nonatomic) BOOL deleteCacheFile;                         /**< After finishing reverse work, delete temporary files in the Library/Caches, default value is YES */

/**
 Create a new instance

 @param sourceVideoURL The URL for the source video
 @return The new instance
 */
-(instancetype)initWithURL:(NSURL *)sourceVideoURL;

/**
 Create a new instance
 
 @param sourceAsset The source AVAsset to reverse
 @prarm timeRange The time range of the asset to be reversed.
 @return The new instance
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange;

/**
 Create a new instance that reverses the given video and audio streams (0-based, per media type) instead of the first ones.
 ORCILABAudioTrackIndexAll is treated as audio stream 0 (reverse never mixed). An out-of-range index fails the export with ORCILABSessionErrorInvalidTrackIndex.
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange videoTrackIndex:(NSInteger)videoTrackIndex audioTrackIndex:(NSInteger)audioTrackIndex;

/**
 Creates a new instance

 @param sourceAsset The source AVAsset to reverse
 @return The new instance
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset;

/**
 Creates a new export session

 @param sourceVideoURL The URL for the source video
 @param outputURL URL to output reverse video to
 @return The new instance
 */
+(instancetype)exportSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL;

/**
 Creates a new export session
 
 @param sourceAsset The source AVAsset to reverse
 @prarm timeRange The time range of the asset to be reversed.
 @param outputURL URL to output reverse video to
 @return The new instance
 */
+(instancetype)exportSessionWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange outputURL:(NSURL *)outputURL;

/**
 Creates a new export session that reverses the given video and audio streams (0-based, per media type).
 */
+(instancetype)exportSessionWithAsset:(AVAsset *)sourceAsset timeRange:(CMTimeRange)timeRange videoTrackIndex:(NSInteger)videoTrackIndex audioTrackIndex:(NSInteger)audioTrackIndex outputURL:(NSURL *)outputURL;

/**
 Start the export process asynchronously

 @param progressBlock Block to call to report progress of export
 @param completeBlock Block to call when export has completed
 */
-(void)exportAsynchronously:(ORCILABProgressBlock)progressBlock complete:(ORCILABCompleteBlock)completeBlock;

/**
 Cancel the reverse export process
 */
-(void)cancelReverseExport;

@end

