# AuxiNux Virtua — Kernel 7.2.4 · Notes de version

**Base upstream :** Linux **7.2.4** (kernel.org stable, 7 septembre 2026)
**Distribution cible :** Debian 13 (Trixie)
**Release kernel :** `7.2.4-auxinux-virtua-amd64`
**Track :** `prod` · suite APT `kernel` · meta `kernel-virtua`
**Branche git :** `prod/7.2`
**Stockage ZFS :** OpenZFS **2.4.4**, paquet **source DKMS** (`openzfs-zfs-dkms`), recompilé chez le client

---

## 0. Pourquoi cette version

La ligne de production tournait en **7.1.12**. La série 7.1 est passée **EOL le
2 septembre 2026** : elle ne reçoit plus aucun correctif de sécurité. Le passage
en 7.2.4 n'est donc pas un confort.

Cette version répond en plus à une **instabilité au reboot observée sur une
partie du parc seulement**. Les correctifs correspondants sont en §2.

---

## 1. Changement structurel : la configuration est désormais vérifiée

`build-virtua-kernel.sh` appliquait sa configuration ainsi :

```bash
cfg() { ./scripts/config "$@" || true; }
```

Ce `|| true` **avalait toute erreur**. Or `scripts/config` accepte sans broncher
un symbole inexistant : il écrit la ligne dans `.config`, qu'`olddefconfig`
supprime ensuite en silence. Un symbole renommé ou supprimé entre deux versions
du noyau devenait donc **un no-op parfaitement invisible**.

Une nouvelle étape `[6a]` indexe les 21 721 symboles Kconfig de l'arbre source
et vérifie que **chaque** option demandée :

* **existe** dans cette version du noyau — sinon erreur bloquante ;
* a bien été **retenue** par `olddefconfig` — sinon avertissement détaillé
  nommant la valeur obtenue.

Sur le premier build à blanc en 7.2.4, ce contrôle a immédiatement révélé
**huit symboles morts**, dont **`CGROUP_NS`, présent dans le script depuis
l'import initial** : une intention de configuration qui n'a jamais rien produit.

| Symbole | Verdict en 7.2.4 |
|---|---|
| `CGROUP_NS` | supprimé — les namespaces cgroup sont inconditionnels |
| `X86_5LEVEL` | supprimé — pagination 5 niveaux inconditionnelle |
| `RANDOM_TRUST_CPU`, `RANDOM_TRUST_BOOTLOADER` | supprimés — pilotés au boot par `random.trust_cpu=`, actifs par défaut |
| `SECURITY_APPARMOR_BOOTPARAM_VALUE` | supprimé |
| `BTRFS_FS_REF_VERIFY` | supprimé |
| `PAHOLE_HAS_SPLIT_BTF` | supprimé |
| `EDAC_I7300_MC` | renommé `EDAC_I7300` |

Deux autres options ont été retirées après lecture du Kconfig : `EDAC_I5000`
est `depends on BROKEN` en amont, et `VFIO_MDEV` est un tristate **sans prompt**
sélectionné par les pilotes mdev.

Un mode `-config-only` a été ajouté : il applique et vérifie la configuration
puis s'arrête, ce qui valide ~350 options en quelques minutes au lieu d'une
compilation complète.

---

## 2. Instabilité au reboot — ce qui a été corrigé

