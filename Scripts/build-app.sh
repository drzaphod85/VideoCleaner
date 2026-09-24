#!/bin/bash
# Builds VideoCleaner.app (and optionally a .dmg) from the Swift package.
#
#   Scripts/build-app.sh            # release build → build/VideoCleaner.app
#   Scripts/build-app.sh --dmg      # …and build/VideoCleaner-<version>.dmg
#   Scripts/build-app.sh --debug    # debug build
set -euo pipefail

cd "$(dirname "$0")/.."
SCRATCH="${TMPDIR:-/tmp}/VideoCleaner-build"   # outside iCloud Drive (see Scripts/test.sh)
ROOT="$(pwd)"
NAME="VideoCleaner"
VERSION="$(cat VERSION)"
CONFIG="release"
MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --debug) CONFIG="debug" ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# iCloud Drive sometimes creates "File 2.swift" duplicates that break the build
find Sources Tests -name "* 2.*" -delete 2>/dev/null || true

echo "▸ Building $NAME $VERSION ($CONFIG)…"
# Universal binary (Apple silicon + Intel); falls back to the native architecture only
if swift build --scratch-path "$SCRATCH" -c "$CONFIG" --arch arm64 --arch x86_64 2>&1 | grep -vE "deprecated"; then
    BIN="$(swift build --scratch-path "$SCRATCH" -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/$NAME"
else
    echo "  (universal build failed — building for this Mac only)"
    swift build --scratch-path "$SCRATCH" -c "$CONFIG"
    BIN="$(swift build --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path)/$NAME"
fi

# Assemble and sign in a temp folder (iCloud/Finder add xattrs that codesign rejects)
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/videocleaner-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# Translations go in the main bundle (Bundle.main) so SwiftUI and L() find them
mkdir -p "$APP/Contents/Resources/en.lproj"
for lproj in Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done
xattr -cr "$APP"

echo "▸ Signing (ad hoc)"
codesign --force --deep --sign - --identifier io.github.drzaphod85.videocleaner "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$ROOT/build"
rm -rf "$ROOT/build/$NAME.app"
ditto "$APP" "$ROOT/build/$NAME.app"
echo "✓ $ROOT/build/$NAME.app"

if [ "$MAKE_DMG" = 1 ]; then
    DMG="$ROOT/build/$NAME-$VERSION.dmg"
    mkdir -p "$STAGE/dmg"
    ditto "$APP" "$STAGE/dmg/$NAME.app"
    ln -s /Applications "$STAGE/dmg/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE/dmg" -ov -format UDZO "$DMG"
    echo "✓ $DMG"
fi
