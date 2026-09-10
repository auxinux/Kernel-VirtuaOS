# Plan — Kernel VirtuaOS `7.2.4-auxinux-virtua-amd64`

**Branche :** `prod/7.2` · **Track :** `prod` · **Suite APT :** `kernel` · **Meta :** `kernel-virtua`
**Date :** 10 septembre 2026 · **Statut :** proposition, aucun build lancé

---

## 0. Constat vérifié avant proposition

| Point | Vérification |
|---|---|
| 7.2.4 existe | kernel.org `releases.json` : stable **7.2.4**, publiée le **2026-09-07** |
| 7.1 est mort | 7.1.13 marquée **EOL** le 2026-09-02 — la prod 7.1.x ne reçoit plus de correctif |
| 7.3 | mainline `7.3-rc2` — reste sur `main`, track `dev`, hors de ce plan |
| OpenZFS | 2.4.4 est la dernière ; `META` déclare `Linux-Maximum 7.2`. La garde `[7b/9]` compare la **série** (`7.2`) et non la révision → `7.2 gt 7.2` = faux → **passe**. Aucun changement ZFS requis |
| Nom du kernel | `KERNEL_NAME_SUFFIX = auxinux-virtua-amd64` (ligne 581) → release = `7.2.4-auxinux-virtua-amd64`. **Conforme à la demande sans modifier la plomberie** |

---

## 1. Stratégie de branche

```
main        ──●──●──●──────────────────►   ligne 7.3, track=dev, kernel-virtua-dev, suite kernel-dev
               └── prod/7.2 ──●──●──────►   ligne 7.2, track=prod, kernel-virtua,     suite kernel
```

* `prod/7.2` : branche **longue durée** de la ligne de production. Reçoit 7.2.4, puis 7.2.5, 7.2.6…
* `main` : reste la ligne de développement (7.3). Les correctifs de config validés en prod remontent par cherry-pick `prod/7.2 → main`, jamais l'inverse en masse.
* Tag à la publication : `v7.2.4-1` (`-1` = `VIRTUA_BUILD_NUMBER`). Un rebuild du même upstream avec une config corrigée devient `v7.2.4-2`.

Le cloisonnement prod/dev existant (suffixe, meta, dossiers, suite APT) est déjà correct dans les deux scripts — rien à changer côté publication.

---

## 2. Instabilité au reboot — hypothèses classées

Vous décrivez de l'instabilité **au reboot, sur certaines machines seulement**. Voici les causes réelles que la config actuelle ne couvre pas, de la plus probable à la moins :

| # | Cause | Symptôme observé | Correctif |
|---|---|---|---|
| 1 | **Watchdog matériel armé par le BIOS, jamais nourri** | reboot spontané ~30-60 s après le boot, aucune trace | `WATCHDOG_HANDLE_BOOT_ENABLED=y` + drivers `ITCO_WDT`, `SP5100_TCO`, `IT87_WDT`, `W83627HF_WDT`, `IPMI_WATCHDOG` |
| 2 | **Aucune console framebuffer** | la machine boote et fonctionne, mais **écran noir** → diagnostiqué à tort comme « plantée » | `VT`, `FRAMEBUFFER_CONSOLE`, `SYSFB_SIMPLEFB`, `DRM_SIMPLEDRM`, + `DRM_AST` (BMC ASPEED) et `DRM_MGAG200` (Matrox G200 : iDRAC / iLO) — **absents aujourd'hui, présents sur la quasi-totalité des cartes serveur** |
| 3 | **Erreurs mémoire non rapportées** | reboot / gel aléatoire sur les vieilles machines | EDAC par génération de chipset + `RAS` + `ACPI_APEI_GHES` + `MEMORY_FAILURE` → cf. §5 |
| 4 | **Tentative de suspend/S3 ACPI** | ne revient pas d'un cycle d'alim | `SUSPEND=n`, `HIBERNATION=n` — inutile sur un serveur, supprime toute la classe de bugs |
| 5 | **Blocage entropie au démarrage** | boot qui pend plusieurs minutes avant systemd | `RANDOM_TRUST_CPU` / `RANDOM_TRUST_BOOTLOADER` |
| 6 | **Pas de clavier au rescue** | impossible d'intervenir en console | `SERIO_I8042` + `KEYBOARD_ATKBD` (PS/2, machines pré-2013) et `USB_HID` + EHCI/OHCI/UHCI |
| 7 | **Reboot silencieux au lieu d'une panic tracée** | rien dans les logs | `SOFTLOCKUP_DETECTOR`, `HARDLOCKUP_DETECTOR`, `DETECT_HUNG_TASK`, `BOOTPARAM_*_PANIC=n`, `KEXEC`/`CRASH_DUMP` (kdump) |
| 8 | **Microcode absent** | errata CPU (TSX Haswell, fam 15h AMD) | `MICROCODE=y`, `MICROCODE_LATE_LOADING=n` (le late-loading est lui-même une source connue de corruption) |

