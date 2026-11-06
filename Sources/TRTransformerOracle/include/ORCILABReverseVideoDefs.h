//
//  ORCILABReverseVideoDefs.h
//  ORCILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const kORCILABReverseVideoExportSessionErrorDomain;

/** audioTrackIndex value that mixes every audio track into one (the pre-1.12.19 Transcode behaviour). */
extern NSInteger const ORCILABAudioTrackIndexAll;

typedef enum : NSInteger {
    ORCILABSessionErrorMissingOutputURL                = -101,
    ORCILABSessionErrorAVAssetReaderStartReading       = -102,
    ORCILABSessionErrorVideoNoSamples                  = -103,
    ORCILABSessionErrorAVAssetWriterStartWriting       = -104,
    ORCILABSessionErrorVideoUnableToWirteFrame         = -105,
    ORCILABSessionErrorUserCancel                      = -106,
    ORCILABSessionErrorAVAssetReaderReading            = -107,
    ORCILABSessionErrorAVAssetExportSessionCompatibility   = -108,
    ORCILABSessionErrorInsertTrack                     = -109,
    ORCILABSessionErrorAVAssetExportSessionCreate      = -110,
    
    ORCILABSessionErrorAudioInvalidTrackIndex          = -201,
    ORCILABSessionErrorAudioCannotAddInput             = -202,
    ORCILABSessionErrorAudioCanAddOutput               = -203,
    ORCILABSessionErrorNoCompleteAudioExport           = -204,
    
    ORCILABSessionErrorInvalidTrackIndex               = -301,   /**< Requested video/audio track index is out of range for the source */
} ORCILABSessionError;

/**
 Block called when a reversal has completed.
 
 @param complete YES if successful, NO if not
 @param error If not successful, the NSError describing the problem
 */
typedef void(^ORCILABCompleteBlock)(BOOL complete, NSError *error);

/**
 Progress block called during reversal process
 
 @param currentOperation The current operation name/title
 @param progress The current progress normalized 0 .. 1, INFINITY for an operation that is indeterminate
 */
typedef void(^ORCILABProgressBlock)(NSString *currentOperation, float progress);


/**
 Category for easily generation NSError instances in the kORCILABReverseVideoExportSessionErrorDomain domain.
 */
@interface NSError(ORCILABReverseVideoExportSession)

/**
 Return an NSError with the kORCILABReverseVideoExportSessionDomain, error code and localized description set
 
 @param errorStatus The error status to return
 @return The NSError instance
 */
+(NSError *)ORCILABSessionError:(ORCILABSessionError)errorStatus;


/**
 Returns an NSError with a helpful localized description for common audio errors

 @param statusCode The status code
 @return The NSError instance
 */
+(NSError *)orc_errorWithAudioFileStatusCode:(OSStatus)statusCode;

@end
