/******************************************************************************
 * Copyright (c) 2024 KineMaster Corp. All rights reserved.
 * https://www.kinemastercorp.com/
 *
 * THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY
 * KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
 * PURPOSE.
 ******************************************************************************/

import AVFoundation
import VideoToolbox

public func isProResType(_ track: AVAssetTrack!) -> Bool {
    for formatDescription in track?.formatDescriptions ?? [] {
        let desc = formatDescription as! CMFormatDescription
        let codecType: FourCharCode = CMFormatDescriptionGetMediaSubType(desc)

        switch codecType {
        case kCMVideoCodecType_AppleProRes4444XQ,
             kCMVideoCodecType_AppleProRes4444,
             kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProResRAW,
             kCMVideoCodecType_AppleProResRAWHQ:
            return true
        default:
            break
        }
    }
    return false
}

public func isProResCodec(_ codecType: CMVideoCodecType) -> Bool {
    switch codecType {
    case kCMVideoCodecType_AppleProRes4444XQ,
         kCMVideoCodecType_AppleProRes4444,
         kCMVideoCodecType_AppleProRes422HQ,
         kCMVideoCodecType_AppleProRes422,
         kCMVideoCodecType_AppleProRes422LT,
         kCMVideoCodecType_AppleProRes422Proxy,
         kCMVideoCodecType_AppleProResRAW,
         kCMVideoCodecType_AppleProResRAWHQ:
        return true
    default:
        return false
    }
}

public func isDolbyVisionType(_ track: AVAssetTrack!) -> Bool {
    for formatDescription in track?.formatDescriptions ?? [] {
        let desc = formatDescription as! CMFormatDescription
        let extensions: CFDictionary? = CMFormatDescriptionGetExtensions(desc)
        let codecType: FourCharCode = CMFormatDescriptionGetMediaSubType(desc)

        switch codecType {
        case kCMVideoCodecType_DolbyVisionHEVC:
            return true
        case kCMVideoCodecType_HEVC,
             kCMVideoCodecType_HEVCWithAlpha:
            if let extensions = extensions {
                let extDict = extensions as NSDictionary
                // ObjC: extDict[@"SampleDescriptionExtensionAtoms"][@"dvvC"] — nil when the atoms entry is missing,
                // and a real `objectForKeyedSubscript:` send (same failure mode) when it is present.
                var dvvC: AnyObject? = nil
                if let atoms = extDict["SampleDescriptionExtensionAtoms"] {
                    dvvC = (atoms as! NSObject).perform(NSSelectorFromString("objectForKeyedSubscript:"), with: "dvvC" as NSString)?.takeUnretainedValue()
                }
                if dvvC != nil { return true }
                else { return false }
            }
            return true
        default:
            break
        }
    }
    return false
}

func isHEVCCodec(_ codecType: CMVideoCodecType) -> Bool {
    switch codecType {
    case kCMVideoCodecType_HEVC,
         kCMVideoCodecType_HEVCWithAlpha:
        return true
    default:
        return false
    }
}

func isDolbyVisionCodec(_ codecType: CMVideoCodecType) -> Bool {
    switch codecType {
    case kCMVideoCodecType_DolbyVisionHEVC:
        return true
    default:
        return false
    }
}

public func makeCompressionProperties(_ size: CGSize, _ estimatedDataRate: CGFloat, _ sourceCodecType: CMVideoCodecType, _ isHDRFormat: Bool, _ isDolbyFormat: Bool) -> [AnyHashable: Any]! {
    let fullHDProportion: Int = 1920 * 1080

    let settings = NSMutableDictionary()

    settings.setObject(NSNumber(value: Double(estimatedDataRate)),
                       forKey: AVVideoAverageBitRateKey as NSString)
    settings.setObject(size.width * size.height > CGFloat(fullHDProportion) ? NSNumber(value: true) : NSNumber(value: false),
                       forKey: AVVideoAllowFrameReorderingKey as NSString)

    if isHDRFormat {
        settings.setObject(kVTHDRMetadataInsertionMode_Auto as NSString,
                           forKey: kVTCompressionPropertyKey_HDRMetadataInsertionMode as NSString)
    }

    if isDolbyFormat {
        settings.setObject(kVTProfileLevel_HEVC_Main10_AutoLevel as NSString,
                           forKey: AVVideoProfileLevelKey as NSString)
    } else if isProResCodec(sourceCodecType) || isHEVCCodec(sourceCodecType) {
        settings.setObject(kVTProfileLevel_HEVC_Main_AutoLevel as NSString,
                           forKey: AVVideoProfileLevelKey as NSString)
    } else {
        if size.width * size.height > CGFloat(fullHDProportion) {
            settings.setObject(AVVideoProfileLevelH264HighAutoLevel as NSString,
                               forKey: AVVideoProfileLevelKey as NSString)
            settings.setObject(AVVideoH264EntropyModeCABAC as NSString,
                               forKey: AVVideoH264EntropyModeKey as NSString)
        } else {
            settings.setObject(AVVideoProfileLevelH264MainAutoLevel as NSString,
                               forKey: AVVideoProfileLevelKey as NSString)
        }
    }
    return settings as? [AnyHashable: Any]
}

