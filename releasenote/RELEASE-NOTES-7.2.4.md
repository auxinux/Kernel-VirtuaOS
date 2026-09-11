# Noyau AuxiNux Virtua 7.2.4

**Basé sur :** Linux 7.2.4 (stable, kernel.org)
**Pour :** hôtes hyperviseur VirtuaOS sous Debian 13 (Trixie)
**Paquet :** `kernel-virtua` · dépôt APT `dep.auxinux.ca/VIRTUA`, suite `kernel`
**Remplace :** la série 7.1.x, désormais en fin de support amont

---

## En bref

Ce noyau est conçu pour faire tourner des machines virtuelles (KVM/QEMU) et
des conteneurs (LXC, Docker) sur un serveur, avec un objectif simple : rester
léger, couvrir un parc matériel large — Intel et AMD sur environ 12 ans et
plus — et démarrer de façon fiable.

Cette version corrige en particulier plusieurs causes fréquentes de
redémarrages instables observées sur certaines machines, et modernise le
support de la virtualisation et des conteneurs.

---

## Nouveautés principales

### Redémarrages plus fiables

Plusieurs situations qui provoquaient des redémarrages inattendus ou des
écrans figés sont désormais prises en charge :

- **Watchdogs matériels reconnus** (Intel TCO, AMD SP5100, IPMI, ITE, Winbond) :
  le système les maintient actifs correctement au lieu de laisser le BIOS
  redémarrer la machine seul.
- **Affichage de secours sur serveurs avec carte de gestion (BMC)** : les
  puces graphiques ASPEED et Matrox G200, présentes sur la plupart des cartes
  serveur (iDRAC, iLO, Supermicro), sont maintenant reconnues. Une machine qui
  semblait « plantée » avec un écran noir démarrait en réalité normalement.
- **Détection des erreurs de mémoire vive** sur les générations de processeurs
  Intel et AMD les plus courantes, pour repérer une barrette défectueuse au
  lieu de subir des plantages aléatoires.
- **Mise en veille désactivée** : sur un serveur, la mise en veille (suspend/
  hibernation) n'a pas d'utilité et peut provoquer des blocages au retour —
  elle est retirée.

### Compatibilité matérielle élargie

Le noyau reste compatible avec les processeurs 64 bits Intel et AMD sur une
large fenêtre de temps (grosso modo les 12 dernières années et plus), avec une
gestion correcte de la fréquence et de l'économie d'énergie sur chaque
génération — y compris les processeurs AMD antérieurs à Zen 2, qui étaient
mal pris en charge par les réglages par défaut.

### Virtualisation et conteneurs

- Support étendu de KVM (dont le chiffrement mémoire des VM sur les
  processeurs AMD qui le proposent) et du passage de périphériques PCI/GPU en
  mode direct à une VM (VFIO).
- **Correctif important pour Docker et LXC** : les profils de sécurité
  AppArmor, qui pouvaient silencieusement ne pas s'appliquer aux conteneurs
  selon la configuration système, sont désormais correctement pris en compte.
- Prise en charge d'outils modernes de supervision des conteneurs (via BTF/
  eBPF, utilisé par exemple par `bpftrace` ou Cilium).
- Réseau : compatibilité étendue pour les équilibreurs de charge (Docker
  Swarm, Kubernetes) et le VPN WireGuard.

### Stockage

- **Les systèmes de fichiers ext4 et Btrfs sont tous deux directement intégrés
  au noyau** (plutôt qu'en module optionnel), ce qui rend le démarrage plus
  robuste dans les deux cas. Aucune action n'est requise si votre serveur
  utilise déjà ext4.
- Meilleures performances et fiabilité pour Btrfs (vérifications internes
  désactivées, compression et sommes de contrôle accélérées).
- ZFS reste proposé en paquet séparé (`openzfs-zfs-dkms`), recompilé
  automatiquement pour chaque noyau installé.

### Sécurité

Les protections contre les failles matérielles de type Spectre/Meltdown et
apparentées restent actives par défaut, ce qui est recommandé sur un serveur
hébergeant plusieurs machines virtuelles ou conteneurs de locataires
différents. Un administrateur qui gère un serveur à usage unique et de
confiance peut choisir de les désactiver au démarrage (`mitigations=off`),
en connaissance de cause du compromis performance/sécurité que cela implique.

---

## Installation / mise à jour

```bash
sudo apt update
sudo apt install kernel-virtua
sudo reboot
```

Après redémarrage, vérifiez la version active :

```bash
uname -r
# doit afficher : 7.2.4-auxinux-virtua-amd64
```

Si ZFS est utilisé, vérifiez que le module a bien été reconstruit pour ce
noyau :

```bash
sudo dkms status
```

**Retour en arrière possible.** L'ancien noyau reste installé et disponible
au démarrage (menu GRUB avancé) : en cas de problème, vous pouvez redémarrer
dessus le temps de diagnostiquer.

---

## À savoir avant de déployer largement

- Le changement de série (7.1 → 7.2) implique que tout module externe au
  noyau (comme ZFS) doit être recompilé — c'est automatique, mais vérifiez
  que cela s'est bien passé sur une machine avant de généraliser.
- Comme pour toute mise à jour de noyau, il est recommandé de la valider
  d'abord sur un nombre restreint de machines représentatives de votre parc,
  avant un déploiement complet.

---

## Licence

Ce noyau est distribué sous licence GPL-2.0-only. Le code source complet, la
configuration utilisée et les scripts de compilation sont disponibles sur
demande, conformément à la GPL-2.0 §3.
