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

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

BOOL orc_isProResType(AVAssetTrack * track);
BOOL orc_isProResCodec(CMVideoCodecType codecType);
BOOL orc_isDolbyVisionType(AVAssetTrack *track);
NSDictionary * orc_makeCompressionProperties(CGSize size, CGFloat estimatedDataRate, CMVideoCodecType sourceCodecType, BOOL isHDRFormat, BOOL isDolbyFormat);
NSDictionary * orc_makeVideoReaderSettings(BOOL containsHDRVideo, BOOL containsAlphaChannel, BOOL orc_isProResType);
NSDictionary * orc_makeVideoDefaultSettings(CGSize size, NSDictionary * compressionProperties);
NSDictionary * orc_makeVideoOutputSettings(CGSize size, CMVideoCodecType sourceCodecType, BOOL containsHDRVideo, BOOL containsAlphaChannel, NSDictionary * compressionProperties);
NSDictionary * orc_makeDefaultCompressionProperties(CGSize size, CGFloat estimatedDataRate);
