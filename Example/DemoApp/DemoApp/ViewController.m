//
/******************************************************************************
 * Copyright (c) 2022 KineMaster Corp. All rights reserved.
 * https://www.kinemastercorp.com/
 *
 * THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY
 * KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR
 * PURPOSE.
 ******************************************************************************/

#import "ViewController.h"

@import AVKit;
@import AVFoundation;
@import TRTransformer;

#import <OHQBImagePicker/OHQBImagePicker.h>
#import <M13ProgressSuite/M13ProgressViewBar.h>

@interface ViewController()<QBImagePickerControllerDelegate, UIPickerViewDataSource, UIPickerViewDelegate> {
    __weak IBOutlet M13ProgressViewBar *progressBar;
    __weak IBOutlet UILabel *progressLabel;
    
}

@property (weak, nonatomic) IBOutlet UILabel *startTimeLabel;
@property (weak, nonatomic) IBOutlet UILabel *durationLabel;

@property (strong, nonatomic) AVAsset *asset;
@property (nonatomic, strong) ILABReverseVideoExportSession *reverseSession;
@property (nonatomic, strong) ILABTranscodeSession *transcodeSession;

// picker
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UIPickerView *pickerView;

@property (nonatomic) CMTime startTime;
@property (nonatomic) CMTime duration;

@property (nonatomic) BOOL pressStartTimeChange;
@property (nonatomic) NSUInteger pickerComponentHour;
@property (nonatomic) NSUInteger pickerComponentMinute;
@property (nonatomic) NSUInteger pickerComponentSecond;
@property (nonatomic) NSUInteger pickerComponentMilliSecond;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    progressBar.hidden = YES;
    progressBar.showPercentage = NO;
    progressBar.progressBarThickness = 3;
    progressBar.progressBarCornerRadius = 3;
    progressBar.indeterminate = YES;
    
    progressLabel.hidden = YES;
    progressLabel.text = @"";
    
    [self initPickerView];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)pickerVideoTouched:(id)sender {
    QBImagePickerController *picker = [QBImagePickerController new];
    picker.delegate = self;
    picker.mediaType = QBImagePickerMediaTypeVideo;
    [self presentViewController:picker animated:YES completion:nil];
}

- (IBAction)reverseVideoTouched:(id)sender {
    [self reverseAsset:self.asset startTime:self.startTime duration:self.duration];
}

- (IBAction)cancelReverse:(id)sender {
    if (self.reverseSession) {
        [self.reverseSession cancelReverseExport];
    }
    if (self.transcodeSession) {
        [self.transcodeSession cancelTranscode];
    }
}

- (IBAction)transcodeTouched:(id)sender {
    [self transcodeAsset:self.asset startTime:self.startTime duration:self.duration];
}

- (NSString *)timeFormatted:(CMTime)time
{
    NSUInteger seconds = CMTimeGetSeconds(time);
    
    NSUInteger hour = seconds / 3600;
    NSUInteger minute = (seconds / 60) % 60;
    NSUInteger second = seconds % 60;
    NSUInteger millisecond = ((time.value % time.timescale) / 1000) > 1 ? (time.value % time.timescale) / 1000 : time.value % time.timescale;
    
    return [NSString stringWithFormat:@"%02lu:%02lu:%02lu.%03lu", (unsigned long)hour, (unsigned long)minute, (unsigned long)second, (unsigned long)millisecond];
}

- (void)qb_imagePickerController:(QBImagePickerController *)imagePickerController didFinishPickingItems:(NSArray *)items {
    PHVideoRequestOptions *reqOpts=[PHVideoRequestOptions new];
    reqOpts.version=(PHVideoRequestOptionsVersion)PHImageRequestOptionsVersionCurrent;
    reqOpts.deliveryMode=PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    reqOpts.networkAccessAllowed = NO;
    reqOpts.progressHandler = ^(double progress, NSError * _Nullable error, BOOL * _Nonnull stop, NSDictionary * _Nullable info) {
        NSLog(@"Video download progress %f", progress);
    };
    
    __weak typeof(self) weakSelf = self;

    [[PHImageManager defaultManager] requestAVAssetForVideo:[items firstObject]
                                                    options:reqOpts
                                              resultHandler:^(AVAsset * _Nullable asset, AVAudioMix * _Nullable audioMix, NSDictionary * _Nullable info) {
                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                      AVAssetTrack *vTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
                                                      weakSelf.asset = asset;
                                                      weakSelf.startTime = kCMTimeZero;
                                                      weakSelf.duration = vTrack.timeRange.duration;
                                                      [weakSelf.startTimeLabel setText:[self timeFormatted:kCMTimeZero]];
                                                      [weakSelf.durationLabel setText:[self timeFormatted:weakSelf.duration]];
                                                  });
                                              }];

    [self dismissViewControllerAnimated:YES completion:nil];
}

