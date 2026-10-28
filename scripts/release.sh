#!/bin/zsh
# Cut a release: zip → GitHub Release → update the Homebrew cask → wipe local artifacts.
#
#   ./scripts/release.sh 2.3.3
#
# Bumps CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist.
# Needs `gh`, authenticated.
set -euo pipefail

TAP_REPO="DoAutumn/homebrew-tap"
GH_REPO="DoAutumn/NotchTerm"
CASK_TOKEN="notchterm"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: ./scripts/release.sh <version>   e.g. ./scripts/release.sh 2.3.3"; exit 1; }

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
PLIST="$ROOT/Resources/Info.plist"
ZIP="$ROOT/dist/NotchTerm-${VERSION}.zip"
TAG="v$VERSION"

[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "!! working tree is dirty — commit first"; exit 1; }
git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 && { echo "!! tag $TAG already exists"; exit 1; }

echo "==> Checking the remote"
git -C "$ROOT" fetch -q origin
[ -z "$(git -C "$ROOT" ls-remote --tags origin "$TAG")" ] || {
    echo "!! tag $TAG already exists on the remote — someone released it elsewhere."
    echo "   Pull, then pick the next free version."
    exit 1
}
UPSTREAM="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)"
BEHIND="$(git -C "$ROOT" rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)"
[ "$BEHIND" -eq 0 ] || {
    echo "!! HEAD is $BEHIND commit(s) behind $UPSTREAM — rebase first, then rerun."
    exit 1
}

command -v gh >/dev/null || { echo "!! gh not found — install it first (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "!! gh is not authenticated — run: gh auth login"; exit 1; }

if [ -n "${TAP_DIR:-}" ]; then
    TAP="$TAP_DIR"
    git -C "$TAP" pull -q --ff-only
else
    TAP="$(mktemp -d)/homebrew-tap"
    trap 'rm -rf "$(dirname "$TAP")"' EXIT
    echo "==> Cloning $TAP_REPO"
    git clone -q "https://github.com/$TAP_REPO.git" "$TAP"
fi
CASK="$TAP/Casks/${CASK_TOKEN}.rb"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

"$SCRIPT_DIR/build-zip.sh"
[ -f "$ZIP" ] || { echo "!! expected zip missing: $ZIP" >&2; exit 1; }

echo "==> Tagging $TAG"
git -C "$ROOT" add Resources/Info.plist
git -C "$ROOT" commit -m "release: $TAG"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin HEAD "$TAG"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" --repo "$GH_REPO" --generate-notes

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo "==> Cleaning dist/ and .dSYM"
rm -rf "$ROOT/dist"
rm -rf "$ROOT"/.build/**/*.dSYM(N)

echo "==> Writing cask $CASK_TOKEN $VERSION ($SHA)"
cat > "$CASK" <<CASK
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$GH_REPO/releases/download/v#{version}/NotchTerm-#{version}.zip"
  name "NotchTerm"
  desc "Cursor Agent and long git/npm tasks in the Mac notch — hook-driven, no process scans"
  homepage "https://github.com/$GH_REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "NotchTerm.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/NotchTerm.app"]
  end

  uninstall quit: "com.doautumn.notchterm"

  zap trash: [
    "~/Library/Application Support/com.doautumn.notchterm",
    "~/Library/Preferences/com.doautumn.notchterm.plist",
    "~/Library/Saved Application State/com.doautumn.notchterm.savedState",
  ]
end
CASK

git -C "$TAP" add -A
git -C "$TAP" commit -m "notchterm $VERSION"
git -C "$TAP" push || {
    echo "!! pushing the tap failed — the GitHub release for $TAG is already published,"
    echo "   only the cask bump is missing. Fix the git credentials and bump the cask by hand."
    exit 1
}

echo
echo "==> Released $TAG"
echo "    brew install --cask DoAutumn/tap/notchterm"
echo "    brew upgrade --cask notchterm"
