# VirtuaOS Kernel

Kernel project for VirtuaOS hypervisor hosts.

The `virtua` profile targets KVM/QEMU, LXC, Docker, VirtIO, VFIO/IOMMU,
virtual networking, storage and DKMS-based OpenZFS support. Its main packages
are `kernel-virtua` and `linux-image-*-auxinux-virtua-*`.

VirtuaOS consumes this kernel through the AuxiNux APT repository.

Build and repository entry points:

```bash
./build-virtua-kernel.sh
sudo GPG_KEY=repo@auxinux.ca ./build-depot-kernel.sh ./output
```

This repository accepts only the `virtua` profile and currently publishes
amd64 packages.

## OpenZFS

ZFS support is shipped as a **DKMS source package** (`openzfs-zfs-dkms`,
arch `all`), not as a module precompiled against a specific kernel build.

This is the same choice Debian's own `zfs-dkms` makes, as opposed to
Ubuntu's precompiled `zfs-modules-<kernel>` / kmod approach. The reason is
licensing, not convenience: Linux is GPL-2.0 and OpenZFS is CDDL, and the two
licenses are considered incompatible by the Linux kernel maintainers and the
FSF. Shipping a **binary** kernel module built by linking OpenZFS object code
against a specific kernel tree distributes a combined GPL/CDDL binary — a
legal grey area most distributions avoid entirely. Ubuntu accepts that risk
under its own legal reading; this project does not.

With DKMS, the package instead ships OpenZFS **source code**. The module is
compiled locally, on the target machine, against whatever kernel is actually
installed there, at install/upgrade time — no combined binary ever leaves
this build pipeline or gets published to the repository.

Practical implication: `linux-headers-<release>` **must** be present in the
repository alongside the kernel image whenever `openzfs-zfs-dkms` is
published, or DKMS will silently fail to build the module on install.
`build-depot-kernel.sh` enforces this and refuses to generate the meta
package otherwise.

## Publication tracks: prod and dev

The repository publishes two independent channels from the same scripts and the
same signing key. They share nothing else — separate kernel suffixes, package
names, build directories, package directories and APT suites:

| Track | Kernel release | Meta package | APT suite | Repo directory |
|---|---|---|---|---|
| `prod` | `X.Y.Z-auxinux-virtua-amd64` | `kernel-virtua` | `kernel` | `KERNEL/` |
| `dev` | `X.Y.Z-DEV-auxinux-virtua-amd64` | `kernel-virtua-dev` | `kernel-dev` | `KERNEL-DEV/` |

A production host enables only the `kernel` suite, so it can never be offered a
DEV kernel — the two channels do not share a package name.

```bash
# Production
./build-virtua-kernel.sh KERNEL_VERSION=7.1.12
sudo GPG_KEY=repo@auxinux.ca ./build-depot-kernel.sh /tmp/virtua-kernel

# Test / DEV
./build-virtua-kernel.sh track=dev KERNEL_VERSION=7.2.2
sudo RELEASE_TRACK=dev GPG_KEY=repo@auxinux.ca ./build-depot-kernel.sh /tmp/virtua-kernel-dev
```

Client configuration:

```bash
sudo wget -O /usr/share/keyrings/virtua-archive-keyring.gpg \
  https://dep.auxinux.ca/VIRTUA/virtua-archive-keyring.gpg

# production hosts
echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=amd64] https://dep.auxinux.ca/VIRTUA kernel main' \
  | sudo tee /etc/apt/sources.list.d/virtua-kernel-prod.list

# test hosts only
echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=amd64] https://dep.auxinux.ca/VIRTUA kernel-dev main' \
  | sudo tee /etc/apt/sources.list.d/virtua-kernel-dev.list
```

Never use `[trusted=yes]`: the repository is GPG-signed, and `trusted=yes`
tells APT to skip signature verification entirely.

## OpenZFS kernel compatibility window

Each OpenZFS release declares the kernel range it supports in its `META` file
(`Linux-Minimum` / `Linux-Maximum`). Outside that window DKMS cannot build the
module — and because a failed DKMS build does **not** make `apt install` fail,
the result is a host that believes ZFS is installed but has no module (and, on
ZFS-on-root, does not come back up).

`build-virtua-kernel.sh` reads `META` from the ZFS source and aborts the build
if the target kernel is outside the declared range, rather than publishing a
package that can never compile.

| OpenZFS | Linux-Maximum |
|---|---|
| 2.4.2 | 7.0 |
| 2.4.4 | 7.2 |

The default is OpenZFS 2.4.4, which covers the 7.1 and 7.2 kernel series. When
bumping `ZFS_VERSION`, also pin the matching `ZFS_SHA256` (from the GPG-signed
`zfs-<version>.sha256.asc` published with the release).