> Les points 1, 2 et 4 expliquent à eux seuls la très grande majorité des « instable au reboot sur certaines machines ». Aucun n'est couvert par la config actuelle.

---

## 3. Couverture CPU AMD / Intel — 12 ans et plus

**Découverte importante :** en 7.2, le choix « x86-64 Processor family » (`GENERIC_CPU`, `MK8`, `MPSC`, `MCORE2`) **a été supprimé** de `arch/x86/Kconfig.cpu`. Il ne reste que `MATOM` et `X86_NATIVE_CPU`. Un build amd64 est donc **déjà** en baseline `-march=x86-64` (x86-64-v1) — c'est-à-dire compatible avec **toute** machine 64 bits, de l'Athlon 64 à Zen 6. La couverture demandée est acquise par construction.

**Ce qu'il faut verrouiller :**

* `X86_NATIVE_CPU=n` — **garde explicite**. Cette option compile en `-march=native`, produisant un kernel accordé au CPU *de la machine de build* : il plante en `#UD` sur toute machine plus ancienne. C'est littéralement le mécanisme « ça boote ici, pas là ».
* **cpufreq multi-générations** — un seul driver ne couvre pas 12 ans :
  * `X86_ACPI_CPUFREQ` : Core 2 → Sandy Bridge, AMD K10 / Bulldozer / Piledriver
  * `X86_POWERNOW_K8` : AMD K8 / K10
  * `X86_INTEL_PSTATE` : Sandy Bridge et suivants
  * `X86_AMD_PSTATE` : Zen 2 et suivants **uniquement** — sans acpi-cpufreq, tout AMD pré-Zen 2 tourne à fréquence fixe
  * gouverneur par défaut : `schedutil`
* **Topologie** : `SCHED_MC`, `SCHED_SMT`, `SCHED_CLUSTER`, `SCHED_MC_PRIO` (Turbo Boost Max 3.0)
* **Diagnostic matériel** : `X86_MCE` + `X86_MCE_INTEL` + `X86_MCE_AMD` + `RAS` + `ACPI_APEI_GHES` → on sait *pourquoi* la machine est tombée
* **Capteurs / IPMI** en modules : `SENSORS_CORETEMP`, `SENSORS_K8TEMP`, `SENSORS_K10TEMP`, `SENSORS_NCT6775`, `SENSORS_IT87`, `SENSORS_W83627HF`, `IPMI_SI`, `IPMI_DEVICE_INTERFACE`
* **Console série** : `SERIAL_8250_CONSOLE` — indispensable pour capturer une panic de reboot sur un serveur distant

Les GPU lourds (`i915`, `amdgpu`, `radeon`, `nouveau`) **restent désactivés** : c'est le bon choix pour un hyperviseur, un driver hôte lié au GPU empêche le passthrough VFIO.

---

## 4. Virtualisation — optimisation réelle

### KVM / QEMU
`KVM_SMM`, `KVM_AMD_SEV` (chiffrement mémoire invité AMD), `KVM_INTEL_TDX` si présent en 7.2, `KVM_PROVE_MMU=n`, `KVM_WERROR=n`.
**Nested activé par défaut** via un `modprobe.d` livré dans le paquet meta (`kvm_intel.nested=1`, `kvm_amd.nested=1`) — aujourd'hui il faut le faire à la main sur chaque hôte.
`PARAVIRT` + `PARAVIRT_SPINLOCKS` : indispensables si VirtuaOS tourne lui-même dans une VM (imbrication).

### Passthrough
Ajout de `VFIO_PCI_IGD` (iGPU Intel). `INTEL_IOMMU_DEFAULT_ON` reste **off** volontairement : l'activer par défaut casse le boot sur certaines cartes anciennes — on documente `intel_iommu=on iommu=pt` comme opt-in.
vDPA : `VDPA`, `VP_VDPA`, `MLX5_VDPA`.

