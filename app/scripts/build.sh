#!/bin/bash
# Build OpenCode Island for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/OpenCodeIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
PLUGIN_DIR="$(dirname "$PROJECT_DIR")/plugin"

echo "=== Building OpenCode Island ==="
echo ""

# Build plugin first
echo "Building plugin..."
cd "$PLUGIN_DIR"
if ! command -v bun &> /dev/null; then
    echo "ERROR: bun is not installed. Install it from https://bun.sh"
    exit 1
fi
bun install
bun run build
echo "Plugin built successfully"
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive
echo "Archiving..."
xcodebuild archive \
    -scheme OpenCodeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    | xcpretty || xcodebuild archive \
    -scheme OpenCodeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic

# Create ExportOptions.plist
# Using 'development' method instead of 'developer-id' (which requires paid Apple Developer account)
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | xcpretty || xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/OpenCode Island.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