| Cause | Correctif |
|---|---|
| **Watchdog matériel armé par le BIOS et jamais nourri** — cause n°1 des reboots spontanés ~60 s après le démarrage | `WATCHDOG_HANDLE_BOOT_ENABLED` : le noyau nourrit le chien jusqu'à la reprise par l'espace utilisateur. Pilotes `ITCO_WDT` (Intel), `SP5100_TCO` (AMD), `IT87_WDT`, `W83627HF_WDT`, `IPMI_WATCHDOG` |
| **Aucune console framebuffer** — la machine boote et fonctionne mais l'écran reste noir, ce qui est rapporté comme un plantage | `VT`, `FRAMEBUFFER_CONSOLE`, `DRM_SIMPLEDRM`, `SYSFB_SIMPLEFB`, et surtout **`DRM_AST`** (BMC ASPEED) et **`DRM_MGAG200`** (Matrox G200 : iDRAC, iLO) — absents jusqu'ici |
| **Erreurs mémoire jamais rapportées** sur du matériel ancien | Pilotes EDAC par génération de chipset (`EDAC_AMD64`, `EDAC_I3000` → `EDAC_I10NM`), `X86_MCE`, `RAS`, `ACPI_APEI_GHES`, `MEMORY_FAILURE` |
| **Tentative de suspend/S3 ACPI** sur un serveur | `SUSPEND=n`, `HIBERNATION=n` — classe entière de bugs supprimée |
| **Kernel accordé à la machine de build** | `X86_NATIVE_CPU=n` explicite : `-march=native` produit un binaire qui tombe en `#UD` sur toute machine plus ancienne |
| **Pas de clavier en rescue** sur les machines anciennes | `SERIO_I8042` + `KEYBOARD_ATKBD` (PS/2), `USB_HID`, EHCI/OHCI/UHCI en plus de XHCI |
| **Reboot silencieux, aucune trace** | `SOFTLOCKUP_DETECTOR`, `HARDLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` (sans panic forcée), `KEXEC` + `CRASH_DUMP` pour kdump, `SERIAL_8250_CONSOLE` |
| **Errata CPU** | `MICROCODE=y` (les symboles `MICROCODE_INTEL`/`MICROCODE_AMD` ont été fusionnés en amont). `MICROCODE_LATE_LOADING=n` : le chargement à chaud est une source connue de corruption |

---

## 3. Couverture Intel / AMD sur 12 ans et plus

En 7.2, le choix « x86-64 Processor family » (`GENERIC_CPU`, `MK8`, `MCORE2`) a
été **supprimé** d'`arch/x86/Kconfig.cpu`. Un build amd64 est donc déjà en
baseline `-march=x86-64`, compatible de l'Athlon 64 à Zen 6 : la couverture est
acquise par construction. Il restait à la protéger (`X86_NATIVE_CPU=n`, §2).

**Fréquence — aucun pilote ne couvre 12 ans à lui seul :**

| Pilote | Couverture |
|---|---|
| `X86_ACPI_CPUFREQ` | Core 2 → Sandy Bridge, AMD K10 / Bulldozer / Piledriver |
| `X86_POWERNOW_K8` | AMD K8 / K10 |
| `X86_INTEL_PSTATE` | Sandy Bridge et suivants |
| `X86_AMD_PSTATE` | **Zen 2 et suivants uniquement** |

Sans `acpi-cpufreq`, tout AMD antérieur à Zen 2 tournait à fréquence figée.
Gouverneur par défaut : `schedutil`.

**Topologie et supervision :** `SCHED_MC`, `SCHED_MC_PRIO` (Turbo Boost Max 3.0),
`SCHED_SMT`, `SCHED_CLUSTER`, `X86_X2APIC`, `NUMA`. Capteurs `CORETEMP`,
`K8TEMP`, `K10TEMP`, `NCT6775`, `IT87`, `W83627HF`, plus `IPMI_SI`.