-(void)reverseAsset:(AVAsset *)asset startTime:(CMTime)startTime duration:(CMTime)duration {
    if (asset == nil) {
        [self displayPickerError];
        return;
    }

    [progressBar performAction:M13ProgressViewActionNone animated:NO];
    progressBar.hidden = NO;
    [progressBar setProgress:0. animated:NO];
    
    progressLabel.text = @"";
    progressLabel.hidden = NO;
    
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *outputURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-reversed.mov", [[NSUUID UUID] UUIDString]]];
    NSLog(@"Output URL: %@", outputURL.path);
    
    self.reverseSession = [ILABReverseVideoExportSession exportSessionWithAsset:asset
                                                                     timeRange:CMTimeRangeMake(startTime, duration)
                                                                     outputURL:outputURL];
    self.reverseSession.showDebug = YES;
    __weak typeof(self) weakSelf = self;
    
    [self.reverseSession exportAsynchronously:^(NSString *currentOperation, float progress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        strongSelf->progressLabel.text = currentOperation;
        
        if (progress == INFINITY) {
            strongSelf->progressBar.indeterminate = YES;
        } else {
            strongSelf->progressBar.indeterminate = NO;
            [strongSelf->progressBar setProgress:progress animated:NO];
        }
    } complete:^(BOOL complete, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            strongSelf->progressLabel.text = @"Done.";
            strongSelf->progressBar.indeterminate = NO;
            [strongSelf->progressBar performAction:(complete) ? M13ProgressViewActionSuccess : M13ProgressViewActionFailure animated:YES];
            
            if (complete) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf) {
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        strongSelf->_reverseSession = nil;
                        [strongSelf playVideoAsset:[AVURLAsset assetWithURL:outputURL]];
                    }
                });
            }
        });
    }];
}

-(void)playVideoAsset:(AVAsset *)asset {
    self.asset = nil;

    [self.startTimeLabel setText:[self timeFormatted:kCMTimeZero]];
    [self.durationLabel setText:[self timeFormatted:kCMTimeZero]];

    progressLabel.hidden = YES;
    progressBar.hidden = YES;
    
    AVPlayerViewController *avpc = [[AVPlayerViewController alloc] init];
    avpc.player = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
    [self presentViewController:avpc animated:YES completion:nil];
}

- (void)displayPickerError {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:@"Please picker media" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *action = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:action];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)transcodeAsset:(AVAsset *)asset startTime:(CMTime)startTime duration:(CMTime)duration {
    if (asset == nil) {
        [self displayPickerError];
        return;
    }
    
    [progressBar performAction:M13ProgressViewActionNone animated:NO];
    progressBar.hidden = NO;
    [progressBar setProgress:0. animated:NO];
    
    progressLabel.text = @"";
    progressLabel.hidden = NO;
    
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [cachePath stringByAppendingFormat:@"/%@-transcoded.mov", [[NSUUID UUID] UUIDString]];
    NSURL *outputURL = [NSURL fileURLWithPath:path isDirectory:NO];
    NSLog(@"Output URL: %@", outputURL.path);

    NSLog(@"transcode viewController timeRange: start(%.3f), duration(%.3f)",
          CMTimeGetSeconds(startTime), CMTimeGetSeconds(duration));
    self.transcodeSession = [ILABTranscodeSession transcodeSessionWithAsset:asset
                                                                  timeRange:CMTimeRangeMake(startTime, CMTimeAdd(duration, CMTimeMake(10, 1000)))
                                                                  outputURL:outputURL];
    self.transcodeSession.showDebug = YES;

    __weak typeof(self) weakSelf = self;
    [self.transcodeSession transcodeAsynchronously:^(NSString *currentOperation, float progress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        strongSelf->progressLabel.text = currentOperation;
        
        if (progress == INFINITY) {
            strongSelf->progressBar.indeterminate = YES;
        } else {
            strongSelf->progressBar.indeterminate = NO;
            [strongSelf->progressBar setProgress:progress animated:NO];
        }
    } complete:^(BOOL complete, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            strongSelf->progressLabel.text = @"Done.";
            strongSelf->progressBar.indeterminate = NO;
            [strongSelf->progressBar performAction:(complete) ? M13ProgressViewActionSuccess : M13ProgressViewActionFailure animated:YES];
            
            if (complete) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf) {
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        strongSelf->_transcodeSession = nil;
                        [strongSelf playVideoAsset:[AVURLAsset assetWithURL:outputURL]];
                    }
                });
            }
        });
    }];

}

