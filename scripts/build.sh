#!/usr/bin/env bash
set -euo pipefail

# ── Arguments & Globals ──────────────────────────────────────────────
ARCH="${1:?Usage: build.sh <arm64-v8a|armeabi-v7a|x86_64|x86>}"
API="${API:-23}"
FFMPEG_VERSION="${FFMPEG_VERSION:-n7.1}"
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME}"
JOBS="$(nproc)"

WORKDIR="$(pwd)/build-${ARCH}"
PREFIX="${WORKDIR}/install"
OUTPUT="$(pwd)/output/${ARCH}"
mkdir -p "$WORKDIR" "$PREFIX" "$OUTPUT"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
export PATH="${PREFIX}/bin:${PATH}"

# ── Arch mapping ─────────────────────────────────────────────────────
case "$ARCH" in
  arm64-v8a)
    TARGET=aarch64-linux-android
    FFMPEG_ARCH=aarch64
    CPU=armv8-a
    ;;
  armeabi-v7a)
    TARGET=armv7a-linux-androideabi
    FFMPEG_ARCH=arm
    CPU=armv7-a
    ;;
  x86_64)
    TARGET=x86_64-linux-android
    FFMPEG_ARCH=x86_64
    CPU=x86-64
    ;;
  x86)
    TARGET=i686-linux-android
    FFMPEG_ARCH=x86
    CPU=i686
    ;;
  *)
    echo "Unknown arch: $ARCH"; exit 1
    ;;
esac

TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="${TOOLCHAIN}/sysroot"
CC="${TOOLCHAIN}/bin/${TARGET}${API}-clang"
CXX="${TOOLCHAIN}/bin/${TARGET}${API}-clang++"
AR="${TOOLCHAIN}/bin/llvm-ar"
RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
STRIP="${TOOLCHAIN}/bin/llvm-strip"
NM="${TOOLCHAIN}/bin/llvm-nm"
AS="${CC}"

# Fix for armeabi-v7a: clang binary name differs
if [ "$ARCH" = "armeabi-v7a" ]; then
  CC="${TOOLCHAIN}/bin/armv7a-linux-androideabi${API}-clang"
  CXX="${TOOLCHAIN}/bin/armv7a-linux-androideabi${API}-clang++"
fi

COMMON_CFLAGS="-fPIC -DANDROID -D__ANDROID_API__=${API}"
COMMON_LDFLAGS="-static"

export CC CXX AR RANLIB STRIP NM AS

echo "=== Building FFmpeg ${FFMPEG_VERSION} for ${ARCH} (API ${API}) ==="
echo "=== NDK: ${NDK} ==="
echo "=== CC: ${CC} ==="

# ── Helper: git clone with retry ─────────────────────────────────────
clone() {
  local repo="$1" dir="$2" branch="${3:-}"
  if [ ! -d "$dir" ]; then
    if [ -n "$branch" ]; then
      git clone --depth 1 --branch "$branch" "$repo" "$dir"
    else
      git clone --depth 1 "$repo" "$dir"
    fi
  fi
}

cd "$WORKDIR"

# ══════════════════════════════════════════════════════════════════════
# Library builds
# ══════════════════════════════════════════════════════════════════════

