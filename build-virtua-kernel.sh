#!/usr/bin/env bash
set -Eeuo pipefail

# Définie tout en haut du script: la validation des arguments (plus bas)
# appelle die() bien avant la section "Helpers", donc elle doit déjà exister.
die() { echo; echo "ERREUR: $*" >&2; exit 1; }

# ============================================================
# Virtua Kernel Builder
# Hyperviseur Virtua (KVM/QEMU + LXC + Docker)
# Base: Debian 13 / Trixie
# ============================================================
#
# Usage:
#   ./build-virtua-kernel.sh                        # source=kernelorg (defaut)
#   ./build-virtua-kernel.sh profile=desktop        # kernel desktop recent
#   ./build-virtua-kernel.sh -arch=arm64            # ARM64/aarch64 build
#   ./build-virtua-kernel.sh source=debian
#   ./build-virtua-kernel.sh source=kernelorg
#   ./build-virtua-kernel.sh -check-kernelorg       # compare kernel.org vs dernier build
#   ./build-virtua-kernel.sh -check-debian          # compare Debian backports vs dernier build
#
# Variables optionnelles (toutes ont une valeur par defaut) :
#
#   RELEASE_TRACK       : "prod" ou "dev" (defaut: prod)
#                         prod -> X.Y.Z-auxinux-virtua-amd64      / kernel-virtua
#                         dev  -> X.Y.Z-dev-auxinux-virtua-amd64  / kernel-virtua-dev
#   SOURCE              : "kernelorg" ou "debian" (defaut: kernelorg)
#   PROFILE             : "virtua", "desktop" ou "auxinuxos" (defaut: virtua)
#   TARGET_ARCH         : "amd64", "arm" ou "arm64" (defaut: amd64)
#   KERNEL_MAJOR        : branche kernel ex: "6.12"
#                         "auto" = detecte la plus recente (defaut: auto)
#   KERNEL_VERSION      : version exacte ex: "6.12.31"
#                         auto-detecte si absent
#   VIRTUA_BUILD_NUMBER : incrementer si on rebuild le MEME upstream
#                         avec une config differente (defaut: 1)
#   META_PACKAGE        : paquet meta recommande dans README
#   JOBS                : parallelisme make (defaut: nproc)
#   BUILD_ROOT          : dossier de travail (defaut: /usr/src/virtua-kernel-build)
#   OUTPUT_DIR          : dossier de sortie des .deb (defaut: BUILD_ROOT/output)
#   CHECK_DIR           : dossier inspecte par -check-* (defaut: OUTPUT_DIR)
#   DEPLOY=1            : copie les .deb produits vers DEPLOY_TARGET
#   DEPLOY_TARGET       : cible locale ou rsync distante (optionnel)
#
# Exemples:
#   ./build-virtua-kernel.sh KERNEL_VERSION=6.12.31
#   JOBS=8 ./build-virtua-kernel.sh source=debian
# ============================================================

SOURCE="kernelorg"
MODE="build"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-current}"
RELEASE_BRANCH="${RELEASE_BRANCH:-}"

# --- Canal de publication (track) : prod ou dev ---------------------------
# NE PAS confondre avec RELEASE_CHANNEL (current/lts/mainline) qui sélectionne
# la série kernel.org. RELEASE_TRACK sélectionne le canal de PUBLICATION :
#   prod -> 7.1.12-auxinux-virtua-amd64       (paquet meta kernel-virtua)
#   dev  -> 7.2.2-dev-auxinux-virtua-amd64    (paquet meta kernel-virtua-dev)
# Le marqueur 'dev' est en minuscules: la policy Debian interdit les majuscules
# dans un nom de paquet, et le nom du paquet noyau est dérivé du release
# (mkdebian écrit "Package: linux-image-${KERNELRELEASE}" tel quel).
# Les deux canaux ont des suffixes, des dossiers de build et des suites APT
# distincts : un kernel DEV ne peut jamais être servi aux hôtes de production.
RELEASE_TRACK="${RELEASE_TRACK:-prod}"

PROFILE="${PROFILE:-virtua}"
PROFILES="${PROFILES:-}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
KERNEL_MAJOR="${KERNEL_MAJOR:-auto}"
KERNEL_FLAVOUR="${KERNEL_FLAVOUR:-}"
META_PACKAGE="${META_PACKAGE:-}"
VIRTUA_BUILD_NUMBER="${VIRTUA_BUILD_NUMBER:-1}"

BUILD_ROOT="${BUILD_ROOT:-}"   # défaut résolu après le track (suffixe -dev)
OUTPUT_DIR="${OUTPUT_DIR:-}"
CHECK_DIR="${CHECK_DIR:-}"
JOBS="${JOBS:-}"
DEPLOY="${DEPLOY:-0}"
# Build à blanc: applique et VÉRIFIE la config, puis s'arrête avant la
# compilation. Sert à valider les ~200 options (et leurs noms de symboles)
# en quelques minutes au lieu d'attendre une compilation complète.
CONFIG_ONLY="${CONFIG_ONLY:-0}"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"

KERNELORG_BASE_URL="https://cdn.kernel.org/pub/linux/kernel"

# --- OpenZFS en paquet source DKMS (modèle Debian) ---
# Construit un paquet SOURCE (openzfs-zfs-dkms, arch=all) qui se recompile via
# DKMS à l'installation, contre le kernel réellement en place sur la machine
# cible. Pas de module précompilé lié à CE kernel: on évite de distribuer un
# .deb binaire qui combine dans un même objet du code GPL-2.0 (Linux) et
# CDDL (OpenZFS) — c'est ce que faisait l'ancien modèle "module précompilé"
# (kmod-zfs-<release>), jugé risqué légalement.
# ATTENTION à la fenêtre de compatibilité kernel d'OpenZFS (fichier META du
# tarball: Linux-Minimum / Linux-Maximum). Hors de cette fenêtre, DKMS échoue à
# compiler chez le client — sans erreur bloquante visible à l'install.
#   OpenZFS 2.4.2 -> Linux-Maximum 7.0  (INSUFFISANT pour un kernel 7.1/7.2)
#   OpenZFS 2.4.4 -> Linux-Maximum 7.2
# L'étape [7b/9] vérifie cette fenêtre et interrompt le build si elle est
# dépassée, au lieu de publier un paquet ZFS qui ne compilera jamais.
WITH_ZFS="${WITH_ZFS:-auto}"          # auto = activé sur amd64 natif, sinon off
ZFS_VERSION="${ZFS_VERSION:-2.4.4}"   # supporte les kernels jusqu'à 7.2
ZFS_BASE_URL="${ZFS_BASE_URL:-https://github.com/openzfs/zfs/releases/download}"
# Publier aussi le userland OpenZFS (zfsutils, zed, libs) construit ici, pour
# qu'il soit à la même version que le module DKMS. Cf. [7b/9].
ZFS_PUBLISH_USERLAND="${ZFS_PUBLISH_USERLAND:-1}"
# Vérification d'intégrité de la source ZFS. Renseigne le sha256 du tarball
# zfs-<ZFS_VERSION>.tar.gz (obligatoire sauf ALLOW_UNVERIFIED_SOURCE=1).
ZFS_SHA256="${ZFS_SHA256:-}"

# Empreintes GPG ÉPINGLÉES des mainteneurs kernel.org (vérification du source).
# Source: https://www.kernel.org/signature.html
KERNEL_ORG_KEYS=(
  "ABAF11C65A2970B130ABE3C479BE3E4300411886"  # Linus Torvalds
  "647F28654894E3BD457199BE38DBBDC86092693E"  # Greg Kroah-Hartman
)
KERNEL_ORG_KEYSERVER="${KERNEL_ORG_KEYSERVER:-hkps://keys.openpgp.org}"
# Garde-fou: ne JAMAIS mettre 1 en production. Uniquement build hors-ligne/test.
ALLOW_UNVERIFIED_SOURCE="${ALLOW_UNVERIFIED_SOURCE:-0}"
# Garde-fou DISTINCT pour la source OpenZFS. Un build mainline/RC désactive la
# vérif GPG du kernel (les snapshots git n'ont pas de .tar.sign), mais cela n'a
# aucune raison d'affaiblir aussi la vérif du tarball ZFS, qui est toujours
# publié avec un sha256 signé. Les deux gardes sont donc indépendantes.
ALLOW_UNVERIFIED_ZFS="${ALLOW_UNVERIFIED_ZFS:-0}"

usage() {
  cat <<EOF
AuxiNux Kernel Builder

Builds custom Debian kernel .deb packages for AuxiNux Virtua.
Default build target: latest stable kernel.org source, profile=virtua.

Usage:
  $0 [options]
  $0 -check-kernelorg [CHECK_DIR=/path/to/debs]
  $0 -check-debian [CHECK_DIR=/path/to/debs]
  $0 -h | --help

Publication track (prod / dev):
  track=prod
      Production kernel. Release: X.Y.Z-auxinux-virtua-amd64
      Meta-package: kernel-virtua, published in APT suite 'kernel'.
      This is the default.

  track=dev
      Test/development kernel. Release: X.Y.Z-dev-auxinux-virtua-amd64
      Meta-package: kernel-virtua-dev, published in APT suite 'kernel-dev'.
      Separate build root, output directory, package names and APT suite, so a
      dev kernel can never reach a production host through the prod suite.

      Note: track=dev selects the PUBLICATION channel. It is unrelated to
      --channel=mainline / --dev, which selects the kernel.org release series.

Profile (fixed by this repository):
  profile=virtua
      Host/hypervisor kernel for Virtua.
      Produces: X.X.X-auxinux-virtua-amd64
      Recommended meta-package: kernel-virtua
      Supported architecture: amd64 only.
      Includes the Wi-Fi/Bluetooth kernel stack needed for wired or wireless hosts.

Source selection:
  source=kernelorg
      Download the latest stable source from kernel.org. This is the default.

  source=debian
      Build from Debian 13/Trixie linux-source packages.

Kernel.org release channel:
  --channel=current
      Latest normal stable release (default). Never selects an RC.
      Add --branch=X.Y to stay on another stable series.

  --channel=lts
      Latest kernel.org longterm release. Add --branch=X.Y to pin a series.

  --channel=mainline
      Latest mainline/RC snapshot. Explicit development build only.

  KERNEL_VERSION=X.Y.Z[-rcN]
      Build an exact version and bypass channel detection.

Architecture:
  -arch=amd64
      Native x86_64/amd64 build. This is the only supported target.
      Produces a kernel release ending with -amd64.

Check modes:
  -check-kernelorg
      Compare the latest stable kernel.org version with the latest built
      linux-image-* package found in CHECK_DIR.

  -check-debian
      Compare the latest Debian linux-source version with the latest built
      linux-image-* package found in CHECK_DIR.

Options:
  KERNEL_VERSION=x.y.z       Build an exact upstream version.
  KERNEL_MAJOR=x.y           Select a major branch, mainly for Debian source.
  TARGET_ARCH=name           Same as -arch=name.
  VIRTUA_BUILD_NUMBER=n      Increment when rebuilding the same upstream version.
  JOBS=n                     Parallel make jobs. Default: nproc.
  BUILD_ROOT=/path           Build workspace.
                             Default: /usr/src/virtua-kernel-build (track prod)
                                      /usr/src/virtua-kernel-build-dev (track dev)
  OUTPUT_DIR=/path           Output directory for generated .deb files.
  CHECK_DIR=/path            Directory inspected by -check-* modes.

OpenZFS en paquet source DKMS (modèle Debian, CDDL/GPL séparées):
  WITH_ZFS=auto|1|0          Build the OpenZFS source package (openzfs-zfs-dkms,
                             arch=all), recompiled via DKMS at install time
                             against whatever kernel is actually present.
                             Default: auto (ON on native amd64, OFF when
                             cross-compiling). Aliases: with-zfs / no-zfs.
  ZFS_VERSION=x.y.z          OpenZFS version. Default: 2.4.4 (supporte kernel 7.2).
  ZFS_PUBLISH_USERLAND=1|0   Publier aussi le userland OpenZFS (zfsutils, zed,
                             libs) à la même version que le module DKMS.
                             Défaut: 1. Debian ne fournit pas les paquets
                             'openzfs-*' que le DKMS recommande.
  ZFS_SHA256=hash            sha256 du tarball zfs-<ZFS_VERSION>.tar.gz.
                             Obligatoire si WITH_ZFS=1 (sauf ALLOW_UNVERIFIED_SOURCE=1).
  ALLOW_UNVERIFIED_SOURCE=1  Désactive la vérif GPG du source kernel (DÉCONSEILLÉ).
  ALLOW_UNVERIFIED_ZFS=1     Désactive la vérif sha256 du source ZFS (DÉCONSEILLÉ).
                             Garde distincte: un build mainline/RC relâche la
                             première sans toucher à la seconde.

Examples:
  $0
  $0 KERNEL_VERSION=7.1.12                      # prod  -> 7.1.12-auxinux-virtua-amd64
  $0 track=dev KERNEL_VERSION=7.2.2             # dev   -> 7.2.2-dev-auxinux-virtua-amd64
  $0 --channel=current --branch=7.0
  $0 --channel=lts --branch=6.18
  $0 KERNEL_VERSION=6.12.31
  $0 source=debian KERNEL_MAJOR=6.12
  $0 ZFS_SHA256=<hash>                 # build + paquet DKMS ZFS 2.4.2 vérifié
  $0 no-zfs                            # kernel seul, sans paquet ZFS
  $0 -docker                           # build dans un conteneur debian:13 amd64

Build dans Docker:
  -docker (ou --docker)      Relance tout le build dans un conteneur debian:13
                             linux/amd64 (utile sur macOS/Windows). Installe les
                             deps, crée un user non-root, monte ./output pour les
                             .deb, et un volume cache 'virtua-kernel-build'.
                             Tous les autres arguments sont transmis tels quels.
                             Foreground: meurt si tu fermes le terminal.
  -docker-bg                 Comme -docker mais DÉTACHÉ: survit à la fermeture du
                             terminal (idéal pour un long build). Journalise dans
                             ./output/virtua-build.log. Suivi: docker logs -f virtua-build
  DOCKER_IMAGE=nom           Image de base. Défaut: debian:13.
  DOCKER_NAME=nom            Nom du conteneur. Défaut: virtua-build.
  $0 -check-kernelorg CHECK_DIR=/var/www/dep.auxinux.ca/VIRTUA/KERNEL

Exit codes for check modes:
  0   already up to date
  10  build required
  1   error
EOF
}

