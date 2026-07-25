# AuxiNux Virtua — Kernel 7.0.11 · Notes de version

**Base upstream :** Linux **7.0.11** (kernel.org stable)
**Distribution cible :** Debian 13 (Trixie)
**Construit par :** `build-virtua-kernel.sh` (config dérivée de la config Debian amd64, puis durcie/spécialisée par profil)
**Stockage ZFS :** OpenZFS **2.4.2** compilé *contre ce kernel* et livré en modules appariés (`kmod-zfs-7.0.11-auxinux-…`) — pas de DKMS à l'installation.

Deux saveurs sont produites :

| Profil | Suffixe kernel | Paquet meta | Usage | Arch |
|---|---|---|---|---|
| **virtua** | `7.0.11-auxinux-virtua-amd64` | `kernel-virtua` | Hôte / hyperviseur (KVM + LXC + Docker) | amd64 |
| **desktop** | `7.0.11-auxinux-desktop-<arch>` | `kernel-auxinux-desktop` | Poste & VM desktop (GPU/son/USB) | amd64, arm64 |

---

## 1. Modifications communes aux deux profils

Appliquées sur la base Debian avant toute spécialisation :

| Domaine | Modification | Pourquoi |
|---|---|---|
| **Nom** | `CONFIG_LOCALVERSION="-auxinux-virtua\|-auxinux-desktop"`, `LOCALVERSION_AUTO` désactivé | Identité kernel AuxiNux stable, sans `+` parasite ni doublement de suffixe |
| **Clés** | `SYSTEM_TRUSTED_KEYS=""`, `SYSTEM_REVOCATION_KEYS=""` | Pas de dépendance aux clés d'infra Debian (build hors-arbre Debian) |
| **Taille** | `DEBUG_INFO` et `DEBUG_INFO_BTF` désactivés | Réduction majeure de la taille du paquet et du temps de build |
| **Compression** | Paquets `.deb` en **zstd** | Décompression rapide, bonne densité |

---

## 2. Profil **virtua** (hyperviseur)

Kernel optimisé pour faire tourner des VM (KVM/QEMU), des conteneurs LXC et Docker
sur un hôte **headless**.

### Virtualisation KVM / QEMU
- `KVM` (built-in), `KVM_INTEL` + `KVM_AMD` (**modules** — ne chargent que sur le bon CPU), `KVM_XEN`

### Passthrough PCI / IOMMU
- `VFIO`, `VFIO_PCI`, `VFIO_IOMMU_TYPE1`, `VFIO_MDEV`, `PCI_STUB`
- `IOMMU_SUPPORT`, `INTEL_IOMMU`, `AMD_IOMMU`, `IRQ_REMAP`

### Performance hyperviseur
- `KSM` (dé-duplication mémoire entre VM)
- `TRANSPARENT_HUGEPAGE`, `HUGETLBFS`, `HUGETLB_PAGE`

### VirtIO / vhost (I/O accéléré des invités)
- `VIRTIO`, `VIRTIO_PCI`, `VIRTIO_BLK`, `VIRTIO_NET`, `VIRTIO_CONSOLE`, `VIRTIO_BALLOON`, `VIRTIO_INPUT`, `VIRTIO_FS`
- `VHOST`, `VHOST_NET`, `VHOST_VSOCK`, `VHOST_SCSI`, `VSOCKETS`, `VIRTIO_VSOCKETS`

### Réseau hyperviseur
- `TUN`, `TAP`, `MACVLAN`, `MACVTAP`, `IPVLAN`, `BRIDGE`, `VLAN_8021Q`, `BONDING`
- `VXLAN` + `GENEVE` + `OPENVSWITCH` (**modules**)
- `NETFILTER`, `NF_TABLES`

### Conteneurs (LXC / Docker)
- `CGROUPS`, `CGROUP_BPF`, `CGROUP_FREEZER`, `CGROUP_PIDS`, `CGROUP_DEVICE`, `CGROUP_NS`, `CPUSETS`, `MEMCG`
- `NAMESPACES`, `USER_NS`, `NET_NS`, `PID_NS`, `IPC_NS`, `UTS_NS`
- `OVERLAY_FS`, `SECCOMP`, `SECCOMP_FILTER`, `VETH`

### Réseau conteneurs (NAT Docker)
- `BRIDGE_NETFILTER`, `NF_CONNTRACK`, `NF_NAT`
- `NETFILTER_XT_MATCH_ADDRTYPE`, `NETFILTER_XT_MATCH_CONNTRACK`
- `IP_NF_IPTABLES`, `IP_NF_FILTER`, `IP_NF_NAT`, `IP_NF_TARGET_MASQUERADE`, `NFT_NAT`, `NFT_MASQ`

### Stockage hôte
- `BLK_DEV_DM`, `DM_THIN_PROVISIONING`, `DM_SNAPSHOT`, `DM_CACHE`, `MD`
- `BLK_DEV_NVME`, `NVME_CORE`, `FUSE_FS`
- `NFS_FS` + `CIFS` (**modules**)

### Systèmes de fichiers
- `EXT4_FS` (built-in — racine fréquente)
- `BTRFS_FS`, `XFS_FS`, `F2FS_FS` (**modules**)

