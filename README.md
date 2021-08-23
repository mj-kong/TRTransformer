# TRTransformer

A description of this package.

support `Reverse` and `Transcode`
output file format
- video: H264
- audio: M4A

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
