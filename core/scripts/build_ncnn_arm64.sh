#!/bin/bash
# Cross-compiles NCNN (Vulkan backend) for the Steam Frame (aarch64 Linux,
# glibc 2.17 baseline) using the zig-based toolchain in core/toolchains/.
#
# NCNN links directly against the target's libvulkan.so (Vulkan::Vulkan)
# rather than dlopen-ing it at runtime on this platform, so the linker needs
# *a* aarch64 libvulkan.so to resolve against at build time -- this script
# fetches the real one off the headset over SSH (set STEAMFRAME_HOST to
# override the "steamframe" ssh config alias) purely to satisfy that link
# step; the on-device copy is what actually loads at runtime, and the
# fetched copy is never committed (see .gitignore) or redistributed.
#
# Vulkan headers are architecture-independent C headers, so the host's own
# `vulkan-headers` package (pacman -S vulkan-headers) is used as-is.
set -euo pipefail

STEAMFRAME_HOST="${STEAMFRAME_HOST:-steamframe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NCNN_DIR="${CORE_DIR}/ncnn"
SYSROOT_DIR="${CORE_DIR}/toolchains/sysroot-arm64"
BUILD_DIR="${NCNN_DIR}/build-arm64"
TOOLCHAIN_FILE="${CORE_DIR}/toolchains/zig-aarch64-steamframe.toolchain.cmake"

mkdir -p "${SYSROOT_DIR}/usr/lib"
VULKAN_LIB="${SYSROOT_DIR}/usr/lib/libvulkan.so"
if [ ! -e "${VULKAN_LIB}" ]; then
    echo "Fetching target libvulkan.so from ${STEAMFRAME_HOST} (link-time only)..."
    remote_lib="$(ssh "${STEAMFRAME_HOST}" 'readlink -f /usr/lib/libvulkan.so')"
    scp -q "${STEAMFRAME_HOST}:${remote_lib}" "${SYSROOT_DIR}/usr/lib/"
    ln -sf "$(basename "${remote_lib}")" "${VULKAN_LIB}"
fi

VULKAN_INCLUDE_DIR="/usr/include"
if [ ! -f "${VULKAN_INCLUDE_DIR}/vulkan/vulkan.h" ]; then
    echo "Vulkan headers not found at ${VULKAN_INCLUDE_DIR}/vulkan/vulkan.h -- run: sudo pacman -S vulkan-headers" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"
cmake -S "${NCNN_DIR}" -B "${BUILD_DIR}" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DNCNN_VULKAN=ON \
    -DVulkan_INCLUDE_DIR="${VULKAN_INCLUDE_DIR}" \
    -DVulkan_LIBRARY="${VULKAN_LIB}" \
    -DNCNN_SHARED_LIB=OFF \
    -DNCNN_BUILD_TOOLS=OFF \
    -DNCNN_BUILD_EXAMPLES=OFF \
    -DNCNN_BUILD_BENCHMARK=OFF \
    -DNCNN_BUILD_TESTS=OFF \
    -DNCNN_PYTHON=OFF \
    -DNCNN_OPENMP=OFF

cmake --build "${BUILD_DIR}" -j"$(nproc)"

echo "Done: ${BUILD_DIR}/src/libncnn.a"
