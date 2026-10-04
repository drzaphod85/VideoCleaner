#!/bin/bash
# Builds VideoCleaner.app (and optionally a .dmg) from the Swift package.
#
#   Scripts/build-app.sh             # release build → build/VideoCleaner.app
#   Scripts/build-app.sh --dmg       # …and build/VideoCleaner-<version>.dmg
#   Scripts/build-app.sh --notarize  # …DMG notarized by Apple and stapled (implies --dmg)
#   Scripts/build-app.sh --debug     # debug build
#   Scripts/build-app.sh --install   # …and install to ~/Applications (no admin rights needed)
#   Scripts/build-app.sh --release   # notarized DMG → GitHub release v<VERSION> → Homebrew cask (implies --notarize)
#
# Releasing: the code must be committed and pushed. The DMG is uploaded to the GitHub release v<VERSION> (created
# with the notes in RELEASE_NOTES.md when that file exists, else GitHub's generated notes; an existing release gets
# its DMG replaced). Then version and sha256 in Casks/videocleaner.rb of the tap (TAP_DIR, default
# ../homebrew-tap, cloned from drzaphod85/homebrew-tap when missing) are updated, committed and pushed.
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
RELEASE=0
REPO="drzaphod85/VideoCleaner"
TAP_REPO="drzaphod85/homebrew-tap"
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-tap}"
CASK="Casks/videocleaner.rb"
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --notarize) MAKE_DMG=1; NOTARIZE=1 ;;
        --debug) CONFIG="debug" ;;
        --install) INSTALL=1 ;;
        --release) MAKE_DMG=1; NOTARIZE=1; RELEASE=1 ;;
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

if [ "$RELEASE" = 1 ]; then
    # Release exactly what is on GitHub: the tag is made from the pushed commit
    command -v gh >/dev/null || { echo "Releasing needs the GitHub CLI (gh)." >&2; exit 1; }
    if [ -n "$(git status --porcelain)" ]; then
        echo "Commit your changes before releasing." >&2; exit 1
    fi
    git fetch -q origin
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        echo "Push main before releasing (HEAD is not origin/main)." >&2; exit 1
    fi
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
# Bundled ffmpeg/ffprobe (built by Scripts/build-ffmpeg.sh) and their license
if [ -x Vendor/ffmpeg/ffmpeg ] && [ -x Vendor/ffmpeg/ffprobe ]; then
    mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty/FFmpeg"
    cp Vendor/ffmpeg/ffmpeg Vendor/ffmpeg/ffprobe "$APP/Contents/Helpers/"
    cp Vendor/ffmpeg/LICENSE Vendor/ffmpeg/BUILD_INFO "$APP/Contents/Resources/ThirdParty/FFmpeg/"
    echo "▸ Bundling FFmpeg $(cat Vendor/ffmpeg/VERSION)"
else
    echo "  (no bundled ffmpeg — run Scripts/build-ffmpeg.sh to include one)"
fi
xattr -cr "$APP"

# Sign nested helpers first (hardened runtime + timestamp are required for notarization)
for HELPER in "$APP"/Contents/Helpers/*; do
    [ -e "$HELPER" ] || continue
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - "$HELPER"
    else
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$HELPER"
    fi
done

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

if [ "$RELEASE" = 1 ]; then
    TAG="v$VERSION"
    SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "▸ Replacing the DMG of release $TAG"
        gh release upload "$TAG" "$DMG" -R "$REPO" --clobber
    else
        echo "▸ Creating release $TAG"
        if [ -f RELEASE_NOTES.md ]; then NOTES=(--notes-file RELEASE_NOTES.md); else NOTES=(--generate-notes); fi
        gh release create "$TAG" "$DMG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "$NAME $VERSION" "${NOTES[@]}"
    fi
    # The cask must match what users download, so check the uploaded file itself
    URL="https://github.com/$REPO/releases/download/$TAG/$NAME-$VERSION.dmg"
    REMOTE_SHA="$(curl -sfL "$URL" | shasum -a 256 | cut -d' ' -f1)"
    if [ "$REMOTE_SHA" != "$SHA" ]; then
        echo "The DMG on GitHub ($REMOTE_SHA) differs from the local one ($SHA)." >&2; exit 1
    fi
    echo "✓ $URL"

    echo "▸ Updating the Homebrew cask"
    if [ ! -d "$TAP_DIR/.git" ]; then gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q; fi
    git -C "$TAP_DIR" pull -q --ff-only
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP_DIR/$CASK"
    if git -C "$TAP_DIR" diff --quiet; then
        echo "  (cask already up to date)"
    else
        git -C "$TAP_DIR" commit -q -am "videocleaner $VERSION"
        git -C "$TAP_DIR" push -q
        echo "✓ $TAP_REPO: videocleaner $VERSION ($SHA)"
    fi
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
