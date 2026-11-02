# Toolchain for building FPVR: the Godot editor (to export the project) and
# the zig-based ARM64/glibc2.17 cross-compile chain for core/ (see
# core/toolchains/ and core/scripts/build_ncnn_arm64.sh for why zig, not
# aarch64-linux-gnu-gcc, is what actually builds for the Steam Frame --
# linking against this host's own newer glibc produced a binary that
# failed to dlopen on real hardware with "GLIBC_2.43 not found").
#
# Used two ways: as a local VSCode Dev Container (see devcontainer.json,
# same image, interactive use) and as the GitHub Actions release build
# environment (.github/workflows/release.yml) -- one definition for both,
# so "builds on my machine" and "builds in CI" are the same claim.
#
# Pinned versions throughout (Zig 0.17.0, Godot 4.7.2) to match what this
# project has actually been built and tested with all along, not
# "whatever's current" at image-build time.

FROM debian:bookworm-slim

ARG ZIG_VERSION=0.17.0
ARG GODOT_VERSION=4.7.2-stable
ARG GODOT_VERSION_DOTTED=4.7.2.stable

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        ca-certificates \
        curl \
        xz-utils \
        unzip \
        zip \
        python3 \
        python3-pip \
        scons \
        cmake \
        pkg-config \
        libvulkan-dev \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

# zig -- the ARM64/glibc2.17 cross-compiler itself (see core/toolchains/).
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

# Godot editor (headless-capable) + export templates -- needed to run
# `godot --headless --export-debug` the exact same way every local build
# in this project's history has. Installed to the standard locations
# Godot itself expects (~/.local/share/godot/export_templates/<version>/),
# not a project-local path, so `godot --export-debug` finds them with no
# extra flags.
RUN curl -fsSL "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" -o /tmp/godot.zip \
    && unzip -q /tmp/godot.zip -d /tmp/godot \
    && mv /tmp/godot/Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm -rf /tmp/godot.zip /tmp/godot

RUN curl -fsSL "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_export_templates.tpz" -o /tmp/templates.tpz \
    && mkdir -p "/root/.local/share/godot/export_templates/${GODOT_VERSION_DOTTED}" \
    && unzip -q /tmp/templates.tpz -d /tmp/templates \
    && mv /tmp/templates/templates/* "/root/.local/share/godot/export_templates/${GODOT_VERSION_DOTTED}/" \
    && rm -rf /tmp/templates.tpz /tmp/templates

# The real target device's ARM64 Vulkan *loader* (libvulkan.so.1) is what
# core/scripts/build_ncnn_arm64.sh fetches live over SSH for local dev --
# not available/appropriate in CI (no device reachable, and it's not ours
# to bake into an image regardless). The Vulkan loader's ABI is the same
# standardized Khronos interface for any device though (that's the whole
# point of a loader -- it dispatches to whatever ICD driver is actually
# present at *runtime*, completely separately from this), so any aarch64
# build of it satisfies the cross-linker identically. Pulled here from
# Debian's own arm64 package without installing arm64 packages onto this
# (x86_64) image -- `apt-get download` just fetches the .deb.
RUN dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get download libvulkan1:arm64 \
    && mkdir -p /opt/sysroot-arm64/usr/lib \
    && dpkg -x libvulkan1_*_arm64.deb /tmp/libvulkan-extract \
    && find /tmp/libvulkan-extract -name 'libvulkan.so*' -exec cp -P {} /opt/sysroot-arm64/usr/lib/ \; \
    && ln -sf libvulkan.so.1 /opt/sysroot-arm64/usr/lib/libvulkan.so \
    && rm -rf /tmp/libvulkan-extract libvulkan1_*_arm64.deb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
