#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration ---
PROJECT_NAME="glosos-macOS"
SCHEME_NAME="glosos-macOS"
CONFIGURATION="Release"
BUILD_DIR="./build"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/ExportedApp"
APP_NAME="glosos-macOS.app"
DMG_NAME="glosos-macOS.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
EXPORT_PLIST="${BUILD_DIR}/ExportOptions.plist"

# Color helpers
GREEN='\033[0;32m'
NC='\033[0m' # No Color
echo -e "${GREEN}=== Starting glosos-macOS Packaging Pipeline ===${NC}"

# Ensure we are in the project root
if [ ! -d "${PROJECT_NAME}.xcodeproj" ]; then
    echo "Error: Please run this script from the root directory containing ${PROJECT_NAME}.xcodeproj."
    exit 1
fi

# Clean previous builds
echo "Cleaning old build files..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 1. Archive the App
echo -e "${GREEN}1. Archiving application...${NC}"
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE="Automatic"

# 2. Create ExportOptions.plist
echo -e "${GREEN}2. Creating ExportOptions.plist...${NC}"
cat <<EOF > "$EXPORT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

# 3. Export the Archive
echo -e "${GREEN}3. Exporting archive for Developer ID distribution...${NC}"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_PATH"

EXPORTED_APP_PATH="${EXPORT_PATH}/${APP_NAME}"

# Verify app existence
if [ ! -d "$EXPORTED_APP_PATH" ]; then
    echo "Error: Exported application not found at ${EXPORTED_APP_PATH}"
    exit 1
fi

# 4. Package as DMG
echo -e "${GREEN}4. Creating Disk Image (DMG)...${NC}"
DMG_TEMP_DIR="${BUILD_DIR}/dmg_temp"
mkdir -p "$DMG_TEMP_DIR"

# Copy app to temp folder
cp -R "$EXPORTED_APP_PATH" "$DMG_TEMP_DIR/"

# Create symlink to Applications folder
ln -s /Applications "$DMG_TEMP_DIR/Applications"

# Build DMG
hdiutil create -volname "${PROJECT_NAME}" -srcfolder "$DMG_TEMP_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_TEMP_DIR"

echo -e "${GREEN}Package created successfully at: ${DMG_PATH}${NC}"

# 5. Notarization Instructions
echo -e "\n${GREEN}=== Notarization & Offline Stapling ===${NC}"
echo "To make the application distributable to other macOS users without warnings:"
echo "1. Submit for Notarization:"
echo "   xcrun notarytool submit ${DMG_PATH} --apple-id <your-apple-id> --password <app-specific-password> --team-id <your-team-id> --wait"
echo ""
echo "2. Staple the Notarization Ticket:"
echo "   xcrun stapler staple ${DMG_PATH}"
echo ""
echo "Done!"