### GPU — **désactivés** (hôte headless)
- `DRM_AMDGPU`, `DRM_NOUVEAU`, `DRM_RADEON`, `DRM_XE`, `DRM_I915` → **off** (allègement, rien à piloter sur un hyperviseur sans écran)

### Garde-fou de build
Le build **échoue** si l'une de ces options critiques manque après résolution :
`KVM, VIRTIO, VIRTIO_PCI, VHOST_NET, NAMESPACES, USER_NS, NET_NS, PID_NS, CGROUPS, OVERLAY_FS, SECCOMP, BRIDGE, VETH, TUN, EXT4_FS`.

---

## 3. Profil **desktop** (poste & VM desktop)

Reste proche de la config Debian : **conserve les GPU** et l'environnement utilisateur,
tout en gardant VirtIO/KVM pour tourner aussi bien en VM qu'en bare-metal.

### VirtIO + KVM
- Même socle VirtIO que virtua (`VIRTIO*`, `VSOCKETS`, `VIRTIO_VSOCKETS`)
- `KVM` + `KVM_INTEL`/`KVM_AMD` (modules)

### Affichage / GPU (conservés, contrairement à virtua)
- `DRM`, `DRM_KMS_HELPER`
- `DRM_I915`, `DRM_XE`, `DRM_AMDGPU`, `DRM_RADEON`, `DRM_NOUVEAU` (**modules**)

### Entrées / périphériques
- `INPUT_EVDEV`, `HID`, `HID_GENERIC`
- `USB_SUPPORT`, `USB_XHCI_HCD`

### Son & sans-fil
- `SOUND`, `SND`, `SND_HDA_INTEL` (module)
- `BT`, `CFG80211`, `MAC80211` (**modules**)

### Conteneurs (socle plus léger que virtua)
- `CGROUPS`, `NAMESPACES`, `USER_NS`, `NET_NS`, `PID_NS`, `OVERLAY_FS`, `SECCOMP`, `SECCOMP_FILTER`

### Systèmes de fichiers
- `EXT4_FS` (built-in), `BTRFS_FS`, `XFS_FS`, `F2FS_FS` (modules)

### Garde-fou de build
Build interrompu si manque : `VIRTIO, VIRTIO_PCI, VIRTIO_NET, VIRTIO_BLK, DRM, INPUT_EVDEV, HID, USB_SUPPORT, EXT4_FS`.

---

## 4. virtua vs desktop — en un coup d'œil

| Catégorie | virtua (hyperviseur) | desktop |
|---|---|---|
| KVM / VirtIO / vhost | ✅ complet (vhost-scsi, vsock…) | ✅ socle VirtIO + KVM |
| Passthrough VFIO / IOMMU | ✅ | ❌ |
| KSM / HugePages | ✅ | ❌ |
| Réseau avancé (OVS, VXLAN, bonding, macvtap) | ✅ | ❌ |
| Conteneurs LXC/Docker complet (BPF, NAT) | ✅ | partiel (base ns/cgroups) |
| Stockage (DM thin, cache, NVMe, NFS, CIFS) | ✅ | ❌ |
| **GPU / DRM** | ❌ désactivés | ✅ i915/xe/amdgpu/radeon/nouveau |
| Son / Bluetooth / Wi-Fi | ❌ | ✅ |
| USB / HID / clavier-souris | minimal | ✅ |
| Architectures | amd64 | amd64 + arm64 |

---

## 5. OpenZFS 2.4.2 (modules appariés)

- Compilé **contre l'arbre exact** de ce kernel (`--with-config=kernel`), puis empaqueté
  via `make deb-kmod` → `kmod-zfs-7.0.11-auxinux-…`.
- Le meta-paquet (`kernel-virtua` / `kernel-auxinux-desktop`) **dépend automatiquement**
  du `kmod-zfs` correspondant : ZFS est disponible **dès le premier boot**, sans
  recompilation DKMS.
- Raison d'être : OpenZFS est hors-arbre (CDDL) et suit les kernels avec retard.
  Apparier ZFS au kernel élimine le désappariement de versions (le `zfs-dkms` distro
  pouvait refuser de compiler sur un kernel trop récent).

> ⚠️ **Hôtes ZFS-on-root** : ne jamais booter ce kernel sans son `kmod-zfs` apparié —
> sinon `/` (sur ZFS) ne monte pas. Le meta-paquet garantit la présence du module.

---

## 6. Installation

**Dépôt signé :**
```bash
sudo wget -O /usr/share/keyrings/virtua-archive-keyring.gpg \
  https://dep.auxinux.ca/VIRTUA/virtua-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=amd64,arm64] https://dep.auxinux.ca/VIRTUA kernel main' \
  | sudo tee /etc/apt/sources.list.d/virtua-kernel.list
sudo apt update
```

**Hyperviseur :**
```bash
sudo apt install kernel-virtua
```

**Desktop :**
```bash
sudo apt install kernel-auxinux-desktop
```

Après reboot :
```bash
uname -r   # attendu: 7.0.11-auxinux-virtua-amd64  (ou -auxinux-desktop-…)
```
