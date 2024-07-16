//
/******************************************************************************
 * Copyright (c) 2024 KineMaster Corp. All rights reserved.
 * https://www.kinemastercorp.com/
 *
 * THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY
 * KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
 * PURPOSE.
 ******************************************************************************/

#import "TRTransformAPI.h"

BOOL isProResType(AVAssetTrack * track) {
    for (id formatDescription in track.formatDescriptions) {
        CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)formatDescription;
        FourCharCode codecType = CMFormatDescriptionGetMediaSubType(desc);
        
        switch (codecType) {
            case kCMVideoCodecType_AppleProRes4444XQ:
            case kCMVideoCodecType_AppleProRes4444:
            case kCMVideoCodecType_AppleProRes422HQ:
            case kCMVideoCodecType_AppleProRes422:
            case kCMVideoCodecType_AppleProRes422LT:
            case kCMVideoCodecType_AppleProRes422Proxy:
            case kCMVideoCodecType_AppleProResRAW:
            case kCMVideoCodecType_AppleProResRAWHQ:
                return YES;
            default:
                break;
        }
    }
    return NO;
}

NSDictionary * makeCompressionProperties(CGSize size, CGFloat estimatedDataRate, CMVideoCodecType sourceCodecType, BOOL containsHDRVideo) {
    static const NSInteger fullHDProportion = 1920 * 1080;
    
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    if (containsHDRVideo) {
        [settings setObject:@(estimatedDataRate)
                     forKey:AVVideoAverageBitRateKey];
        [settings setObject:size.width * size.height > fullHDProportion ? @(YES) : @(NO)
                     forKey:AVVideoAllowFrameReorderingKey];
        [settings setObject:(__bridge NSString*)kVTHDRMetadataInsertionMode_Auto
                     forKey:(__bridge NSString*)kVTCompressionPropertyKey_HDRMetadataInsertionMode];
        [settings setObject:(__bridge NSString*)kVTProfileLevel_HEVC_Main10_AutoLevel
                     forKey:AVVideoProfileLevelKey];
    } else {
        [settings setObject:@(estimatedDataRate)
                     forKey:AVVideoAverageBitRateKey];
        [settings setObject:size.width * size.height > fullHDProportion ? @(YES) : @(NO)
                     forKey:AVVideoAllowFrameReorderingKey];
        switch (sourceCodecType) {
            case kCMVideoCodecType_HEVC:
            case kCMVideoCodecType_HEVCWithAlpha:
            case kCMVideoCodecType_AppleProRes4444XQ:
                [settings setObject:(__bridge NSString*)kVTProfileLevel_HEVC_Main_AutoLevel
                             forKey:AVVideoProfileLevelKey];
                break;
            default:
                if (size.width * size.height > fullHDProportion) {
                    [settings setObject:AVVideoProfileLevelH264HighAutoLevel
                                 forKey:AVVideoProfileLevelKey];
                    [settings setObject:AVVideoH264EntropyModeCABAC
                                 forKey:AVVideoH264EntropyModeKey];
                } else {
                    [settings setObject:AVVideoProfileLevelH264MainAutoLevel
                                 forKey:AVVideoProfileLevelKey];
                }
                break;
        }
    }
    return settings;
}

NSDictionary * makeVideoReaderSettings(BOOL containsHDRVideo, BOOL containsAlphaChannel, BOOL isProResType) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    if (containsHDRVideo) {
        [settings setObject:@(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                     forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    } else if (containsAlphaChannel) {
        [settings setObject:@(kCVPixelFormatType_32ARGB)
                     forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    } else if (isProResType) {
        [settings setObject:@(kCVPixelFormatType_4444AYpCbCr16)
                     forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    } else {
        [settings setObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                     forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    }
    return settings;
}

NSDictionary * makeVideoDefaultSettings(CGSize size, NSDictionary * compressionProperties) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];

    [settings setObject:@(size.width)
                 forKey:AVVideoWidthKey];
    [settings setObject:@(size.height)
                 forKey:AVVideoHeightKey];
    [settings setObject:AVVideoCodecTypeH264
                 forKey:AVVideoCodecKey];
    [settings setObject:compressionProperties
                 forKey:AVVideoCompressionPropertiesKey];

    return settings;
}

AVVideoCodecType convertToCodecType(CMVideoCodecType codecType, BOOL containsAlphaChannel) {
    switch (codecType) {
        case kCMVideoCodecType_AppleProRes4444XQ:
        case kCMVideoCodecType_HEVCWithAlpha:
            return AVVideoCodecTypeHEVCWithAlpha;
            
        case kCMVideoCodecType_AppleProRes4444:
        case kCMVideoCodecType_AppleProRes422HQ:
        case kCMVideoCodecType_AppleProRes422:
        case kCMVideoCodecType_AppleProRes422LT:
        case kCMVideoCodecType_AppleProRes422Proxy:
        case kCMVideoCodecType_HEVC: 
            return containsAlphaChannel ? AVVideoCodecTypeHEVCWithAlpha : AVVideoCodecTypeHEVC;
            
        default:
            return AVVideoCodecTypeH264;
    }
}

NSDictionary * makeVideoOutputSettings(CGSize size, CMVideoCodecType sourceCodecType, BOOL containsHDRVideo, BOOL containsAlphaChannel, NSDictionary * compressionProperties) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    [settings setObject:@(size.width)
                 forKey:AVVideoWidthKey];
    [settings setObject:@(size.height)
                 forKey:AVVideoHeightKey];
    [settings setObject: convertToCodecType(sourceCodecType, containsAlphaChannel)
                 forKey:AVVideoCodecKey];
    [settings setObject:compressionProperties
                 forKey:AVVideoCompressionPropertiesKey];
    if (containsHDRVideo) {
        NSDictionary *colorProperties = @{
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        };
        [settings setObject:colorProperties
                     forKey:AVVideoColorPropertiesKey];
    }
    return settings;
}

NSDictionary * makeDefaultCompressionProperties(CGSize size, CGFloat estimatedDataRate) {
    static const NSInteger fullHDProportion = 1920 * 1080;
    
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    [settings setObject:@(estimatedDataRate)
                 forKey:AVVideoAverageBitRateKey];
    [settings setObject:size.width * size.height > fullHDProportion ? @(YES) : @(NO)
                 forKey:AVVideoAllowFrameReorderingKey];
    if (size.width * size.height > fullHDProportion) {
        [settings setObject:AVVideoProfileLevelH264HighAutoLevel
                     forKey:AVVideoProfileLevelKey];
        [settings setObject:AVVideoH264EntropyModeCABAC
                     forKey:AVVideoH264EntropyModeKey];
    } else {
        [settings setObject:AVVideoProfileLevelH264MainAutoLevel
                     forKey:AVVideoProfileLevelKey];
    }
    return settings;
}