# ============================================================
# Build dans Docker (-docker) : relance TOUT le build dans un conteneur
# debian:13 amd64, installe les deps, et exécute avec les autres arguments.
# Pratique sur macOS/Windows où l'hôte n'est pas Debian.
# ============================================================
run_in_docker() {
  local script_dir image cname inner _docker_track_suffix
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  image="${DOCKER_IMAGE:-debian:13}"
  # Le track n'est pas encore résolu à ce stade (run_in_docker s'exécute avant
  # le parsing complet): on le pré-détecte pour ne pas partager le volume de
  # cache ni le nom de conteneur entre prod et dev.
  _docker_track_suffix=""
  for _a in "$@" ${DOCKER_PASSTHROUGH[@]+"${DOCKER_PASSTHROUGH[@]}"}; do
    case "$_a" in
      track=dev|--track=dev|RELEASE_TRACK=dev) _docker_track_suffix="-dev" ;;
    esac
  done
  [[ "${RELEASE_TRACK:-prod}" != "dev" ]] || _docker_track_suffix="-dev"
  cname="${DOCKER_NAME:-virtua-build${_docker_track_suffix}}"

  command -v docker >/dev/null 2>&1 \
    || { echo "ERREUR: docker introuvable. Installe/ouvre Docker Desktop." >&2; exit 1; }
  docker info >/dev/null 2>&1 \
    || { echo "ERREUR: le démon Docker ne répond pas. Lance Docker Desktop." >&2; exit 1; }

  mkdir -p "$script_dir/output"

  # Script interne du conteneur. En mode détaché, on journalise dans /output
  # (= ./output sur l'hôte) pour garder le log même si le conteneur disparaît.
  inner='
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y sudo ca-certificates rsync
      id builder >/dev/null 2>&1 || useradd -m -s /bin/bash builder
      echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder
      chmod 0440 /etc/sudoers.d/builder
      chown -R builder:builder /work /output "${VIRTUA_BUILD_ROOT}"
      exec sudo -u builder -H env OUTPUT_DIR=/output BUILD_ROOT="${VIRTUA_BUILD_ROOT}" DEPLOY="${DEPLOY}" DEPLOY_TARGET="${DEPLOY_TARGET}" ./build-virtua-kernel.sh "$@"'

  local -a docker_args=(
    --name "$cname"
    --platform linux/amd64
    -v "$script_dir":/work -w /work
    -v "$script_dir/output":/output
    -v "virtua-kernel-build${_docker_track_suffix}":"/usr/src/virtua-kernel-build${_docker_track_suffix}"
    -e DEPLOY="${DEPLOY}"
    -e DEPLOY_TARGET="${DEPLOY_TARGET}"
    -e VIRTUA_BUILD_ROOT="/usr/src/virtua-kernel-build${_docker_track_suffix}"
  )

  # Évite un conflit de nom si un run précédent a laissé un conteneur.
  docker rm -f "$cname" >/dev/null 2>&1 || true

  echo "============================================================"
  echo " Build dans Docker $([[ "$DOCKER_DETACH" == "1" ]] && echo '(détaché — survit à la fermeture du terminal)')"
  echo " Image   : ${image} (plateforme linux/amd64)"
  echo " Source  : ${script_dir}  ->  /work"
  echo " Sortie  : ${script_dir}/output  ->  /output"
  echo " Args    : ${DOCKER_PASSTHROUGH[*]:-(aucun)}"
  echo " Cache   : volume docker 'virtua-kernel-build' (sources/tarballs réutilisés)"
  echo "============================================================"

  if [[ "$DOCKER_DETACH" == "1" ]]; then
    # Détaché: journal vers ./output/virtua-build.log, conteneur conservé.
    docker run -d "${docker_args[@]}" \
      "$image" bash -lc "{ $inner ; } > /output/virtua-build.log 2>&1" \
      _ ${DOCKER_PASSTHROUGH[@]+"${DOCKER_PASSTHROUGH[@]}"} >/dev/null
    echo
    echo "Build lancé en arrière-plan (conteneur '${cname}'). Tu peux fermer le terminal."
    echo "Suivre en direct :   docker logs -f ${cname}"
    echo "        ou (hôte) :   tail -f \"${script_dir}/output/virtua-build.log\""
    echo "État              :   docker ps --filter name=${cname}"
    echo "Arrêter           :   docker rm -f ${cname}"
    echo "Résultats         :   ${script_dir}/output/  (.deb à la fin)"
    exit 0
  fi

  # Foreground interactif.
  local tflag
  if [[ -t 0 ]]; then tflag="-it"; else tflag="-i"; fi
  exec docker run --rm $tflag "${docker_args[@]}" \
    "$image" bash -lc "$inner" \
    _ ${DOCKER_PASSTHROUGH[@]+"${DOCKER_PASSTHROUGH[@]}"}
}

# Détecte -docker AVANT toute logique Debian (sinon échoue sur l'hôte macOS).
DOCKER_BUILD=0
DOCKER_DETACH=0
DOCKER_PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    -docker|--docker|docker) DOCKER_BUILD=1 ;;
    -docker-bg|--docker-bg|-docker-detach|--docker-detach|docker-bg)
      DOCKER_BUILD=1; DOCKER_DETACH=1 ;;
    *) DOCKER_PASSTHROUGH+=("$arg") ;;
  esac
done
if (( DOCKER_BUILD == 1 )); then
  run_in_docker
fi

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    -docker|--docker|docker) ;;                         # déjà traité ci-dessus
    -docker-bg|--docker-bg|-docker-detach|--docker-detach|docker-bg) ;;  # idem
    source=debian) SOURCE="debian" ;;
    source=kernelorg) SOURCE="kernelorg" ;;
    --channel=*|channel=*) RELEASE_CHANNEL="${arg#*=}" ;;
    --branch=*|branch=*) RELEASE_BRANCH="${arg#*=}" ;;
    --current|--stable|--latest) RELEASE_CHANNEL="current" ;;
    --lts|--longterm) RELEASE_CHANNEL="lts" ;;
    --mainline|--dev) RELEASE_CHANNEL="mainline" ;;   # note: --dev = mainline (série), PAS le track dev
    track=*|--track=*|RELEASE_TRACK=*) RELEASE_TRACK="${arg#*=}" ;;
    profile=all) PROFILES="virtua desktop" ;;
    profile=virtua) PROFILE="virtua" ;;
    profile=desktop) PROFILE="desktop" ;;
    profile=auxinuxos) PROFILE="auxinuxos" ;;
    profile=*) PROFILES="${arg#*=}" ;;   # ex: profile=virtua,desktop
    PROFILES=*) PROFILES="${arg#*=}" ;;
    -arch=*) TARGET_ARCH="${arg#*=}" ;;
    --arch=*) TARGET_ARCH="${arg#*=}" ;;
    arch=*) TARGET_ARCH="${arg#*=}" ;;
    TARGET_ARCH=*) TARGET_ARCH="${arg#*=}" ;;
    -check-debian|--check-debian) MODE="check"; SOURCE="debian" ;;
    -check-kernelorg|--check-kernelorg) MODE="check"; SOURCE="kernelorg" ;;
    KERNEL_MAJOR=*) KERNEL_MAJOR="${arg#*=}" ;;
    KERNEL_FLAVOUR=*) KERNEL_FLAVOUR="${arg#*=}" ;;
    META_PACKAGE=*) META_PACKAGE="${arg#*=}" ;;
    KERNEL_VERSION=*) KERNEL_VERSION="${arg#*=}" ;;
    -config-only|--config-only|config-only) CONFIG_ONLY=1 ;;
    VIRTUA_BUILD_NUMBER=*) VIRTUA_BUILD_NUMBER="${arg#*=}" ;;
    JOBS=*) JOBS="${arg#*=}" ;;
    WITH_ZFS=*) WITH_ZFS="${arg#*=}" ;;
    with-zfs) WITH_ZFS="1" ;;
    no-zfs|without-zfs) WITH_ZFS="0" ;;
    ZFS_VERSION=*) ZFS_VERSION="${arg#*=}" ;;
    ZFS_SHA256=*) ZFS_SHA256="${arg#*=}" ;;
    ALLOW_UNVERIFIED_ZFS=*) ALLOW_UNVERIFIED_ZFS="${arg#*=}" ;;
    ZFS_PUBLISH_USERLAND=*) ZFS_PUBLISH_USERLAND="${arg#*=}" ;;
    CROSS_COMPILE=*) CROSS_COMPILE="${arg#*=}" ;;
    BUILD_ROOT=*) BUILD_ROOT="${arg#*=}" ;;
    OUTPUT_DIR=*) OUTPUT_DIR="${arg#*=}" ;;
    CHECK_DIR=*) CHECK_DIR="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERREUR: argument inconnu: $arg"; usage; exit 1 ;;
  esac
done

case "$RELEASE_CHANNEL" in
  current|stable|latest) RELEASE_CHANNEL="current" ;;
  lts|longterm) RELEASE_CHANNEL="lts" ;;
  mainline|dev) RELEASE_CHANNEL="mainline" ;;
  *) die "release channel invalide: ${RELEASE_CHANNEL}. Valeurs: current, lts, mainline." ;;
esac

# ============================================================
# Track de publication: prod / dev
# ============================================================
# Chaque track a son propre suffixe de kernel, son paquet meta, son dossier de
# build et son dossier de sortie. Rien n'est partagé, pour qu'un build dev ne
# puisse ni écraser un artefact prod ni se retrouver dans la suite APT prod.
case "$RELEASE_TRACK" in
  prod|production|stable) RELEASE_TRACK="prod" ;;
  dev|devel|test|testing) RELEASE_TRACK="dev" ;;
  *) die "RELEASE_TRACK invalide: ${RELEASE_TRACK}. Valeurs: prod, dev." ;;
esac

if [[ "$RELEASE_TRACK" == "dev" ]]; then
  TRACK_FLAVOUR="dev-auxinux-virtua"
  TRACK_META="kernel-virtua-dev"
  TRACK_SUITE="kernel-dev"
  TRACK_BUILD_SUFFIX="-dev"
else
  TRACK_FLAVOUR="auxinux-virtua"
  TRACK_META="kernel-virtua"
  TRACK_SUITE="kernel"
  TRACK_BUILD_SUFFIX=""
fi

# This repository owns only the VirtuaOS hypervisor kernel. Desktop and
# AuxiNuxOS workstation profiles live in ../AuxiNuxOS and must never be emitted
# from this project or uploaded to the Virtua kernel channel.
[[ -z "$PROFILES" ]] \
  || die "ce dépôt construit uniquement profile=virtua; utilise ../AuxiNuxOS pour le kernel AuxiNuxOS."
[[ "$PROFILE" == "virtua" ]] \
  || die "profile=${PROFILE} n'appartient pas au projet Kernel/VirtuaOS."
[[ -z "$KERNEL_FLAVOUR" || "$KERNEL_FLAVOUR" == "$TRACK_FLAVOUR" ]] \
  || die "KERNEL_FLAVOUR doit rester ${TRACK_FLAVOUR} sur le track ${RELEASE_TRACK}."
[[ -z "$META_PACKAGE" || "$META_PACKAGE" == "$TRACK_META" ]] \
  || die "META_PACKAGE doit rester ${TRACK_META} sur le track ${RELEASE_TRACK}."

if [[ "$RELEASE_CHANNEL" == "mainline" || "${KERNEL_VERSION:-}" == *-rc* ]]; then
  # Choisir mainline est l'opt-in explicite requis pour le snapshot git non signé.
  ALLOW_UNVERIFIED_SOURCE=1
fi

case "$TARGET_ARCH" in
  amd64)
    KERNEL_ARCH_SUFFIX="amd64"
    KBUILD_ARCH="x86_64"
    KBUILD_DEBARCH="amd64"
    DEFAULT_CROSS_COMPILE=""
    ARCH_DEPS=()
    ;;
  arm)
    KERNEL_ARCH_SUFFIX="arm64"
    KBUILD_ARCH="arm64"
    KBUILD_DEBARCH="arm64"
    DEFAULT_CROSS_COMPILE="aarch64-linux-gnu-"
    ARCH_DEPS=(gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)
    ;;
  arm64)
    KERNEL_ARCH_SUFFIX="arm64"
    KBUILD_ARCH="arm64"
    KBUILD_DEBARCH="arm64"
    DEFAULT_CROSS_COMPILE="aarch64-linux-gnu-"
    ARCH_DEPS=(gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)
    ;;
  *)
    echo "ERREUR: architecture invalide: ${TARGET_ARCH}. Valeurs supportées: amd64, arm, arm64." >&2
    exit 1
    ;;
esac

CROSS_COMPILE="${CROSS_COMPILE:-$DEFAULT_CROSS_COMPILE}"

# Résout WITH_ZFS=auto: ON sur amd64 natif, OFF si cross-compilation (arm64).
# Construire OpenZFS en cross-compile est un nid à problèmes; on l'évite.
if [[ "$WITH_ZFS" == "auto" ]]; then
  if [[ "$KBUILD_DEBARCH" == "amd64" && -z "$CROSS_COMPILE" ]]; then
    WITH_ZFS="1"
  else
    WITH_ZFS="0"
  fi
