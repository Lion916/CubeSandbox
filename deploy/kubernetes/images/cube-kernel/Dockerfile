# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Tencent. All rights reserved.
#
# K8s cube-kernel installer image: assembles pre-built guest vmlinux artifacts.
#
# Build context must contain:
#   artifacts/vmlinux-bm          # required
#   artifacts/vmlinux-pvm         # required on amd64; optional on arm64 (no PVM guest)
#   artifacts/vmlinux-kvm         # optional, amd64 only (nested-KVM guest kernel)
#   scripts/component-entrypoint.sh
#
# Example:
#   docker build -f deploy/kubernetes/images/cube-kernel/Dockerfile \
#     -t cube-kernel:TAG /path/to/cube-kernel-ctx
#
# See .github/workflows/release-docker-images.yml and
# deploy/kubernetes/images/build-cube-images.sh.

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ENV IMAGE_ROOT=/opt/cube-image
ENV TOOLBOX_ROOT=/usr/local/services/cubetoolbox
ENV CUBE_COMPONENT=cube-kernel
ENV CUBE_ROLE=install

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      tini \
      util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY artifacts/ /tmp/kernel-artifacts/
COPY scripts/component-entrypoint.sh /usr/local/bin/component-entrypoint.sh

ARG CUBE_VERSION=unknown
ARG CUBE_KERNEL_BM_VERSION=
ARG CUBE_KERNEL_PVM_VERSION=
ARG CUBE_KERNEL_KVM_VERSION=
RUN set -eux; \
    mkdir -p ${IMAGE_ROOT}/cube-kernel-scf; \
    test -f /tmp/kernel-artifacts/vmlinux-bm; \
    cp /tmp/kernel-artifacts/vmlinux-bm ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-bm; \
    ln -sfn vmlinux-bm ${IMAGE_ROOT}/cube-kernel-scf/vmlinux; \
    if [ -f /tmp/kernel-artifacts/vmlinux-pvm ]; then \
      cp /tmp/kernel-artifacts/vmlinux-pvm ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-pvm; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
      echo "skipping vmlinux-pvm on TARGETARCH=${TARGETARCH} (no PVM guest kernel)"; \
    else \
      echo "vmlinux-pvm is required for TARGETARCH=${TARGETARCH:-amd64} cube-kernel images" >&2; \
      exit 1; \
    fi; \
    if [ -f /tmp/kernel-artifacts/vmlinux-kvm ]; then \
      if [ "${TARGETARCH}" != "amd64" ]; then \
        echo "vmlinux-kvm is amd64-only, got TARGETARCH=${TARGETARCH}" >&2; \
        exit 1; \
      fi; \
      cp /tmp/kernel-artifacts/vmlinux-kvm ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-kvm; \
    fi; \
    rm -rf /tmp/kernel-artifacts; \
    BM_TAG="${CUBE_KERNEL_BM_VERSION:-${CUBE_VERSION}}"; \
    PVM_TAG="${CUBE_KERNEL_PVM_VERSION:-${CUBE_VERSION}}"; \
    KVM_TAG="${CUBE_KERNEL_KVM_VERSION:-${BM_TAG}}"; \
    BM_DIGEST="$(sha256sum -- ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-bm | awk '{print $1}')"; \
    test -n "${BM_DIGEST}"; \
    BM_SHORT="sha256-$(printf '%s' "${BM_DIGEST}" | cut -c1-12)"; \
    printf 'sha256:%s\n' "${BM_DIGEST}" > ${IMAGE_ROOT}/cube-kernel-scf/version; \
    { \
      printf '{\n  "schema_version": 1,\n  "variants": {\n'; \
      printf '    "bm": {"version": "%s", "digest_sha256": "sha256:%s", "tag": "%s"}' \
        "${BM_SHORT}" "${BM_DIGEST}" "${BM_TAG}"; \
      if [ -f ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-pvm ]; then \
        PVM_DIGEST="$(sha256sum -- ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-pvm | awk '{print $1}')"; \
        test -n "${PVM_DIGEST}"; \
        PVM_SHORT="sha256-$(printf '%s' "${PVM_DIGEST}" | cut -c1-12)"; \
        printf ',\n    "pvm": {"version": "%s", "digest_sha256": "sha256:%s", "tag": "%s"}' \
          "${PVM_SHORT}" "${PVM_DIGEST}" "${PVM_TAG}"; \
      fi; \
      if [ -f ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-kvm ]; then \
        KVM_DIGEST="$(sha256sum -- ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-kvm | awk '{print $1}')"; \
        test -n "${KVM_DIGEST}"; \
        KVM_SHORT="sha256-$(printf '%s' "${KVM_DIGEST}" | cut -c1-12)"; \
        printf ',\n    "kvm": {"version": "%s", "digest_sha256": "sha256:%s", "tag": "%s"}' \
          "${KVM_SHORT}" "${KVM_DIGEST}" "${KVM_TAG}"; \
      fi; \
      printf '\n  }\n}\n'; \
    } > ${IMAGE_ROOT}/cube-kernel-scf/version.json; \
    chmod +x /usr/local/bin/component-entrypoint.sh; \
    test -f ${IMAGE_ROOT}/cube-kernel-scf/vmlinux-bm; \
    test -L ${IMAGE_ROOT}/cube-kernel-scf/vmlinux

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/component-entrypoint.sh"]
