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

BOOL isProRes(AVAssetTrack * track);
NSDictionary * makeCompressionProperties(CGSize size, CGFloat estimatedDataRate, CMVideoCodecType sourceCodecType, BOOL availableHDR, BOOL isProRes);
NSDictionary * makeVideoReaderSettings(BOOL availableHDR, BOOL isProRes);
NSDictionary * makeVideoDefaultSettings(CGSize size, NSDictionary * compressionProperties);
NSDictionary * makeVideoOutputSettings(CGSize size, CMVideoCodecType sourceCodecType, BOOL availableHDR, NSDictionary * compressionProperties);
NSDictionary * makeDefaultCompressionProperties(CGSize size, CGFloat estimatedDataRate);
