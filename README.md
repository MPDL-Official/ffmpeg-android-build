# FFmpeg Android Build

Static FFmpeg binaries for Android, built via GitHub Actions.

Produces standalone `ffmpeg` and `ffprobe` executables that run directly on Android devices — no root, no shared libraries, no app wrapper needed.

## Features

- Fully static binaries, single-file deployment
- minSdkVersion 28 (Android 9.0+)
- GPL + nonfree license configuration
- 4 architectures: `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`
- Automated build & release via GitHub Actions

### Included Libraries

| Library | Purpose |
|---------|---------|
| x264 | H.264 encoder |
| x265 | H.265/HEVC encoder |
| libmp3lame | MP3 encoder |
| libopus | Opus audio codec |
| libvorbis | Vorbis audio codec |
| libvpx | VP8/VP9 codec |
| fdk-aac | AAC encoder (nonfree) |
| dav1d | AV1 decoder |
| libass | ASS/SSA subtitle renderer |
| freetype | Font rendering (libass dep) |
| fribidi | Bidirectional text (libass dep) |
| harfbuzz | Text shaping (libass dep) |

## Download

Pre-built binaries are available on the [Releases](https://github.com/MPDL-Official/ffmpeg-android-build/releases) page.

Each release includes per-architecture tarballs and SHA256 checksums:

```
ffmpeg-android-arm64-v8a.tar.gz
ffmpeg-android-armeabi-v7a.tar.gz
ffmpeg-android-x86_64.tar.gz
ffmpeg-android-x86.tar.gz
```

## Usage

### Via ADB

```bash
# Push to device
adb push ffmpeg /data/local/tmp/
adb shell chmod +x /data/local/tmp/ffmpeg

# Run
adb shell /data/local/tmp/ffmpeg -version
```

### On-device (Termux, etc.)

```bash
chmod +x ffmpeg
./ffmpeg -i input.mp4 -c:v libx264 -crf 23 output.mp4
```

## Build It Yourself

### Trigger via GitHub Actions

1. Go to **Actions** > **Build FFmpeg for Android**
2. Click **Run workflow**
3. Select architecture (or `all`), FFmpeg version tag, and whether to create a release
4. Wait for the build to complete (~30-60 min)

### Workflow Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `arch` | `all` | Target architecture (`all`, `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`) |
| `ffmpeg_version` | `n7.1` | FFmpeg git tag |
| `create_release` | `true` | Create a GitHub Release with the built binaries |

### Local Build

Requires Android NDK r27c and standard build tools (cmake, meson, nasm, ninja, etc.).

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r27c
export API=23
export FFMPEG_VERSION=n7.1

bash scripts/build.sh arm64-v8a
# Output: output/arm64-v8a/ffmpeg, output/arm64-v8a/ffprobe
```

## Project Structure

```
.github/workflows/build.yml  — CI workflow (matrix build, release)
scripts/build.sh              — Build script (deps + FFmpeg)
```

## License

The built FFmpeg binaries are licensed under **GPL v3+** with **nonfree** components (fdk-aac). See [FFmpeg Legal](https://www.ffmpeg.org/legal.html) for details.

This build configuration and scripts are provided as-is under the MIT License.
