#!/bin/bash
# Cross-compiles the fpvr_core GDExtension for the Steam Frame (aarch64
# Linux, glibc 2.17 baseline) via zig cc/zig c++, mirroring the "Core:
# Build (Linux ARM64 - Steam Frame)" VSCode task in ../../.vscode/tasks.json
# exactly -- see that task's comment for why zig (not aarch64-linux-gnu-gcc,
# which links against this host's own too-new glibc) and why 2.17.
#
# Extracted to a script so GitHub Actions (.github/workflows/release.yml)
# runs the identical build instead of re-deriving the shim logic in YAML;
# the VSCode task is left as-is for local interactive use.
#
# Usage: build_core_arm64.sh [template_debug|template_release]
set -euo pipefail

TARGET="${1:-template_debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${CORE_DIR}"

mkdir -p .zig-cache .cross_bin_arm64
for t in ar ranlib ld strip objcopy; do
    ln -sf "$(command -v "aarch64-linux-gnu-$t")" ".cross_bin_arm64/$t"
done

# SCons' use_llvm path hard-codes the compiler names "clang"/"clang++" on
# PATH -- symlinked here to the project's already-committed wrappers
# (toolchains/bin/aarch64-steamframe-clang[++], the same ones the NCNN
# cmake toolchain file uses) instead of re-deriving that zig invocation a
# second time.
ln -sf "${CORE_DIR}/toolchains/bin/aarch64-steamframe-clang" .cross_bin_arm64/clang
ln -sf "${CORE_DIR}/toolchains/bin/aarch64-steamframe-clang++" .cross_bin_arm64/clang++

PATH="${CORE_DIR}/.cross_bin_arm64:${PATH}" scons platform=linux arch=arm64 target="${TARGET}" use_llvm=yes -j"$(nproc)"
