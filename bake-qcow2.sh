#!/usr/bin/env bash
# bake-qcow2.sh — turn the published OCI rootfs image into a bootable
# qcow2 that QEMU's `-drive file=...,if=virtio` consumes directly.
#
# Output : weft-loom-workspace-<arch>.qcow2 — ext4 filesystem holding
# the unpacked rootfs of ghcr.io/openweft/weft-loom-workspace:<tag>
# plus a working /init that loads virtio drivers, configures SLIRP
# networking (10.0.2.15/24 gw 10.0.2.2), mounts /dev/vda at /workspace
# (ext4 auto-format on first boot), and execs weft-microvm-agent.
#
# This is the V0.5.1 deliverable so the loom-server QEMUProvisioner
# can pull `ghcr.io/openweft/weft-loom-workspace-base:<tag>` instead
# of operators having to bake their own per host.
#
# Requirements (CI = ubuntu-latest, see .github/workflows/bake-qcow2.yml):
#   - skopeo (oci pull)
#   - qemu-utils (qemu-img)
#   - libguestfs-tools (guestfish — formats + extracts as non-root)
#
# Multi-arch : driven by the IMAGE_ARCH env var. We pull the matching
# manifest variant from the multi-arch index and bake one qcow2 per
# arch ; CI fans this out across amd64/arm64/riscv64/loong64.
#
# Copyright (c) openweft contributors. BSD 3-Clause.
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-ghcr.io/openweft/weft-loom-workspace:latest}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"        # amd64 | arm64 | riscv64 | loong64
QCOW2_SIZE="${QCOW2_SIZE:-2G}"
OUT_DIR="${OUT_DIR:-$(pwd)/dist}"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t weft-loom-bake-XXXXXX)}"
OUT_QCOW2="${OUT_DIR}/weft-loom-workspace-${IMAGE_ARCH}.qcow2"

log() { printf '[bake] %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "bake: required tool not in PATH: $1" >&2
    exit 1
  }
}

require skopeo
require qemu-img
require guestfish
require tar

mkdir -p "$OUT_DIR" "$WORK_DIR"
log "IMAGE_REF=$IMAGE_REF IMAGE_ARCH=$IMAGE_ARCH SIZE=$QCOW2_SIZE"
log "WORK_DIR=$WORK_DIR OUT=$OUT_QCOW2"

# ------------------------------------------------------------------
# 1. Pull the OCI image (single arch from the multi-arch index) into
#    a local OCI layout, then flatten it to a single rootfs tarball.
# ------------------------------------------------------------------
OCI_DIR="${WORK_DIR}/oci"
ROOTFS_TAR="${WORK_DIR}/rootfs.tar"
ROOTFS_DIR="${WORK_DIR}/rootfs"

log "skopeo copy → $OCI_DIR"
skopeo copy --override-arch "$IMAGE_ARCH" --override-os linux \
  "docker://${IMAGE_REF}" "oci:${OCI_DIR}:img"

# Flatten the layers into one tarball using a throwaway docker
# container if available, otherwise use umoci. CI's ubuntu-latest
# has docker so prefer that — fewer moving parts.
if command -v docker >/dev/null 2>&1; then
  log "docker create + export to flatten layers"
  # Load the OCI layout into the local daemon first.
  skopeo copy "oci:${OCI_DIR}:img" "docker-daemon:weft-loom-workspace-bake:${IMAGE_ARCH}"
  CID="$(docker create --platform "linux/${IMAGE_ARCH}" "weft-loom-workspace-bake:${IMAGE_ARCH}")"
  trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
  docker export "$CID" -o "$ROOTFS_TAR"
elif command -v umoci >/dev/null 2>&1; then
  log "umoci unpack to flatten layers"
  umoci unpack --rootless --image "${OCI_DIR}:img" "${WORK_DIR}/bundle"
  tar -C "${WORK_DIR}/bundle/rootfs" -cf "$ROOTFS_TAR" .
else
  echo "bake: need docker or umoci to flatten OCI layers" >&2
  exit 1
fi

log "rootfs tarball : $(du -sh "$ROOTFS_TAR" | cut -f1)"