### LXC / Docker
* `CGROUP_MISC`, `CGROUP_WRITEBACK`, `BLK_DEV_THROTTLING`, `NET_CLS_BPF`, `NET_ACT_BPF`
* `IP_VS` + `IP_VS_RR` + `IP_VS_NFCT` (Docker Swarm, services k8s), `BRIDGE_VLAN_FILTERING`, `NF_NAT_FTP`
* `XFRM`, `WIREGUARD` (module)
* **`CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor,bpf"`** — valeur Debian 13 exacte. Si `apparmor` n'est pas dans cette chaîne, **les profils AppArmor de Docker et LXC ne s'appliquent pas silencieusement**, alors que `SECURITY_APPARMOR=y` est bien présent. Point non couvert aujourd'hui.
* `SECURITY_LANDLOCK` (systemd 257), `SECURITY_APPARMOR_BOOTPARAM_VALUE=1`
* `BPF_JIT_ALWAYS_ON`, `BPF_UNPRIV_DEFAULT_OFF=y`, **`DEBUG_INFO_BTF=y`** + `DEBUG_INFO_REDUCED` — décision retenue : BTF activé pour bpftrace / cilium / systemd-oomd. Coût ~4-6 Mo dans vmlinuz.
* Nouveau bloc de vérification **« prérequis systemd »** (`FHANDLE`, `DMIID`, `EFIVAR_FS`, `CRYPTO_USER_API_HASH`, `KCMP`, `INOTIFY_USER`, `SIGNALFD`, `TIMERFD`, `EPOLL`, `TMPFS_XATTR`, `TMPFS_POSIX_ACL`, `CGROUP_BPF`) — aujourd'hui hérités par chance de la config Debian, jamais vérifiés.

### Ordonnancement hyperviseur
`PREEMPT_DYNAMIC` avec défaut `PREEMPT_VOLUNTARY` (sélectionnable au boot par `preempt=`), `HZ_250`, `NO_HZ_IDLE`, `HIGH_RES_TIMERS`, `RCU_NOCB_CPU=y` (opt-in via `rcu_nocbs=`), `SCHED_AUTOGROUP=n` (fonctionnalité desktop qui fausse l'équité entre conteneurs et VM).

---

## 5. Mémoire — « DDR2 et plus »

**Précision nécessaire :** le noyau Linux n'a aucune option de configuration liée au type de DRAM. Le contrôleur mémoire est initialisé par le firmware ; le kernel ne « supporte » pas DDR2 vs DDR5. Ce qui existe réellement et répond à votre besoin :

**a) Détection des erreurs mémoire par génération de chipset — le vrai sujet.** Des barrettes DDR2/DDR3 de 12-15 ans qui se dégradent produisent exactement des « reboots aléatoires sur certaines machines ». Sans driver EDAC, l'erreur n'est jamais rapportée :

`EDAC_I3000`, `EDAC_I3200`, `EDAC_I5000`, `EDAC_I5100`, `EDAC_I7300_MC`, `EDAC_I7CORE`, `EDAC_IE31200`, `EDAC_SBRIDGE`, `EDAC_SKX`, `EDAC_I10NM` (Intel, du Core 2 à Emerald Rapids) et `EDAC_AMD64` (K8 → Zen). Plus `MEMORY_FAILURE` : reprise sur erreur mémoire au lieu d'une panic.

**b) Machines à faible RAM.** Un hôte d'époque DDR2 a typiquement 2 à 8 Go :
`ZSWAP=y` + `ZSWAP_COMPRESSOR_DEFAULT_ZSTD` + `ZSMALLOC`, `ZRAM` (module), `COMPACTION`, `KSM` (déjà présent).

**c) Correctif de stabilité : THP en `madvise`, pas `always`.** Sur un hôte KVM à faible mémoire, `TRANSPARENT_HUGEPAGE_ALWAYS` provoque des pics de latence à la compaction et entre en conflit avec KSM. On bascule sur `TRANSPARENT_HUGEPAGE_MADVISE`. QEMU demande explicitement les hugepages quand il en veut — rien n'est perdu.

**d) Gros serveurs modernes.** `SPARSEMEM_VMEMMAP`, `X86_5LEVEL`, `MEMORY_HOTPLUG` + `MEMORY_HOTREMOVE` (déjà requis par `VIRTIO_MEM`), `NUMA` + `NUMA_BALANCING` (documenter `numa_balancing=disable` si VM épinglées).

---

## 6. BTRFS

