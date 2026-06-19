<p align="center"><img src="https://raw.githubusercontent.com/openweft/brand/main/social/weft-loom-workspace.png" alt="weft-loom-workspace" width="720"></p>

# weft-loom-workspace

The rootfs every weft-loom user's microVM boots into. Not a build
container — this is the long-running guest the user's shell tab
lives in. Tool containers (texlive, marp, pandoc, golang, …) are
pulled by `weft-microvm-agent` on demand inside this rootfs and
`crun exec`'d ; this image only ships the agent + the runtime + the
tool wrappers that delegate into those containers.

License : BSD 3-Clause.

## Artifacts

The CI publishes two flavours of the same rootfs from a single tag :

| artifact | registry / location | consumer |
| --- | --- | --- |
| OCI image | `ghcr.io/openweft/weft-loom-workspace:<tag>` | container runtimes (crun, docker) ; `.github/workflows/build.yml` |
| qcow2 base disk | `ghcr.io/openweft/weft-loom-workspace-base:<tag>` (OCI artifact, mediatype `application/vnd.openweft.workspace.qcow2.image`) + GitHub Release asset | `loom-server` QEMUProvisioner ; `.github/workflows/bake-qcow2.yml` |

Both ship for all 4 archs (`amd64`, `arm64`, `riscv64`, `loong64`)
per the openweft infra-images-4arch directive. Tag-gated — neither
artifact is published on `push:main`.

## qcow2 base disk

`bake-qcow2.sh` converts the published OCI rootfs image into a
bootable qcow2 :

1. Pulls `ghcr.io/openweft/weft-loom-workspace:<tag>` for the
   requested arch (`skopeo copy --override-arch ...`).
2. Flattens the OCI layers into a single rootfs tarball
   (`docker create` + `docker export`, with `umoci` as fallback).
3. Creates an empty 2 GiB qcow2 (`qemu-img create`).
4. Formats it ext4 + extracts the rootfs into it + drops the
   production `/init` (verbatim copy of the validated dev μVM init
   script — virtio_pci/blk/net + 9pnet_virtio modprobe, static IP
   `10.0.2.15/24` gw `10.0.2.2` for QEMU SLIRP, `/dev/vda` mounted
   at `/workspace` with ext4 auto-format on first boot, then exec
   `weft-microvm-agent`). Done via `guestfish` so no root or NBD
   needed.
5. Re-encodes with `qemu-img convert -c -O qcow2` for ~3-5x smaller
   release assets.

The resulting `weft-loom-workspace-<arch>.qcow2` is consumed by
QEMU directly :

```sh
qemu-system-aarch64 \
  -M virt -cpu host -accel kvm -m 2G \
  -kernel /path/to/Image \
  -append "console=ttyAMA0 root=/dev/vda rw weft.vmid=<id> weft.nats=nats://10.0.2.2:4222" \
  -drive file=weft-loom-workspace-arm64.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0,net=10.0.2.0/24 -device virtio-net-pci,netdev=n0
```

## loom-server integration

`weft-loom-server` reads `WEFT_WORKSPACE_BASE_QCOW2` to locate the
base disk. The QEMUProvisioner then clones it per-user via
`qemu-img create -F qcow2 -b <base>` (CoW overlay, ~200 KiB per
user vs 2 GiB base) and boots one instance per user :

```sh
export WEFT_LOOM_WORKSPACE_BACKEND=qemu
export WEFT_WORKSPACE_BASE_QCOW2=/var/lib/weft-loom/weft-loom-workspace-arm64.qcow2
```

The base disk should be fetched once per host — either by hand from
the GitHub Release or by `oras pull
ghcr.io/openweft/weft-loom-workspace-base:<tag>` against the OCI
artifact tag. The OCI artifact form is the recommended path because
the loom-server can pin the digest and verify integrity at pull
time, matching the way it pulls tool container images.

## CHANGELOG

- **v0.5.1** — bake the rootfs into a bootable qcow2 base disk
  (`bake-qcow2.sh` + `.github/workflows/bake-qcow2.yml`). Published
  as a GitHub Release asset and as an OCI artifact
  (`weft-loom-workspace-base:<tag>`, mediatype
  `application/vnd.openweft.workspace.qcow2.image`). Multi-arch
  fan-out across amd64/arm64/riscv64/loong64. Consumed by
  loom-server via `WEFT_WORKSPACE_BASE_QCOW2`.
- **v0.4.0** — initial Alpine-based OCI rootfs : weft-microvm-agent
  pinned + ncl + crun + fuse-overlayfs + tool-wrappers for
  pdflatex/marp/pandoc/go. Multi-arch publish via tag-gated CI.
