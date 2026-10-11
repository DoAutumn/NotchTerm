#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/Re:notch.app"
CONTENTS_PATH="$APP_PATH/Contents"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

# Prefer a real signing identity so Automation (iTerm) TCC grants persist
# across rebuilds. Fall back to ad-hoc signing for local smoke builds.
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-certificate -c "Re:notch Local Code Sign" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
        SIGN_IDENTITY="Re:notch Local Code Sign"
    fi
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "warning: no code signing identity found; using ad-hoc signing."
    echo "warning: Automation grants for iTerm may not survive rebuilds."
fi

cd "$PROJECT_DIR"
swift build -c "$BUILD_CONFIGURATION" --triple arm64-apple-macosx --product Renotch
swift build -c "$BUILD_CONFIGURATION" --triple x86_64-apple-macosx --product Renotch

BIN_DIR_ARM64="$(swift build -c "$BUILD_CONFIGURATION" --triple arm64-apple-macosx --show-bin-path)"
BIN_DIR_X86="$(swift build -c "$BUILD_CONFIGURATION" --triple x86_64-apple-macosx --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"

lipo -create \
    "$BIN_DIR_ARM64/Renotch" \
    "$BIN_DIR_X86/Renotch" \
    -output "$CONTENTS_PATH/MacOS/Renotch"

if [ -d "$BIN_DIR_ARM64/Renotch_Renotch.bundle" ]; then
    cp -R "$BIN_DIR_ARM64/Renotch_Renotch.bundle" "$CONTENTS_PATH/Resources/"
elif [ -d "$BIN_DIR_X86/Renotch_Renotch.bundle" ]; then
    cp -R "$BIN_DIR_X86/Renotch_Renotch.bundle" "$CONTENTS_PATH/Resources/"
fi
if [ -f "$PROJECT_DIR/Sources/Renotch/Resources/TrayIconTemplate.png" ]; then
    cp "$PROJECT_DIR/Sources/Renotch/Resources/TrayIconTemplate.png" "$CONTENTS_PATH/Resources/"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"

CUSTOM_ICON="$PROJECT_DIR/AppIcon.icns"
if [ -f "$CUSTOM_ICON" ]; then
    cp "$CUSTOM_ICON" "$CONTENTS_PATH/Resources/AppIcon.icns"
    echo "Using custom AppIcon.icns"
else
    echo "error: AppIcon.icns not found at $CUSTOM_ICON"
    exit 1
fi

echo "Signing with identity: $SIGN_IDENTITY"

codesign \
    --force \
    --deep \
    --options runtime \
    --entitlements "$PROJECT_DIR/Resources/Renotch.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

echo "Built: $APP_PATH"
