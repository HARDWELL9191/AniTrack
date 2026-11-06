#!/usr/bin/env bash
# Linux x86_64 build dependencies for JellyReco (run on Ubuntu 24.04, as in CI):
#  - FFmpeg 8 (BtbN's GPL shared build: every codec, plus VA-API, NVDEC/CUDA, Vulkan and QSV
#    decoders) and libmpv 0.41 built against it, installed to $PREFIX and registered with ldconfig,
#    so the app links libmpv and the AppImage bundler copies it with everything it needs.
#  - The on-device AI: ONNX Runtime (CPU, uses AVX2/AVX-512 where the CPU has them) plus its WebGPU
#    plugin (any Vulkan GPU: AMD, Intel, Nvidia), Intel's OpenVINO plugin in ai/openvino (Core Ultra
#    NPU, with Intel's NPU driver installed), and the bge-small model with fixed shapes.
# Writes FFMPEG_BIN (for the playback check) to $GITHUB_ENV when that's set.
set -euo pipefail
# A failure shows up as an annotation on the run, with the line and the command.
trap 'echo "::error title=prepare_deps_linux.sh::line $LINENO: $BASH_COMMAND (exit $?)"' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"
PREFIX="${PREFIX:-/opt/jellyreco-mpv}"
WORK="${WORK:-${RUNNER_TEMP:-/tmp}/jellyreco-deps}"
MPV_TAG="v0.41.0"
FFMPEG_SERIES="${FFMPEG_SERIES:-8}"
ORT_VERSION="1.31.1"
WEBGPU_EP_VERSION="0.5.0"
OPENVINO_EP_VERSION="1.8.1"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
mkdir -p "$WORK"

echo "::group::Build tools and libraries for libmpv"
$SUDO apt-get update -qq
$SUDO apt-get install -y --no-install-recommends \
  build-essential meson ninja-build pkg-config nasm git curl xz-utils python3-pip python3-venv patchelf file \
  libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev libsoup-3.0-dev \
  libplacebo-dev libass-dev libfreetype-dev libfribidi-dev libharfbuzz-dev libfontconfig-dev \
  libx11-dev libxext-dev libxinerama-dev libxrandr-dev libxss-dev libxpresent-dev libxkbcommon-dev \
  libwayland-dev wayland-protocols libegl-dev libgl-dev libgbm-dev libdrm-dev libva-dev libvdpau-dev libvulkan-dev \
  libpulse-dev libasound2-dev libpipewire-0.3-dev libjpeg-dev zlib1g-dev libuchardet-dev liblcms2-dev libzimg-dev \
  libbluray-dev libarchive-dev libdvdnav-dev librubberband-dev libsecret-1-dev \
  libfuse2t64 xvfb xauth x11-utils imagemagick \
  ocl-icd-libopencl1
echo "::endgroup::"

