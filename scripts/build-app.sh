#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/NotchTerm.app"
CONTENTS_PATH="$APP_PATH/Contents"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
# Apple Silicon only (smaller binary; Intel Macs are not supported).
TRIPLE="arm64-apple-macosx"

# Prefer a real signing identity so Automation (iTerm) TCC grants persist
# across rebuilds. Fall back to ad-hoc signing for local smoke builds.
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-certificate -c "NotchTerm Local Code Sign" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
        SIGN_IDENTITY="NotchTerm Local Code Sign"
    fi
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "warning: no code signing identity found; using ad-hoc signing."
    echo "warning: Automation grants for iTerm may not survive rebuilds."
fi

cd "$PROJECT_DIR"
swift build -c "$BUILD_CONFIGURATION" --triple "$TRIPLE" --product NotchTerm

BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --triple "$TRIPLE" --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"

cp "$BIN_DIR/NotchTerm" "$CONTENTS_PATH/MacOS/NotchTerm"

if [ -d "$BIN_DIR/NotchTerm_NotchTerm.bundle" ]; then
    cp -R "$BIN_DIR/NotchTerm_NotchTerm.bundle" "$CONTENTS_PATH/Resources/"
fi
for asset in TrayIconTemplate.png TrayIconTemplate@2x.png TrayIconTemplate@3x.png notchterm-agent-hook.sh; do
    if [ -f "$PROJECT_DIR/Sources/NotchTerm/Resources/$asset" ]; then
        cp "$PROJECT_DIR/Sources/NotchTerm/Resources/$asset" "$CONTENTS_PATH/Resources/"
    fi
done
if [ -f "$CONTENTS_PATH/Resources/notchterm-agent-hook.sh" ]; then
    chmod 755 "$CONTENTS_PATH/Resources/notchterm-agent-hook.sh"
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

echo "Signing with identity: $SIGN_IDENTITY (arm64 only)"

codesign \
    --force \
    --deep \
    --options runtime \
    --entitlements "$PROJECT_DIR/Resources/NotchTerm.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

echo "Built: $APP_PATH"
lipo -info "$CONTENTS_PATH/MacOS/NotchTerm"
