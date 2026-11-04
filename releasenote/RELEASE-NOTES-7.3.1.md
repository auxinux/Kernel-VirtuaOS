# Noyau AuxiNux Virtua 7.3.1

**Basé sur :** Linux 7.3.1 (stable, kernel.org, publiée le 30 octobre 2026)
**Pour :** hôtes hyperviseur VirtuaOS sous Debian 13 (Trixie)
**Paquet :** `kernel-virtua` · dépôt APT `dep.auxinux.ca/VIRTUA`, suite `kernel`
**Remplace :** 7.2.11

---

## ⚠️ Pas de ZFS sur ce noyau

**Si cette machine utilise ZFS, ne passez pas à ce noyau pour l'instant.**

Aucune version d'OpenZFS publiée ne prend encore en charge la série 7.3 :
OpenZFS 2.4.4 s'arrête à la 7.2. Sur ce noyau, le module `zfs` ne peut donc pas
être compilé, et **`apt` ne signale pas d'échec** :

- les pools ZFS ne sont pas importés au démarrage ;
- une machine dont la racine est sur ZFS ne démarre pas sur ce noyau.

Pour rester sur la 7.2.11, à faire **avant** toute mise à jour :

```bash
sudo apt-mark hold kernel-virtua
```

Le paquet `kernel-virtua` ne recommande plus `openzfs-zfs-dkms`. Le support ZFS
reviendra dans une mise à jour lorsqu'une version d'OpenZFS couvrira la 7.3.

---

## En bref

Passage de la production à la série 7.3, car la série 7.2 est en fin de vie en
amont. Les réglages AuxiNux n'ont pas changé. Cette version a été validée en
test sur le canal `kernel-dev` avant sa publication.

La configuration diffère de la 7.2.11 sur quelques valeurs fixées en amont par
Linux, notamment :

- **Chiffrement en ligne des blocs** : activé, avec repli logiciel.
- **Pilotes** : ajout de la prise en charge des cartes série Moxa PCIe.

---

## Installation / mise à jour

Sur une machine sans ZFS uniquement :

```bash
sudo apt update
sudo apt install kernel-virtua
sudo reboot
```

Après redémarrage, vérifiez la version active :

```bash
uname -r
# doit afficher : 7.3.1-auxinux-virtua-amd64
```

**Retour en arrière possible.** La 7.2.11 reste disponible dans le dépôt et, si
elle était déjà présente, installée sur la machine (menu GRUB avancé). Une
machine ZFS mise à jour par erreur peut redémarrer dessus, puis bloquer le paquet
avec `apt-mark hold` comme indiqué plus haut.

---

## Licence

Ce noyau est distribué sous licence GPL-2.0-only. Le code source complet, la
configuration utilisée et les scripts de compilation sont disponibles sur
demande, conformément à la GPL-2.0 §3.