# ── x264 ─────────────────────────────────────────────────────────────
build_x264() {
  echo ">>> Building x264"
  clone "https://code.videolan.org/videolan/x264.git" x264
  cd x264
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --cross-prefix="${TOOLCHAIN}/bin/llvm-" \
    --sysroot="$SYSROOT" \
    --enable-static \
    --enable-pic \
    --disable-cli \
    --extra-cflags="$COMMON_CFLAGS" \
    --extra-ldflags="$COMMON_LDFLAGS"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── x265 ─────────────────────────────────────────────────────────────
build_x265() {
  echo ">>> Building x265"
  clone "https://bitbucket.org/multicoreware/x265_git.git" x265_git
  mkdir -p x265_git/build_android && cd x265_git/build_android

  cmake ../source \
    -DCMAKE_TOOLCHAIN_FILE="${NDK}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ARCH" \
    -DANDROID_PLATFORM="android-${API}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CFLAGS" \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_PIC=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_ASSEMBLY=OFF \
    -G Ninja
  ninja -j"$JOBS"
  ninja install
  cd "$WORKDIR"
}

# ── libmp3lame ───────────────────────────────────────────────────────
build_lame() {
  echo ">>> Building lame"
  if [ ! -d "lame-3.100" ]; then
    wget -q "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
    tar xzf lame-3.100.tar.gz
  fi
  cd lame-3.100
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --disable-frontend \
    --with-pic \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$COMMON_CFLAGS" \
    LDFLAGS="$COMMON_LDFLAGS"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── libopus ──────────────────────────────────────────────────────────
build_opus() {
  echo ">>> Building opus"
  clone "https://github.com/xiph/opus.git" opus v1.5.2
  cd opus
  autoreconf -fiv
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --disable-doc \
    --disable-extra-programs \
    --with-pic \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$COMMON_CFLAGS" \
    LDFLAGS="$COMMON_LDFLAGS"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── libogg (needed by vorbis) ────────────────────────────────────────
build_ogg() {
  echo ">>> Building libogg"
  clone "https://github.com/xiph/ogg.git" ogg v1.3.5
  cd ogg
  autoreconf -fiv
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --with-pic \
    CC="$CC" CFLAGS="$COMMON_CFLAGS"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── libvorbis ────────────────────────────────────────────────────────
build_vorbis() {
  echo ">>> Building vorbis"
  clone "https://github.com/xiph/vorbis.git" vorbis v1.3.7
  cd vorbis
  autoreconf -fiv
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --with-pic \
    --with-ogg="$PREFIX" \
    CC="$CC" CFLAGS="$COMMON_CFLAGS" \
    LDFLAGS="$COMMON_LDFLAGS -L${PREFIX}/lib"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── libvpx ───────────────────────────────────────────────────────────
build_vpx() {
  echo ">>> Building vpx"
  clone "https://chromium.googlesource.com/webm/libvpx.git" libvpx v1.14.1
  cd libvpx

  case "$ARCH" in
    arm64-v8a)   VPX_TARGET="arm64-android-gcc" ;;
    armeabi-v7a) VPX_TARGET="armv7-android-gcc" ;;
    x86_64)      VPX_TARGET="x86_64-android-gcc" ;;
    x86)         VPX_TARGET="x86-android-gcc" ;;
  esac

  CROSS="${TOOLCHAIN}/bin/llvm-" \
  CC="$CC" CXX="$CXX" \
  CFLAGS="$COMMON_CFLAGS" \
  LDFLAGS="$COMMON_LDFLAGS" \
  ./configure \
    --prefix="$PREFIX" \
    --target="$VPX_TARGET" \
    --sdk-path="$NDK" \
    --enable-static \
    --disable-shared \
    --enable-pic \
    --disable-examples \
    --disable-tools \
    --disable-docs \
    --disable-unit-tests \
    --enable-vp8 \
    --enable-vp9 \
    --enable-vp9-highbitdepth \
    --as=auto
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── fdk-aac ──────────────────────────────────────────────────────────
build_fdk_aac() {
  echo ">>> Building fdk-aac"
  clone "https://github.com/mstorsjo/fdk-aac.git" fdk-aac v2.0.3
  cd fdk-aac
  autoreconf -fiv
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --with-pic \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$COMMON_CFLAGS" \
    CXXFLAGS="$COMMON_CFLAGS"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ── dav1d (AV1 decoder) ─────────────────────────────────────────────
build_dav1d() {
  echo ">>> Building dav1d"
  clone "https://code.videolan.org/videolan/dav1d.git" dav1d 1.5.0

  cat > dav1d/cross-${ARCH}.txt <<CROSSEOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'

[host_machine]
system = 'android'
cpu_family = '${FFMPEG_ARCH}'
cpu = '${CPU}'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-fPIC', '-DANDROID', '-D__ANDROID_API__=${API}']
CROSSEOF

  meson setup dav1d/builddir dav1d \
    --cross-file "dav1d/cross-${ARCH}.txt" \
    --prefix="$PREFIX" \
    --default-library=static \
    --buildtype=release \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false
  ninja -C dav1d/builddir -j"$JOBS"
  ninja -C dav1d/builddir install
  cd "$WORKDIR"
}

# ── freetype ─────────────────────────────────────────────────────────
build_freetype() {
  echo ">>> Building freetype"
  clone "https://github.com/freetype/freetype.git" freetype VER-2-13-3
  cd freetype
  cmake -B build \
    -DCMAKE_TOOLCHAIN_FILE="${NDK}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ARCH" \
    -DANDROID_PLATFORM="android-${API}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFT_DISABLE_BZIP2=ON \
    -DFT_DISABLE_BROTLI=ON \
    -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON \
    -G Ninja
  ninja -C build -j"$JOBS"
  ninja -C build install
  cd "$WORKDIR"
}

# ── fribidi ──────────────────────────────────────────────────────────
build_fribidi() {
  echo ">>> Building fribidi"
  clone "https://github.com/fribidi/fribidi.git" fribidi v1.0.16
  cd fribidi

  cat > cross-${ARCH}.txt <<CROSSEOF
[binaries]
c = '${CC}'
ar = '${AR}'
strip = '${STRIP}'

[host_machine]
system = 'android'
cpu_family = '${FFMPEG_ARCH}'
cpu = '${CPU}'
endian = 'little'

[built-in options]
c_args = ['-fPIC', '-DANDROID', '-D__ANDROID_API__=${API}']
CROSSEOF

  meson setup builddir \
    --cross-file "cross-${ARCH}.txt" \
    --prefix="$PREFIX" \
    --default-library=static \
    --buildtype=release \
    -Ddocs=false \
    -Dtests=false \
    -Dbin=false
  ninja -C builddir -j"$JOBS"
  ninja -C builddir install
  cd "$WORKDIR"
}

# ── harfbuzz ─────────────────────────────────────────────────────────
build_harfbuzz() {
  echo ">>> Building harfbuzz"
  clone "https://github.com/harfbuzz/harfbuzz.git" harfbuzz 10.1.0
  cd harfbuzz

  cat > cross-${ARCH}.txt <<CROSSEOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'

[host_machine]
system = 'android'
cpu_family = '${FFMPEG_ARCH}'
cpu = '${CPU}'
endian = 'little'

[built-in options]
c_args = ['-fPIC', '-DANDROID', '-D__ANDROID_API__=${API}']
cpp_args = ['-fPIC', '-DANDROID', '-D__ANDROID_API__=${API}']
CROSSEOF

  meson setup builddir \
    --cross-file "cross-${ARCH}.txt" \
    --prefix="$PREFIX" \
    --default-library=static \
    --buildtype=release \
    -Dfreetype=enabled \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dicu=disabled \
    -Dtests=disabled \
    -Ddocs=disabled
  ninja -C builddir -j"$JOBS"
  ninja -C builddir install
  cd "$WORKDIR"
}

# ── libass ───────────────────────────────────────────────────────────
build_libass() {
  echo ">>> Building libass"
  clone "https://github.com/libass/libass.git" libass 0.17.3
  cd libass
  autoreconf -fiv
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --with-pic \
    --disable-require-system-font-provider \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$COMMON_CFLAGS -I${PREFIX}/include" \
    CXXFLAGS="$COMMON_CFLAGS -I${PREFIX}/include" \
    LDFLAGS="$COMMON_LDFLAGS -L${PREFIX}/lib" \
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
  make -j"$JOBS"
  make install
  cd "$WORKDIR"
}

# ══════════════════════════════════════════════════════════════════════
# FFmpeg
# ══════════════════════════════════════════════════════════════════════
build_ffmpeg() {
  echo ">>> Building FFmpeg ${FFMPEG_VERSION}"
  clone "https://github.com/FFmpeg/FFmpeg.git" FFmpeg "$FFMPEG_VERSION"
  cd FFmpeg

  EXTRA_CFLAGS="-I${PREFIX}/include $COMMON_CFLAGS"
  EXTRA_LDFLAGS="-L${PREFIX}/lib $COMMON_LDFLAGS"

  # x265 needs -lc++ on Android
  EXTRA_LIBS="-lc++ -lm -ldl"

  ./configure \
    --prefix="$PREFIX" \
    --target-os=android \
    --arch="$FFMPEG_ARCH" \
    --cpu="$CPU" \
    --cc="$CC" \
    --cxx="$CXX" \
    --ar="$AR" \
    --ranlib="$RANLIB" \
    --strip="$STRIP" \
    --nm="$NM" \
    --sysroot="$SYSROOT" \
    --cross-prefix="${TOOLCHAIN}/bin/llvm-" \
    --enable-cross-compile \
    --enable-pic \
    --enable-static \
    --disable-shared \
    --enable-gpl \
    --enable-nonfree \
    --enable-version3 \
    --enable-small \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --disable-debug \
    --disable-symver \
    --pkg-config-flags="--static" \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libfdk-aac \
    --enable-libdav1d \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libharfbuzz \
    --enable-libass \
    --extra-cflags="$EXTRA_CFLAGS" \
    --extra-ldflags="$EXTRA_LDFLAGS" \
    --extra-libs="$EXTRA_LIBS"

  make -j"$JOBS"
  make install

  # Copy final binaries
  cp "${PREFIX}/bin/ffmpeg" "$OUTPUT/ffmpeg"
  cp "${PREFIX}/bin/ffprobe" "$OUTPUT/ffprobe"
  "$STRIP" "$OUTPUT/ffmpeg" "$OUTPUT/ffprobe"

  echo ">>> Done! Binaries at: $OUTPUT"
  ls -lh "$OUTPUT"
  cd "$WORKDIR"
}

# ══════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════
build_x264
build_x265
build_lame
build_opus
build_ogg
build_vorbis
build_vpx
build_fdk_aac
build_dav1d
build_freetype
build_fribidi
build_harfbuzz
build_libass
build_ffmpeg

echo "=== Build complete for ${ARCH} ==="
