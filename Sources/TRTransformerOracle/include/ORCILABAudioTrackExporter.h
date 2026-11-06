//
//  ORCILABAudioTrackExporter.h
//  ORCILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ORCILABReverseVideoDefs.h"
#import <AVFoundation/AVFoundation.h>

/**
 Utility class for exporting an audio AVAssetTrack to a file quickly
 */
@interface ORCILABAudioTrackExporter : NSObject

@property (readonly) BOOL exporting;            /**< Determines if the exporter is currently exporting */
@property (readonly) NSInteger trackIndex;      /**< The track index being exported */
@property (readonly) AVAsset *sourceAsset;      /**< The source asset the track is being exported from */
@property (nonatomic) BOOL isCanceled;

/**
 Create a new instance for the track exporter

 @param sourceAsset The `AVAsset` to export the audio from.
 @param trackIndex The index of the audio track to export, or ORCILABAudioTrackIndexAll to mix every track (M4A export only)
 @return The new instance
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex;

/**
 Create a new instance for the track exporter
 
 @param sourceAsset The `AVAsset` to export the audio from.
 @param trackIndex The index of the audio track to export, or ORCILABAudioTrackIndexAll to mix every track (M4A export only)
 @prarm timeRange The time range of the asset to be reversed.
 @return The new instance
 */
-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex timeRange:(CMTimeRange)timeRange;

/**
 Exports the audio track to a .m4a audio file

 @param outputURL The URL to export to
 @param completion The block that is called when the operation is complete
 */
- (void)exportInM4ATo:(NSURL *)outputURL completion:(ORCILABCompleteBlock)completion;

/**
 Exports the reversed version of the audio track to a .wav file

 @param outputURL The URL to export to
 @param completeBlock The block that is called when the operation is complete
 */
-(void)exportReverseToURL:(NSURL *)outputURL complete:(ORCILABCompleteBlock)completeBlock;

@end