fi
# sha256 ÉPINGLÉ des versions OpenZFS connues (provenance: fichier sha256.asc
# signé GPG par OpenZFS). Évite d'avoir à le fournir pour la version par défaut.
if [[ -z "$ZFS_SHA256" ]]; then
  case "$ZFS_VERSION" in
    # Provenance: fichier zfs-<v>.sha256.asc signé GPG par le release manager
    # OpenZFS (clé 4F3BA9AB6D1F8D683DC2DFB56AD860EED4598027).
    2.4.2) ZFS_SHA256="7e260d0e6af295bea4c5e241cac0a1aef07b58d8dd8035f7898ade3b1bbec78f" ;;
    2.4.4) ZFS_SHA256="2a3c70d55a37cc71618a95a60e81ad66530201eb118d37741dc92efcf848c8b1" ;;
  esac
fi

if [[ "$DEPLOY" == "1" ]]; then
  [[ -n "$DEPLOY_TARGET" ]] || die "DEPLOY=1 mais DEPLOY_TARGET est vide."
fi

# Sur macOS / Windows, on bascule automatiquement en Docker.
if [[ "$(uname -s)" != "Linux" && "$DOCKER_BUILD" != "1" ]]; then
  DOCKER_BUILD=1
fi

if (( DOCKER_BUILD == 1 )); then
  run_in_docker
fi

# Propage aux builds enfants (profile=all) même si fourni via l'environnement.
export WITH_ZFS ZFS_VERSION ZFS_SHA256

# ============================================================
# Build multi-profil (profile=all / PROFILES="virtua desktop")
# Enchaîne les profils pour LA MÊME architecture en se relançant
# une fois par profil. La logique de build reste mono-profil.
# ============================================================
if [[ -n "$PROFILES" ]]; then
  read -r -a _profiles <<< "${PROFILES//,/ }"

  if [[ "$MODE" == "check" ]]; then
    die "le mode -check-* ne supporte qu'un seul profil. Utilise profile=virtua ou profile=desktop."
  fi

  # Réinjecte les arguments d'origine sans aucune mention de profil
  # (chaque profil est passé explicitement à l'enfant).
  passthrough=()
  for a in "$@"; do
    case "$a" in
      profile=*|PROFILES=*) ;;
      *) passthrough+=("$a") ;;
    esac
  done

  echo "============================================================"
  echo " Build multi-profil: ${_profiles[*]} (arch=${TARGET_ARCH})"
  echo "============================================================"

  for _p in "${_profiles[@]}"; do
    case "$_p" in
      virtua|desktop|auxinuxos) ;;
      *) die "profil invalide dans PROFILES: '${_p}'. Valeurs: virtua, desktop, auxinuxos." ;;
    esac
    if [[ "$_p" == "virtua" && "$KBUILD_DEBARCH" != "amd64" ]]; then
      echo
      echo ">>> profil 'virtua' ignoré sur ${KBUILD_DEBARCH} (supporté amd64 uniquement)."
      continue
    fi
    echo
    echo ">>> ============================================================"
    echo ">>> Build du profil '${_p}' (arch=${TARGET_ARCH})"
    echo ">>> ============================================================"
    # PROFILES= vide pour l'enfant: évite toute récursion (y compris via env).
    # Expansion protégée: tableau vide toléré sous set -u.
    PROFILES= "$0" "profile=${_p}" ${passthrough[@]+"${passthrough[@]}"}
  done

  echo
  echo "============================================================"
  echo " Build multi-profil terminé (${_profiles[*]})"
  echo "============================================================"
  exit 0
fi

if [[ -z "$KERNEL_FLAVOUR" ]]; then
  case "$PROFILE" in
    virtua) KERNEL_FLAVOUR="$TRACK_FLAVOUR" ;;
    desktop) KERNEL_FLAVOUR="auxinux-desktop" ;;
    auxinuxos) KERNEL_FLAVOUR="auxinuxos" ;;
  esac
fi

KERNEL_NAME_SUFFIX="${KERNEL_FLAVOUR}-${KERNEL_ARCH_SUFFIX}"

# Le nom du paquet noyau est dérivé du release: scripts/package/mkdebian écrit
# "Package: linux-image-${KERNELRELEASE}" sans normaliser. dpkg-gencontrol
# refuse alors tout caractère hors [a-z0-9+.-] ("illegal package name"), mais
# seulement à l'étape d'empaquetage — c'est-à-dire APRÈS la compilation
# complète. On valide donc ici, en une seconde, plutôt qu'après 40 minutes.
if [[ ! "$KERNEL_NAME_SUFFIX" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
  die "suffixe de kernel invalide pour un nom de paquet Debian: '${KERNEL_NAME_SUFFIX}'.
Un nom de paquet ne peut contenir que [a-z0-9+.-] et commencer par [a-z0-9]
(policy Debian 5.6.1). Les MAJUSCULES sont notamment interdites: utilise
'dev-auxinux-virtua' et non 'DEV-auxinux-virtua'."
fi

if [[ -z "$META_PACKAGE" ]]; then
  case "$PROFILE" in
    virtua) META_PACKAGE="$TRACK_META" ;;
    desktop) META_PACKAGE="kernel-auxinux-desktop" ;;
    auxinuxos) META_PACKAGE="kernel-auxinuxos" ;;
  esac
fi

# Dossiers distincts par track: un build dev ne doit jamais réutiliser l'arbre
# source ni le dossier de sortie du prod (sinon [8/9] recopierait des .deb de
# l'autre canal dans OUTPUT_DIR, qui est importé tel quel par le dépôt).
BUILD_ROOT="${BUILD_ROOT:-/usr/src/virtua-kernel-build${TRACK_BUILD_SUFFIX}}"
OUTPUT_DIR="${OUTPUT_DIR:-${BUILD_ROOT}/output}"
CHECK_DIR="${CHECK_DIR:-${OUTPUT_DIR}}"
if [[ -z "$JOBS" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
  else
    JOBS="1"
  fi
fi

MAKE_ARCH_ARGS=(ARCH="$KBUILD_ARCH" KBUILD_DEBARCH="$KBUILD_DEBARCH")
if [[ -n "$CROSS_COMPILE" ]]; then
  MAKE_ARCH_ARGS+=(CROSS_COMPILE="$CROSS_COMPILE")
fi

# ============================================================
# Helpers
# ============================================================

# Table des options demandées par les blocs de configuration plus bas.
# Format: "SYMBOLE<TAB>ACTION<TAB>VALEUR_ATTENDUE". Elle est rejouée par
# l'étape [6/9], qui vérifie que CHAQUE option demandée existe réellement dans
# cette version du noyau ET qu'elle a bien été retenue par olddefconfig.
CFG_REQUESTS=()

# NE JAMAIS remettre "|| true" ici.
# scripts/config accepte sans broncher un symbole inexistant: il écrit la ligne
# dans .config, qu'olddefconfig supprime ensuite en silence. Un symbole renommé
# entre deux versions du noyau (MICROCODE_INTEL/MICROCODE_AMD fusionnés dans
# MICROCODE en 6.x, famille MITIGATION_*, drivers crypto x86...) devenait donc
# un no-op parfaitement invisible. La détection réelle est faite en [6/9] via
# l'index des symboles Kconfig de l'arbre source.
cfg() {
  local action="${1:-}" sym="${2:-}" expect
  case "$action" in
    --enable)  expect="y" ;;
    --module)  expect="m" ;;
    --disable) expect="n" ;;
    --set-str) expect="str:${3-}" ;;
    --set-val) expect="val:${3-}" ;;
    *) die "cfg(): action non supportée: '${action}' (symbole ${sym:-?})." ;;
  esac
  [[ -n "$sym" ]] || die "cfg(): symbole manquant pour l'action ${action}."
  CFG_REQUESTS+=("${sym}"$'\t'"${action}"$'\t'"${expect}")
  ./scripts/config "$@" \
    || die "scripts/config a échoué: $* (arbre source incohérent?)"
}

# Valeur réellement présente dans .config pour un symbole (diagnostic).
cfg_actual() {
  local line
  line="$(grep -m1 "^CONFIG_${1}=" .config || true)"
  if [[ -n "$line" ]]; then
    echo "${line#*=}"
  elif grep -q "^# CONFIG_${1} is not set\$" .config; then
    echo "n"
  else
    echo "non défini"
  fi
}

is_supported_debian13_base() {
  case "${ID:-}" in
    debian|virtuaos|auxinux|auxinuxos|auxinux-virtua|virtua) ;;
    *)
      case " ${ID_LIKE:-} " in
        *" debian "*) ;;
        *) case "${PRETTY_NAME:-} ${NAME:-}" in *VirtuaOS*|*AuxinuxOS*|*AuxiNuxOS*) ;; *) return 1 ;; esac ;;
      esac
      ;;
  esac

  [[ "${VERSION_CODENAME:-}" == "trixie" || "${VERSION_ID:-}" == "13" ]]
}

# Vérifie un tarball kernel.org contre les clés mainteneur épinglées.
# Bloquant: toute erreur interrompt le build (sauf ALLOW_UNVERIFIED_SOURCE=1).
verify_kernel_tarball() {
  local tarball="$1" sig="$2"

  command -v gpg >/dev/null 2>&1 \
    || die "gpg requis pour vérifier la source kernel.org (installe gnupg).
Pour passer outre (DÉCONSEILLÉ): ALLOW_UNVERIFIED_SOURCE=1"
  command -v xz >/dev/null 2>&1 || die "xz requis pour vérifier la source."

  local gnupghome
  gnupghome="$(mktemp -d)"
  chmod 700 "$gnupghome"

  # Récupère les clés mainteneur dans un trousseau jetable.
  # 1) WKD de kernel.org = source autoritative pour CES clés.
  # 2) repli keyserver par empreinte si le WKD est injoignable.
  # La validation par empreinte épinglée (plus bas) reste l'autorité finale,
  # donc aucune de ces sources n'affaiblit l'épinglage.
  local key imported=0
  GNUPGHOME="$gnupghome" gpg --batch --quiet --auto-key-locate clear,wkd \
    --locate-keys torvalds@kernel.org gregkh@kernel.org 2>/dev/null && imported=1

  if (( imported == 0 )); then
    for key in "${KERNEL_ORG_KEYS[@]}"; do
      GNUPGHOME="$gnupghome" gpg --batch --quiet \
        --keyserver "$KERNEL_ORG_KEYSERVER" --recv-keys "$key" 2>/dev/null && imported=1
    done
  fi

  local status
  status="$(xz -cd "$tarball" \
    | GNUPGHOME="$gnupghome" gpg --batch --status-fd 1 --verify "$sig" - 2>/dev/null || true)"
  rm -rf "$gnupghome"

  grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status" \
    || die "signature kernel.org INVALIDE ou clé introuvable (${KERNEL_ORG_KEYSERVER}).
Vérifie la connectivité au keyserver. Build interrompu."

  local k matched=0
  for k in "${KERNEL_ORG_KEYS[@]}"; do
    grep -q "VALIDSIG.*${k}" <<<"$status" && matched=1
  done
  (( matched == 1 )) \
    || die "signature VALIDE mais clé NON approuvée (hors liste épinglée). Build interrompu."

  echo "Signature kernel.org vérifiée (clé mainteneur épinglée)."
}

case "$PROFILE" in
  virtua|desktop|auxinuxos) ;;
  *) die "PROFILE invalide: ${PROFILE}. Valeurs supportées: virtua, desktop, auxinuxos." ;;
esac

if [[ "$PROFILE" == "virtua" && "$KBUILD_DEBARCH" != "amd64" ]]; then
  die "profile=virtua is supported only on amd64. Use profile=desktop for arm64 builds."
fi

latest_kernelorg_selected() {
  python3 - "$RELEASE_CHANNEL" "$RELEASE_BRANCH" <<'PY'
import json
import sys
import urllib.request

channel, branch = sys.argv[1:]
with urllib.request.urlopen("https://www.kernel.org/releases.json", timeout=20) as response:
    releases = json.load(response)["releases"]

moniker = {"current": "stable", "lts": "longterm", "mainline": "mainline"}[channel]
matches = [release for release in releases if release.get("moniker") == moniker]
if channel != "mainline":
    matches = [release for release in matches if "-rc" not in release["version"]]
if branch:
    matches = [release for release in matches
               if release["version"] == branch or release["version"].startswith(branch + ".")]
if not matches:
    raise SystemExit(f"no kernel.org release for channel={channel}, branch={branch or 'auto'}")
print(matches[0]["version"])
PY
}

latest_debian_source_version() {
  local major source_pkg_version noepoch

  major="$KERNEL_MAJOR"
  if [[ "$major" == "auto" ]]; then
    major="$(apt-cache pkgnames linux-source- 2>/dev/null \
      | grep -E '^linux-source-[0-9]+\.[0-9]+$' \
      | sed 's/^linux-source-//' \
      | sort -V | tail -n1)"
  fi

  [[ -n "$major" ]] || return 1
  source_pkg_version="$(apt-cache policy "linux-source-${major}" \
    | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$source_pkg_version" && "$source_pkg_version" != "(none)" ]] || return 1

  noepoch="${source_pkg_version#*:}"
  printf '%s\n' "${noepoch%%-*}"
}

