#!/usr/bin/env python3
"""Mechanically copy the ObjC Sources/TRTransformer at git tag v1.12.19 -> Sources/TRTransformerOracle,
prefixing every linker/runtime-visible name (and the error-domain string) so both copies can live in one binary.
Usage: python3 Scripts/make_oracle.py .   (regenerates the oracle sources, then self-checks)"""
import os, re, shutil, subprocess, sys, collections

root = sys.argv[1]
TAG = "v1.12.19"   # last ObjC release; Sources/TRTransformer is Swift after it
SRC = "Sources/TRTransformer"
dst = os.path.join(root, "Sources/TRTransformerOracle")

def git(*args):
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True).stdout

try:
    git("rev-parse", "--verify", "--quiet", TAG + "^{commit}")
except subprocess.CalledProcessError:
    sys.exit(f"git tag {TAG} not found; fetch it first (git fetch origin tag {TAG})")
src_files = git("ls-tree", "-r", "--name-only", TAG, "--", SRC).decode().splitlines()
if not src_files:
    sys.exit(f"{TAG} has no files under {SRC}")

LOWER = ["isProResType", "isProResCodec", "isDolbyVisionType", "isHEVCCodec", "isDolbyVisionCodec",
         "makeCompressionProperties", "makeVideoReaderSettings", "makeVideoDefaultSettings",
         "convertToCodecType", "makeVideoOutputSettings", "makeDefaultCompressionProperties",
         "errorWithAudioFileStatusCode",
         "getLayerTagWithChannelPerFrame", "decompressionAudioSettingForPCMType", "compressionAudioSettingForPCMType"]

RULES = [
    (re.compile(r"\bILAB(\w*)"), r"ORCILAB\1"),            # classes, enums, typedefs, category, +ILABSessionError:, statics
    (re.compile(r"\bkILAB(\w*)"), r"kORCILAB\1"),          # error-domain constant AND its string value
    (re.compile(r"\b(" + "|".join(LOWER) + r")\b"), r"orc_\1"),  # C functions in TRTransformAPI + category selectors
    (re.compile(r"\(Settings\)"), r"(ORCSettings)"),       # AVAssetTrack category name
    (re.compile(r"\b(TRTransformAPI|TRTransfomer)\b"), r"ORC\1"),  # header file names (#import lines, comments)
]
INVERSE = [
    (re.compile(r"\bORCILAB"), "ILAB"), (re.compile(r"\bkORCILAB"), "kILAB"),
    (re.compile(r"\borc_"), ""), (re.compile(r"\(ORCSettings\)"), "(Settings)"),
    (re.compile(r"\bORC(TRTransformAPI|TRTransfomer)\b"), r"\1"),
]

def rename_file(name):
    for rx, rep in RULES:
        name = rx.sub(rep, name)
    return name

def apply(rules, text, counts=None):
    for rx, rep in rules:
        if counts is not None:
            for m in rx.finditer(text):
                counts[(m.group(0), rx.sub(rep, m.group(0)))] += 1
        text = rx.sub(rep, text)
    return text

KEEP = {"ORACLE.md"}   # hand-written note, not generated
if os.path.exists(dst):
    for name in os.listdir(dst):
        if name in KEEP: continue
        path = os.path.join(dst, name)
        shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
counts = collections.Counter()
pairs = []
for path in sorted(src_files):
    rel = os.path.relpath(path, SRC)
    d = os.path.join(dst, os.path.dirname(rel), rename_file(os.path.basename(rel)))
    os.makedirs(os.path.dirname(d), exist_ok=True)
    orig = git("show", f"{TAG}:{path}")
    text = orig.decode("utf-8")
    assert not re.search(r"\bORC|\borc_", text), f"{rel} already contains the prefix; inverse check would be unsound"
    open(d, "wb").write(apply(RULES, text, counts).encode("utf-8"))
    pairs.append((orig, d))

# Self-check: undoing the prefixes must give the original bytes back, for every file.
for orig, d in pairs:
    if apply(INVERSE, open(d, "rb").read().decode("utf-8")).encode("utf-8") != orig:
        sys.exit(f"INVERSE MISMATCH: {d}")
print(f"inverse check: {len(pairs)} files byte-identical to the original after stripping the prefixes")
for (a, b), n in sorted(counts.items()):
    print(f"  {a:55s} -> {b}  x{n}")
