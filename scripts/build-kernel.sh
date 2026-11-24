#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Arm ltd. All rights reserved.
#
# Build a guest kernel image from an external kernel source tree.
#
# It supports both native builds (x86_64 or aarch64) and cross builds
# (x86_64 <-> aarch64). The build architecture is taken from
# KERNEL_TARGET_ARCH; the matching ARCH / CROSS_COMPILE values are derived
# automatically (override CROSS_COMPILE via KERNEL_CROSS_COMPILE).
#
# The kernel is built out-of-tree (O=) so KERNEL_SRC_DIR is left untouched.
#
# Required environment:
#   KERNEL_SRC_DIR      Path to the Linux kernel source tree.
#   KERNEL_CONFIG       Path to the kernel .config to build with.
#   KERNEL_OUTPUT_DIR   Out-of-tree build directory; image is written here.
# Optional environment:
#   KERNEL_TARGET_ARCH  x86_64 | aarch64 (default: host arch).
#   KERNEL_FRAGMENT     Optional Kconfig fragment merged on top of KERNEL_CONFIG
#                       (e.g. configs/kernel-oc9.x86_64-kvm.fragment). Merged with the
#                       kernel tree's scripts/kconfig/merge_config.sh.
#   KERNEL_CROSS_COMPILE  Cross-compiler prefix override (default: auto).
#   KERNEL_BUILD_JOBS   Parallel jobs (default: 4).

set -euo pipefail

err() { echo "ERROR: $*" >&2; exit 1; }

KERNEL_SRC_DIR="${KERNEL_SRC_DIR:-}"
KERNEL_CONFIG="${KERNEL_CONFIG:-}"
KERNEL_FRAGMENT="${KERNEL_FRAGMENT:-}"
KERNEL_OUTPUT_DIR="${KERNEL_OUTPUT_DIR:-}"
KERNEL_TARGET_ARCH="${KERNEL_TARGET_ARCH:-$(uname -m | sed 's/^arm64$/aarch64/')}"
KERNEL_CROSS_COMPILE="${KERNEL_CROSS_COMPILE:-}"
KERNEL_BUILD_JOBS="${KERNEL_BUILD_JOBS:-4}"

[ -n "${KERNEL_SRC_DIR}" ]    || err "KERNEL_SRC_DIR is not set"
[ -d "${KERNEL_SRC_DIR}" ]    || err "KERNEL_SRC_DIR '${KERNEL_SRC_DIR}' is not a directory"
[ -n "${KERNEL_CONFIG}" ]     || err "KERNEL_CONFIG is not set"
[ -f "${KERNEL_CONFIG}" ]     || err "kernel config not found: ${KERNEL_CONFIG}"
[ -n "${KERNEL_OUTPUT_DIR}" ] || err "KERNEL_OUTPUT_DIR is not set"

MERGE_CONFIG="${KERNEL_SRC_DIR}/scripts/kconfig/merge_config.sh"
if [ -n "${KERNEL_FRAGMENT}" ]; then
  [ -f "${KERNEL_FRAGMENT}" ] || err "kernel fragment not found: ${KERNEL_FRAGMENT}"
  [ -f "${MERGE_CONFIG}" ] || err "merge_config.sh not found in kernel source: ${MERGE_CONFIG}"
fi

host_arch="$(uname -m | sed 's/^arm64$/aarch64/')"

case "${KERNEL_TARGET_ARCH}" in
  x86_64)  kbuild_arch=x86;   cross_triple=x86_64-linux-gnu ; KERNEL_IMAGE_TARGET=vmlinux ;;
  aarch64) kbuild_arch=arm64; cross_triple=aarch64-linux-gnu ; KERNEL_IMAGE_TARGET=Image ;;
  *) err "unsupported KERNEL_TARGET_ARCH '${KERNEL_TARGET_ARCH}' (expected x86_64 or aarch64)" ;;
esac

cross_compile="${KERNEL_CROSS_COMPILE}"
if [ -z "${cross_compile}" ] && [ "${host_arch}" != "${KERNEL_TARGET_ARCH}" ]; then
  cross_compile="${cross_triple}-"
fi

if [ -n "${cross_compile}" ]; then
  command -v "${cross_compile}gcc" >/dev/null 2>&1 \
    || err "cross compiler '${cross_compile}gcc' not found in PATH; the builder image must provide the ${cross_triple} toolchain for ${host_arch} -> ${KERNEL_TARGET_ARCH} builds"
fi

mkdir -p "${KERNEL_OUTPUT_DIR}"

echo "[kernel] host=${host_arch} target=${KERNEL_TARGET_ARCH} ARCH=${kbuild_arch} CROSS_COMPILE=${cross_compile:-<native>} jobs=${KERNEL_BUILD_JOBS}"
echo "[kernel] src=${KERNEL_SRC_DIR} config=${KERNEL_CONFIG} out=${KERNEL_OUTPUT_DIR}"
if [ -n "${KERNEL_FRAGMENT}" ]; then
  echo "[kernel] fragment=${KERNEL_FRAGMENT}"
fi

if [ -n "${KERNEL_FRAGMENT}" ]; then
  echo "[kernel] merging fragment ${KERNEL_FRAGMENT} on top of ${KERNEL_CONFIG}"
  bash "${MERGE_CONFIG}" -m -O "${KERNEL_OUTPUT_DIR}" \
    "${KERNEL_CONFIG}" "${KERNEL_FRAGMENT}"
else
  install -m 0644 "${KERNEL_CONFIG}" "${KERNEL_OUTPUT_DIR}/.config"
fi

make -C "${KERNEL_SRC_DIR}" O="${KERNEL_OUTPUT_DIR}" \
  ARCH="${kbuild_arch}" CROSS_COMPILE="${cross_compile}" olddefconfig

make -C "${KERNEL_SRC_DIR}" O="${KERNEL_OUTPUT_DIR}" \
  ARCH="${kbuild_arch}" CROSS_COMPILE="${cross_compile}" \
  -j"${KERNEL_BUILD_JOBS}" "${KERNEL_IMAGE_TARGET}"

[ -f "${KERNEL_OUTPUT_DIR}/vmlinux" ] || err "build did not produce ${KERNEL_OUTPUT_DIR}/vmlinux"

# Copy image for aarch64 to destination as vmlinux for deploy scripts to consume
[ "$KERNEL_TARGET_ARCH" = "aarch64" ] && [ -f "${KERNEL_OUTPUT_DIR}/arch/arm64/boot/Image" ] && cp ${KERNEL_OUTPUT_DIR}/arch/arm64/boot/Image ${KERNEL_OUTPUT_DIR}/vmlinux
echo "[kernel] done: ${KERNEL_OUTPUT_DIR}/vmlinux"
