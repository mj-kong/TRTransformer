//
//  ILABReverseVideoDefs.h
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import <Foundation/Foundation.h>

extern NSString * const kILABReverseVideoExportSessionErrorDomain;

typedef enum : NSInteger {
    ILABSessionErrorMissingOutputURL                = -101,
    ILABSessionErrorAVAssetReaderStartReading       = -102,
    ILABSessionErrorVideoNoSamples                  = -103,
    ILABSessionErrorAVAssetWriterStartWriting       = -104,
    ILABSessionErrorVideoUnableToWirteFrame         = -105,
    ILABSessionErrorUserCancel                      = -106,
    ILABSessionErrorAVAssetReaderReading            = -107,
    ILABSessionErrorAVAssetExportSessionCompatibility   = -108,
    ILABSessionErrorInsertTrack                     = -109,
    ILABSessionErrorAVAssetExportSessionCreate      = -110,
    
    ILABSessionErrorAudioInvalidTrackIndex          = -201,
    ILABSessionErrorAudioCannotAddInput             = -202,
    ILABSessionErrorAudioCanAddOutput               = -203,
    ILABSessionErrorNoCompleteAudioExport           = -204,
    
} ILABSessionError;

/**
 Block called when a reversal has completed.
 
 @param complete YES if successful, NO if not
 @param error If not successful, the NSError describing the problem
 */
typedef void(^ILABCompleteBlock)(BOOL complete, NSError *error);

/**
 Progress block called during reversal process
 
 @param currentOperation The current operation name/title
 @param progress The current progress normalized 0 .. 1, INFINITY for an operation that is indeterminate
 */
typedef void(^ILABProgressBlock)(NSString *currentOperation, float progress);


/**
 Category for easily generation NSError instances in the kILABReverseVideoExportSessionErrorDomain domain.
 */
@interface NSError(ILABReverseVideoExportSession)

/**
 Return an NSError with the kILABReverseVideoExportSessionDomain, error code and localized description set
 
 @param errorStatus The error status to return
 @return The NSError instance
 */
+(NSError *)ILABSessionError:(ILABSessionError)errorStatus;


/**
 Returns an NSError with a helpful localized description for common audio errors

 @param statusCode The status code
 @return The NSError instance
 */
+(NSError *)errorWithAudioFileStatusCode:(OSStatus)statusCode;

@end