**Stockage serveur :** `SATA_AHCI` et `BLK_DEV_NVME` en built-in (la racine monte
sans dépendre de l'initramfs), `MEGARAID_SAS`, `SCSI_MPT3SAS`, `SCSI_HPSA`,
`SCSI_SMARTPQI`, `SCSI_AACRAID`, `SCSI_ARCMSR` en modules.

---

## 4. Virtualisation

**KVM :** `KVM_SMM`, `KVM_AMD_SEV` (chiffrement mémoire invité AMD),
`PARAVIRT` + `PARAVIRT_SPINLOCKS` (indispensables si VirtuaOS tourne lui-même
dans une VM).

**Passthrough :** ajout de `VFIO_PCI_IGD` (iGPU Intel).
`INTEL_IOMMU_DEFAULT_ON` reste **volontairement désactivé** : l'activer par
défaut casse le boot sur certaines cartes anciennes. Opt-in documenté :
`intel_iommu=on iommu=pt`.

**vDPA :** `VDPA`, `VP_VDPA`, `MLX5_VDPA_NET`.

**Conteneurs :** `CGROUP_MISC`, `CGROUP_WRITEBACK`, `BLK_DEV_THROTTLING`,
`NET_CLS_BPF`, `NET_ACT_BPF`, `IP_VS` + `IP_VS_RR` + `IP_VS_NFCT` (services
Docker Swarm / Kubernetes), `BRIDGE_VLAN_FILTERING`, `WIREGUARD`.

> **Correctif important — AppArmor.** `SECURITY_APPARMOR=y` ne suffit pas : si
> `apparmor` n'apparaît pas dans la chaîne `CONFIG_LSM`, les profils AppArmor de
> Docker et LXC **ne s'appliquent jamais**, en silence et sans erreur visible.
> La chaîne est désormais figée sur la valeur Debian 13 :
> `landlock,lockdown,yama,integrity,apparmor,bpf`.

**iptables legacy.** Les cibles `IP_NF_FILTER` / `IP_NF_NAT` /
`IP_NF_TARGET_MASQUERADE` dépendent désormais de `IP_NF_IPTABLES_LEGACY`,
lui-même conditionné par `NETFILTER_XTABLES_LEGACY` que Debian désactive.
`IP_NF_TARGET_MASQUERADE` figurait dans la liste des options recommandées et
manquait donc en silence. Le backend legacy est réactivé en modules, en plus du
chemin nftables (`NFT_NAT`, `NFT_MASQ`) déjà présent.

**Préemption et tickless.** La base Debian sélectionne `PREEMPT_LAZY` et
`NO_HZ_FULL`, meilleurs pour un hyperviseur que le `PREEMPT_VOLUNTARY` /
`NO_HZ_IDLE` initialement prévus : on les conserve. `PREEMPT_DYNAMIC` permet de
basculer le modèle au boot (`preempt=`), et `nohz_full=` active le mode tickless
intégral sur les CPU portant des vCPU épinglés.

**eBPF / BTF.** `DEBUG_INFO_BTF` est activé (bpftrace, cilium, systemd-oomd).
Le Kconfig impose `DEBUG_INFO_BTF depends on !DEBUG_INFO_REDUCED` : il faut donc
du DWARF complet. Le paquet `linux-image-*-dbg` produit au passage **n'est pas
publié**.

---

## 5. Mémoire

Le noyau n'a **aucune option liée au type de DRAM** : c'est le firmware qui
initialise le contrôleur mémoire. Ce qui compte réellement sur du matériel
ancien, c'est de **détecter** les erreurs — d'où les pilotes EDAC du §2.

* **Faible RAM** : `ZSWAP` + `ZSWAP_COMPRESSOR_DEFAULT_ZSTD`, `ZSMALLOC`,
  `ZRAM`, `COMPACTION`, `KSM`.
* **THP en `madvise`, plus en `always`** : sur un hôte KVM à mémoire contrainte,
  `THP=always` provoque des pics de latence à la compaction et entre en conflit
  avec KSM. QEMU demande explicitement les hugepages quand il en veut.
* `SPARSEMEM_VMEMMAP`, `MEMORY_HOTPLUG` + `MEMORY_HOTREMOVE` (requis par
  `VIRTIO_MEM`), `NUMA_BALANCING` (désactivable par `numa_balancing=disable` si
  les VM sont épinglées).

---

## 6. Systèmes de fichiers

**Le parc est mixte : `EXT4_FS` et `BTRFS_FS` sont désormais TOUS DEUX
built-in.** Un pilote de racine en built-in monte `/` même avec un initramfs
cassé ou périmé — c'est directement de la robustesse au reboot. **Aucune
migration n'est nécessaire : un hôte ext4 venant de 7.1.x fonctionne tel quel.**

BTRFS : `BTRFS_FS_POSIX_ACL`, debug entièrement coupé (`BTRFS_DEBUG`,
`BTRFS_ASSERT`, `BTRFS_FS_RUN_SANITY_TESTS`), checksums accélérés
(`CRYPTO_CRC32C`, `XXHASH`, `BLAKE2B`, `SHA256`), compression built-in
(`ZSTD_COMPRESS`, `LZO_COMPRESS`) sans quoi `compress=zstd` est inutilisable au
montage de la racine.

E/S : `MQ_IOSCHED_DEADLINE` par défaut, `KYBER` et `BFQ` disponibles, `BLK_WBT`.

> **Exploitation — BTRFS et images de VM.** Appliquer `chattr +C` sur les
> répertoires d'images (`nodatacow`). Le CoW de BTRFS combiné aux `fsync` de
> QEMU fragmente massivement les qcow2/raw. C'est le premier facteur de
> performance BTRFS sur un hyperviseur, et ce n'est pas une option noyau.

---

## 7. Mitigations spéculatives

`CPU_MITIGATIONS=y` et la famille `MITIGATION_*` de 7.2 (`SPECTRE_V1`,
`SPECTRE_V2`, `SPECTRE_BHI`, `RETPOLINE`, `RETHUNK`, `SRSO`, `RETBLEED`, `MDS`,
`TAA`, `MMIO_STALE_DATA`, `L1TF`, `GDS`, `RFDS`, `SRBDS`, `SSB`, `ITS`, `TSA`,
`VMSCAPE`, `PAGE_TABLE_ISOLATION`) sont **compilées et actives par défaut**.

Sur un hôte KVM multi-locataires, les désactiver autorise une **fuite de données
entre VM**. Le coût est réel sur du Haswell/Bulldozer (−15 à −35 % selon la
charge). Un hôte à charge unique et de confiance peut les désactiver au boot
avec `mitigations=off` — c'est une décision d'exploitation, à prendre en
connaissance de cause.

---

## 8. Allègement

Retirés : `SOUND`/`SND`, `MEDIA_SUPPORT` (DVB, webcams, tuners),
`EXTRA_FIRMWARE`, `SUSPEND`, `HIBERNATION`. Les GPU lourds (`i915`, `amdgpu`,
`radeon`, `nouveau`) restent **volontairement absents** : sur un hyperviseur, un
pilote hôte lié au GPU empêche de le céder à une VM en passthrough VFIO.

Compression `KERNEL_ZSTD` et `MODULE_COMPRESS_ZSTD`.

**Deux gardes obligatoires pour OpenZFS DKMS :**

* `TRIM_UNUSED_KSYMS=n` — cette option élague les symboles exportés non utilisés
  en interne et **casse la compilation de tout module hors-arbre**. Le module ZFS
  ne se construirait plus chez le client, et un échec DKMS **ne fait pas échouer
  `apt`**.
* `MODULE_SIG_FORCE=n` — un module DKMS n'est pas signé ; le forcer empêcherait
  son chargement, et un hôte ZFS-on-root ne remonterait pas.

---

## 9. Mise à niveau depuis 7.1.x

```bash
sudo apt update
sudo apt install kernel-virtua
```

| Point | Impact |
|---|---|
| Racine **ext4** | Aucun. `EXT4_FS` reste built-in, aucune migration |
| Racine **BTRFS** | Aucun. Passe de module à built-in |
| **OpenZFS** | Le module DKMS **recompile** au premier boot (2.4.4 couvre la série 7.2). Vérifier `dkms status` |
| Autres modules hors-arbre | Doivent également recompiler — les inventorier avant |
| `SUSPEND`/`HIBERNATION` retirés | Vérifier qu'aucun `resume=UUID=…` ne traîne dans `/etc/default/grub` |
| THP `always` → `madvise` | Change le comportement mémoire, **pas** le boot |
| Rollback | L'ancien 7.1.12 reste installé et sélectionnable dans GRUB — **ne pas le purger avant validation** |

**Le risque réel de cette montée n'est pas le système de fichiers, c'est le saut
de série majeure 7.1 → 7.2 et la recompilation DKMS qui l'accompagne.**

---

## 10. Validation

⚠️ **La campagne de validation matérielle décrite dans `PLAN-7.2.4.md` §11 n'a
pas été exécutée par le pipeline de build.** Elle reste à faire avant tout
déploiement de masse :

* 20 reboots consécutifs par machine, console série capturée
* 1 Intel pré-2015, 1 AMD pré-Zen, 1 machine récente, 1 serveur à BMC,
  **1 hôte à racine ext4** et 1 à racine BTRFS
* `virsh` (démarrage VM + migration à chaud), `lxc-checkconfig`,
  `docker run` avec `aa-status` confirmant le profil **appliqué**
* `dkms status` : module ZFS 2.4.4 construit et chargé
* `edac-util` / `rasdaemon` : contrôleur mémoire détecté sur les machines anciennes