echo "::group::FFmpeg $FFMPEG_SERIES (BtbN, GPL, shared)"
# The newest release in the series from BtbN's "latest" release, e.g.
# ffmpeg-n8.0-latest-linux64-gpl-shared-8.0.tar.xz.
api="https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest"
auth=(); [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
name="$( (curl -fsSL "${auth[@]}" "$api" || echo '{"assets": []}') | python3 -c "
import json, re, sys
names = [a['name'] for a in json.load(sys.stdin).get('assets', [])]
pat = re.compile(r'ffmpeg-n${FFMPEG_SERIES}\.(\d+)-latest-linux64-gpl-shared-${FFMPEG_SERIES}\.\d+\.tar\.xz$')
best = sorted((int(m.group(1)), n) for n in names if (m := pat.match(n)))
print(best[-1][1] if best else '')")"
# Without the API (rate limits): the newest minor version that downloads.
if [ -z "$name" ]; then
  for minor in 9 8 7 6 5 4 3 2 1 0; do
    try="ffmpeg-n$FFMPEG_SERIES.$minor-latest-linux64-gpl-shared-$FFMPEG_SERIES.$minor.tar.xz"
    if curl -fsSL -r 0-0 -o /dev/null "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$try"; then name="$try"; break; fi
  done
fi
[ -n "$name" ] || { echo "::error::No FFmpeg $FFMPEG_SERIES.x linux64 gpl-shared build in BtbN's latest release"; exit 1; }
echo "Using $name"
curl -fsSL "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$name" -o "$WORK/ffmpeg.tar.xz"
rm -rf "$WORK/ffmpeg" && mkdir -p "$WORK/ffmpeg"
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK/ffmpeg" --strip-components=1
$SUDO mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/bin"
$SUDO cp -a "$WORK/ffmpeg/lib/"*.so* "$PREFIX/lib/"
$SUDO cp -a "$WORK/ffmpeg/include/"* "$PREFIX/include/"
$SUDO cp -a "$WORK/ffmpeg/bin/ffmpeg" "$WORK/ffmpeg/bin/ffprobe" "$PREFIX/bin/"
for pc in "$WORK/ffmpeg/lib/pkgconfig/"*.pc; do
  sed -e "s|^prefix=.*|prefix=$PREFIX|" "$pc" | $SUDO tee "$PREFIX/lib/pkgconfig/$(basename "$pc")" > /dev/null
done
echo "$PREFIX/lib" | $SUDO tee /etc/ld.so.conf.d/jellyreco-mpv.conf > /dev/null
$SUDO ldconfig
"$PREFIX/bin/ffmpeg" -hide_banner -version > "$WORK/ffmpeg-version.txt"
sed -n 1p "$WORK/ffmpeg-version.txt"
echo "::endgroup::"

echo "::group::libmpv $MPV_TAG"
rm -rf "$WORK/mpv"
git clone -q --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv "$WORK/mpv"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
(
  cd "$WORK/mpv"
  meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release -Db_lto=false \
    -Dlibmpv=true -Dcplayer=false -Dtests=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
    -Dlua=disabled -Djavascript=disabled -Dcdda=disabled \
    -Dgl=enabled -Degl=enabled -Dwayland=enabled -Dx11=enabled -Dvaapi=enabled -Dvulkan=enabled \
    -Dpulse=enabled -Dalsa=enabled -Dpipewire=enabled -Duchardet=enabled -Dlcms2=enabled -Dzimg=enabled -Drubberband=enabled \
    -Dlibbluray=enabled -Dlibarchive=enabled -Ddvdnav=enabled
  meson compile -C build
  $SUDO meson install -C build --quiet
)
$SUDO ldconfig
ls -la "$PREFIX/lib/libmpv.so"*
echo "::endgroup::"

echo "::group::On-device AI (ONNX Runtime $ORT_VERSION + WebGPU plugin $WEBGPU_EP_VERSION + OpenVINO plugin $OPENVINO_EP_VERSION, bge-small)"
AI="$APP/src-tauri/resources/ai"
mkdir -p "$AI" "$WORK/wheels"
python3 -m pip download --no-deps --only-binary=:all: --platform manylinux_2_28_x86_64 --python-version 3.12 \
  -d "$WORK/wheels" "onnxruntime==$ORT_VERSION" "onnxruntime-ep-webgpu==$WEBGPU_EP_VERSION" "onnxruntime-ep-openvino==$OPENVINO_EP_VERSION"
rm -rf "$WORK/ort" "$WORK/webgpu" "$WORK/openvino"
python3 -I -m zipfile -e "$WORK/wheels/onnxruntime-$ORT_VERSION-cp312-cp312-manylinux_2_28_x86_64.whl" "$WORK/ort"
python3 -I -m zipfile -e "$WORK/wheels/onnxruntime_ep_webgpu-$WEBGPU_EP_VERSION-py3-none-manylinux_2_28_x86_64.whl" "$WORK/webgpu"
cp "$WORK/ort/onnxruntime/capi/libonnxruntime.so.$ORT_VERSION" "$AI/libonnxruntime.so"
cp "$WORK/ort/onnxruntime/capi/libonnxruntime_providers_shared.so" "$AI/"
cp "$WORK/webgpu/onnxruntime_ep_webgpu/libonnxruntime_providers_webgpu.so" "$AI/"
cp "$WORK/webgpu/onnxruntime_ep_webgpu-$WEBGPU_EP_VERSION.dist-info/licenses/ThirdPartyNotices.txt" "$AI/WebGPU_ThirdPartyNotices.txt"
# OpenVINO: the plugin and its runtime as Intel ships them (they find each other through $ORIGIN);
# the plugin's two versioned copies (.so.1, .so.1.x.y) are the same file and aren't needed.
python3 -I -m zipfile -e "$WORK/wheels/onnxruntime_ep_openvino-$OPENVINO_EP_VERSION-py3-none-manylinux_2_28_x86_64.whl" "$WORK/openvino"
rm -rf "$AI/openvino" && mkdir -p "$AI/openvino"
find "$WORK/openvino/onnxruntime_ep_openvino" -maxdepth 1 -type f ! -name "*.py" ! -name "libonnxruntime_providers_openvino_plugin.so.*" -exec cp {} "$AI/openvino/" \;
[ -f "$AI/openvino/libonnxruntime_providers_openvino_plugin.so" ] && [ -f "$AI/openvino/libopenvino_intel_npu_plugin.so" ] || { echo "::error::OpenVINO plugin files missing"; exit 1; }
# The AppImage bundler stops at any library whose dependencies it can't find: name them here instead.
# (OpenVINO's GPU plugin needs the OpenCL loader, libOpenCL.so.1, installed above; like Vulkan's
# loader it only finds the PC's own driver.)
missing=""
for so in $(find "$AI" -name "*.so*" -type f); do
  m=$(LD_LIBRARY_PATH="$AI:$AI/openvino" ldd "$so" 2>/dev/null | grep "not found" || true)
  [ -n "$m" ] && missing="$missing $(basename "$so"):$(echo "$m" | awk '{print $1}' | tr '\n' ' ')"
done
[ -z "$missing" ] || { echo "::error::AI libraries with dependencies the build machine doesn't have:$missing"; exit 1; }
MODEL="https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main"
curl -fsSL "$MODEL/onnx/model.onnx" -o "$AI/model.onnx"
curl -fsSL "$MODEL/vocab.txt" -o "$AI/vocab.txt"
# onnx in its own environment (python3 -I doesn't see packages pip put in the user's folder).
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet onnx
"$WORK/venv/bin/python" -I "$HERE/static_shapes.py" "$AI/model.onnx" 128
ls -la "$AI"
echo "::endgroup::"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "FFMPEG_BIN=$PREFIX/bin/ffmpeg" >> "$GITHUB_ENV"
  echo "MPV_PREFIX=$PREFIX" >> "$GITHUB_ENV"
  echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
fi
