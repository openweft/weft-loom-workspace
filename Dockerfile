# weft-loom-workspace — the rootfs every loom user's microVM boots
# into. NOT a build container ; this is the long-running guest the
# user's shell tab lives in. Tool containers (texlive, markdown,
# golang, …) get pulled by weft-microvm-agent on demand and
# `crun exec` runs them ; this rootfs only needs the agent + the
# runtime + the tool wrappers that delegate into the containers.
#
# Build args :
#   AGENT_VERSION : weft-microvm-agent version pinned at image build
#                   time. Bump in CI when the agent ships a new
#                   release ; the image tag tracks the agent tag
#                   1:1 so a `v0.4.2` image matches `v0.4.2` agent.
#
# Multi-arch via buildx + qemu-binfmt (4 archs : amd64, arm64,
# riscv64, loong64) per the openweft infra-images-4arch directive.

ARG AGENT_VERSION=v0.4.0
ARG ALPINE_VERSION=3.20

FROM alpine:${ALPINE_VERSION} AS base
# Runtime deps :
#   bash         — the shell users get when they click the Shell tab
#   coreutils    — bash builtin fallbacks (printf is in busybox but
#                  date / readlink behave more like GNU)
#   crun         — OCI runtime for the on-demand tool containers
#   ncl          — the openweft container layout puller / unpacker
#                  (weft-microvm-init's pkg/imagestore + cmd/ncl)
#   fuse3 + fuse-overlayfs — crun's preferred overlay driver inside
#                  the guest (no kernel overlayfs in standard alpine)
#   ca-certificates — TLS verification for OCI registry pulls
#   tini         — pid 1 forwarder so crun-spawned procs reap cleanly
#   musl-locales — wide-locale support for texlive output
RUN apk add --no-cache \
        bash coreutils ca-certificates tini \
        crun fuse3 fuse-overlayfs musl-locales \
        curl

FROM base AS workspace
# Drop the agent + ncl binaries pre-built upstream into PATH. CI
# downloads them from the corresponding tag release of weft-microvm-
# agent + weft-microvm-init before the Dockerfile build runs ;
# tracked in .github/workflows/build.yml.
COPY --chmod=0755 binaries/weft-microvm-agent /usr/local/bin/
COPY --chmod=0755 binaries/ncl                /usr/local/bin/

# Tool wrappers : every supported compiler / interpreter has a tiny
# shell script under /usr/local/bin that delegates to `crun exec
# <container>` against the matching workload container. The user's
# shell sees `pdflatex main.tex` and the wrapper turns it into a
# crun exec on the texlive container that the containers reconciler
# keeps warm. Same model `kubectl exec` uses for in-cluster shells.
COPY --chmod=0755 tool-wrappers/* /usr/local/bin/

# Workspace mount point. The agent mounts the user's CubeFS share
# here at boot (or, in QEMU/virtio-9p dev mode, the host bind).
# Containers see /workspace at the same path via container mounts
# in the WorkloadContainer.Mounts list.
WORKDIR /workspace
RUN mkdir -p /workspace && chmod 0755 /workspace

# tini reaps zombies left behind by crun-spawned procs ; the agent
# is the long-running pid the user's shell tab attaches to.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/weft-microvm-agent", "--workspace"]

LABEL org.opencontainers.image.source="https://github.com/openweft/weft-loom-workspace"
LABEL org.opencontainers.image.description="Per-user workspace rootfs for weft-loom microVMs"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"
