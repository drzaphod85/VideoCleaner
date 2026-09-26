#!/bin/bash
# Builds VideoCleaner.app (and optionally a .dmg) from the Swift package.
#
#   Scripts/build-app.sh             # release build → build/VideoCleaner.app
#   Scripts/build-app.sh --dmg       # …and build/VideoCleaner-<version>.dmg
#   Scripts/build-app.sh --notarize  # …DMG notarized by Apple and stapled (implies --dmg)
#   Scripts/build-app.sh --debug     # debug build
#   Scripts/build-app.sh --install   # …and install to ~/Applications (no admin rights needed)
#
# Signing: with a "Developer ID Application" certificate in the keychain the app is signed with it
# (hardened runtime + secure timestamp); otherwise it is signed ad hoc. Override the certificate with
# SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" or force ad hoc with SIGN_IDENTITY="-".
#
# Notarizing needs credentials stored once with:
#   xcrun notarytool store-credentials VideoCleaner --apple-id <apple id> --team-id <TEAMID>
# (asks for an app-specific password from appleid.apple.com). Use another profile name with
# NOTARY_PROFILE=<name>.
set -euo pipefail

cd "$(dirname "$0")/.."
SCRATCH="${TMPDIR:-/tmp}/VideoCleaner-build"   # outside iCloud Drive (see Scripts/test.sh)
ROOT="$(pwd)"
NAME="VideoCleaner"
BUNDLE_ID="io.github.drzaphod85.videocleaner"
VERSION="$(cat VERSION)"
NOTARY_PROFILE="${NOTARY_PROFILE:-VideoCleaner}"
CONFIG="release"
MAKE_DMG=0
NOTARIZE=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --notarize) MAKE_DMG=1; NOTARIZE=1 ;;
        --debug) CONFIG="debug" ;;
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [ "$NOTARIZE" = 1 ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Notarizing needs a Developer ID Application certificate in the keychain." >&2
    exit 1
fi

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

# Assemble, sign and notarize in a temp folder (iCloud/Finder add xattrs that codesign rejects)
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

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "▸ Signing (ad hoc — no Developer ID certificate found)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    echo "▸ Signing with $SIGN_IDENTITY"
    # Hardened runtime is required for notarization. No extra entitlements are needed: running
    # ffmpeg/mkvtoolnix as separate processes and playing video are allowed by default.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [ "$MAKE_DMG" = 1 ]; then
    DMG="$ROOT/build/$NAME-$VERSION.dmg"
    mkdir -p "$ROOT/build" "$STAGE/dmg"
    ditto "$APP" "$STAGE/dmg/$NAME.app"
    ln -s /Applications "$STAGE/dmg/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE/dmg" -ov -format UDZO "$STAGE/$NAME.dmg"
    if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGE/$NAME.dmg"
    fi
    if [ "$NOTARIZE" = 1 ]; then
        echo "▸ Notarizing (usually a few minutes)…"
        xcrun notarytool submit "$STAGE/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        # The ticket covers the DMG and the app inside it; staple both so they open offline too
        xcrun stapler staple "$STAGE/$NAME.dmg"
        xcrun stapler staple "$APP"
        spctl --assess --type open --context context:primary-signature -v "$STAGE/$NAME.dmg"
        spctl --assess --type execute -v "$APP"
    fi
    cp "$STAGE/$NAME.dmg" "$DMG"
    echo "✓ $DMG"
fi

mkdir -p "$ROOT/build"
rm -rf "$ROOT/build/$NAME.app"
ditto "$APP" "$ROOT/build/$NAME.app"
echo "✓ $ROOT/build/$NAME.app"

if [ "$INSTALL" = 1 ]; then
    DEST="$HOME/Applications/$NAME.app"
    mkdir -p "$HOME/Applications"
    osascript -e "quit app \"$NAME\"" 2>/dev/null || true
    rm -rf "$DEST"
    ditto --noextattr --noqtn "$APP" "$DEST"   # the signed copy from the temp folder
    codesign --verify --strict "$DEST"
    echo "✓ Installed: $DEST"
fi
