#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="NotchTerm.app"
APP_PATH="$DIST_DIR/$APP_NAME"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null || echo "2.0.0")"
ZIP_PATH="$DIST_DIR/NotchTerm-${VERSION}.zip"

"$SCRIPT_DIR/build-app.sh"

echo "Creating release zip for NotchTerm ${VERSION}..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Successfully built: $ZIP_PATH"