Racine en BTRFS confirmée → **`BTRFS_FS=y` en built-in**, pas en module : la racine monte même avec un initramfs cassé ou périmé. C'est directement un gain de robustesse au reboot.

* `BTRFS_FS_POSIX_ACL=y`
* **Debug coupé** : `BTRFS_DEBUG=n`, `BTRFS_ASSERT=n`, `BTRFS_FS_RUN_SANITY_TESTS=n`, `BTRFS_FS_REF_VERIFY=n` — gain de performance réel sur le chemin d'écriture
* **Checksums accélérés** : `CRYPTO_CRC32C` + accélération x86 (PCLMULQDQ), `CRYPTO_XXHASH`, `CRYPTO_BLAKE2B`, `CRYPTO_SHA256` + variantes AVX2. *Les noms des drivers crypto x86 ont bougé entre 6.x et 7.x — résolus par le garde-fou du §7.*
* **Compression built-in** : `ZSTD_COMPRESS`, `ZSTD_DECOMPRESS`, `LZO_COMPRESS`, `ZLIB_*` — sinon `compress=zstd` est inutilisable au montage de la racine
* **I/O** : `MQ_IOSCHED_DEADLINE` (défaut), `MQ_IOSCHED_KYBER`, `IOSCHED_BFQ`, `BLK_WBT`
* `AHCI` et `BLK_DEV_NVME` **built-in** : la racine monte sans dépendre de l'initramfs
* **À documenter dans les notes de version** : `chattr +C` sur les répertoires d'images VM. Le CoW de BTRFS combiné aux `fsync` de QEMU fragmente massivement les qcow2/raw. C'est une consigne d'exploitation, pas une option kernel — mais c'est le premier facteur de performance BTRFS sur un hyperviseur.

---

## 7. Garde-fou du script — prérequis à tout le reste

```bash
cfg() { ./scripts/config "$@" || true; }     # ligne 626
```

Ce `|| true` **avale toute erreur** : un symbole renommé ou mal orthographié devient un no-op parfaitement silencieux. Aujourd'hui seule la liste `CRITICAL` (24 symboles) rattrape le problème. Ce plan ajoute **~200 options**, dont plusieurs sur des symboles qui ont changé de nom entre 6.12 et 7.2 (`MICROCODE_INTEL`/`MICROCODE_AMD` fusionnés dans `MICROCODE`, famille `MITIGATION_*`, drivers crypto x86). En l'état, la moitié pourrait ne rien faire sans qu'aucune étape ne le signale.

**Correctif proposé, à faire en premier :**

1. `cfg()` journalise chaque couple (symbole, valeur demandée) dans une table.
2. L'étape `[6/9]` est étendue : après `olddefconfig`, elle vérifie pour chaque symbole demandé qu'il **existe dans l'arbre Kconfig** et que `.config` porte bien la valeur attendue.
3. Elle distingue deux cas : *symbole inconnu dans cette version du noyau* → **erreur bloquante** ; *rabattu par une dépendance* → avertissement nommant la dépendance manquante.

C'est ce qui rend les ~200 options ajoutables sans pari. Sans ce garde-fou, je ne recommande pas d'appliquer le reste.

---

## 8. Léger mais complet

**Retiré** : `SOUND`/`SND`, `MEDIA_SUPPORT` (DVB, webcams), protocoles réseau historiques, gros DRM, `EXTRA_FIRMWARE=""`, `SUSPEND`/`HIBERNATION`.

**Conservé en modules** (chargés seulement si le matériel est présent — coût nul au boot) :
* HBA / RAID : `MEGARAID_SAS`, `MPT3SAS`, `HPSA`, `SMARTPQI`, `AACRAID`, `ARCMSR`, `3W_9XXX`
* NIC : `e1000`, `e1000e`, `igb`, `ixgbe`, `i40e`, `ice`, `tg3`, `bnx2`, `bnx2x`, `bnxt`, `r8169`, `sky2`, `mlx4`, `mlx5`, `vmxnet3`
* Wi-Fi / BT : inchangé (déjà dans `CRITICAL`)
* IPMI, hwmon, EDAC, watchdogs

**Compression** : `MODULE_COMPRESS_ZSTD=y`, `KERNEL_ZSTD=y`.

**`TRIM_UNUSED_KSYMS=n` — garde obligatoire.** Cette option élague les symboles exportés non utilisés en interne et **casse la compilation de tout module hors-arbre** : le module ZFS DKMS ne se construirait plus chez le client, sans qu'`apt` échoue. Même famille de risque que la fenêtre kernel OpenZFS déjà gardée en `[7b/9]`.

