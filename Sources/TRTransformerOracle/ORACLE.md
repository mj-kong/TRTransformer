# TRTransformerOracle

Test-only copy of the ObjC TRTransformer v1.12.19 sources, kept as the reference ("oracle") for the
differential tests in `Tests/TRTransformerTests/Differential/`. Not a product; only the test target links it.

Generated — do not edit by hand. Frozen at git tag `v1.12.19` (the last ObjC release). Regenerate with
`python3 Scripts/make_oracle.py .`: it reads the ObjC sources from that tag (`git fetch origin tag v1.12.19` if
missing), not from the current Swift `Sources/TRTransformer`, and proves that stripping the prefixes gives back
the tag's bytes for every file, i.e. only names changed.

Renames (oracle side only; needed because both copies are linked into one test binary):

- `ILAB*` → `ORCILAB*`: classes `ILABTranscodeSession`, `ILABReverseVideoExportSession`, `ILABAudioTrackExporter`;
  enum `ILABSessionError` and all its cases; typedefs `ILABCompleteBlock`, `ILABProgressBlock`, `ILABGenerateAssetBlock`;
  constant `ILABAudioTrackIndexAll`; static `ILABTrackAtIndex`; `ILABReverseVideoExporterVersionNumber/String` (declared only);
  NSError category `(ILABReverseVideoExportSession)` and its method `+ILABSessionError:`.
- `kILAB*` → `kORCILAB*`: `kILABReverseVideoExportSessionErrorDomain`, **including its string value**
  (oracle errors use domain `kORCILABReverseVideoExportSessionErrorDomain`).
- `orc_` prefix on C functions (TRTransformAPI): `isProResType`, `isProResCodec`, `isDolbyVisionType`, `isHEVCCodec`,
  `isDolbyVisionCodec`, `makeCompressionProperties`, `makeVideoReaderSettings`, `makeVideoDefaultSettings`,
  `convertToCodecType`, `makeVideoOutputSettings`, `makeDefaultCompressionProperties`.
- `orc_` prefix on category methods of shared Apple classes: `+[NSError errorWithAudioFileStatusCode:]`,
  `-[AVAssetTrack getLayerTagWithChannelPerFrame:]`, `-decompressionAudioSettingForPCMType`, `-compressionAudioSettingForPCMType`;
  category `AVAssetTrack (Settings)` → `(ORCSettings)`.
- Side effect of the token-based rename (harmless, kept for a purely mechanical diff): the private session properties
  `isProResType` / `isDolbyVisionType` (same spelling as the C functions) became `orc_isProResType` / `orc_isDolbyVisionType`,
  and so did the `isProResType` parameter of `makeVideoReaderSettings`.
- Files: `ILAB*.{h,m}` → `ORCILAB*`, `TRTransformAPI.{h,m}` → `ORCTRTransformAPI`, `TRTransfomer.h` → `ORCTRTransfomer.h`
  (and the matching `#import` lines).