#pragma mark - picker
- (void)initPickerView {
    self.pickerView = [[UIPickerView alloc] init];
    self.pickerView.dataSource = self;
    self.pickerView.delegate = self;
}

- (void)setPickerComponents:(CMTime)time {
    NSUInteger seconds = CMTimeGetSeconds(time);
    
    self.pickerComponentHour = seconds / 3600;
    self.pickerComponentMinute = (seconds / 60) % 60;
    self.pickerComponentSecond = seconds % 60;
    self.pickerComponentMilliSecond = ((time.value % time.timescale) / 1000) > 1 ? (time.value % time.timescale) / 1000 : time.value % time.timescale;
}

- (void)selectPickerRows {
    [self.pickerView selectRow:self.pickerComponentHour inComponent:0 animated:NO];
    [self.pickerView selectRow:self.pickerComponentMinute inComponent:1 animated:NO];
    [self.pickerView selectRow:self.pickerComponentSecond inComponent:2 animated:NO];
    [self.pickerView selectRow:self.pickerComponentMilliSecond inComponent:3 animated:NO];
}

- (IBAction)startTimeChange:(id)sender {
    self.pressStartTimeChange = YES;
    
    [self setPickerComponents:self.startTime];
    [self selectPickerRows];
    [self showReverseTimeControllPicker:@"Change Reverse Start Time" message:[NSString stringWithFormat:@"asset duration: %@", [self timeFormatted:self.asset.duration]]];
}

- (IBAction)durationChange:(id)sender {
    self.pressStartTimeChange = NO;
    
    [self setPickerComponents:self.duration];
    [self selectPickerRows];
    [self showReverseTimeControllPicker:@"Change Reverse Duration"
                                message:[NSString stringWithFormat:@"asset duration: %@\nstart time: %@",
                                         [self timeFormatted:self.asset.duration], [self timeFormatted:self.startTime]]];
}

- (void)showReverseTimeControllPicker:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *action = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        Float64 seconds = self.pickerComponentHour * 3600 + self.pickerComponentMinute * 60 + self.pickerComponentSecond + self.pickerComponentMilliSecond / 1000.0;
        CMTime time = CMTimeMakeWithSeconds(seconds, 1000);

        BOOL inputTimeError = NO;
        if (self.pressStartTimeChange) {
            if (CMTimeCompare(self.asset.duration, time) < 0) {
                inputTimeError = YES;
            }
        } else {
            if (CMTimeCompare(self.asset.duration, CMTimeAdd(self.startTime, time)) < 0) {
                inputTimeError = YES;
            }
        }
        if (inputTimeError) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:@"Inputed time is wrong" preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *action = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
            [alert addAction:action];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        
        if (self.pressStartTimeChange) {
            self.startTime = time;
            self.startTimeLabel.text = [self timeFormatted:time];
        } else {
            self.duration = time;
            self.durationLabel.text = [self timeFormatted:time];
        }
    }];
    [alert addTextFieldWithConfigurationHandler:nil];
    [alert addAction:action];
    self.textField = alert.textFields.firstObject;
    self.textField.inputView = self.pickerView;
    if (self.pressStartTimeChange) {
        self.textField.text = [self timeFormatted:self.startTime];
    } else {
        self.textField.text = [self timeFormatted:self.duration];
    }
    [self presentViewController:alert animated:TRUE completion:nil];
}

#pragma mark - UIPickerViewDataSource
- (NSInteger)numberOfComponentsInPickerView:(nonnull UIPickerView *)pickerView {
    return 4; // Hour : Minute : Second : MilliSecond
}

- (NSInteger)pickerView:(nonnull UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    if (component == 0) return 24;
    else if (component == 1) return 60;
    else if (component == 2) return 60;
    else return 1000;
}

#pragma mark - UIPickerViewDelegate
- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (component == 0) self.pickerComponentHour = row;
    else if (component == 1) self.pickerComponentMinute = row;
    else if (component == 2) self.pickerComponentSecond = row;
    else self.pickerComponentMilliSecond = row;
    
    [self.textField setText:[NSString stringWithFormat:@"%02lu:%02lu:%02lu.%03lu", (unsigned long)self.pickerComponentHour,
                             (unsigned long)self.pickerComponentMinute,
                             (unsigned long)self.pickerComponentSecond,
                             (unsigned long)self.pickerComponentMilliSecond]];
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return [NSString stringWithFormat:@"%d", (int)row];
}

@end