latest_built_kernel_version() {
  local f pkg version release upstream

  [[ -d "$CHECK_DIR" ]] || return 1

  for f in "$CHECK_DIR"/*.deb; do
    [[ -e "$f" ]] || continue

    if command -v dpkg-deb >/dev/null 2>&1; then
      pkg="$(dpkg-deb -f "$f" Package 2>/dev/null || true)"
      version="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
      case "$pkg" in
        linux-image-*-"${KERNEL_NAME_SUFFIX}")
          release="${pkg#linux-image-}"
          upstream="${release%-${KERNEL_NAME_SUFFIX}}"
          printf '%s\t%s\t%s\n' "$upstream" "$version" "$pkg"
          ;;
      esac
    else
      case "$(basename "$f")" in
        linux-image-*-"${KERNEL_NAME_SUFFIX}"_*.deb)
          release="$(basename "$f")"
          release="${release#linux-image-}"
          release="${release%%_*}"
          upstream="${release%-${KERNEL_NAME_SUFFIX}}"
          printf '%s\t%s\t%s\n' "$upstream" "inconnu" "linux-image-${release}"
          ;;
      esac
    fi
  done | sort -V | tail -n1
}

version_gt() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$1" gt "$2"
  else
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
  fi
}

run_check() {
  local latest built built_upstream built_pkg_version built_pkg

  if [[ "$SOURCE" == "kernelorg" ]]; then
    echo "Vérification kernel.org (${RELEASE_CHANNEL}${RELEASE_BRANCH:+, branche ${RELEASE_BRANCH}})..."
    latest="$(latest_kernelorg_selected)"
  else
    echo "Vérification Debian linux-source..."
    latest="$(latest_debian_source_version)"
  fi
  [[ -n "$latest" ]] || die "impossible de détecter la dernière version source (${SOURCE})."

  built="$(latest_built_kernel_version || true)"
  if [[ -n "$built" ]]; then
    IFS=$'\t' read -r built_upstream built_pkg_version built_pkg <<< "$built"
  else
    built_upstream="aucun"
    built_pkg_version="aucun"
    built_pkg="aucun"
  fi

  echo
  echo "Source          : ${SOURCE}"
  echo "Dernière source : ${latest}"
  echo "Dernier build   : ${built_upstream}"
  echo "Paquet build    : ${built_pkg}"
  echo "Version paquet  : ${built_pkg_version}"
  echo "Dossier vérifié : ${CHECK_DIR}"
  echo

  if [[ "$built_upstream" == "aucun" ]]; then
    echo "Résultat: BUILD_REQUIS (aucun kernel ${KERNEL_NAME_SUFFIX} trouvé)"
    exit 10
  fi

  if version_gt "$latest" "$built_upstream"; then
    echo "Résultat: BUILD_REQUIS (${latest} > ${built_upstream})"
    exit 10
  fi

  echo "Résultat: À_JOUR (${built_upstream} >= ${latest})"
  exit 0
}

# ============================================================
# Garde-fous
# ============================================================

[[ "$(uname -s)" == "Linux" ]] || die "build natif réservé à Linux; utilise Docker sur macOS/Windows."
[[ "$EUID" -ne 0 ]] || die "ne lance pas ce script en root. Utilise ton utilisateur normal avec sudo."
[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
. /etc/os-release
is_supported_debian13_base || \
  die "prévu pour Debian 13 / VirtuaOS / AuxinuxOS Trixie. Détecté: ${PRETTY_NAME:-inconnu}"

if [[ "$MODE" == "check" && "$SOURCE" == "kernelorg" ]]; then
  run_check
fi

# ============================================================
# [1/9] Dépôt backports
# ============================================================
echo
echo "[1/9] Ajout trixie-backports si absent..."

sudo mkdir -p /etc/apt/sources.list.d

if [[ ! -f /etc/apt/sources.list.d/trixie-backports.sources ]]; then
  sudo tee /etc/apt/sources.list.d/trixie-backports.sources > /dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi

sudo apt update

if [[ "$MODE" == "check" ]]; then
  run_check
fi

# ============================================================
# [2/9] Dépendances
# ============================================================
echo
echo "[2/9] Installation des dépendances..."

COMMON_DEPS=(
  build-essential fakeroot bc bison flex
  libssl-dev libelf-dev libdw-dev dwarves
  cpio rsync xz-utils kmod zstd
  debhelper dpkg-dev python3 tar gzip wget
  gnupg dirmngr ca-certificates   # vérification GPG du source kernel.org
)

# Dépendances de build OpenZFS (paquet source DKMS, empaquetage NATIF Debian
# via native-deb-utils / dpkg-buildpackage).
ZFS_DEPS=(
  autoconf automake libtool gawk
  uuid-dev libblkid-dev libudev-dev
  zlib1g-dev libaio-dev libattr1-dev libffi-dev
  libtirpc-dev                        # XDR/RPC requis par native-deb-utils
  python3-dev python3-setuptools
  debhelper dh-python po-debconf      # packaging .deb natif (pas d'alien/rpm)
)
if [[ "$WITH_ZFS" == "1" ]]; then
  COMMON_DEPS+=("${ZFS_DEPS[@]}")
fi

if [[ "$SOURCE" == "debian" ]]; then
  # Détection de KERNEL_MAJOR si auto
  if [[ "${KERNEL_MAJOR}" == "auto" ]]; then
    echo "Détection de la dernière linux-source disponible dans backports..."
    KERNEL_MAJOR="$(apt-cache pkgnames linux-source- 2>/dev/null \
        | grep -E '^linux-source-[0-9]+\.[0-9]+$' \
        | sed 's/^linux-source-//' \
        | sort -V | tail -n1)"
    [[ -n "$KERNEL_MAJOR" ]] || \
      die "impossible de détecter linux-source. Définis KERNEL_MAJOR (ex: KERNEL_MAJOR=6.12)."
    echo "Source détectée: linux-source-${KERNEL_MAJOR}"
  fi

  sudo apt install -y "${COMMON_DEPS[@]}" \
    "${ARCH_DEPS[@]}" \
    "linux-source-${KERNEL_MAJOR}/trixie-backports"

else
  # kernelorg: pas besoin du paquet linux-source, juste les outils
  sudo apt install -y "${COMMON_DEPS[@]}" "${ARCH_DEPS[@]}"
fi

# ============================================================
# [3/9] Récupération du source kernel
# ============================================================
echo
echo "[3/9] Récupération du source kernel (source=${SOURCE})..."

sudo mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
sudo chown -R "$(id -un):$(id -gn)" "$BUILD_ROOT"
# OUTPUT_DIR hors de BUILD_ROOT (ex: OUTPUT_DIR=~/out-7.2.11) restait à root:
# la copie finale des .deb échouait après ~5h de compilation.
sudo chown "$(id -un):$(id -gn)" "$OUTPUT_DIR"
cd "$BUILD_ROOT"

if [[ "$SOURCE" == "debian" ]]; then
  # --- Source Debian ---
  SOURCE_TAR="/usr/src/linux-source-${KERNEL_MAJOR}.tar.xz"
  [[ -f "$SOURCE_TAR" ]] || die "source introuvable: $SOURCE_TAR"

  SOURCE_PKG_VERSION="$(dpkg-query -W -f='${Version}' "linux-source-${KERNEL_MAJOR}")"
  _noepoch="${SOURCE_PKG_VERSION#*:}"
  KERNEL_VERSION="${KERNEL_VERSION:-${_noepoch%%-*}}"

  echo "Source paquet : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})"
  echo "Version kernel: ${KERNEL_VERSION}"

  rm -rf "linux-source-${KERNEL_MAJOR}"
  rm -f ./*.deb ./*.changes ./*.buildinfo
  echo "Extraction de $SOURCE_TAR..."
  tar -xf "$SOURCE_TAR"
  SOURCE_DIR="${BUILD_ROOT}/linux-source-${KERNEL_MAJOR}"

else
  # --- Source kernel.org ---

  # Détermine KERNEL_MAJOR et KERNEL_VERSION
  if [[ "${KERNEL_MAJOR}" == "auto" && -z "${KERNEL_VERSION:-}" ]]; then
    echo "Détection kernel.org (${RELEASE_CHANNEL}${RELEASE_BRANCH:+, branche ${RELEASE_BRANCH}})..."
    LATEST="$(latest_kernelorg_selected)"
    [[ -n "$LATEST" ]] || \
      die "impossible de détecter la version sur kernel.org. Définis KERNEL_VERSION (ex: KERNEL_VERSION=6.12.31)."
    KERNEL_VERSION="$LATEST"
    echo "Version détectée: ${KERNEL_VERSION}"
  elif [[ -z "${KERNEL_VERSION:-}" ]]; then
    die "KERNEL_VERSION requis avec source=kernelorg quand KERNEL_MAJOR est défini. Ex: KERNEL_VERSION=6.12.31"
  fi

  # Déduit KERNEL_MAJOR depuis KERNEL_VERSION si besoin (ex: 6.12.31 -> 6.12)
  KERNEL_MAJOR="${KERNEL_MAJOR:-$(echo "$KERNEL_VERSION" | cut -d. -f1,2)}"
  [[ "${KERNEL_MAJOR}" != "auto" ]] || \
    KERNEL_MAJOR="$(echo "$KERNEL_VERSION" | cut -d. -f1,2)"

  MAJOR_NUM="$(echo "$KERNEL_VERSION" | cut -d. -f1)"
  if [[ "$KERNEL_VERSION" == *-rc* ]]; then
    # kernel.org publie les RC de Linus comme snapshots git, sans .tar.sign.
    TARBALL="linux-${KERNEL_VERSION}.tar.gz"
    TARBALL_SIG=""
    DOWNLOAD_URL="https://git.kernel.org/torvalds/t/${TARBALL}"
    SIG_URL=""
    [[ "$ALLOW_UNVERIFIED_SOURCE" == "1" ]] || die \
      "mainline ${KERNEL_VERSION} est un snapshot git sans signature tarball. Relance avec ALLOW_UNVERIFIED_SOURCE=1 pour un build de développement explicite."
  else
    TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    TARBALL_SIG="linux-${KERNEL_VERSION}.tar.sign"
    KERNELORG_SERIES_URL="${KERNELORG_BASE_URL}/v${MAJOR_NUM}.x"
    DOWNLOAD_URL="${KERNELORG_SERIES_URL}/${TARBALL}"
    SIG_URL="${KERNELORG_SERIES_URL}/${TARBALL_SIG}"
  fi

  echo "Téléchargement: ${DOWNLOAD_URL}"

  rm -rf "linux-${KERNEL_VERSION}"
  rm -f ./*.deb ./*.changes ./*.buildinfo

  # Télécharge seulement si pas déjà là (pratique pour relancer)
  if [[ ! -f "${TARBALL}" ]]; then
    wget -c --show-progress "${DOWNLOAD_URL}" -O "${TARBALL}"
  else
    echo "Tarball déjà présent, réutilisation: ${TARBALL}"
  fi

  # Vérification de signature OBLIGATOIRE du tarball kernel.org.
  if [[ "$ALLOW_UNVERIFIED_SOURCE" == "1" ]]; then
    echo "AVERTISSEMENT: ALLOW_UNVERIFIED_SOURCE=1 — vérification GPG de la source IGNORÉE (déconseillé)."
  else
    echo "Vérification de la signature du source kernel.org..."
    if [[ ! -f "${TARBALL_SIG}" ]]; then
      wget -q "${SIG_URL}" -O "${TARBALL_SIG}" \
        || die "impossible de télécharger la signature ${SIG_URL}.
Le source ne peut pas être vérifié. Pour passer outre (DÉCONSEILLÉ): ALLOW_UNVERIFIED_SOURCE=1"
    fi
    verify_kernel_tarball "${TARBALL}" "${TARBALL_SIG}"
  fi

  echo "Extraction..."
  tar -xf "${TARBALL}"
  SOURCE_DIR="${BUILD_ROOT}/linux-${KERNEL_VERSION}"
  SOURCE_PKG_VERSION="kernel.org"
fi

# ============================================================
# [4/9] Config de base
# ============================================================
echo
echo "[4/9] Sélection de la config de base..."

cd "$SOURCE_DIR"

pick_base_config() {
  local c
  # 1) config Debian dont le nom contient la version detectee
  for c in /boot/config-"${KERNEL_VERSION}"*-amd64; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  # 2) la config amd64 la plus recente presente
  c="$(ls -1 /boot/config-*-amd64 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
  # 3) le kernel courant
  [[ -f "/boot/config-$(uname -r)" ]] && { echo "/boot/config-$(uname -r)"; return 0; }
  return 1
}

BASE_CONFIG="$(pick_base_config || true)"

if [[ "$KBUILD_DEBARCH" != "amd64" ]]; then
  echo "Architecture cible non-amd64 (${KBUILD_DEBARCH}); utilisation de make defconfig."
  make "${MAKE_ARCH_ARGS[@]}" defconfig
elif [[ -n "${BASE_CONFIG}" ]]; then
  cp "$BASE_CONFIG" .config
  echo "Config de base: $BASE_CONFIG"
else
  # Pas de config Debian dans /boot (cas typique en conteneur Docker).
  # On installe le kernel de référence Debian pour obtenir une VRAIE config
  # amd64. IMPORTANT: on n'utilise PAS /proc/config.gz en priorité — dans un
  # conteneur c'est la config de l'hôte (LinuxKit/Docker Desktop), sans
  # VIRTUALIZATION ni KVM, ce qui casse le build hyperviseur.
  echo "Aucune config Debian dans /boot; installation du kernel de référence..."
  sudo apt install -y linux-image-amd64 linux-headers-amd64 \
    || sudo apt install -y -t trixie-backports linux-image-amd64 linux-headers-amd64 \
    || true
  BASE_CONFIG="$(pick_base_config || true)"
  if [[ -n "${BASE_CONFIG}" ]]; then
    cp "$BASE_CONFIG" .config
    echo "Config de base: $BASE_CONFIG"
  elif [[ -f /proc/config.gz ]]; then
    echo "AVERTISSEMENT: aucune config Debian; repli sur /proc/config.gz (config hôte,"
    echo "  potentiellement incomplète). Les options critiques seront re-forcées ensuite."
    zcat /proc/config.gz > .config
  else
    die "impossible de trouver une config kernel de base (ni /boot, ni paquet Debian, ni /proc/config.gz)."
  fi
fi

LOCAL_VERSION="-${KERNEL_NAME_SUFFIX}"
PKG_VERSION="${KERNEL_VERSION}-${KERNEL_NAME_SUFFIX}.${VIRTUA_BUILD_NUMBER}"

echo
echo "============================================================"
echo " Virtua Kernel Builder"
echo " Track         : ${RELEASE_TRACK} (suite APT '${TRACK_SUITE}', meta ${META_PACKAGE})"
echo " Source        : ${SOURCE}"
echo " Profile       : ${PROFILE}"
echo " Target arch   : ${TARGET_ARCH} (kernel ARCH=${KBUILD_ARCH}, deb=${KBUILD_DEBARCH})"
echo " Cross compile : ${CROSS_COMPILE:-none}"
echo " Source pkg    : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})"
echo " Kernel cible  : ${KERNEL_VERSION}${LOCAL_VERSION}"
echo " Version dpkg  : ${PKG_VERSION}"
echo " Meta paquet   : ${META_PACKAGE}"
echo " Build root    : ${BUILD_ROOT}"
echo " Output dir    : ${OUTPUT_DIR}"
echo " Jobs          : ${JOBS}"
echo "============================================================"

# Adapte la config empruntee a CETTE version du source
make "${MAKE_ARCH_ARGS[@]}" olddefconfig

# ============================================================
# [5/9] Configuration AuxiNux
# ============================================================
echo
echo "[5/9] Application de la configuration AuxiNux (${PROFILE})..."

# --- Nom du kernel ---
# CONFIG_LOCALVERSION fournit le suffixe.
# LOCALVERSION="" vide passé à make évite:
#   - le doublement du suffixe custom
#   - le "+" parasite sur arbres type git
cfg --set-str LOCALVERSION "$LOCAL_VERSION"
cfg --disable LOCALVERSION_AUTO

# --- Pas de clés de signature hors infra Debian ---
cfg --set-str SYSTEM_TRUSTED_KEYS ""
cfg --set-str SYSTEM_REVOCATION_KEYS ""

# --- Infos de debug et BTF --------------------------------------------------
# BTF (DEBUG_INFO_BTF) est requis par tout l'outillage eBPF CO-RE moderne:
# bpftrace, cilium, systemd-oomd, l'observabilité des conteneurs. C'est le
# défaut Debian et l'hôte VirtuaOS est justement un hôte à conteneurs.
#
# ATTENTION à la contrainte Kconfig (lib/Kconfig.debug):
#     config DEBUG_INFO_BTF
#         depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
# BTF et DEBUG_INFO_REDUCED sont donc MUTUELLEMENT EXCLUSIFS: il faut du DWARF
# complet. Le surcoût est du temps de build et un gros vmlinux intermédiaire,
# PAS un gros vmlinuz: seul le BTF dédupliqué (~4-6 Mo) part dans l'image.
# Le paquet linux-image-*-dbg produit au passage n'est pas publié ([8/9]).
cfg --disable DEBUG_INFO_NONE
cfg --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
cfg --disable DEBUG_INFO_REDUCED
cfg --disable DEBUG_INFO_SPLIT
cfg --enable DEBUG_INFO_BTF
cfg --enable DEBUG_INFO_BTF_MODULES

# --- Compression: kernel et modules ----------------------------------------
cfg --enable KERNEL_ZSTD
cfg --enable MODULE_COMPRESS
cfg --enable MODULE_COMPRESS_ZSTD

# --- Modules hors-arbre (OpenZFS DKMS): gardes OBLIGATOIRES ----------------
# TRIM_UNUSED_KSYMS élague les symboles exportés non utilisés en interne et
# casse la compilation de TOUT module hors-arbre. Le module ZFS DKMS ne se
# construirait plus chez le client — et un échec DKMS ne fait PAS échouer apt.
cfg --disable TRIM_UNUSED_KSYMS
# Un module DKMS est non signé: MODULE_SIG_FORCE ou un lockdown actif
# l'empêcheraient de charger, et un hôte ZFS-on-root ne remonterait pas.
cfg --disable MODULE_SIG_FORCE
cfg --enable MODVERSIONS

if [[ "$PROFILE" == "virtua" ]]; then

# --- KVM / QEMU / virtualisation ---
cfg --enable VIRTUALIZATION     # porte menu x86: sans elle, KVM est ignore
cfg --enable KVM
cfg --module KVM_INTEL          # module: ne charge que sur hote Intel
cfg --module KVM_AMD            # module: ne charge que sur hote AMD
cfg --enable KVM_XEN
cfg --enable VFIO
cfg --enable VFIO_PCI
cfg --enable VFIO_IOMMU_TYPE1
# VFIO_MDEV: tristate sans prompt, auto-sélectionné par les pilotes mdev.
cfg --enable IOMMUFD           # interface moderne QEMU/VFIO
cfg --enable VFIO_DEVICE_CDEV  # exposition VFIO via iommufd
cfg --enable PCI_STUB           # bind device pour passthrough
cfg --enable IOMMU_SUPPORT
cfg --enable INTEL_IOMMU
cfg --enable AMD_IOMMU
cfg --enable IRQ_REMAP
cfg --enable VFIO_PCI_IGD        # passthrough iGPU Intel
# INTEL_IOMMU_DEFAULT_ON reste volontairement OFF: l'activer par défaut casse
# le boot sur certaines cartes anciennes. Opt-in documenté: intel_iommu=on iommu=pt.
cfg --disable INTEL_IOMMU_DEFAULT_ON

# --- KVM: fonctions avancées ---
cfg --enable KVM_SMM
cfg --enable KVM_AMD_SEV         # chiffrement mémoire invité AMD (SEV/SEV-ES/SNP)
cfg --disable KVM_WERROR
# PARAVIRT: indispensable si VirtuaOS tourne lui-même dans une VM (imbrication).
cfg --enable PARAVIRT
cfg --enable PARAVIRT_SPINLOCKS

# --- Perf hyperviseur ---
cfg --enable KSM                # dedup memoire entre VMs
cfg --enable TRANSPARENT_HUGEPAGE
cfg --enable HUGETLBFS
cfg --enable HUGETLB_PAGE

# --- VirtIO / vhost ---
cfg --enable VIRTIO
cfg --enable VIRTIO_PCI
cfg --enable VIRTIO_BLK
cfg --enable VIRTIO_NET
cfg --enable VIRTIO_CONSOLE
cfg --enable VIRTIO_BALLOON
cfg --enable VIRTIO_INPUT
cfg --enable VIRTIO_FS
cfg --enable VIRTIO_MEM        # hotplug mémoire des VMs
cfg --module VIRTIO_PMEM       # mémoire persistante VirtIO
cfg --enable VHOST
cfg --enable VHOST_NET
cfg --enable VHOST_VSOCK
cfg --module VHOST_SCSI
cfg --enable VHOST_IOTLB
cfg --module VHOST_VDPA
cfg --enable VDPA
cfg --module VP_VDPA
cfg --module MLX5_VDPA_NET
cfg --enable VSOCKETS
cfg --enable VIRTIO_VSOCKETS

# --- Réseau hyperviseur ---
cfg --enable TUN
cfg --enable TAP
cfg --enable MACVLAN
cfg --enable MACVTAP             # interfaces macvtap pour VMs
cfg --enable IPVLAN
cfg --enable BRIDGE
cfg --enable VLAN_8021Q
cfg --module VXLAN
cfg --module GENEVE
cfg --module BONDING
cfg --module OPENVSWITCH
cfg --enable NETFILTER
cfg --enable NF_TABLES
cfg --enable NET_SCHED
cfg --enable NET_CLS_CGROUP
cfg --enable NET_CLS_BPF
cfg --enable NET_ACT_BPF
cfg --enable XFRM_USER
cfg --module WIREGUARD
# IPVS: services Docker Swarm / Kubernetes.
cfg --module IP_VS
cfg --module IP_VS_RR
cfg --module IP_VS_WRR
cfg --enable IP_VS_NFCT
cfg --enable BRIDGE_VLAN_FILTERING

# --- LXC / Docker / containers ---
cfg --enable CGROUPS
cfg --enable CGROUP_BPF
cfg --enable CGROUP_FREEZER
cfg --enable CGROUP_PIDS
cfg --enable CGROUP_DEVICE
cfg --enable CGROUP_SCHED
cfg --enable FAIR_GROUP_SCHED
cfg --enable CFS_BANDWIDTH
cfg --enable CGROUP_CPUACCT
cfg --enable CGROUP_PERF
cfg --enable CGROUP_HUGETLB
cfg --enable BLK_CGROUP
cfg --enable BLK_CGROUP_IOCOST
cfg --enable CPUSETS
cfg --enable MEMCG
cfg --enable PSI
cfg --enable NAMESPACES
cfg --enable USER_NS
cfg --enable NET_NS
cfg --enable PID_NS
cfg --enable IPC_NS
cfg --enable UTS_NS
cfg --enable TIME_NS
cfg --enable OVERLAY_FS
cfg --enable SECCOMP
cfg --enable SECCOMP_FILTER
cfg --enable VETH               # paires veth: indispensable Docker/LXC
cfg --enable CHECKPOINT_RESTORE # migration et restauration CRIU/LXC
cfg --enable POSIX_MQUEUE
cfg --enable KEYS
cfg --enable DEVTMPFS
cfg --enable BPF_SYSCALL
cfg --enable BPF_JIT
cfg --enable BPF_JIT_ALWAYS_ON
cfg --enable BPF_UNPRIV_DEFAULT_OFF
cfg --enable CGROUP_MISC
cfg --enable CGROUP_WRITEBACK
cfg --enable BLK_DEV_THROTTLING

# --- LSM: la chaîne compte autant que les options --------------------------
# SECURITY_APPARMOR=y ne suffit PAS: si 'apparmor' n'est pas dans CONFIG_LSM,
# les profils AppArmor de Docker et LXC ne s'appliquent jamais — en silence,
# sans erreur visible. On reprend la chaîne exacte de Debian 13.
cfg --enable SECURITY
cfg --enable SECURITY_APPARMOR
cfg --enable SECURITY_LANDLOCK   # utilisé par systemd 257
cfg --enable SECURITY_YAMA
cfg --enable SECURITY_SELINUX
cfg --set-str LSM "landlock,lockdown,yama,integrity,apparmor,bpf"

# --- Prérequis systemd (fichier REQUIREMENTS amont) ------------------------
# Aujourd'hui hérités par chance de la config Debian, jamais vérifiés.
cfg --enable FHANDLE
cfg --enable DMIID
cfg --enable INOTIFY_USER
cfg --enable SIGNALFD
cfg --enable TIMERFD
cfg --enable EPOLL
cfg --enable SYSVIPC
cfg --enable TMPFS
cfg --enable TMPFS_POSIX_ACL
cfg --enable TMPFS_XATTR
cfg --enable CRYPTO_USER_API_HASH
cfg --enable KCMP
cfg --enable NET_NS
cfg --enable PROC_FS
cfg --enable SYSFS

# --- Réseau containers (NAT Docker) ---
cfg --enable BRIDGE_NETFILTER
cfg --enable NF_CONNTRACK
cfg --enable NF_NAT
cfg --enable NETFILTER_XT_MATCH_ADDRTYPE
cfg --enable NETFILTER_XT_MATCH_CONNTRACK
cfg --enable IP_NF_IPTABLES
# En 7.x les cibles ci-dessous dépendent de IP_NF_IPTABLES_LEGACY, absent de la
# config Debian (ère nftables). Le chemin nft est déjà couvert par NFT_NAT et
# NFT_MASQ, mais on garde le backend legacy en modules: certains déploiements
# Docker/LXC plus anciens s'appuient encore sur iptables-legacy.
# NETFILTER_XTABLES_LEGACY est desactive chez Debian (ere nftables) et
# conditionne tout le backend legacy: il faut l'activer AVANT les cibles.
cfg --enable NETFILTER_XTABLES_LEGACY
cfg --module IP_NF_IPTABLES_LEGACY
cfg --module IP_NF_FILTER
cfg --module IP_NF_NAT
cfg --module IP_NF_TARGET_MASQUERADE
cfg --enable NFT_NAT
cfg --enable NFT_MASQ

# --- Wi-Fi / Bluetooth pour hosts Virtua raccordés en sans-fil ---
# Le host doit rester capable de monter un lien radio même s'il n'est pas filaire.
cfg --enable RFKILL
cfg --module CFG80211
cfg --module MAC80211
cfg --module BT

# --- Stockage hyperviseur ---
cfg --enable BLK_DEV_DM
cfg --enable DM_THIN_PROVISIONING
cfg --enable DM_SNAPSHOT
cfg --enable DM_CACHE
cfg --enable MD
cfg --enable BLK_DEV_NVME
cfg --enable NVME_CORE
cfg --module NFS_FS
cfg --module CIFS
cfg --enable FUSE_FS
cfg --module SQUASHFS
cfg --module AUTOFS_FS

# --- Filesystems ---
# EXT4 et BTRFS TOUS DEUX built-in: le parc est mixte (racines ext4 héritées
# du 7.1.x et racines BTRFS). Un pilote de racine en built-in monte / même si
# l'initramfs est cassé ou périmé — c'est directement de la robustesse au
# reboot, le sujet de cette version.
cfg --enable EXT4_FS
cfg --enable BTRFS_FS
cfg --enable BTRFS_FS_POSIX_ACL
cfg --module XFS_FS
cfg --module F2FS_FS

# BTRFS: tout le debug coupé (gain réel sur le chemin d'écriture).
cfg --disable BTRFS_DEBUG
cfg --disable BTRFS_ASSERT
cfg --disable BTRFS_FS_RUN_SANITY_TESTS

# Compression BTRFS en built-in: sans ça, compress=zstd est inutilisable au
# montage de la racine.
cfg --enable ZSTD_COMPRESS
cfg --enable ZSTD_DECOMPRESS
cfg --enable LZO_COMPRESS
cfg --enable LZO_DECOMPRESS

# Checksums BTRFS accélérés matériellement (crc32c par défaut).
cfg --enable CRYPTO_CRC32C
cfg --enable CRYPTO_XXHASH
cfg --enable CRYPTO_BLAKE2B
cfg --enable CRYPTO_SHA256

# Ordonnanceurs d'E/S: mq-deadline par défaut, kyber/bfq disponibles.
cfg --enable MQ_IOSCHED_DEADLINE
cfg --enable MQ_IOSCHED_KYBER
cfg --enable IOSCHED_BFQ
cfg --enable BLK_WBT
cfg --enable BLK_WBT_MQ

# --- GPU lourds: volontairement absents -------------------------------------
# Sur un hyperviseur c'est le BON choix: un pilote hôte lié au GPU empêche de
# le céder à une VM en passthrough VFIO.
cfg --disable DRM_AMDGPU
cfg --disable DRM_NOUVEAU
cfg --disable DRM_RADEON
cfg --disable DRM_XE
cfg --disable DRM_I915

# --- Console serveur --------------------------------------------------------
# Sans pilote d'affichage, la machine boote et fonctionne mais l'écran reste
# NOIR — régulièrement diagnostiqué à tort comme "plantée au reboot".
# AST (ASPEED) et MGAG200 (Matrox G200) sont les contrôleurs des BMC présents
# sur la quasi-totalité des cartes serveur (iDRAC, iLO, Supermicro).
cfg --enable VT
cfg --enable VT_CONSOLE
cfg --enable FRAMEBUFFER_CONSOLE
cfg --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
cfg --enable DRM
cfg --enable DRM_KMS_HELPER
cfg --enable DRM_FBDEV_EMULATION
cfg --enable DRM_SIMPLEDRM
cfg --enable SYSFB_SIMPLEFB
cfg --module DRM_AST
cfg --module DRM_MGAG200
# Affichages émulés, pour un VirtuaOS lui-même invité (imbrication).
cfg --module DRM_BOCHS
cfg --module DRM_QXL
cfg --module DRM_VIRTIO_GPU
cfg --module DRM_VMWGFX

# --- Entrée console: PS/2 et USB -------------------------------------------
# Sans ça, aucun clavier en rescue GRUB/console sur les machines anciennes.
cfg --enable INPUT_EVDEV
cfg --enable HID
cfg --enable HID_GENERIC
cfg --module USB_HID
cfg --enable USB_SUPPORT
cfg --module USB_XHCI_HCD
cfg --module USB_EHCI_HCD        # indispensable avant 2012
cfg --module USB_OHCI_HCD
cfg --module USB_UHCI_HCD
cfg --module USB_STORAGE
cfg --enable SERIO_I8042         # PS/2, machines pré-2013
cfg --enable KEYBOARD_ATKBD

# --- Console série ----------------------------------------------------------
# Seul moyen de capturer une panic de reboot sur un serveur distant.
cfg --enable SERIAL_8250
cfg --enable SERIAL_8250_CONSOLE
cfg --enable SERIAL_CORE_CONSOLE

# ============================================================
# Plateforme CPU: couvrir Intel et AMD sur 12 ans et plus
# ============================================================
# En 7.2 le choix "x86-64 Processor family" (GENERIC_CPU/MK8/MCORE2) a été
# SUPPRIMÉ d'arch/x86/Kconfig.cpu: un build amd64 est déjà en baseline
# -march=x86-64, donc compatible de l'Athlon 64 à Zen 6. La couverture est
# acquise par construction — il ne reste qu'à la protéger.
#
# X86_NATIVE_CPU compile en -march=native, produisant un kernel accordé au CPU
# de la MACHINE DE BUILD: il tombe en #UD sur toute machine plus ancienne.
# C'est littéralement le mécanisme "ça boote ici, pas là".
cfg --disable X86_NATIVE_CPU

# Microcode: errata CPU (TSX Haswell, AMD fam 15h). En 6.x/7.x les symboles
# MICROCODE_INTEL et MICROCODE_AMD ont été FUSIONNÉS dans MICROCODE.
cfg --enable MICROCODE
# Le chargement à chaud est une source connue de corruption/panic: on charge
# via l'initramfs au démarrage, pas sur un système en marche.
cfg --disable MICROCODE_LATE_LOADING

# Fréquence: aucun driver ne couvre 12 ans à lui seul.
#   X86_ACPI_CPUFREQ : Core 2 -> Sandy Bridge, AMD K10/Bulldozer/Piledriver
#   X86_POWERNOW_K8  : AMD K8/K10
#   X86_INTEL_PSTATE : Sandy Bridge et suivants
#   X86_AMD_PSTATE   : Zen 2 et suivants UNIQUEMENT
# Sans acpi-cpufreq, tout AMD antérieur à Zen 2 tourne à fréquence figée.
cfg --enable CPU_FREQ
cfg --enable X86_ACPI_CPUFREQ
cfg --module X86_POWERNOW_K8
cfg --enable X86_INTEL_PSTATE
cfg --enable X86_AMD_PSTATE
cfg --module X86_PCC_CPUFREQ
cfg --enable CPU_FREQ_GOV_SCHEDUTIL
cfg --enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
cfg --enable CPU_FREQ_GOV_PERFORMANCE
cfg --enable CPU_FREQ_GOV_POWERSAVE
cfg --enable CPU_FREQ_GOV_ONDEMAND
cfg --enable CPU_IDLE
cfg --enable INTEL_IDLE

# Topologie: Turbo Boost Max 3.0, SMT, chiplets Zen.
cfg --enable SMP
cfg --enable SCHED_MC
cfg --enable SCHED_MC_PRIO
cfg --enable SCHED_SMT
cfg --enable SCHED_CLUSTER
cfg --enable X86_X2APIC
cfg --enable NUMA
cfg --enable NUMA_BALANCING

# Ordonnancement adapté à un hôte VM + conteneurs.
# La base Debian sélectionne déjà PREEMPT_LAZY et NO_HZ_FULL, et ce sont de
# MEILLEURS choix qu'un PREEMPT_VOLUNTARY/NO_HZ_IDLE forcés:
#   - PREEMPT_LAZY: latence proche du preempt complet sans son surcoût.
#   - NO_HZ_FULL: mode tickless intégral sur les CPU listés dans nohz_full=,
#     gain réel de latence pour des vCPU épinglés. Sans nohz_full= au boot, le
#     comportement est celui de NO_HZ_IDLE: on ne perd rien.
# PREEMPT_DYNAMIC laisse de toute façon basculer le modèle au boot (preempt=).
cfg --enable PREEMPT_DYNAMIC     # preempt= sélectionnable au boot
cfg --enable HZ_250
cfg --enable HIGH_RES_TIMERS
cfg --enable RCU_NOCB_CPU        # opt-in au boot via rcu_nocbs=
# SCHED_AUTOGROUP est une fonctionnalité desktop (groupement par session tty)
# qui fausse l'équité entre conteneurs et VM sur un serveur.
cfg --disable SCHED_AUTOGROUP

# ============================================================
# Robustesse au boot et au reboot
# ============================================================
# Cause n°1 des reboots spontanés "sur certaines machines": un watchdog
# matériel armé par le BIOS que personne ne nourrit. WATCHDOG_HANDLE_BOOT_ENABLED
# fait nourrir le chien par le noyau jusqu'à ce que l'espace utilisateur prenne
# le relais, au lieu de laisser la machine redémarrer toute seule.
cfg --enable WATCHDOG
cfg --enable WATCHDOG_HANDLE_BOOT_ENABLED
cfg --module ITCO_WDT            # Intel TCO (chipsets Intel)
cfg --module SP5100_TCO          # AMD SP5100/FCH
cfg --module IT87_WDT
cfg --module W83627HF_WDT
cfg --module IPMI_WATCHDOG

# Suspend/hibernation: inutile sur un serveur et source d'une classe entière
# de bugs ACPI/S3 au retour d'un cycle d'alimentation.
cfg --disable SUSPEND
cfg --disable HIBERNATION

# Entropie: RANDOM_TRUST_CPU et RANDOM_TRUST_BOOTLOADER ont été SUPPRIMÉS du
# Kconfig (plus aucun symbole en 7.2). La confiance au RDRAND et à l'entropie
# du bootloader est désormais active par défaut et se pilote uniquement au
# boot: random.trust_cpu=0 / random.trust_bootloader=0 pour la désactiver.
# Rien à configurer ici — le blocage de getrandom() au démarrage ne se produit
# donc plus par défaut.

# Détecter et TRACER au lieu de redémarrer en silence.
cfg --enable LOCKUP_DETECTOR
cfg --enable SOFTLOCKUP_DETECTOR
cfg --enable HARDLOCKUP_DETECTOR
cfg --enable DETECT_HUNG_TASK
cfg --disable BOOTPARAM_SOFTLOCKUP_PANIC
cfg --disable BOOTPARAM_HUNG_TASK_PANIC

# kdump: capture réelle de la panic (paquet kdump-tools côté hôte).
cfg --enable KEXEC
cfg --enable KEXEC_FILE
cfg --enable CRASH_DUMP

# EFI et variables EFI (efibootmgr, GRUB, systemd).
cfg --enable EFI
cfg --enable EFI_STUB
cfg --enable EFI_VARS_PSTORE
cfg --enable EFIVAR_FS
cfg --enable ACPI
cfg --enable ACPI_TABLE_UPGRADE

# ============================================================
# Mémoire et diagnostic matériel
# ============================================================
# Le noyau n'a AUCUNE option liée au type de DRAM (DDR2/DDR3/...): c'est le
# firmware qui initialise le contrôleur. Ce qui compte réellement sur du
# matériel ancien, c'est de DÉTECTER les erreurs mémoire: des barrettes
# DDR2/DDR3 de 12-15 ans qui se dégradent produisent exactement des "reboots
# aléatoires sur certaines machines", et sans pilote EDAC l'erreur n'est
# jamais rapportée.
cfg --enable EDAC
cfg --module EDAC_AMD64          # AMD K8 -> Zen
cfg --module EDAC_I3000
cfg --module EDAC_I3200
# EDAC_I5000 (Greencreek/Blackford) est 'depends on BROKEN' en amont: exclu.
cfg --module EDAC_I5100
cfg --module EDAC_I7300
cfg --module EDAC_I7CORE
cfg --module EDAC_IE31200
cfg --module EDAC_SBRIDGE
cfg --module EDAC_SKX
cfg --module EDAC_I10NM

# Machine Check + RAS + erreurs firmware: savoir POURQUOI la machine est tombée.
cfg --enable X86_MCE
cfg --enable X86_MCE_INTEL
cfg --enable X86_MCE_AMD
cfg --enable RAS
cfg --enable ACPI_APEI
cfg --enable ACPI_APEI_GHES
cfg --enable ACPI_APEI_MEMORY_FAILURE
cfg --enable MEMORY_FAILURE      # reprise sur erreur mémoire au lieu de panic

# Hôtes à faible RAM (une machine d'époque DDR2 a 2 à 8 Go).
cfg --enable ZSWAP
cfg --enable ZSWAP_COMPRESSOR_DEFAULT_ZSTD
cfg --enable ZSMALLOC
cfg --module ZRAM
cfg --enable COMPACTION

# THP en madvise, PAS en always.
# Sur un hôte KVM à mémoire contrainte, THP=always provoque des pics de latence
# à la compaction et entre en conflit avec KSM. QEMU demande explicitement les
# hugepages quand il en veut: rien n'est perdu.
cfg --enable TRANSPARENT_HUGEPAGE_MADVISE
cfg --disable TRANSPARENT_HUGEPAGE_ALWAYS

cfg --enable SPARSEMEM_VMEMMAP
cfg --enable MEMORY_HOTPLUG
cfg --enable MEMORY_HOTREMOVE

# Supervision matérielle: IPMI et capteurs, sur 12 ans de générations.
cfg --enable HWMON
cfg --module IPMI_HANDLER
cfg --module IPMI_DEVICE_INTERFACE
cfg --module IPMI_SI
cfg --module SENSORS_CORETEMP
cfg --module SENSORS_K8TEMP
cfg --module SENSORS_K10TEMP
cfg --module SENSORS_NCT6775
cfg --module SENSORS_IT87
cfg --module SENSORS_W83627HF
cfg --enable THERMAL
cfg --module X86_PKG_TEMP_THERMAL

# ============================================================
# Stockage: contrôleurs serveur sur 12 ans
# ============================================================
# AHCI et NVMe en built-in: la racine monte sans dépendre de l'initramfs.
cfg --enable ATA
cfg --enable SATA_AHCI
cfg --enable ATA_PIIX
cfg --module MEGARAID_SAS
cfg --module SCSI_MPT3SAS
cfg --module SCSI_HPSA
cfg --module SCSI_SMARTPQI
cfg --module SCSI_AACRAID
cfg --module SCSI_ARCMSR

# ============================================================
# Allègement: retirer ce qu'un hyperviseur headless n'utilise jamais
# ============================================================
cfg --disable SOUND
cfg --disable MEDIA_SUPPORT      # DVB, webcams, tuners
cfg --set-str EXTRA_FIRMWARE ""

# ============================================================
# Mitigations spéculatives: compilées ET actives par défaut
# ============================================================
# Sur un hôte KVM multi-locataires, les désactiver autorise une fuite de
# données ENTRE VM. Le coût est réel sur du Haswell/Bulldozer (-15 à -35 %),
# et l'admin garde 'mitigations=off' au boot pour un hôte à charge unique et
# de confiance. C'est un choix d'exploitation, pas un choix de build.
cfg --enable CPU_MITIGATIONS
cfg --enable MITIGATION_PAGE_TABLE_ISOLATION
cfg --enable MITIGATION_RETPOLINE
cfg --enable MITIGATION_SPECTRE_V1
cfg --enable MITIGATION_SPECTRE_V2
cfg --enable MITIGATION_SPECTRE_BHI
cfg --enable MITIGATION_RETHUNK
cfg --enable MITIGATION_SRSO
cfg --enable MITIGATION_RETBLEED
cfg --enable MITIGATION_MDS
cfg --enable MITIGATION_TAA
cfg --enable MITIGATION_MMIO_STALE_DATA
cfg --enable MITIGATION_L1TF
cfg --enable MITIGATION_GDS
cfg --enable MITIGATION_RFDS
cfg --enable MITIGATION_SRBDS
cfg --enable MITIGATION_SSB
cfg --enable MITIGATION_ITS
cfg --enable MITIGATION_TSA
cfg --enable MITIGATION_VMSCAPE

else

# --- Desktop / VM desktop ---
# Le profil desktop reste proche de la config Debian et ne retire pas les GPU.
cfg --enable VIRTIO
cfg --enable VIRTIO_PCI
cfg --enable VIRTIO_BLK
cfg --enable VIRTIO_NET
cfg --enable VIRTIO_CONSOLE
cfg --enable VIRTIO_BALLOON
cfg --enable VIRTIO_INPUT
cfg --enable VIRTIO_FS
cfg --enable VSOCKETS
cfg --enable VIRTIO_VSOCKETS

cfg --enable VIRTUALIZATION
cfg --enable KVM
cfg --module KVM_INTEL
cfg --module KVM_AMD

cfg --enable DRM
cfg --enable DRM_KMS_HELPER
cfg --module DRM_I915
cfg --module DRM_XE
cfg --module DRM_AMDGPU
cfg --module DRM_RADEON
cfg --module DRM_NOUVEAU

cfg --enable INPUT_EVDEV
cfg --enable HID
cfg --enable HID_GENERIC
cfg --enable USB_SUPPORT
cfg --enable USB_XHCI_HCD
cfg --enable SOUND
cfg --enable SND
cfg --module SND_HDA_INTEL
cfg --module BT
cfg --module CFG80211
cfg --module MAC80211

cfg --enable CGROUPS
cfg --enable NAMESPACES
cfg --enable USER_NS
cfg --enable NET_NS
cfg --enable PID_NS
cfg --enable OVERLAY_FS
cfg --enable SECCOMP
cfg --enable SECCOMP_FILTER
cfg --enable EXT4_FS
cfg --module BTRFS_FS
cfg --module XFS_FS
cfg --module F2FS_FS

if [[ "$PROFILE" == "auxinuxos" ]]; then
  # COSMIC et Wayland sont en espace utilisateur; leur prérequis noyau est un
  # chemin DRM/KMS, input, audio et radio complet.
  cfg --enable VT
  cfg --enable VT_CONSOLE
  cfg --enable FRAMEBUFFER_CONSOLE
  cfg --enable DRM_DISPLAY_HELPER
  cfg --enable DRM_FBDEV_EMULATION
  cfg --enable DRM_SIMPLEDRM
  cfg --enable BACKLIGHT_CLASS_DEVICE
  cfg --enable RFKILL
  cfg --enable WLAN

  # Principales familles Wi-Fi Intel, Qualcomm, MediaTek, Realtek et Broadcom.
  cfg --module IWLWIFI
  cfg --module IWLMVM
  cfg --module ATH10K
  cfg --module ATH10K_PCI
  cfg --module ATH11K
  cfg --module ATH11K_PCI
  cfg --module ATH12K
  cfg --module ATH12K_PCI
  cfg --module MT76
  cfg --module MT76_USB
  cfg --module MT76_CONNAC_LIB
  cfg --module RTW88
  cfg --module RTW88_PCI
  cfg --module RTW88_USB
  cfg --module RTW89
  cfg --module RTW89_PCI
  cfg --module BRCMFMAC
  cfg --module BRCMFMAC_PCIE
  cfg --module BRCMFMAC_USB
  cfg --module MWIFIEX
  cfg --module MWIFIEX_PCIE
  cfg --module MWIFIEX_USB
  cfg --module RTL8XXXU

  cfg --module BT_HCIBTUSB
  cfg --module BT_HCIUART
  cfg --enable INPUT_UINPUT
  cfg --enable INPUT_JOYDEV
  cfg --module HID_MULTITOUCH
fi

fi

# Résout les dépendances et fige la config
make "${MAKE_ARCH_ARGS[@]}" olddefconfig

# ============================================================
# [6/9] Vérification de la config finale
# ============================================================
echo
echo "[6/9] Vérification de la config finale..."

# ============================================================
# [6a] Vérification des options RÉELLEMENT demandées
# ============================================================
# Sans ce contrôle, un cfg() sur un symbole renommé ou supprimé upstream est un
# no-op silencieux: scripts/config écrit la ligne, olddefconfig la retire, et
# rien ne le signale. Cette version applique ~200 options; l'ancien "|| true"
# n'était plus tenable.
#
# Deux verdicts distincts:
#   INCONNU  -> le symbole n'existe pas dans CE noyau (renommé/supprimé).
#               Erreur bloquante: l'intention exprimée n'a rien produit.
#   IGNORÉ   -> le symbole existe mais olddefconfig ne l'a pas retenu, presque
#               toujours parce qu'une dépendance manque. Avertissement détaillé.
echo "Indexation des symboles Kconfig de ${KERNEL_VERSION}..."
KCONFIG_SYMBOLS="${BUILD_ROOT}/kconfig-symbols-${KERNEL_VERSION}.txt"
find . -type f -name 'Kconfig*' -print0 \
  | xargs -0 grep -hoE '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' \
  | awk '{print $NF}' | sort -u > "$KCONFIG_SYMBOLS"
echo "  $(wc -l < "$KCONFIG_SYMBOLS") symboles connus, ${#CFG_REQUESTS[@]} options demandées."

cfg_unknown=()
cfg_ignored=()
for req in "${CFG_REQUESTS[@]}"; do
  IFS=$'\t' read -r _sym _action _expect <<<"$req"

  if ! grep -qxF "$_sym" "$KCONFIG_SYMBOLS"; then
    cfg_unknown+=("${_sym} (${_action})")
    continue
  fi

  case "$_expect" in
    y|m)
      grep -q "^CONFIG_${_sym}=${_expect}\$" .config \
        || cfg_ignored+=("${_sym}: demandé=${_expect} obtenu=$(cfg_actual "$_sym")")
      ;;
    n)
      grep -q "^CONFIG_${_sym}=[ym]\$" .config \
        && cfg_ignored+=("${_sym}: demandé=n obtenu=$(cfg_actual "$_sym")")
      ;;
    str:*)
      _want="${_expect#str:}"
      grep -q "^CONFIG_${_sym}=\"${_want}\"\$" .config \
        || cfg_ignored+=("${_sym}: demandé=\"${_want}\" obtenu=$(cfg_actual "$_sym")")
      ;;
    val:*)
      _want="${_expect#val:}"
      grep -q "^CONFIG_${_sym}=${_want}\$" .config \
        || cfg_ignored+=("${_sym}: demandé=${_want} obtenu=$(cfg_actual "$_sym")")
      ;;
  esac
done

if (( ${#cfg_ignored[@]} > 0 )); then
  echo
  echo "AVERTISSEMENT: ${#cfg_ignored[@]} option(s) demandée(s) non retenue(s) par olddefconfig"
  echo "  (symbole existant mais dépendance manquante, ou valeur forcée):"
  printf '  - %s\n' "${cfg_ignored[@]}"
fi

if (( ${#cfg_unknown[@]} > 0 )); then
  echo
  echo "Symboles INCONNUS dans Linux ${KERNEL_VERSION}:"
  printf '  - %s\n' "${cfg_unknown[@]}"
  die "${#cfg_unknown[@]} symbole(s) Kconfig inexistant(s) dans ce noyau.
Ils ont été renommés ou supprimés upstream: le cfg() correspondant n'a RIEN fait.
Corrige les noms dans la section de configuration avant de compiler."
fi

echo "Toutes les options demandées existent dans Linux ${KERNEL_VERSION}."

opt_on() { grep -q "^CONFIG_${1}=[ym]" .config; }

if [[ "$PROFILE" == "virtua" ]]; then
  # Sans ces options le kernel n'est pas un kernel Virtua valable.
  CRITICAL=(
    KVM VIRTIO VIRTIO_PCI VHOST_NET
    NAMESPACES USER_NS NET_NS PID_NS
    CGROUPS CGROUP_SCHED MEMCG BLK_CGROUP OVERLAY_FS SECCOMP
    BRIDGE VETH TUN
    RFKILL CFG80211 MAC80211 BT
    # Racines supportées: le parc est mixte ext4 / BTRFS, les DEUX doivent
    # être built-in sous peine d'un hôte qui ne remonte pas après upgrade.
    EXT4_FS BTRFS_FS
    # Console: sans ça la machine boote mais reste écran noir, ce qui est
    # systématiquement rapporté comme une instabilité au reboot.
    VT FRAMEBUFFER_CONSOLE DRM_SIMPLEDRM
    # Entrée console et console série: seuls moyens d'intervenir/diagnostiquer.
    HID_GENERIC USB_HID SERIAL_8250_CONSOLE
    # Anti-reboot spontané.
    WATCHDOG_HANDLE_BOOT_ENABLED
    # Plateforme CPU 12 ans et plus.
    MICROCODE X86_ACPI_CPUFREQ
    # Modules hors-arbre (ZFS DKMS): sans MODVERSIONS le DKMS casse.
    MODVERSIONS
    # eBPF CO-RE.
    BPF_SYSCALL DEBUG_INFO_BTF
    # Prérequis systemd non négociables.
    FHANDLE INOTIFY_USER SIGNALFD TIMERFD EPOLL TMPFS_XATTR
  )

  # Fortement souhaitées, on avertit seulement.
  RECOMMENDED=(
    KVM_INTEL KVM_AMD VFIO_PCI IOMMU_SUPPORT IOMMUFD VFIO_DEVICE_CDEV
    VIRTIO_NET VIRTIO_BLK VIRTIO_FS VIRTIO_MEM VHOST_VSOCK VHOST_IOTLB MACVTAP
    KVM_SMM KVM_AMD_SEV PARAVIRT PARAVIRT_SPINLOCKS VDPA
    NF_TABLES NF_NAT IP_NF_TARGET_MASQUERADE WIREGUARD IP_VS
    CGROUP_CPUACCT CGROUP_HUGETLB CFS_BANDWIDTH PSI CHECKPOINT_RESTORE
    CGROUP_MISC CGROUP_WRITEBACK BLK_DEV_THROTTLING
    SECURITY_APPARMOR SECURITY_LANDLOCK
    XFS_FS KSM TRANSPARENT_HUGEPAGE HUGETLBFS BTRFS_FS_POSIX_ACL
    # Console serveur / BMC.
    DRM_AST DRM_MGAG200
    # Fréquence: la couverture 12 ans dépend d'avoir PLUSIEURS drivers.
    X86_POWERNOW_K8 X86_INTEL_PSTATE X86_AMD_PSTATE CPU_FREQ_GOV_SCHEDUTIL
    # Diagnostic matériel et mémoire.
    EDAC EDAC_AMD64 EDAC_SBRIDGE X86_MCE RAS ACPI_APEI_GHES MEMORY_FAILURE
    # Watchdogs concrets.
    ITCO_WDT SP5100_TCO IPMI_WATCHDOG IPMI_SI
    # Mémoire contrainte.
    ZSWAP ZRAM
    # Diagnostic de panic.
    KEXEC CRASH_DUMP DETECT_HUNG_TASK SOFTLOCKUP_DETECTOR
    # Stockage serveur.
    SATA_AHCI MEGARAID_SAS SCSI_MPT3SAS
    # Mitigations (posture: actives par défaut).
    CPU_MITIGATIONS MITIGATION_RETPOLINE MITIGATION_SPECTRE_V2
  )
elif [[ "$PROFILE" == "desktop" ]]; then
  # Desktop: le minimum attendu est de booter correctement en bare metal ou VM.
  CRITICAL=(
    VIRTIO VIRTIO_PCI VIRTIO_NET VIRTIO_BLK
    DRM INPUT_EVDEV HID USB_SUPPORT EXT4_FS
  )

  RECOMMENDED=(
    DRM_I915 DRM_XE DRM_AMDGPU DRM_NOUVEAU DRM_RADEON
    SOUND SND SND_HDA_INTEL BT CFG80211 MAC80211
    BTRFS_FS XFS_FS OVERLAY_FS SECCOMP
  )
else
  CRITICAL=(
    DRM DRM_KMS_HELPER INPUT_EVDEV HID USB_SUPPORT
    SOUND SND RFKILL WLAN CFG80211 MAC80211 BT EXT4_FS
  )

  RECOMMENDED=(
    DRM_I915 DRM_XE DRM_AMDGPU DRM_NOUVEAU DRM_RADEON
    DRM_SIMPLEDRM DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE
    SND_HDA_INTEL BT_HCIBTUSB
    IWLWIFI ATH10K ATH11K ATH12K MT76 RTW88 RTW89 BRCMFMAC
    BTRFS_FS XFS_FS OVERLAY_FS SECCOMP
  )
fi

missing_crit=()
for o in "${CRITICAL[@]}"; do
  opt_on "$o" || missing_crit+=("$o")
done

missing_reco=()
for o in "${RECOMMENDED[@]}"; do
  opt_on "$o" || missing_reco+=("$o")
done

(( ${#missing_reco[@]} == 0 )) || \
  echo "AVERTISSEMENT: options recommandées absentes: ${missing_reco[*]}"

(( ${#missing_crit[@]} == 0 )) || \
  die "options CRITIQUES absentes après olddefconfig: ${missing_crit[*]}
Vérifie le .config et les dépendances. Build interrompu."

echo "Config OK — toutes les options critiques sont présentes."

if [[ "$CONFIG_ONLY" == "1" ]]; then
  echo
  echo "============================================================"
  echo " Build à blanc (CONFIG_ONLY=1): arrêt avant compilation."
  echo " Config vérifiée : ${SOURCE_DIR}/.config"
  echo " Release visée   : ${KERNEL_VERSION}${LOCAL_VERSION}"
  echo "============================================================"
  exit 0
fi

# ============================================================
# [7/9] Compilation
# ============================================================
echo
echo "[7/9] Compilation du kernel (peut être long)..."
echo "Log conseillé: ./build-virtua-kernel.sh 2>&1 | tee ~/virtua-kernel.log"

# BUILD_ROOT est réutilisé entre profils. Supprime uniquement les artefacts de
# packaging à sa racine pour empêcher un ancien build d'être recopié/publié.
rm -f "$BUILD_ROOT"/*.deb "$BUILD_ROOT"/*.buildinfo "$BUILD_ROOT"/*.changes

# LOCALVERSION="" (vide mais défini):
#   - suffixe vient de CONFIG_LOCALVERSION uniquement -> pas de doublement
#   - supprime le "+" parasite sur arbres git
make "${MAKE_ARCH_ARGS[@]}" -j"$JOBS" bindeb-pkg \
  LOCALVERSION="" \
  KDEB_PKGVERSION="$PKG_VERSION" \
  KDEB_COMPRESS="zstd"

# ============================================================
# [7b/9] Paquet source OpenZFS DKMS (modèle Debian)
# ============================================================
# openzfs-zfs-dkms (arch=all) embarque le SOURCE OpenZFS: aucun module n'est
# précompilé ici, DKMS recompile contre le kernel réellement installé côté
# client. On ne cible donc AUCUN kernel précis au build (pas de
# --with-linux/--with-config=kernel, pas d'install de headers): c'est
# justement tout l'intérêt vs l'ancien modèle "module précompilé" (kmod-zfs),
# qui distribuait un binaire liant du code GPL-2.0 (Linux) et CDDL (OpenZFS)
# dans un même objet — risque légal jugé inacceptable.
if [[ "$WITH_ZFS" == "1" ]]; then
  echo
  echo "[7b/9] Construction du paquet source OpenZFS ${ZFS_VERSION} (DKMS)..."

  ZFS_TARBALL="zfs-${ZFS_VERSION}.tar.gz"
  ZFS_URL="${ZFS_BASE_URL}/zfs-${ZFS_VERSION}/${ZFS_TARBALL}"
  ZFS_SRC_DIR="${BUILD_ROOT}/zfs-${ZFS_VERSION}"

  cd "$BUILD_ROOT"

  if [[ ! -f "$ZFS_TARBALL" ]]; then
    echo "Téléchargement: ${ZFS_URL}"
    wget -c --show-progress "$ZFS_URL" -O "$ZFS_TARBALL"
  else
    echo "Tarball ZFS déjà présent, réutilisation: ${ZFS_TARBALL}"
  fi

  # Vérification d'intégrité de la source ZFS (sha256 épinglé, OBLIGATOIRE).
  # Garde PROPRE à ZFS: un build mainline/RC relâche ALLOW_UNVERIFIED_SOURCE
  # parce que les snapshots git kernel.org n'ont pas de .tar.sign — ce n'est
  # pas une raison d'accepter un tarball ZFS non vérifié.
  if [[ "$ALLOW_UNVERIFIED_ZFS" == "1" ]]; then
    echo "AVERTISSEMENT: vérification du source ZFS IGNORÉE (ALLOW_UNVERIFIED_ZFS=1)."
  elif [[ -n "$ZFS_SHA256" ]]; then
    echo "Vérification sha256 du source ZFS..."
    echo "${ZFS_SHA256}  ${ZFS_TARBALL}" | sha256sum -c - \
      || die "sha256 du tarball ZFS invalide. Source corrompue ou ZFS_SHA256 erroné."
  else
    die "ZFS_SHA256 non défini.
Fournis le sha256 de ${ZFS_TARBALL} (page de release OpenZFS), ex:
  ZFS_SHA256=<hash> ./build-virtua-kernel.sh ...
Ou passe outre (DÉCONSEILLÉ): ALLOW_UNVERIFIED_ZFS=1"
  fi

  rm -rf "$ZFS_SRC_DIR"
  tar -xf "$ZFS_TARBALL"
  [[ -d "$ZFS_SRC_DIR" ]] || die "extraction ZFS échouée: $ZFS_SRC_DIR introuvable."

  cd "$ZFS_SRC_DIR"

  # --- Fenêtre de compatibilité kernel déclarée par OpenZFS (fichier META) ---
  # Hors de cette fenêtre, DKMS ne compilera pas chez le client. Comme l'échec
  # DKMS à l'installation n'est PAS bloquant pour apt, publier un tel paquet
  # donne un hôte sans ZFS qui se croit correctement installé (et un hôte
  # ZFS-on-root qui ne remonte pas). On refuse donc de construire.
  if [[ -f META ]]; then
    zfs_kmin="$(awk -F'[[:space:]]+' '/^Linux-Minimum:/{print $2}' META)"
    zfs_kmax="$(awk -F'[[:space:]]+' '/^Linux-Maximum:/{print $2}' META)"
    kver_series="$(echo "$KERNEL_VERSION" | cut -d. -f1,2)"
    echo "OpenZFS ${ZFS_VERSION}: kernels supportés ${zfs_kmin:-?} -> ${zfs_kmax:-?} (cible: ${kver_series})"

    if [[ -n "$zfs_kmax" ]] && dpkg --compare-versions "$kver_series" gt "$zfs_kmax"; then
      die "OpenZFS ${ZFS_VERSION} déclare Linux-Maximum ${zfs_kmax}, or ce build cible ${kver_series}.
DKMS échouerait à compiler le module chez le client, SANS bloquer l'installation.
Utilise une version d'OpenZFS qui couvre ${kver_series} (ZFS_VERSION=..., avec son
ZFS_SHA256), ou construis ce kernel sans ZFS (no-zfs)."
    fi
    if [[ -n "$zfs_kmin" ]] && dpkg --compare-versions "$kver_series" lt "$zfs_kmin"; then
      die "OpenZFS ${ZFS_VERSION} exige un kernel >= ${zfs_kmin}, or ce build cible ${kver_series}."
    fi
  else
    echo "AVERTISSEMENT: fichier META absent du source ZFS; fenêtre kernel non vérifiable."
  fi

  echo "Configuration OpenZFS (build source, sans ciblage d'un kernel précis)..."
  ./configure --prefix=/usr --with-tirpc

  echo "Construction du paquet source OpenZFS (native-deb-utils, DKMS)..."
  # native-deb-utils = cible Makefile.am NATIVE d'OpenZFS (dpkg-buildpackage),
  # PAS d'alien/rpm. Produit openzfs-zfs-dkms (arch=all) + des paquets
  # userspace (zfsutils, libzfs, ...) déjà fournis par Debian: on ne garde et
  # publie QUE le paquet DKMS, le reste est supprimé juste après.
  make -j"$JOBS" native-deb-utils

  cd "$BUILD_ROOT"
  shopt -s nullglob
  zfs_debs=( "$BUILD_ROOT"/openzfs-zfs-dkms_*.deb )
  zfs_userspace_debs=( "$BUILD_ROOT"/openzfs-*.deb )
  shopt -u nullglob
  (( ${#zfs_debs[@]} > 0 )) \
    || die "aucun paquet openzfs-zfs-dkms_*.deb trouvé dans $BUILD_ROOT après native-deb-utils."

  # --- Userland OpenZFS ---------------------------------------------------
  # Le module DKMS et les outils (zfs, zpool, libzfs...) doivent avoir la MÊME
  # version: OpenZFS ne garantit pas la compatibilité entre un userland et un
  # module de branches différentes.
  #
  # Ces paquets ne peuvent pas venir de Debian: openzfs-zfs-dkms recommande
  # 'openzfs-zfsutils'/'openzfs-zfs-zed', qui n'existent nulle part chez Debian
  # (le paquet Debian s'appelle zfsutils-linux). La recommandation était donc
  # insatisfiable, et l'hôte se retrouvait avec le userland Debian de trixie
  # (2.3.2) face à un module 2.4.4 — versions désaccordées.
  #
  # Aucun enjeu de licence ici: ce sont des binaires CDDL en espace utilisateur,
  # jamais liés au noyau. Seule la partie noyau reste distribuée en source.
  # Le paquet de suite de tests est exclu (volumineux, inutile en production).
  if [[ "$ZFS_PUBLISH_USERLAND" == "1" ]]; then
    echo "Conservation du userland OpenZFS (aligné sur le module DKMS)..."
    for u in "${zfs_userspace_debs[@]}"; do
      case "$(basename "$u")" in
        openzfs-zfs-test_*)
          echo "  rm $(basename "$u") (suite de tests, non publiée)"; rm -f "$u" ;;
        *) echo "  garde $(basename "$u")" ;;
      esac
    done
  else
    echo "Nettoyage des paquets userspace OpenZFS (ZFS_PUBLISH_USERLAND=0)..."
    for u in "${zfs_userspace_debs[@]}"; do
      case "$(basename "$u")" in
        openzfs-zfs-dkms_*) ;;   # celui qu'on garde et publie
        *) echo "  rm $(basename "$u")"; rm -f "$u" ;;
      esac
    done
  fi

  echo "Paquets OpenZFS générés:"
  shopt -s nullglob
  for z in "$BUILD_ROOT"/openzfs-*.deb; do echo "  $(basename "$z")"; done
  shopt -u nullglob
else
  echo
  echo "[7b/9] Paquet OpenZFS (DKMS): désactivé (WITH_ZFS=${WITH_ZFS})."
fi

# ============================================================
# [8/9] Validation et copie
# ============================================================
echo
echo "[8/9] Validation et copie des paquets..."

cd "$BUILD_ROOT"

shopt -s nullglob
debs=( ./*.deb )
shopt -u nullglob

(( ${#debs[@]} > 0 )) || die "aucun paquet .deb généré dans $BUILD_ROOT"

# OUTPUT_DIR peut contenir plusieurs profils/architectures. On conserve les
# autres builds pour pouvoir publier virtua + desktop ensemble.

echo
echo "Noms internes des paquets générés:"
for pkg in "${debs[@]}"; do
  echo "------------------------------------------------------------"
  echo "$(basename "$pkg")"
  dpkg-deb -f "$pkg" Package Version Architecture
done

echo
echo "Copie vers OUTPUT_DIR..."
for pkg in "${debs[@]}"; do
  pkg_name="$(dpkg-deb -f "$pkg" Package)"
  pkg_arch="$(dpkg-deb -f "$pkg" Architecture)"
  pkg_version="$(dpkg-deb -f "$pkg" Version)"

  # Les paquets -dbg/-dbgsym pèsent 1 à 2 Go et ne sont utiles qu'au débogage
  # noyau. Le meta ne les référence pas: les publier ne fait que saturer le
  # dépôt et la bande passante des clients.
  case "$pkg_name" in
    *-dbg|*-dbgsym)
      echo "SKIP $(basename "$pkg") (symboles de debug, non publiés)"
      continue
      ;;
  esac

  if [[ "$pkg_name" == "linux-libc-dev" ]]; then
    echo "SKIP $(basename "$pkg") (linux-libc-dev reste fourni par Debian)"
    rm -f "$OUTPUT_DIR/${pkg_name}"_*_"${pkg_arch}".deb \
          "$OUTPUT_DIR/${pkg_name}-${KERNEL_NAME_SUFFIX}.deb"
    continue
  fi

  case "$pkg_name" in
    linux-image-*|linux-headers-*|openzfs-*)
      dest_name="${pkg_name}.deb"
      ;;
    *)
      dest_name="${pkg_name}-${KERNEL_NAME_SUFFIX}-${pkg_arch}.deb"
      ;;
  esac

  # Nettoie les anciens noms canoniques longs et l'ancien nom court.
  rm -f "$OUTPUT_DIR/${pkg_name}"_*_"${pkg_arch}".deb "$OUTPUT_DIR/${dest_name}"
  cp -v "$pkg" "$OUTPUT_DIR/${dest_name}"
done

cat > "$OUTPUT_DIR/README-${KERNEL_NAME_SUFFIX}.txt" <<EOF
Virtua Kernel Repository
========================

Kernel    : Linux ${KERNEL_VERSION}${LOCAL_VERSION}
Version   : ${PKG_VERSION}
Track     : ${RELEASE_TRACK} (suite APT: ${TRACK_SUITE})
Source    : ${SOURCE}
Profile   : ${PROFILE}
Arch      : ${TARGET_ARCH} (${KBUILD_DEBARCH})
Base src  : linux-source-${KERNEL_MAJOR} (${SOURCE_PKG_VERSION})
OpenZFS   : $([[ "$WITH_ZFS" == "1" ]] && echo "${ZFS_VERSION} (paquet source DKMS: openzfs-zfs-dkms)" || echo "non inclus")
Généré    : $(date -Iseconds)

APT source (dépôt signé — ne pas utiliser trusted=yes, qui désactiverait la
vérification de signature côté client):

  sudo wget -O /usr/share/keyrings/virtua-archive-keyring.gpg \\
       https://dep.auxinux.ca/VIRTUA/virtua-archive-keyring.gpg

  echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=${KBUILD_DEBARCH}] https://dep.auxinux.ca/VIRTUA ${TRACK_SUITE} main' \\
       | sudo tee /etc/apt/sources.list.d/virtua-kernel-${RELEASE_TRACK}.list

Installation:
  sudo apt update
  sudo apt install ${META_PACKAGE}

Installation directe sans paquet meta:
  sudo apt install linux-image-${KERNEL_VERSION}${LOCAL_VERSION} linux-headers-${KERNEL_VERSION}${LOCAL_VERSION}

Après reboot:
  uname -r   # attendu: ${KERNEL_VERSION}${LOCAL_VERSION}
EOF

# ============================================================
# [9/9] Terminé
# ============================================================
echo
echo "[9/9] Terminé."
echo
echo "Paquets générés:"
ls -lh "$OUTPUT_DIR"
echo
echo "Envoi vers le serveur dépôt:"
echo "  rsync -avz --progress ${OUTPUT_DIR}/ debian@dep.auxinux.ca:/tmp/virtua-kernel/"
echo "Puis sur dep.auxinux.ca:"
echo "  sudo ./build-depot-kernel.sh /tmp/virtua-kernel"
echo
echo "Kernel attendu après install: ${KERNEL_VERSION}${LOCAL_VERSION}"
echo "============================================================"

if [[ "$DEPLOY" == "1" ]]; then
  echo
  echo "Déploiement vers ${DEPLOY_TARGET}..."
  if [[ "$DEPLOY_TARGET" == *:* ]]; then
    rsync -a "${OUTPUT_DIR}/" "${DEPLOY_TARGET%/}/"
  else
    mkdir -p "$DEPLOY_TARGET"
    rsync -a "${OUTPUT_DIR}/" "${DEPLOY_TARGET%/}/"
  fi
  echo "  OK"
fi
