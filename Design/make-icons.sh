#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/icon.svg"
RENDERER="$SCRIPT_DIR/svg2png"
RENDERER_SOURCE="$SCRIPT_DIR/svg2png.swift"
# Write straight into the one catalog Xcode reads. A second copy under Design/ only drifts.
OUTPUT="$SCRIPT_DIR/../OpenTalkType/Assets.xcassets/AppIcon.appiconset"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opentalktype-icons.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing source SVG: $SOURCE" >&2
  exit 1
fi

if [[ ! -x "$RENDERER" ]]; then
  if [[ ! -f "$RENDERER_SOURCE" ]]; then
    echo "Missing renderer source: $RENDERER_SOURCE" >&2
    exit 1
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required to build svg2png; install Xcode." >&2
    exit 1
  fi
  xcrun swiftc -parse-as-library -O "$RENDERER_SOURCE" -o "$RENDERER"
fi

mkdir -p "$OUTPUT"

for SIZE in 16 32 128 256 512; do
  DEST="$OUTPUT/icon_${SIZE}x${SIZE}.png"
  "$RENDERER" "$SOURCE" "$DEST" "$SIZE"
  if [[ ! -s "$DEST" ]]; then
    echo "Failed to create $DEST" >&2
    exit 1
  fi
done

cp "$OUTPUT/icon_32x32.png" "$OUTPUT/icon_16x16@2x.png"
"$RENDERER" "$SOURCE" "$OUTPUT/icon_32x32@2x.png" 64
cp "$OUTPUT/icon_256x256.png" "$OUTPUT/icon_128x128@2x.png"
cp "$OUTPUT/icon_512x512.png" "$OUTPUT/icon_256x256@2x.png"
# 1024 is only ever the @2x of 512, and an unreferenced file in an .appiconset is a build
# warning, so render it under its catalog name rather than its own.
"$RENDERER" "$SOURCE" "$OUTPUT/icon_512x512@2x.png" 1024

cat > "$OUTPUT/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Created $OUTPUT"
