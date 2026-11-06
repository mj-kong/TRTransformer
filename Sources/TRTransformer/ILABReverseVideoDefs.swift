//
//  ILABReverseVideoDefs.swift
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

import AudioToolbox
import AVFoundation
import Foundation

public let kILABReverseVideoExportSessionErrorDomain: String = "kILABReverseVideoExportSessionErrorDomain"

/** audioTrackIndex value that mixes every audio track into one (the pre-1.12.19 Transcode behaviour). */
public let ILABAudioTrackIndexAll: Int = -1

/// Same shape as the ObjC `typedef enum : NSInteger { ... } ILABSessionError` imported into Swift
/// (a RawRepresentable struct plus one global per case), so `ILABSessionErrorUserCancel.rawValue` keeps compiling.
public struct ILABSessionError: Hashable, Equatable, RawRepresentable {
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public init(rawValue: Int) { self.rawValue = rawValue }
    public var rawValue: Int
}

public var ILABSessionErrorMissingOutputURL: ILABSessionError { ILABSessionError(-101) }
public var ILABSessionErrorAVAssetReaderStartReading: ILABSessionError { ILABSessionError(-102) }
public var ILABSessionErrorVideoNoSamples: ILABSessionError { ILABSessionError(-103) }
public var ILABSessionErrorAVAssetWriterStartWriting: ILABSessionError { ILABSessionError(-104) }
public var ILABSessionErrorVideoUnableToWirteFrame: ILABSessionError { ILABSessionError(-105) }
public var ILABSessionErrorUserCancel: ILABSessionError { ILABSessionError(-106) }
public var ILABSessionErrorAVAssetReaderReading: ILABSessionError { ILABSessionError(-107) }
public var ILABSessionErrorAVAssetExportSessionCompatibility: ILABSessionError { ILABSessionError(-108) }
public var ILABSessionErrorInsertTrack: ILABSessionError { ILABSessionError(-109) }
public var ILABSessionErrorAVAssetExportSessionCreate: ILABSessionError { ILABSessionError(-110) }

public var ILABSessionErrorAudioInvalidTrackIndex: ILABSessionError { ILABSessionError(-201) }
public var ILABSessionErrorAudioCannotAddInput: ILABSessionError { ILABSessionError(-202) }
public var ILABSessionErrorAudioCanAddOutput: ILABSessionError { ILABSessionError(-203) }
public var ILABSessionErrorNoCompleteAudioExport: ILABSessionError { ILABSessionError(-204) }

/**< Requested video/audio track index is out of range for the source */
public var ILABSessionErrorInvalidTrackIndex: ILABSessionError { ILABSessionError(-301) }

/**
 Block called when a reversal has completed.

 @param complete YES if successful, NO if not
 @param error If not successful, the NSError describing the problem
 */
public typealias ILABCompleteBlock = (Bool, Error?) -> Void

/**
 Progress block called during reversal process

 @param currentOperation The current operation name/title
 @param progress The current progress normalized 0 .. 1, INFINITY for an operation that is indeterminate
 */
public typealias ILABProgressBlock = (String?, Float) -> Void

typealias ILABGenerateAssetBlock = (Bool, AVAsset?, Error?) -> Void

/**
 Category for easily generation NSError instances in the kILABReverseVideoExportSessionErrorDomain domain.
 */
extension NSError {

    /**
     Return an NSError with the kILABReverseVideoExportSessionDomain, error code and localized description set

     @param errorStatus The error status to return
     @return The NSError instance
     */
    public class func ilabSessionError(_ errorStatus: ILABSessionError) -> Error! {
        return _ilabSessionError(errorStatus.rawValue)
    }

