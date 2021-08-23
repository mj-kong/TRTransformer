//
//  ILABReverseVideoExportSession.h
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//  Copyright © 2017 chrissung. All rights reserved.
//

#import "ILABReverseVideoDefs.h"
#import <AVFoundation/AVFoundation.h>

/**
 Utility class for reversing videos
 */
@interface ILABReverseVideoExportSession : NSObject

@property (readonly) BOOL sourceReady;                              /**< Source is loaded and ready to be reversed */
@property (readonly) NSInteger sourceVideoTracks;                   /**< Number of video tracks on source asset, anything beyond the 1st will be ignored/skipped */
@property (readonly) NSInteger sourceAudioTracks;                   /**< Number of audio tracks on source asset */
@property (readonly) CMTime sourceDuration;                         /**< Duration of source asset */
@property (readonly) NSTimeInterval sourceDurationSeconds;          /**< Duration in seconds of the source asset */
@property (readonly) float sourceFPS;                               /**< Maximum FPS of the source asset */
@property (readonly) CGAffineTransform sourceTransform;             /**< Source transform */
@property (readonly) CGSize sourceSize;                             /**< Natural size of the source asset */

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
 Start the export process asynchronously

 @param progressBlock Block to call to report progress of export
 @param completeBlock Block to call when export has completed
 */
-(void)exportAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock;

/**
 Cancel the reverse export process
 */
-(void)cancelReverseExport;

@end

