# VirtuaOS Kernel

Kernel project for VirtuaOS hypervisor hosts.

The `virtua` profile targets KVM/QEMU, LXC, Docker, VirtIO, VFIO/IOMMU,
virtual networking, storage and matched ZFS modules. Its main packages are
`kernel-virtua` and `linux-image-*-auxinux-virtua-*`.

VirtuaOS consumes this kernel through the AuxiNux APT repository.

Build and repository entry points:

```bash
./build-virtua-kernel.sh
sudo GPG_KEY=repo@auxinux.ca ./build-depot-kernel.sh ./output
```

This repository accepts only the `virtua` profile and currently publishes
amd64 packages.