    // Keeps the ObjC selector `+ILABSessionError:` (NSInteger argument, same ABI as the old enum).
    @objc(ILABSessionError:)
    class func _ilabSessionError(_ errorStatus: Int) -> NSError? {
        switch errorStatus {
        case ILABSessionErrorMissingOutputURL.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Missing Output URL."])
        case ILABSessionErrorAVAssetReaderStartReading.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "AVAssetReader startReading Error."])
        case ILABSessionErrorVideoNoSamples.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "No samples in source video."])
        case ILABSessionErrorAVAssetWriterStartWriting.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter startWriting Error."])
        case ILABSessionErrorVideoUnableToWirteFrame.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Appending pixel buffer Error"])
        case ILABSessionErrorUserCancel.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "User cancel."])
        case ILABSessionErrorAVAssetReaderReading.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Cannot decode."])
        case ILABSessionErrorAVAssetExportSessionCompatibility.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Check error to ensure compatibility"])
        case ILABSessionErrorInsertTrack.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Insert AVTrack error."])
        case ILABSessionErrorAVAssetExportSessionCreate.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "AVAssetExporter create error."])

        case ILABSessionErrorAudioInvalidTrackIndex.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "The specified track index is invalid."])
        case ILABSessionErrorAudioCannotAddInput.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Cannot add input for audio export."])
        case ILABSessionErrorAudioCanAddOutput.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Cannout add output for audio export."])
        case ILABSessionErrorNoCompleteAudioExport.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "Export is already in progress."])

        case ILABSessionErrorInvalidTrackIndex.rawValue:
            return NSError(domain: kILABReverseVideoExportSessionErrorDomain, code: errorStatus, userInfo: [NSLocalizedDescriptionKey: "The requested video or audio track index is out of range."])
        default:
            // The ObjC switch had no default (undefined result for an unknown code); nil is the closest defined value.
            return nil
        }
    }

    /**
     Returns an NSError with a helpful localized description for common audio errors

     @param statusCode The status code
     @return The NSError instance
     */
    public convenience init!(audioFileStatusCode statusCode: OSStatus) {
        let e = NSError.errorWithAudioFileStatusCode(statusCode)
        self.init(domain: e.domain, code: e.code, userInfo: e.userInfo)
    }

    @objc(errorWithAudioFileStatusCode:)
    class func errorWithAudioFileStatusCode(_ statusCode: OSStatus) -> NSError {
        var errorDescription: String? = nil
        // Every case falls through (the ObjC switch had no `break`), so the description always ends up "Unknown Error".
        switch statusCode {
        case kAudioFileUnspecifiedError:
            errorDescription = "kAudioFileUnspecifiedError"
            fallthrough
        case kAudioFileUnsupportedFileTypeError:
            errorDescription = "kAudioFileUnsupportedFileTypeError"
            fallthrough
        case kAudioFileUnsupportedDataFormatError:
            errorDescription = "kAudioFileUnsupportedDataFormatError"
            fallthrough
        case kAudioFileUnsupportedPropertyError:
            errorDescription = "kAudioFileUnsupportedPropertyError"
            fallthrough
        case kAudioFileBadPropertySizeError:
            errorDescription = "kAudioFileBadPropertySizeError"
            fallthrough
        case kAudioFilePermissionsError:
            errorDescription = "kAudioFilePermissionsError"
            fallthrough
        case kAudioFileNotOptimizedError:
            errorDescription = "kAudioFileNotOptimizedError"
            fallthrough
        case kAudioFileInvalidChunkError:
            errorDescription = "kAudioFileInvalidChunkError"
            fallthrough
        case kAudioFileDoesNotAllow64BitDataSizeError:
            errorDescription = "kAudioFileDoesNotAllow64BitDataSizeError"
            fallthrough
        case kAudioFileInvalidPacketOffsetError:
            errorDescription = "kAudioFileInvalidPacketOffsetError"
            fallthrough
        case kAudioFileInvalidFileError:
            errorDescription = "kAudioFileInvalidFileError"
            fallthrough
        case kAudioFileOperationNotSupportedError:
            errorDescription = "kAudioFileOperationNotSupportedError"
            fallthrough
        case kAudioFileNotOpenError:
            errorDescription = "kAudioFileNotOpenError"
            fallthrough
        case kAudioFileEndOfFileError:
            errorDescription = "kAudioFileEndOfFileError"
            fallthrough
        case kAudioFilePositionError:
            errorDescription = "kAudioFilePositionError"
            fallthrough
        case kAudioFileFileNotFoundError:
            errorDescription = "kAudioFileFileNotFoundError"
            fallthrough
        default:
            errorDescription = "Unknown Error"
        }

        return NSError(domain: NSOSStatusErrorDomain, code: Int(statusCode), userInfo: [NSLocalizedDescriptionKey: errorDescription!])
    }
}

// MARK: - C conversion semantics (arm64), used where the ObjC relied on C casts / integer division

/// C `(int)x` on arm64 (`fcvtzs w`): NaN → 0, out-of-range saturates (Swift's `Int32(x)` would trap instead).
@inline(__always) func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return .max }
    if x <= -2147483648.0 { return .min }
    return Int32(x)
}

/// C `(int64_t)x` / `(NSInteger)x` on arm64 (`fcvtzs x`): NaN → 0, out-of-range saturates.
@inline(__always) func cInt64(_ x: Double) -> Int64 {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return .max }
    if x <= -9223372036854775808.0 { return .min }
    return Int64(x)
}

/// C signed `a % b` on arm64 (`sdiv` + `msub`): `b == 0` yields `a`, `b == -1` yields 0 (Swift's `%` would trap).
@inline(__always) func cSRem(_ a: Int, _ b: Int) -> Int {
    if b == 0 { return a }
    if b == -1 { return 0 }
    return a % b
}

/// C unsigned `a % b` on arm64 (`udiv` + `msub`): `b == 0` yields `a`.
@inline(__always) func cURem(_ a: UInt, _ b: UInt) -> UInt {
    if b == 0 { return a }
    return a % b
}

/// What an ObjC message to nil returns for a struct (clang zero-fills it): all fields 0, NOT the identity.
let zeroAffineTransform = CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
