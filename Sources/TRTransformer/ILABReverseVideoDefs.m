//
//  ILABReverseVideoDefs.m
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ILABReverseVideoDefs.h"
#import <AVFoundation/AVFoundation.h>

NSString * const kILABReverseVideoExportSessionErrorDomain = @"kILABReverseVideoExportSessionErrorDomain";

@implementation NSError(ILABReverseVideoExportSession)

+(NSError *)ILABSessionError:(ILABSessionError)errorStatus {
    switch(errorStatus) {
        case ILABSessionErrorMissingOutputURL:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Missing Output URL."}];
        case ILABSessionErrorAVAssetReaderStartReading:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"AVAssetReader startReading Error."}];
        case ILABSessionErrorVideoNoSamples:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"No samples in source video."}];
        case ILABSessionErrorAVAssetWriterStartWriting:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"AVAssetWriter startWriting Error."}];
        case ILABSessionErrorVideoUnableToWirteFrame:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Appending pixel buffer Error"}];
        case ILABSessionErrorUserCancel:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"User cancel."}];
        case ILABSessionErrorAVAssetReaderReading:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannot open, this media may be damaged."}];

        case ILABSessionErrorAudioInvalidTrackIndex:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"The specified track index is invalid."}];
        case ILABSessionErrorAudioCannotAddInput:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannot add input for audio export."}];
        case ILABSessionErrorAudioCanAddOutput:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannout add output for audio export."}];
        case ILABSessionErrorNoCompleteAudioExport:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Export is already in progress."}];
    }
}

+(NSError *)errorWithAudioFileStatusCode:(OSStatus)statusCode {
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
