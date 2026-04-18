#!/usr/bin/env bash
set -euo pipefail

# ── Arguments & Globals ──────────────────────────────────────────────
ARCH="${1:?Usage: build.sh <arm64-v8a|armeabi-v7a|x86_64|x86>}"
API="${API:-28}"
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

COMMON_CFLAGS="-fPIC -DANDROID"
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

# ── pkg-config wrapper for cross-compilation ─────────────────────────
# Meson 1.3.x ignores PKG_CONFIG_LIBDIR env and cross-file properties.
# A wrapper script that forces the search path is the only reliable fix.
PKGCONFIG_WRAPPER="${WORKDIR}/pkg-config-cross"
cat > "$PKGCONFIG_WRAPPER" <<WRAPPER
#!/bin/sh
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
exec pkg-config "\$@"
WRAPPER
chmod +x "$PKGCONFIG_WRAPPER"

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
  if [ ! -d "fdk-aac-2.0.2" ]; then
    wget -q "https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v2.0.2.tar.gz" -O fdk-aac-2.0.2.tar.gz
    tar xzf fdk-aac-2.0.2.tar.gz
  fi
  cd fdk-aac-2.0.2

  # Stub out AOSP-internal log/log.h that isn't in the NDK
  mkdir -p stub/log
  cat > stub/log/log.h <<'STUBEOF'
#pragma once
#define ALOG(...)
#define ALOGE(...)
#define ALOGW(...)
#define ALOGI(...)
#define ALOGD(...)
#define ALOGV(...)
#define android_errorWriteLog(...)
STUBEOF

  autoreconf -fiv
  ./configure \
    --prefix="$PREFIX" \
    --host="$TARGET" \
    --enable-static \
    --disable-shared \
    --with-pic \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$COMMON_CFLAGS -I$(pwd)/stub" \
    CXXFLAGS="$COMMON_CFLAGS -I$(pwd)/stub"
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
pkg-config = '${PKGCONFIG_WRAPPER}'

[host_machine]
system = 'android'
cpu_family = '${FFMPEG_ARCH}'
cpu = '${CPU}'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['${PREFIX}/lib/pkgconfig']

[built-in options]
c_args = ['-fPIC', '-DANDROID']
CROSSEOF

  PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig" \
  PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
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

  # Write a clean freetype2.pc — CMake may not generate one, or may
  # reference zlib which has no .pc file in the NDK sysroot.
  mkdir -p "${PREFIX}/lib/pkgconfig"
  cat > "${PREFIX}/lib/pkgconfig/freetype2.pc" <<PCEOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: FreeType 2
Description: A free, high-quality, and portable font engine.
Version: 26.1.20
Requires:
Libs: -L\${libdir} -lfreetype -lz
Cflags: -I\${includedir}/freetype2
PCEOF
  echo ">>> freetype2.pc at: ${PREFIX}/lib/pkgconfig/"
  ls -la "${PREFIX}/lib/pkgconfig/freetype"* 2>/dev/null || true
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
pkg-config = '${PKGCONFIG_WRAPPER}'

[host_machine]
system = 'android'
cpu_family = '${FFMPEG_ARCH}'
cpu = '${CPU}'
endian = 'little'

[properties]
pkg_config_libdir = ['${PREFIX}/lib/pkgconfig']
cmake_prefix_path = ['${PREFIX}']

[built-in options]
c_args = ['-fPIC', '-DANDROID']
CROSSEOF

  PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig" \
  PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
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
  echo ">>> Building harfbuzz (amalgamated source)"
  clone "https://github.com/harfbuzz/harfbuzz.git" harfbuzz 10.1.0
  cd harfbuzz

  # Build using amalgamated source — bypasses meson entirely
  $CXX \
    $COMMON_CFLAGS \
    -O2 -fno-exceptions -fno-rtti \
    -DHB_TINY \
    -DHAVE_FREETYPE \
    -I src \
    -I "${PREFIX}/include/freetype2" \
    -c src/harfbuzz.cc \
    -o harfbuzz.o

  $AR rcs libharfbuzz.a harfbuzz.o
  $RANLIB libharfbuzz.a

  # Install
  mkdir -p "${PREFIX}/lib" "${PREFIX}/include/harfbuzz" "${PREFIX}/lib/pkgconfig"
  cp libharfbuzz.a "${PREFIX}/lib/"
  cp src/hb.h src/hb-*.h "${PREFIX}/include/harfbuzz/"

  # Generate .pc file
  cat > "${PREFIX}/lib/pkgconfig/harfbuzz.pc" <<PCEOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: harfbuzz
Description: HarfBuzz text shaping library
Version: 10.1.0
Libs: -L\${libdir} -lharfbuzz -lfreetype -lz
Cflags: -I\${includedir}/harfbuzz
PCEOF

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
    --disable-libunibreak \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$COMMON_CFLAGS -I${PREFIX}/include -I${PREFIX}/include/freetype2 -I${PREFIX}/include/harfbuzz -I${PREFIX}/include/fribidi" \
    CXXFLAGS="$COMMON_CFLAGS -I${PREFIX}/include" \
    LDFLAGS="$COMMON_LDFLAGS -L${PREFIX}/lib" \
    PKG_CONFIG="${PKGCONFIG_WRAPPER}" \
    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
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

  # Debug: verify pkg-config can find all deps
  echo "--- pkg-config debug ---"
  ls "${PREFIX}/lib/pkgconfig/"
  "${PKGCONFIG_WRAPPER}" --list-all 2>&1 | head -20
  for pkg in x264 x265 libmp3lame opus vorbis vpx fdk-aac dav1d freetype2 fribidi harfbuzz libass; do
    "${PKGCONFIG_WRAPPER}" --exists "$pkg" 2>&1 && echo "  $pkg: OK" || echo "  $pkg: NOT FOUND"
  done
  echo "--- end debug ---"

  EXTRA_CFLAGS="-I${PREFIX}/include $COMMON_CFLAGS"
  EXTRA_LDFLAGS="-L${PREFIX}/lib $COMMON_LDFLAGS"

  # x265 needs -lc++ on Android
  EXTRA_LIBS="-lc++ -lm -ldl"

  PKG_CONFIG="${PKGCONFIG_WRAPPER}" \
  PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
  ./configure \
    --prefix="$PREFIX" \
    --pkg-config="${PKGCONFIG_WRAPPER}" \
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
