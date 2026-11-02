#!/bin/bash
# Cross-compiles NCNN (Vulkan backend) for the Steam Frame (aarch64 Linux,
# glibc 2.17 baseline) using the zig-based toolchain in core/toolchains/.
#
# NCNN links directly against the target's libvulkan.so (Vulkan::Vulkan)
# rather than dlopen-ing it at runtime on this platform, so the linker needs
# *a* aarch64 libvulkan.so to resolve against at build time. The Vulkan
# loader's ABI is the same standardized Khronos interface everywhere -- it
# just dispatches to whatever ICD driver is actually present at runtime --
# so any aarch64 build of it satisfies the cross-linker identically; the
# on-device copy is what actually loads at runtime regardless of which one
# this was linked against.
#
# Two sources, checked in order:
#   1. A pre-staged loader at PRESTAGED_VULKAN_LIB (default
#      /opt/sysroot-arm64/usr/lib/libvulkan.so) -- what the devcontainer
#      image (.devcontainer/Dockerfile) bakes in from Debian's own arm64
#      package, used both for local Dev Container builds and in CI, where
#      there's no device to reach over SSH anyway.
#   2. Fetched live off the headset over SSH (set STEAMFRAME_HOST to
#      override the "steamframe" ssh config alias) -- the original local-dev
#      path, kept for building directly on the host outside the container.
# Either way the fetched/staged copy is link-time only, never committed
# (see .gitignore) or redistributed.
#
# Vulkan headers are architecture-independent C headers, so the host's own
# `vulkan-headers` package (pacman -S vulkan-headers) is used as-is.
set -euo pipefail

STEAMFRAME_HOST="${STEAMFRAME_HOST:-steamframe}"
PRESTAGED_VULKAN_LIB="${PRESTAGED_VULKAN_LIB:-/opt/sysroot-arm64/usr/lib/libvulkan.so}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NCNN_DIR="${CORE_DIR}/ncnn"
SYSROOT_DIR="${CORE_DIR}/toolchains/sysroot-arm64"
BUILD_DIR="${NCNN_DIR}/build-arm64"
TOOLCHAIN_FILE="${CORE_DIR}/toolchains/zig-aarch64-steamframe.toolchain.cmake"

mkdir -p "${SYSROOT_DIR}/usr/lib"
VULKAN_LIB="${SYSROOT_DIR}/usr/lib/libvulkan.so"
if [ ! -e "${VULKAN_LIB}" ]; then
    if [ -e "${PRESTAGED_VULKAN_LIB}" ]; then
        # Symlinked into SYSROOT_DIR (not used from PRESTAGED_VULKAN_LIB
        # in place) because core/SConstruct's own arm64 build *also* links
        # -lvulkan directly, via a LIBPATH pointing at this same
        # core/toolchains/sysroot-arm64/usr/lib -- it has no idea
        # PRESTAGED_VULKAN_LIB exists, so the loader needs to actually be
        # here for that later link step to succeed, not just for NCNN's.
        echo "Using pre-staged target libvulkan.so at ${PRESTAGED_VULKAN_LIB} (link-time only)..."
        ln -sf "${PRESTAGED_VULKAN_LIB}" "${VULKAN_LIB}"
    else
        echo "Fetching target libvulkan.so from ${STEAMFRAME_HOST} (link-time only)..."
        remote_lib="$(ssh "${STEAMFRAME_HOST}" 'readlink -f /usr/lib/libvulkan.so')"
        scp -q "${STEAMFRAME_HOST}:${remote_lib}" "${SYSROOT_DIR}/usr/lib/"
        ln -sf "$(basename "${remote_lib}")" "${VULKAN_LIB}"
    fi
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
