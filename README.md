# TRTransformer
A set of utility classes for reversing or transcoding AVAsset video and audio partially.

These classes will reverse or transcode video, audio and videos with audio. 

Video reversal is based heavily on Chris Sung's [CSVideoReverse](https://github.com/chrissung/CSVideoReverse) class, This is forked from [Interfacelab/ILABReverseVideoExporter](https://github.com/Interfacelab/ILABReverseVideoExporter)


## Reverse
/// Example
```swift
let url = // Local or Remote Asset URL
let asset = AVAsset(url: url) 
let outputURL = // URL
let session = ILABReverseVideoExportSession(asset: asset, outputURL)

session.exportAsynchronously({ [unowned self] (message: String?, progress: Float) in
    // process reverse

}) { [unowned self] (result: Bool, erro: Error?) in
    // complete reverse

}
```

## Transcode
/// Example
```swift
let url = // Local or Remote Asset URL
let asset = AVAsset(url: url) 
let outputURL = // URL
let session = ILABTranscodeSession(asset: asset, outputURL)

session.transcodeAsynchronously({ [unowned self] (message: String?, progress: Float) in
    // process transcode

}) { [unowned self] (result: Bool, erro: Error?) in
    // complete transcode

}
```
