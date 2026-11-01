# CMake toolchain for cross-compiling NCNN (and anything else under core/)
# for the Steam Frame: aarch64 Linux, targeting glibc 2.17 via zig cc/zig c++
# (see core/toolchains/bin/aarch64-steamframe-clang[++] for why) instead of
# aarch64-linux-gnu-gcc, which would link against this host's own
# (too-new) glibc -- the same problem and fix already used for the main
# fpvr_core GDExtension build (see .vscode/tasks.json, "Core: Build (Linux
# ARM64 - Steam Frame)").
#
# ar/ranlib stay the real aarch64-linux-gnu-* binutils: they only pack/index
# object files, they don't link against target glibc, so the version
# mismatch that motivates the zig cc substitution doesn't apply to them.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

get_filename_component(_fpvr_toolchain_dir "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)

set(CMAKE_C_COMPILER "${_fpvr_toolchain_dir}/bin/aarch64-steamframe-clang")
set(CMAKE_CXX_COMPILER "${_fpvr_toolchain_dir}/bin/aarch64-steamframe-clang++")
set(CMAKE_AR "aarch64-linux-gnu-ar")
set(CMAKE_RANLIB "aarch64-linux-gnu-ranlib")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