Dans la même logique : `MODULE_SIG_FORCE=n` et lockdown non forcé, sinon le module ZFS DKMS non signé ne charge pas — et un hôte ZFS-on-root ne remonte pas.

**Cible :** vmlinuz ~12-14 Mo (BTF inclus), arbre `/lib/modules` ~120-180 Mo compressé zstd.

---

## 9. Mitigations spéculatives

Décision retenue : **compilées et actives par défaut.**

`CPU_MITIGATIONS=y` et la famille `MITIGATION_*` de 7.2 (`SPECTRE_V1`, `SPECTRE_V2`, `RETPOLINE`, `RETHUNK`, `SRSO`, `RETBLEED`, `MDS`, `TAA`, `L1TF`, `GDS`, `RFDS`, `ITS`, `TSA`, `VMSCAPE`, `PAGE_TABLE_ISOLATION`…).

Justification : sur un hôte KVM multi-locataires, désactiver ces mitigations autorise une fuite de données **entre VM**. Le coût est réel sur du Haswell/Bulldozer (-15 à -35 % selon la charge) et l'admin garde `mitigations=off` au boot pour un hôte à charge unique et de confiance — ce sera documenté dans les notes de version, avec l'avertissement.

---

## 10. Exécution

| # | Étape | Livrable |
|---|---|---|
| 1 | Garde-fou `cfg()` + vérification de symboles (§7) | `build-virtua-kernel.sh` |
| 2 | Nouveaux blocs de config : CPU/plateforme, reboot, mémoire/EDAC, BTRFS, virtualisation, allègement | `build-virtua-kernel.sh` |
| 3 | Extension des listes `CRITICAL` / `RECOMMENDED` + bloc « prérequis systemd » | `build-virtua-kernel.sh` |
| 4 | `modprobe.d` (nested KVM) + `sysctl.d` livrés par le meta | `build-depot-kernel.sh` |
| 5 | Build à blanc `KERNEL_VERSION=7.2.4 track=prod` sans publication | logs + `.config` diffé contre 7.1.x |
| 6 | Revue du `.config` généré | validation avant compilation longue |
| 7 | Build complet + paquets ZFS 2.4.4 DKMS + userland | `.deb` dans `OUTPUT_DIR` |
| 8 | Tests (§11) | rapport |
| 9 | `RELEASE-NOTES-7.2.4.md`, tag `v7.2.4-1`, publication dépôt | suite APT `kernel` |

Commandes de référence :

```bash
# build
./build-virtua-kernel.sh track=prod KERNEL_VERSION=7.2.4 VIRTUA_BUILD_NUMBER=1

# publication
sudo GPG_KEY=repo@auxinux.ca ./build-depot-kernel.sh /usr/src/virtua-kernel-build/output
```

Aucun argument nouveau : le nom `7.2.4-auxinux-virtua-amd64` sort tel quel de la plomberie existante.

---

## 11. Validation avant publication

Le sujet du ticket étant *l'instabilité au reboot*, la validation doit la cibler explicitement :

* **20 reboots consécutifs** scriptés sur chaque machine de test, avec console série capturée
* Parc de test minimal : **1 Intel pré-2015** (Haswell/Ivy Bridge), **1 AMD pré-Zen** (Bulldozer/Piledriver), **1 machine récente**, **1 serveur à BMC** (validation `DRM_AST`/`DRM_MGAG200`)
* `virsh` : démarrage VM + migration à chaud ; `lxc-start` ; `docker run` avec profil AppArmor **vérifié appliqué** (`aa-status`)
* `dkms status` : module ZFS 2.4.4 effectivement construit et chargé
* `btrfs scrub` sur la racine + mesure d'écriture sur un répertoire d'images VM
* `edac-util` / `rasdaemon` : contrôleur mémoire bien détecté sur les vieilles machines
* Rollback : l'ancien kernel prod reste installé et sélectionnable dans GRUB pendant toute la campagne

---

## 12. Hors périmètre

* La ligne **7.3 reste sur `main`**, en track `dev`, non modifiée par ce plan. Les correctifs de config validés ici remonteront par cherry-pick une fois éprouvés en prod.
* **Aucun rétro-portage vers 7.1** : la série est EOL depuis le 2 septembre 2026.
* Pas de changement au modèle OpenZFS DKMS, ni au cloisonnement prod/dev du dépôt : les deux sont corrects en l'état.