public func makeVideoReaderSettings(_ containsHDRVideo: Bool, _ containsAlphaChannel: Bool, _ isProResType: Bool) -> [AnyHashable: Any]! {
    let settings = NSMutableDictionary()
    if containsHDRVideo {
        settings.setObject(NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                           forKey: kCVPixelBufferPixelFormatTypeKey as NSString)
    } else if containsAlphaChannel {
        settings.setObject(NSNumber(value: kCVPixelFormatType_32ARGB),
                           forKey: kCVPixelBufferPixelFormatTypeKey as NSString)
    } else if isProResType {
        settings.setObject(NSNumber(value: kCVPixelFormatType_4444AYpCbCr16),
                           forKey: kCVPixelBufferPixelFormatTypeKey as NSString)
    } else {
        settings.setObject(NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                           forKey: kCVPixelBufferPixelFormatTypeKey as NSString)
    }
    return settings as? [AnyHashable: Any]
}

public func makeVideoDefaultSettings(_ size: CGSize, _ compressionProperties: [AnyHashable: Any]!) -> [AnyHashable: Any]! {
    let settings = NSMutableDictionary()

    settings.setObject(NSNumber(value: Double(size.width)),
                       forKey: AVVideoWidthKey as NSString)
    settings.setObject(NSNumber(value: Double(size.height)),
                       forKey: AVVideoHeightKey as NSString)
    settings.setObject(AVVideoCodecType.h264.rawValue as NSString,
                       forKey: AVVideoCodecKey as NSString)
    // ObjC `setObject:nil` raised; force-unwrapping a nil argument traps the same way.
    settings.setObject(compressionProperties! as NSDictionary,
                       forKey: AVVideoCompressionPropertiesKey as NSString)

    return settings as? [AnyHashable: Any]
}

func convertToCodecType(_ codecType: CMVideoCodecType, _ containsAlphaChannel: Bool) -> AVVideoCodecType {
    switch codecType {
    case kCMVideoCodecType_AppleProRes4444XQ,
         kCMVideoCodecType_HEVCWithAlpha:
        return AVVideoCodecType.hevcWithAlpha

    case kCMVideoCodecType_AppleProRes4444,
         kCMVideoCodecType_AppleProRes422HQ,
         kCMVideoCodecType_AppleProRes422,
         kCMVideoCodecType_AppleProRes422LT,
         kCMVideoCodecType_AppleProRes422Proxy,
         kCMVideoCodecType_HEVC,
         kCMVideoCodecType_DolbyVisionHEVC:
        return containsAlphaChannel ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc

    default:
        return AVVideoCodecType.h264
    }
}

public func makeVideoOutputSettings(_ size: CGSize, _ sourceCodecType: CMVideoCodecType, _ containsHDRVideo: Bool, _ containsAlphaChannel: Bool, _ compressionProperties: [AnyHashable: Any]!) -> [AnyHashable: Any]! {
    let settings = NSMutableDictionary()

    settings.setObject(NSNumber(value: Double(size.width)),
                       forKey: AVVideoWidthKey as NSString)
    settings.setObject(NSNumber(value: Double(size.height)),
                       forKey: AVVideoHeightKey as NSString)
    settings.setObject(convertToCodecType(sourceCodecType, containsAlphaChannel).rawValue as NSString,
                       forKey: AVVideoCodecKey as NSString)
    // ObjC `setObject:nil` raised; force-unwrapping a nil argument traps the same way.
    settings.setObject(compressionProperties! as NSDictionary,
                       forKey: AVVideoCompressionPropertiesKey as NSString)
    if containsHDRVideo {
        let colorProperties: NSDictionary = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        settings.setObject(colorProperties,
                           forKey: AVVideoColorPropertiesKey as NSString)
    }
    return settings as? [AnyHashable: Any]
}

public func makeDefaultCompressionProperties(_ size: CGSize, _ estimatedDataRate: CGFloat) -> [AnyHashable: Any]! {
    let fullHDProportion: Int = 1920 * 1080

    let settings = NSMutableDictionary()

    settings.setObject(NSNumber(value: Double(estimatedDataRate)),
                       forKey: AVVideoAverageBitRateKey as NSString)
    settings.setObject(size.width * size.height > CGFloat(fullHDProportion) ? NSNumber(value: true) : NSNumber(value: false),
                       forKey: AVVideoAllowFrameReorderingKey as NSString)
    if size.width * size.height > CGFloat(fullHDProportion) {
        settings.setObject(AVVideoProfileLevelH264HighAutoLevel as NSString,
                           forKey: AVVideoProfileLevelKey as NSString)
        settings.setObject(AVVideoH264EntropyModeCABAC as NSString,
                           forKey: AVVideoH264EntropyModeKey as NSString)
    } else {
        settings.setObject(AVVideoProfileLevelH264MainAutoLevel as NSString,
                           forKey: AVVideoProfileLevelKey as NSString)
    }
    return settings as? [AnyHashable: Any]
}
