#!/bin/bash
# Builds the ffmpeg and ffprobe that are bundled inside VideoCleaner.app (Contents/Helpers).
#
#   Scripts/build-ffmpeg.sh            # → Vendor/ffmpeg/{ffmpeg,ffprobe} (universal), LICENSE, BUILD_INFO
#   FFMPEG_VERSION=9.0.2 Scripts/build-ffmpeg.sh
#
# The build is LGPL 2.1-or-later: no GPL or non-free parts and no external libraries — VideoCleaner only
# needs FFmpeg's own demuxers, muxers, decoders and encoders (AAC, AC-3, SRT…) plus Apple's VideoToolbox
# and AudioToolbox. Source code: https://ffmpeg.org/releases/ (the exact tarball is recorded in BUILD_INFO).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="${FFMPEG_VERSION:-9.0.2}"
MIN_MACOS="15.0"
OUT="$ROOT/Vendor/ffmpeg"
WORK="${TMPDIR:-/tmp}/VideoCleaner-ffmpeg-$VERSION"
TARBALL="ffmpeg-$VERSION.tar.xz"
URL="https://ffmpeg.org/releases/$TARBALL"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK" "$OUT"
if [ ! -f "$WORK/$TARBALL" ]; then
    echo "▸ Downloading $URL"
    curl -fL --progress-bar -o "$WORK/$TARBALL" "$URL"
fi
SHA256="$(shasum -a 256 "$WORK/$TARBALL" | cut -d' ' -f1)"

CONFIGURE=(
    --target-os=darwin
    --disable-autodetect          # never pick up Homebrew libraries by accident
    --enable-videotoolbox --enable-audiotoolbox
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv   # macOS keeps iconv in its own library
    --disable-network --disable-doc --disable-ffplay --disable-debug
    --enable-static --disable-shared
    --disable-gpl --disable-nonfree
)

for ARCH in arm64 x86_64; do
    echo "▸ Building ffmpeg $VERSION for $ARCH"
    SRC="$WORK/src-$ARCH"
    rm -rf "$SRC"; mkdir -p "$SRC"
    tar -xf "$WORK/$TARBALL" -C "$SRC" --strip-components 1
    EXTRA=()
    [ "$ARCH" = "x86_64" ] && EXTRA+=(--enable-cross-compile --disable-x86asm)
    (
        cd "$SRC"
        ./configure --arch="$ARCH" --cc="clang -arch $ARCH" \
            --extra-cflags="-mmacosx-version-min=$MIN_MACOS" --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
            "${CONFIGURE[@]}" ${EXTRA[@]+"${EXTRA[@]}"} > "$WORK/configure-$ARCH.log"
        make -j"$JOBS" ffmpeg ffprobe > "$WORK/make-$ARCH.log" 2>&1
    )
done

echo "▸ Combining into universal binaries"
for TOOL in ffmpeg ffprobe; do
    lipo -create "$WORK/src-arm64/$TOOL" "$WORK/src-x86_64/$TOOL" -output "$OUT/$TOOL"
    strip -x "$OUT/$TOOL" 2>/dev/null || true
done
cp "$WORK/src-arm64/COPYING.LGPLv2.1" "$OUT/LICENSE"
cat > "$OUT/BUILD_INFO" <<INFO
FFmpeg $VERSION — LGPL 2.1 or later
Source: $URL
SHA-256: $SHA256
Configure: ${CONFIGURE[*]}
Built: $(date -u +%Y-%m-%d) for arm64 + x86_64, macOS $MIN_MACOS or later
INFO
echo "$VERSION" > "$OUT/VERSION"
"$OUT/ffmpeg" -hide_banner -version | head -1
echo "✓ $OUT"
