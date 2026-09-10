#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP="$DIST_DIR/PDF拼印.app"

mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers \
    "$ROOT_DIR/Sources/Imposition.swift" "$ROOT_DIR/Sources/main.swift" \
    -o "$BUILD_DIR/PDFPrint-$ARCH"
done

xcrun lipo -create \
  "$BUILD_DIR/PDFPrint-arm64" \
  "$BUILD_DIR/PDFPrint-x86_64" \
  -output "$APP/Contents/MacOS/PDFPrint"

cp "$ROOT_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/PDF拼印-macOS.zip"

echo "Built: $APP"

