# Noyau AuxiNux Virtua 7.2.11

**Basé sur :** Linux 7.2.11 (stable, kernel.org, publiée le 15 octobre 2026)
**Pour :** hôtes hyperviseur VirtuaOS sous Debian 13 (Trixie)
**Paquet :** `kernel-virtua` · dépôt APT `dep.auxinux.ca/VIRTUA`, suite `kernel`
**Remplace :** 7.2.4

---

## En bref

Mise à jour de maintenance de la série 7.2. Elle reprend à l'identique la
configuration de la 7.2.4 et apporte les correctifs de stabilité et de
sécurité publiés en amont entre Linux 7.2.4 et 7.2.11.

Les réglages AuxiNux n'ont pas changé. Seules quelques valeurs par défaut
fixées en amont par Linux diffèrent de la 7.2.4 :

- **Mémoire ajoutée à chaud** : la mémoire branchée ou attribuée pendant le
  fonctionnement est désormais mise en service automatiquement, au lieu de
  rester hors ligne jusqu'à une action manuelle.
- **Lecteurs de cartes Alcor Micro** : pris en charge (en module).

---

## Stockage

ZFS reste fourni par OpenZFS 2.4.4, en paquet source DKMS
(`openzfs-zfs-dkms`). Le module est recompilé automatiquement sur la machine
pour ce nouveau noyau lors de l'installation.

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
# doit afficher : 7.2.11-auxinux-virtua-amd64
```

Si ZFS est utilisé, vérifiez que le module a bien été reconstruit pour ce
noyau :

```bash
sudo dkms status
```

**Retour en arrière possible.** La 7.2.4 reste disponible dans le dépôt et
installée sur la machine (menu GRUB avancé) : en cas de problème, vous pouvez
redémarrer dessus le temps de diagnostiquer.

---

## Licence

Ce noyau est distribué sous licence GPL-2.0-only. Le code source complet, la
configuration utilisée et les scripts de compilation sont disponibles sur
demande, conformément à la GPL-2.0 §3.
