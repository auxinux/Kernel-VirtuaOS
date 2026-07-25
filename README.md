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