# ------------------------------------------------------------------
# 2. Drop the production /init alongside the rootfs. We re-create the
#    canonical script verbatim here so the bake is self-contained —
#    no external file path lookup, no drift between dev-baked and
#    CI-baked artifacts. Keep in sync with /tmp/weft-loom-workspace-
#    build/alpine-initramfs/init (the validated dev μVM init).
# ------------------------------------------------------------------
INIT_SRC="${WORK_DIR}/init"
cat > "$INIT_SRC" <<'INIT_EOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mkdir -p /workspace /run /dev/pts
mount -t devpts devpts /dev/pts

NATS_URL=""
VMID=""
for kv in $(cat /proc/cmdline); do
  case "$kv" in
    weft.nats=*) NATS_URL="${kv#weft.nats=}" ;;
    weft.vmid=*) VMID="${kv#weft.vmid=}" ;;
  esac
done

# Load virtio drivers : net + blk + 9p (9p kept as fallback).
modprobe virtio_pci 2>&1
modprobe virtio_blk 2>&1 && echo "init: virtio_blk loaded"
modprobe virtio_net 2>&1 && echo "init: virtio_net loaded"
modprobe ext4 2>&1
modprobe 9pnet_virtio 2>&1
sleep 1

# Network
ifconfig lo up
IF=$(ls /sys/class/net/ | grep -v '^lo$' | head -1)
if [ -n "$IF" ]; then
  ifconfig "$IF" 10.0.2.15 netmask 255.255.255.0 up
  route add default gw 10.0.2.2
  echo "init: $IF up @ 10.0.2.15 gw 10.0.2.2"
fi

# /workspace from virtio-blk (per-user CoW qcow2). Format on first
# boot if not yet — the per-user overlay sees the base as raw bytes
# and ext4 magic gives away whether it's been initialised.
if [ -b /dev/vda ]; then
  if ! /sbin/blkid /dev/vda 2>/dev/null | grep -q ext4; then
    echo "init: formatting /dev/vda as ext4 (first boot)"
    /sbin/mke2fs -t ext4 -F /dev/vda 2>&1 | tail -3
  fi
  mount -t ext4 /dev/vda /workspace && echo "init: /workspace mounted from /dev/vda (persistent CoW)"
else
  mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 workspace /workspace 2>/dev/null && echo "init: /workspace mounted from 9p (fallback)"
fi

echo "init: launching agent vmid=$VMID nats=$NATS_URL"
exec /usr/local/bin/weft-microvm-agent --exec-vm-id="$VMID" --nats-url="$NATS_URL" --listen="127.0.0.1:51999" --metrics-addr=""
INIT_EOF
chmod 0755 "$INIT_SRC"

# ------------------------------------------------------------------
# 3. Create the empty qcow2, then use guestfish to format ext4 +
#    extract the rootfs tarball + drop /init. guestfish is the
#    standard libguestfs frontend for this : it spawns a tiny qemu
#    appliance under the hood so we don't need root or NBD.
# ------------------------------------------------------------------
RAW_QCOW2="${WORK_DIR}/raw.qcow2"
log "qemu-img create $RAW_QCOW2 $QCOW2_SIZE"
qemu-img create -f qcow2 "$RAW_QCOW2" "$QCOW2_SIZE"

log "guestfish : mkfs ext4 + tar-in rootfs + drop /init"
# Newer guestfish lets us pipe everything in one session — single
# appliance boot, much faster than command-per-call.
guestfish --rw -a "$RAW_QCOW2" <<GUESTFISH_EOF
run
part-disk /dev/sda mbr
mkfs ext4 /dev/sda1
mount /dev/sda1 /
tar-in $ROOTFS_TAR /
upload $INIT_SRC /init
chmod 0755 /init
GUESTFISH_EOF

# ------------------------------------------------------------------
# 4. Re-encode with compression so the GitHub Release asset stays
#    small. qemu-img convert with -c + -O qcow2 keeps the disk
#    bootable while shrinking it 3-5x.
# ------------------------------------------------------------------
log "qemu-img convert -c -O qcow2 → $OUT_QCOW2"
qemu-img convert -c -O qcow2 "$RAW_QCOW2" "$OUT_QCOW2"
qemu-img info "$OUT_QCOW2" >&2

log "done. artifact : $OUT_QCOW2 ($(du -sh "$OUT_QCOW2" | cut -f1))"
