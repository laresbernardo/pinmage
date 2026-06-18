#!/bin/bash

# Pinmage macOS Build & Install Script
# Compiles Swift sources, installs Pinmage directly to /Applications,
# and clears all Gatekeeper quarantine flags.
# Also produces Pinmage.dmg for sharing/distribution.

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_FILE="$SOURCE_DIR/PinmageApp/Info.plist"
NEW_VERSION="Unknown"
NEW_BUILD="Unknown"

# Auto-increment version/build using PlistBuddy if it exists
if [ -f "$PLIST_FILE" ] && [ -x /usr/libexec/PlistBuddy ]; then
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_FILE")
    IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
    NEXT_PATCH=$((patch + 1))
    NEW_VERSION="$major.$minor.$NEXT_PATCH"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST_FILE"
    
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_FILE")
    NEW_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST_FILE"
    
    # Write updated details to website/version.json
    WEBSITE_VERSION_FILE="$SOURCE_DIR/website/version.json"
    if [ -d "$SOURCE_DIR/website" ]; then
        TODAY=$(date +"%Y-%m-%d")
        echo -e "{" > "$WEBSITE_VERSION_FILE"
        echo -e "  \"version\": \"$NEW_VERSION\"," >> "$WEBSITE_VERSION_FILE"
        echo -e "  \"build\": \"$NEW_BUILD\"," >> "$WEBSITE_VERSION_FILE"
        echo -e "  \"date\": \"$TODAY\"" >> "$WEBSITE_VERSION_FILE"
        echo -e "}" >> "$WEBSITE_VERSION_FILE"
    fi
else
    echo -e "${YELLOW}Warning: PlistBuddy not found. Skipping auto-incrementing build number.${NC}"
fi

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}       PINMAGE MAC APP BUILD SYSTEM     ${NC}"
if [ "$NEW_VERSION" != "Unknown" ]; then
echo -e "${BLUE}       Installing: Version $NEW_VERSION Build $NEW_BUILD${NC}"
fi
echo -e "${BLUE}==================================================${NC}"

# 1. Verify macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo -e "${RED}Error: This script requires macOS.${NC}"
    exit 1
fi

# 2. Check Swift compiler
if ! command -v swiftc &> /dev/null; then
    echo -e "${RED}Error: Swift compiler not found.${NC}"
    echo -e "Run: xcode-select --install"
    exit 1
fi

# Build in local /tmp disk to avoid cloud storage / sandbox locking issues during swiftc compilation
BUILD_DIR="/tmp/PinmageBuild"
APP_BUNDLE="$BUILD_DIR/Pinmage.app"
DMG_STAGING="$BUILD_DIR/dmg_staging"
DMG_LOCAL="$BUILD_DIR/Pinmage.dmg"
INSTALL_DEST="/Applications/Pinmage.app"
FINAL_DMG="$SOURCE_DIR/Pinmage.dmg"

# 3. Clean up
echo -e "${YELLOW}Cleaning previous build artifacts...${NC}"
rm -rf "$BUILD_DIR" "$FINAL_DMG"
sleep 1
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$DMG_STAGING"

# 4. Compile directly into /tmp
echo -e "${YELLOW}Compiling Swift sources → /tmp ...${NC}"
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)

# Stage source files to /tmp/PinmageSource
SRC_STAGING="/tmp/PinmageSource"
rm -rf "$SRC_STAGING"
mkdir -p "$SRC_STAGING"
cp -R "$SOURCE_DIR/PinmageApp" "$SRC_STAGING/"
xattr -rc "$SRC_STAGING"
find "$SRC_STAGING" -type f -exec touch {} +
sleep 1

swiftc -O -sdk "$SDK_PATH" \
    -o "$APP_BUNDLE/Contents/MacOS/Pinmage" \
    "$SRC_STAGING/PinmageApp/Models.swift" \
    "$SRC_STAGING/PinmageApp/GlassCard.swift" \
    "$SRC_STAGING/PinmageApp/MetadataWriter.swift" \
    "$SRC_STAGING/PinmageApp/GeminiManager.swift" \
    "$SRC_STAGING/PinmageApp/PinmageManager.swift" \
    "$SRC_STAGING/PinmageApp/Views/MainView.swift" \
    "$SRC_STAGING/PinmageApp/Views/DashboardView.swift" \
    "$SRC_STAGING/PinmageApp/Views/ProcessView.swift" \
    "$SRC_STAGING/PinmageApp/Views/SettingsView.swift" \
    "$SRC_STAGING/PinmageApp/PinmageApp.swift"

rm -rf "$SRC_STAGING"

echo -e "${GREEN}✓ Compilation successful.${NC}"

# 5. Inject Info.plist
cp "$PLIST_FILE" "$APP_BUNDLE/Contents/Info.plist"

# 6. Generate .icns app icon from AppIcon.png if provided
ICON_SOURCE="$SOURCE_DIR/PinmageApp/AppIcon.png"
if [ -f "$ICON_SOURCE" ]; then
    echo -e "${YELLOW}Generating app icon from AppIcon.png...${NC}"
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png"     > /dev/null
    sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png"  > /dev/null
    sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png"     > /dev/null
    sips -z 64 64     "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png"  > /dev/null
    sips -z 128 128   "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png"   > /dev/null
    sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png"> /dev/null
    sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png"   > /dev/null
    sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png"> /dev/null
    sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png"   > /dev/null
    sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png"> /dev/null
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
    echo -e "${GREEN}✓ App icon generated and bundled.${NC}"
fi

# 7. Deep ad-hoc code sign --deep covers nested binaries/frameworks
echo -e "${YELLOW}Code signing deep ad-hoc...${NC}"
codesign --force --deep --sign - "$APP_BUNDLE"

# 8. Strip all extended attributes while the bundle is on local disk
xattr -rc "$APP_BUNDLE"
echo -e "${GREEN}✓ Signed and quarantine-cleared.${NC}"

# ─── DIRECT INSTALL TO /Applications ────────────────────────────────────────
if [ "$CI" != "true" ]; then
    echo -e "${YELLOW}Installing Pinmage → /Applications ...${NC}"
    rm -rf "$INSTALL_DEST"
    ditto "$APP_BUNDLE" "$INSTALL_DEST"

    # Strip quarantine on the installed copy
    xattr -rc "$INSTALL_DEST"

    # Re-sign the installed copy in place
    codesign --force --deep --sign - "$INSTALL_DEST"

    echo -e "${GREEN}✓ Pinmage installed to /Applications/Pinmage.app${NC}"
else
    echo -e "${GREEN}✓ CI detected. Skipping direct install to /Applications.${NC}"
fi

# ─── BUILD DMG FOR DISTRIBUTION ────────────────────────────────────────
echo -e "${YELLOW}Packaging Pinmage.dmg for distribution...${NC}"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "Pinmage Installer" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_LOCAL" > /dev/null

# Strip quarantine from the DMG itself
xattr -rc "$DMG_LOCAL"
cp "$DMG_LOCAL" "$FINAL_DMG"

# Clean up /tmp
rm -rf "$BUILD_DIR"

# ─── LAUNCH ──────────────────────────────────────────────────────────────────
echo -e "${BLUE}==================================================${NC}"
echo -e "${GREEN}🚀 BUILD SYSTEM COMPLETED SUCCESSFULLY!${NC}"
echo -e "${GREEN}DMG for sharing:      $FINAL_DMG${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

if [ "$CI" != "true" ]; then
    echo -e "Launching Pinmage..."
    open "$INSTALL_DEST"
else
    echo -e "${GREEN}✓ CI detected. Skipping app launch.${NC}"
fi
