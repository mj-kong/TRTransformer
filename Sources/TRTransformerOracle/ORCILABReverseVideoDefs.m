//
//  ORCILABReverseVideoDefs.m
//  ORCILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ORCILABReverseVideoDefs.h"
#import <AVFoundation/AVFoundation.h>

NSString * const kORCILABReverseVideoExportSessionErrorDomain = @"kORCILABReverseVideoExportSessionErrorDomain";
NSInteger const ORCILABAudioTrackIndexAll = -1;

@implementation NSError(ORCILABReverseVideoExportSession)

+(NSError *)ORCILABSessionError:(ORCILABSessionError)errorStatus {
    switch(errorStatus) {
        case ORCILABSessionErrorMissingOutputURL:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Missing Output URL."}];
        case ORCILABSessionErrorAVAssetReaderStartReading:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"AVAssetReader startReading Error."}];
        case ORCILABSessionErrorVideoNoSamples:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"No samples in source video."}];
        case ORCILABSessionErrorAVAssetWriterStartWriting:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"AVAssetWriter startWriting Error."}];
        case ORCILABSessionErrorVideoUnableToWirteFrame:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Appending pixel buffer Error"}];
        case ORCILABSessionErrorUserCancel:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"User cancel."}];
        case ORCILABSessionErrorAVAssetReaderReading:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannot decode."}];
        case ORCILABSessionErrorAVAssetExportSessionCompatibility:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Check error to ensure compatibility"}];
        case ORCILABSessionErrorInsertTrack:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Insert AVTrack error."}];
        case ORCILABSessionErrorAVAssetExportSessionCreate:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"AVAssetExporter create error."}];

        case ORCILABSessionErrorAudioInvalidTrackIndex:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"The specified track index is invalid."}];
        case ORCILABSessionErrorAudioCannotAddInput:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannot add input for audio export."}];
        case ORCILABSessionErrorAudioCanAddOutput:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannout add output for audio export."}];
        case ORCILABSessionErrorNoCompleteAudioExport:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Export is already in progress."}];

        case ORCILABSessionErrorInvalidTrackIndex:
            return [NSError errorWithDomain:kORCILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"The requested video or audio track index is out of range."}];
    }
}

+(NSError *)orc_errorWithAudioFileStatusCode:(OSStatus)statusCode {
    NSString *errorDescription=nil;
    switch (statusCode) {
        case kAudioFileUnspecifiedError:
            errorDescription = @"kAudioFileUnspecifiedError";
            
        case kAudioFileUnsupportedFileTypeError:
            errorDescription = @"kAudioFileUnsupportedFileTypeError";
            
        case kAudioFileUnsupportedDataFormatError:
            errorDescription = @"kAudioFileUnsupportedDataFormatError";
            
        case kAudioFileUnsupportedPropertyError:
            errorDescription = @"kAudioFileUnsupportedPropertyError";
            
        case kAudioFileBadPropertySizeError:
            errorDescription = @"kAudioFileBadPropertySizeError";
            
        case kAudioFilePermissionsError:
            errorDescription = @"kAudioFilePermissionsError";
            
        case kAudioFileNotOptimizedError:
            errorDescription = @"kAudioFileNotOptimizedError";
            
        case kAudioFileInvalidChunkError:
            errorDescription = @"kAudioFileInvalidChunkError";
            
        case kAudioFileDoesNotAllow64BitDataSizeError:
            errorDescription = @"kAudioFileDoesNotAllow64BitDataSizeError";
            
        case kAudioFileInvalidPacketOffsetError:
            errorDescription = @"kAudioFileInvalidPacketOffsetError";
            
        case kAudioFileInvalidFileError:
            errorDescription = @"kAudioFileInvalidFileError";
            
        case kAudioFileOperationNotSupportedError:
            errorDescription = @"kAudioFileOperationNotSupportedError";
            
        case kAudioFileNotOpenError:
            errorDescription = @"kAudioFileNotOpenError";
            
        case kAudioFileEndOfFileError:
            errorDescription = @"kAudioFileEndOfFileError";
            
        case kAudioFilePositionError:
            errorDescription = @"kAudioFilePositionError";
            
        case kAudioFileFileNotFoundError:
            errorDescription = @"kAudioFileFileNotFoundError";
            
        default:
            errorDescription = @"Unknown Error";
    }
    
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:statusCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
}


@end
