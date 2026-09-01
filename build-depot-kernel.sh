#!/usr/bin/env bash
set -Eeuo pipefail

############################################################
# Virtua Kernel Repository Builder
#
# Usage:
#   sudo ./build-depot-kernel.sh [IMPORT_DIR]
#
# Variables optionnelles:
#   RELEASE_TRACK  : "prod" ou "dev" (defaut: prod)
#                    prod -> suite 'kernel'     KERNEL/     kernel-virtua
#                    dev  -> suite 'kernel-dev' KERNEL-DEV/ kernel-virtua-dev
#   REPO_ROOT      : racine du depot (defaut: /var/www/dep.auxinux.ca/VIRTUA)
#   KERNEL_DIR     : dossier des .deb (defaut: REPO_ROOT/<KERNEL|KERNEL-DEV>)
#   SIGN           : 1 = signe le depot avec GPG, 0 = trusted=yes (defaut: 1)
#   GPG_KEY        : id/email de la cle de signature (requis si SIGN=1)
#   KEEP_VERSIONS  : nb de versions a garder par paquet, 0 = tout garder (defaut: 3)
#   ZFS_META_DEP    : depends, recommends ou none (defaut: recommends)
#   ARCHES         : architecture APT publiee (fixe: "amd64")
#   KERNEL_FLAVOUR : suffixe fixe par track (auxinux-virtua / DEV-auxinux-virtua)
#   META_PACKAGE   : paquet meta fixe par track (kernel-virtua / kernel-virtua-dev)
#   STRICT_EXISTING: 1 = un paquet hors-track deja present devient bloquant
#   DEPLOY=1       : copie le dépôt final vers DEPLOY_TARGET (optionnel)
#   DEPLOY_TARGET  : cible locale ou rsync distante pour la publication
#                    genere uniquement auxinux-virtua -> kernel-virtua [amd64]
############################################################

usage() {
  cat <<EOF
AuxiNux Kernel Repository Builder

Imports kernel .deb packages, generates meta-packages, rebuilds the APT
repository metadata, and optionally signs the repository.

Usage:
  sudo $0 [IMPORT_DIR]
  sudo $0 -h | --help

Arguments:
  IMPORT_DIR
      Directory containing .deb files to import into the repository.
      If omitted, KERNEL_DIR is used and no import copy is performed.

Publication track (prod / dev):
  RELEASE_TRACK=prod   (default)
      APT suite 'kernel', packages in REPO_ROOT/KERNEL,
      flavour auxinux-virtua, meta-package kernel-virtua.

  RELEASE_TRACK=dev
      APT suite 'kernel-dev', packages in REPO_ROOT/KERNEL-DEV,
      flavour DEV-auxinux-virtua, meta-package kernel-virtua-dev.

  Both tracks live in the same repository root and share the same signing key,
  but have separate suites, directories and package names. A production host
  that only enables the 'kernel' suite can never be offered a DEV kernel.

Default repository layout:
  REPO_ROOT/dists/kernel/main/binary-amd64/Packages       (prod)
  REPO_ROOT/KERNEL/*.deb
  REPO_ROOT/dists/kernel-dev/main/binary-amd64/Packages   (dev)
  REPO_ROOT/KERNEL-DEV/*.deb

Environment options:
  REPO_ROOT=/path
      Repository root. Default: /var/www/dep.auxinux.ca/VIRTUA

  KERNEL_DIR=/path
      Directory that stores kernel .deb packages.
      Default: REPO_ROOT/KERNEL (prod) or REPO_ROOT/KERNEL-DEV (dev)

  SIGN=1|0
      Sign Release/InRelease with GPG. Default: 1.
      Use SIGN=0 only for trusted=yes/internal testing.

  GPG_KEY=id-or-email
      GPG signing key used when SIGN=1.

  KEEP_VERSIONS=n
      Number of kernel releases to keep per package family. Kernel packages
      embed their version in the package NAME, so grouping is done on the
      family (linux-image::auxinux-virtua-amd64) rather than the exact name.
      Default: 3. Use 0 to keep everything.
      WARNING: this deletes already-published .deb files. Use KEEP_VERSIONS=0
      when publishing a release, and run the purge as a deliberate operation.

  ZFS_META_DEP=depends|recommends|none
      How kernel meta-packages reference the OpenZFS DKMS source package
      (openzfs-zfs-dkms). Default: recommends.

  ARCHES="amd64"
      Fixed Debian package architecture for this repository.

  KERNEL_FLAVOUR=auxinux-virtua
  META_PACKAGE=kernel-virtua
      Fixed values for the VirtuaOS kernel repository.

Examples:
  sudo GPG_KEY='repo@auxinux.ca' $0 /tmp/virtua-kernel

  sudo RELEASE_TRACK=dev GPG_KEY='repo@auxinux.ca' $0 /tmp/virtua-kernel-dev

  sudo SIGN=0 $0 .

Client setup for a signed repository:
  sudo wget -O /usr/share/keyrings/virtua-archive-keyring.gpg \\
    https://dep.auxinux.ca/VIRTUA/virtua-archive-keyring.gpg

  # Production
  echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=amd64] https://dep.auxinux.ca/VIRTUA kernel main' \\
    | sudo tee /etc/apt/sources.list.d/virtua-kernel-prod.list

  # Test / DEV (machines de test uniquement)
  echo 'deb [signed-by=/usr/share/keyrings/virtua-archive-keyring.gpg arch=amd64] https://dep.auxinux.ca/VIRTUA kernel-dev main' \\
    | sudo tee /etc/apt/sources.list.d/virtua-kernel-dev.list

Client install examples:
  sudo apt update
  sudo apt install kernel-virtua        # production
  sudo apt install kernel-virtua-dev    # test
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

if (( $# > 1 )); then
  echo "ERROR: too many arguments." >&2
  usage
  exit 1
fi

# ============================================================
# Track de publication: prod / dev
# ============================================================
# Deux canaux indépendants dans le MÊME dépôt, mais avec des suites APT, des
# dossiers de paquets, des saveurs de kernel et des paquets meta distincts.
# Un hôte de production n'active que la suite 'kernel' et ne peut donc jamais
# se voir proposer un noyau DEV.
#
#   prod -> suite 'kernel'      KERNEL/      auxinux-virtua      kernel-virtua
#   dev  -> suite 'kernel-dev'  KERNEL-DEV/  DEV-auxinux-virtua  kernel-virtua-dev
RELEASE_TRACK="${RELEASE_TRACK:-prod}"
case "$RELEASE_TRACK" in
  prod|production|stable) RELEASE_TRACK="prod" ;;
  dev|devel|test|testing) RELEASE_TRACK="dev" ;;
  *) echo "ERROR: RELEASE_TRACK invalide: ${RELEASE_TRACK}. Valeurs: prod, dev." >&2; exit 1 ;;
esac

if [[ "$RELEASE_TRACK" == "dev" ]]; then
  TRACK_SUITE="kernel-dev"
  TRACK_DIRNAME="KERNEL-DEV"
  TRACK_FLAVOUR="DEV-auxinux-virtua"
  TRACK_META="kernel-virtua-dev"
  # Un paquet de production n'a rien à faire dans le canal dev.
  TRACK_FORBIDDEN_DEFAULT="auxinuxos auxinux-desktop kernel-auxinuxos kernel-auxinux-desktop"
else
  TRACK_SUITE="kernel"
  TRACK_DIRNAME="KERNEL"
  TRACK_FLAVOUR="auxinux-virtua"
  TRACK_META="kernel-virtua"
  # 'DEV-auxinux-virtua' doit être explicitement banni du canal prod: le motif
  # de recherche du meta (linux-image-*-auxinux-virtua-*) matcherait sinon un
  # noyau DEV, et le paquet kernel-virtua pointerait dessus.
  TRACK_FORBIDDEN_DEFAULT="auxinuxos auxinux-desktop kernel-auxinuxos kernel-auxinux-desktop DEV-auxinux-virtua kernel-virtua-dev"
fi

REPO_ROOT="${REPO_ROOT:-/var/www/dep.auxinux.ca/VIRTUA}"
KERNEL_DIR="${KERNEL_DIR:-${REPO_ROOT}/${TRACK_DIRNAME}}"
REPO_LABEL="${REPO_LABEL:-Virtua Kernel Repository}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-Virtua Custom Kernel Repository}"
PUBLIC_REPO_URL="${PUBLIC_REPO_URL:-https://dep.auxinux.ca/VIRTUA}"
KEYRING_BASENAME="${KEYRING_BASENAME:-virtua-archive-keyring}"
SOURCES_LIST_NAME="${SOURCES_LIST_NAME:-virtua-kernel-${RELEASE_TRACK}}"
IMPORT_DIR="${1:-$KERNEL_DIR}"
DEPLOY="${DEPLOY:-0}"
DEPLOY_TARGET="${DEPLOY_TARGET:-}"

DIST="$TRACK_SUITE"
COMPONENT="main"
ARCHES="${ARCHES:-amd64}"

SIGN="${SIGN:-1}"
GPG_KEY="${GPG_KEY:-}"
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"
ZFS_META_DEP="${ZFS_META_DEP:-recommends}"
FORBIDDEN_PACKAGE_PATTERNS="${FORBIDDEN_PACKAGE_PATTERNS:-$TRACK_FORBIDDEN_DEFAULT}"

# Le script tourne en root (sudo), mais la clé GPG vit en général dans le
# trousseau de l'utilisateur qui a lancé sudo, pas dans /root/.gnupg.
# On pointe GNUPGHOME dessus, sauf si déjà défini explicitement.
if [[ -z "${GNUPGHOME:-}" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  _sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [[ -n "$_sudo_home" && -d "$_sudo_home/.gnupg" ]] && GNUPGHOME="$_sudo_home/.gnupg"
fi
[[ -n "${GNUPGHOME:-}" ]] && export GNUPGHOME
KERNEL_FLAVOUR="${KERNEL_FLAVOUR:-$TRACK_FLAVOUR}"
META_PACKAGE="${META_PACKAGE:-$TRACK_META}"
[[ "$KERNEL_FLAVOUR" == "$TRACK_FLAVOUR" ]] \
  || { echo "ERROR: track ${RELEASE_TRACK} only accepts KERNEL_FLAVOUR=${TRACK_FLAVOUR}." >&2; exit 1; }
[[ "$META_PACKAGE" == "$TRACK_META" ]] \
  || { echo "ERROR: track ${RELEASE_TRACK} only accepts META_PACKAGE=${TRACK_META}." >&2; exit 1; }
[[ "$ARCHES" == "amd64" ]] \
  || { echo "ERROR: Kernel/VirtuaOS currently publishes amd64 only." >&2; exit 1; }
META_PROFILES=("${TRACK_FLAVOUR}:${TRACK_META}:amd64")

KEYRING_ASC="${REPO_ROOT}/${KEYRING_BASENAME}.asc"
KEYRING_GPG="${REPO_ROOT}/${KEYRING_BASENAME}.gpg"

die() { echo; echo "ERREUR: $*" >&2; exit 1; }

echo "=================================================="
echo " Virtua Repository Builder"
echo "=================================================="
echo "Track         : $RELEASE_TRACK (suite APT '$TRACK_SUITE', meta $TRACK_META)"
echo "Repo root     : $REPO_ROOT"
echo "Kernel dir    : $KERNEL_DIR"
echo "Import dir    : $IMPORT_DIR"
echo "Architectures : $ARCHES"
echo "Signature GPG : $([[ "$SIGN" == "1" ]] && echo "oui ($GPG_KEY)" || echo "non (trusted=yes)")"
echo "Versions gard.: $([[ "$KEEP_VERSIONS" -eq 0 ]] && echo "toutes" || echo "$KEEP_VERSIONS")"
echo "ZFS meta dep. : $ZFS_META_DEP"
echo "Profils meta  : ${META_PROFILES[*]}"
echo "Deploy        : $([[ "$DEPLOY" == "1" ]] && echo "oui -> ${DEPLOY_TARGET:-<non défini>}" || echo "non")"
echo

[[ $EUID -eq 0 ]] || die "lance ce script avec sudo."

# Un IMPORT_DIR passé explicitement en argument DOIT exister: le créer à la
# volée transformerait une faute de frappe en "0 paquet importé" silencieux,
# puis en republication du dépôt inchangé — pire, en publication d'un dépôt
# vide si KERNEL_DIR l'était aussi.
if (( $# == 1 )); then
  [[ -d "$IMPORT_DIR" ]] || die "IMPORT_DIR introuvable: ${IMPORT_DIR}"
fi

# Prépare les répertoires de travail/publication manquants pour éviter une
# création manuelle préalable sur un serveur dépôt neuf.
mkdir -p "$REPO_ROOT" "$KERNEL_DIR" "$IMPORT_DIR"

if [[ "$SIGN" == "1" && -z "$GPG_KEY" ]]; then
  die "SIGN=1 mais GPG_KEY non défini.
Crée une clé dédiée puis relance avec GPG_KEY=...:
  gpg --quick-generate-key 'Virtua Kernel Repository <repo@auxinux.ca>' rsa4096 sign 0
  gpg --list-secret-keys --keyid-format=long
  sudo GPG_KEY='repo@auxinux.ca' ./build-depot-kernel.sh
Ou désactive la signature (déconseillé pour un dépôt public): SIGN=0"
fi

# Vérifie tôt que la clé secrète est accessible (évite d'échouer à l'étape [8/9]).
if [[ "$SIGN" == "1" ]]; then
  if ! gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1; then
    die "clé secrète GPG introuvable pour '${GPG_KEY}' (GNUPGHOME=${GNUPGHOME:-/root/.gnupg}).
La clé a probablement été créée par un autre utilisateur que root.
Relance en pointant le bon trousseau, ex:
  sudo GNUPGHOME=/home/${SUDO_USER:-debian}/.gnupg GPG_KEY='${GPG_KEY}' ./build-depot-kernel.sh
Ou crée la clé directement dans ce trousseau (en root)."
  fi
fi

# Un dépôt non signé (trusted=yes) ne doit pas être publié par accident.
if [[ "$SIGN" != "1" && "${ALLOW_UNSIGNED:-0}" != "1" ]]; then
  die "SIGN=0 publie un dépôt NON signé (trusted=yes), dangereux en production.
Confirme explicitement avec ALLOW_UNSIGNED=1 si c'est volontaire (test/interne)."
fi

apt-get update
DEPS=(apt-utils dpkg-dev xz-utils)
[[ "$SIGN" == "1" ]] && DEPS+=(gnupg)
apt-get install -y "${DEPS[@]}"

############################################################
# [1/9] Import des paquets
############################################################
echo "[1/9] Import des paquets..."

if [[ "$IMPORT_DIR" != "$KERNEL_DIR" ]]; then
  found=0
  while IFS= read -r -d '' f; do
    # Refuse un fichier corrompu/non-deb avant de l'intégrer (et de le signer).
    dpkg-deb -I "$f" >/dev/null 2>&1 || die "fichier .deb invalide ou corrompu: $f"
    import_package="$(dpkg-deb -f "$f" Package)"
    for forbidden_pattern in $FORBIDDEN_PACKAGE_PATTERNS; do
      if [[ "$import_package" == *"$forbidden_pattern"* ]]; then
        die "paquet '${import_package}' refusé dans ce dépôt (${REPO_ROOT}).
Utilise le générateur de dépôt correspondant; pour AuxiNuxOS:
  sudo GPG_KEY='repo@auxinux.ca' ./build-depot-AuxiNuxOS.sh ${IMPORT_DIR}"
      fi
    done
    cp -fv "$f" "$KERNEL_DIR"/
    found=1
  done < <(find "$IMPORT_DIR" -maxdepth 1 -name '*.deb' -print0)
  (( found == 1 )) || echo "  (aucun .deb dans $IMPORT_DIR)"
else
  echo "  (import_dir = kernel_dir, rien à copier)"
fi

# Le filtre de paquets interdits ne s'appliquait qu'aux fichiers importés. Les
# .deb déjà présents dans KERNEL_DIR (importés avant l'ajout du filtre, ou
# déposés à la main) n'étaient jamais revérifiés et restaient donc indexés et
# publiés. On revalide l'intégralité du dossier à chaque passage.
echo "  Vérification des paquets déjà présents dans $KERNEL_DIR..."
for f in "$KERNEL_DIR"/*.deb; do
  [[ -e "$f" ]] || continue
  existing_package="$(dpkg-deb -f "$f" Package)"
  for forbidden_pattern in $FORBIDDEN_PACKAGE_PATTERNS; do
    if [[ "$existing_package" == *"$forbidden_pattern"* ]]; then
      if [[ "${STRICT_EXISTING:-0}" == "1" ]]; then
        die "paquet '${existing_package}' présent dans ${KERNEL_DIR} mais interdit sur le track ${RELEASE_TRACK}.
Fichier: ${f}
Retire-le du dossier, puis relance."
      fi
      echo "  AVERTISSEMENT: '${existing_package}' n'appartient pas au track ${RELEASE_TRACK}"
      echo "                 ($(basename "$f")) — il reste publié dans la suite '${TRACK_SUITE}'."
      echo "                 Le retirer casserait les clients qui l'ont installé: décision"
      echo "                 d'exploitation. Pour rendre ce cas bloquant: STRICT_EXISTING=1."
    fi
  done
done

# Normalise TOUS les .deb au format APT canonique <Package>_<Version>_<Arch>.deb.
# dpkg-scanpackages n'indexe de façon fiable que les fichiers nommés ainsi:
# des noms personnalisés (sans version/arch) sont ignorés -> meta non installable.
# Corrige aussi en place les fichiers déjà présents (pas besoin de recompiler).
echo "  Normalisation des noms de fichiers..."
for f in "$KERNEL_DIR"/*.deb; do
  [[ -e "$f" ]] || continue
  p="$(dpkg-deb -f "$f" Package)"
  v="$(dpkg-deb -f "$f" Version)"
  a="$(dpkg-deb -f "$f" Architecture)"
  [[ -n "$p" && -n "$v" && -n "$a" ]] || continue
  canonical="${p}_${v//:/%3a}_${a}.deb"   # ':' (epoch) interdit dans un nom de fichier
  if [[ "$(basename "$f")" != "$canonical" ]]; then
    echo "    $(basename "$f") -> $canonical"
    mv -f "$f" "$KERNEL_DIR/$canonical"
  fi
done

############################################################
# [2/9] Purge des anciennes versions
############################################################
echo "[2/9] Purge des anciennes versions..."

# Regroupe un paquet noyau par FAMILLE, en retirant la version du NOM.
#
# Sans ça la purge ne purgeait jamais rien: pour un noyau, la version est
# incluse dans le nom du paquet (linux-image-7.1.10-auxinux-virtua-amd64), donc
# "les versions du paquet X" valait toujours exactement 1, quel que soit
# KEEP_VERSIONS. C'est pourquoi le dépôt accumulait 7.1.1, 7.1.3, 7.1.10...
#
#   linux-image-7.1.10-auxinux-virtua-amd64      -> linux-image::auxinux-virtua-amd64      (7.1.10)
#   linux-image-7.2.2-DEV-auxinux-virtua-amd64   -> linux-image::DEV-auxinux-virtua-amd64  (7.2.2)
#   kernel-virtua                                -> kernel-virtua        (version du paquet)
#
# Les noyaux DEV et prod tombent donc dans des familles distinctes et ne se
# purgent jamais l'un l'autre.
pkg_family_key() {
  local pkg="$1" version="$2"
  if [[ "$pkg" =~ ^(linux-[a-z]+)-([0-9]+(\.[0-9]+)+)-(.+)$ ]]; then
    printf '%s::%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[2]}"
  else
    printf '%s\t%s\n' "$pkg" "$version"
  fi
}

prune_old() {
  local n="$1"
  if (( n <= 0 )); then
    echo "  Purge désactivée (KEEP_VERSIONS=0)."
    return 0
  fi

  # Un seul balayage du dossier (l'ancienne version relisait chaque .deb une
  # fois par famille, sur des fichiers qui pèsent jusqu'à 2 Go).
  local index famkey sortkey pkg version arch
  index="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      pkg="$(dpkg-deb -f "$f" Package)"
      version="$(dpkg-deb -f "$f" Version)"
      arch="$(dpkg-deb -f "$f" Architecture)"
      IFS=$'\t' read -r famkey sortkey < <(pkg_family_key "$pkg" "$version")
      printf '%s\t%s\t%s\n' "${famkey}|${arch}" "$sortkey" "$f"
    done | sort -t$'\t' -k1,1 -k2,2V
  )"

  [[ -n "$index" ]] || { echo "  (aucun paquet à purger)"; return 0; }

  local fam
  while IFS= read -r fam; do
    [[ -n "$fam" ]] || continue
    local files=()
    mapfile -t files < <(awk -F'\t' -v F="$fam" '$1==F{print $3}' <<< "$index")
    local count=${#files[@]}
    if (( count > n )); then
      local remove=$(( count - n ))
      echo "  ${fam}: ${count} versions -> suppression des ${remove} plus anciennes"
      local i
      for ((i=0; i<remove; i++)); do
        echo "    rm $(basename "${files[$i]}")"
        rm -f "${files[$i]}"
      done
    fi
  done < <(cut -d$'\t' -f1 <<< "$index" | sort -u)
}

prune_old "$KEEP_VERSIONS"

############################################################
# [3/9] Génération du paquet meta
############################################################
echo "[3/9] Génération du paquet meta..."

generate_meta_package() {
  local kernel_flavour="$1"
  local meta_package="$2"
  local deb_arch="$3"
  local record image_version image_pkg image_file kernel_release
  local header_pkg header_version deps recommends tmp safe_version pkg version pkg_arch

  record="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      pkg="$(dpkg-deb -f "$f" Package)"
      version="$(dpkg-deb -f "$f" Version)"
      pkg_arch="$(dpkg-deb -f "$f" Architecture)"
      [[ "$pkg_arch" == "$deb_arch" ]] || continue
      case "$pkg" in
        # Ignore les paquets de symboles de debug: le meta doit dépendre
        # du vrai noyau, pas de linux-image-...-dbg / -dbgsym.
        linux-image-*-"${kernel_flavour}"-*-dbg) ;;
        linux-image-*-"${kernel_flavour}"-*-dbgsym) ;;
        # Sur le track prod, kernel_flavour vaut 'auxinux-virtua' et le motif
        # générique ci-dessous matcherait AUSSI un noyau DEV nommé
        # linux-image-7.2.2-DEV-auxinux-virtua-amd64 (le '*' couvre 'DEV').
        # kernel-virtua pointerait alors sur un noyau de test. On l'exclut.
        # Sur le track dev ce motif ne matche rien (DEV-DEV-...), donc inoffensif.
        linux-image-*-DEV-"${kernel_flavour}"-*) ;;
        linux-image-*-"${kernel_flavour}"-*)
          printf '%s\t%s\t%s\n' "$version" "$pkg" "$f"
          ;;
      esac
    done | sort -V | tail -n1
  )"

  if [[ -z "$record" ]]; then
    echo "  Aucun paquet linux-image-*-${kernel_flavour}-* [$deb_arch] trouvé, meta ${meta_package} non généré."
    return 0
  fi

  IFS=$'\t' read -r image_version image_pkg image_file <<< "$record"
  kernel_release="${image_pkg#linux-image-}"
  header_pkg="linux-headers-${kernel_release}"
  deps="${image_pkg} (= ${image_version})"
  recommends=""

  header_version="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      if [[ "$(dpkg-deb -f "$f" Package)" == "$header_pkg" ]]; then
        pkg_arch="$(dpkg-deb -f "$f" Architecture)"
        [[ "$pkg_arch" == "$deb_arch" || "$pkg_arch" == "all" ]] || continue
        dpkg-deb -f "$f" Version
        break
      fi
    done
  )"

  if [[ -n "$header_version" ]]; then
    deps="${deps}, ${header_pkg} (= ${header_version})"
  else
    echo "  AVERTISSEMENT: headers absents pour ${kernel_release}; meta image seulement."
  fi

  # Paquet source OpenZFS (DKMS, modèle Debian) si présent dans le dépôt. Le
  # nom du paquet est FIXE (openzfs-zfs-dkms, arch=all): contrairement à
  # l'ancien module précompilé (kmod-zfs-<release>), il n'est pas apparié à un
  # kernel précis par son nom — DKMS le recompile pour n'importe quel kernel
  # installé, à condition d'avoir les headers correspondants au moment de
  # l'install.
  local zfs_pkg zfs_version
  zfs_pkg="$(
    for f in "$KERNEL_DIR"/*.deb; do
      [[ -e "$f" ]] || continue
      pkg="$(dpkg-deb -f "$f" Package)"
      pkg_arch="$(dpkg-deb -f "$f" Architecture)"
      [[ "$pkg" == "openzfs-zfs-dkms" && "$pkg_arch" == "all" ]] || continue
      echo "$pkg"; break
    done
  )"
  if [[ -n "$zfs_pkg" ]]; then
    # DKMS échoue SILENCIEUSEMENT à l'installation si les headers du kernel
    # cible sont absents du dépôt (le module ne se (re)compile juste jamais,
    # sans erreur bloquante visible). On refuse donc de publier ce meta dans
    # cette situation, plutôt qu'un simple avertissement.
    [[ -n "$header_version" ]] \
      || die "openzfs-zfs-dkms présent dans ${KERNEL_DIR} mais ${header_pkg} absent.
DKMS ne pourra pas compiler le module ZFS à l'installation sans ces headers.
Ajoute ${header_pkg} au dépôt, ou retire openzfs-zfs-dkms de ${KERNEL_DIR}."

    zfs_version="$(
      for f in "$KERNEL_DIR"/*.deb; do
        [[ -e "$f" ]] || continue
        [[ "$(dpkg-deb -f "$f" Package)" == "$zfs_pkg" ]] || continue
        dpkg-deb -f "$f" Version; break
      done
    )"
    case "$ZFS_META_DEP" in
      depends)
        deps="${deps}, ${zfs_pkg} (= ${zfs_version})"
        echo "  + OpenZFS DKMS en Depends: ${zfs_pkg} (${zfs_version})"
        ;;
      recommends)
        recommends="${zfs_pkg} (= ${zfs_version})"
        echo "  + OpenZFS DKMS en Recommends: ${zfs_pkg} (${zfs_version})"
        ;;
      none)
        echo "  + OpenZFS DKMS détecté mais ignoré par le meta: ${zfs_pkg} (${zfs_version})"
        ;;
      *)
        die "ZFS_META_DEP invalide: ${ZFS_META_DEP}. Valeurs: depends, recommends, none."
        ;;
    esac
  fi

  rm -f "$KERNEL_DIR/${meta_package}"_*_"${deb_arch}".deb

  tmp="$(mktemp -d)"
  mkdir -p "$tmp/DEBIAN" "$tmp/usr/share/doc/$meta_package"
  cat > "$tmp/DEBIAN/control" <<EOF
Package: ${meta_package}
Version: ${image_version}
Architecture: ${deb_arch}
Section: kernel
Priority: optional
Maintainer: AuxiNux <repo@auxinux.ca>
Depends: ${deps}
EOF
  [[ -n "$recommends" ]] && printf 'Recommends: %s\n' "$recommends" >> "$tmp/DEBIAN/control"
  cat >> "$tmp/DEBIAN/control" <<EOF
Description: AuxiNux kernel meta-package
 This package depends on the latest AuxiNux ${kernel_flavour} kernel image and headers.
EOF
  printf 'AuxiNux %s kernel meta-package\n' "$kernel_flavour" > "$tmp/usr/share/doc/$meta_package/README"
  gzip -9n "$tmp/usr/share/doc/$meta_package/README"

  safe_version="${image_version//:/_}"
  dpkg-deb --build "$tmp" "$KERNEL_DIR/${meta_package}_${safe_version}_${deb_arch}.deb" >/dev/null
  rm -rf "$tmp"

  echo "  ${meta_package} [$deb_arch] -> ${image_pkg} (${image_version})"
}

for meta_profile in "${META_PROFILES[@]}"; do
  IFS=':' read -r meta_flavour meta_package meta_arches <<< "$meta_profile"
  for deb_arch in $meta_arches; do
    generate_meta_package "$meta_flavour" "$meta_package" "$deb_arch"
  done
done

############################################################
# [4/9] Création arborescence
############################################################
echo "[4/9] Création arborescence..."

for deb_arch in $ARCHES; do
  mkdir -p "$REPO_ROOT/dists/$DIST/$COMPONENT/binary-${deb_arch}"
done
mkdir -p "$REPO_ROOT/dists/$DIST/$COMPONENT/binary-all"
mkdir -p "$REPO_ROOT/dists/$DIST/$COMPONENT/i18n"

############################################################
# [5/9] Génération Packages
############################################################
echo "[5/9] Génération Packages..."

# IMPORTANT: on scanne un chemin RELATIF à la racine du dépôt pour que
# le champ Filename soit "KERNEL/xxx.deb" et non un chemin absolu
# (sinon apt construit une URL invalide et apt install échoue).
cd "$REPO_ROOT"
REL_KERNEL="$(realpath --relative-to="$REPO_ROOT" "$KERNEL_DIR")"

case "$REL_KERNEL" in
  ../*|/*) die "KERNEL_DIR doit être à l'intérieur de REPO_ROOT pour générer un Filename valide." ;;
esac

for deb_arch in $ARCHES; do
  pkg_file="$REPO_ROOT/dists/$DIST/$COMPONENT/binary-${deb_arch}/Packages"
  dpkg-scanpackages --multiversion --arch "$deb_arch" "$REL_KERNEL" /dev/null > "$pkg_file"
  gzip -9fk "$pkg_file"
  xz   -9fk "$pkg_file"
done

############################################################
# [6/9] binary-all + i18n (vides)
############################################################
echo "[6/9] Génération binary-all et i18n..."

PKG_ALL="$REPO_ROOT/dists/$DIST/$COMPONENT/binary-all/Packages"
: > "$PKG_ALL"
gzip -9fk "$PKG_ALL"
xz   -9fk "$PKG_ALL"

I18N="$REPO_ROOT/dists/$DIST/$COMPONENT/i18n/Translation-en"
: > "$I18N"
gzip -9fk "$I18N"
xz   -9fk "$I18N"

############################################################
# [7/9] Génération Release
############################################################
echo "[7/9] Génération Release..."

cd "$REPO_ROOT/dists/$DIST"

apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="AuxiNux" \
  -o APT::FTPArchive::Release::Label="$REPO_LABEL" \
  -o APT::FTPArchive::Release::Suite="$DIST" \
  -o APT::FTPArchive::Release::Codename="$DIST" \
  -o APT::FTPArchive::Release::Architectures="${ARCHES} all" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="$REPO_DESCRIPTION" \
  release . > Release

############################################################
# [8/9] Signature GPG
############################################################
echo "[8/9] Signature..."

rm -f Release.gpg InRelease

if [[ "$SIGN" == "1" ]]; then
  # Release.gpg = signature détachée ; InRelease = Release signé inline.
  gpg --batch --yes --default-key "$GPG_KEY" -abs -o Release.gpg Release
  gpg --batch --yes --default-key "$GPG_KEY" --clearsign -o InRelease Release

  # Publie la clé publique pour les utilisateurs (format .asc et .gpg).
  gpg --armor --export "$GPG_KEY" > "$KEYRING_ASC"
  gpg --export "$GPG_KEY"          > "$KEYRING_GPG"
  echo "  Clé publique publiée: $KEYRING_GPG"
else
  echo "  Signature désactivée (SIGN=0) — dépôt en trusted=yes."
fi

############################################################
# [9/9] Permissions
############################################################
echo "[9/9] Permissions..."

# Ne rend lisibles que les éléments réellement publiés (pas tout REPO_ROOT,
# qui peut contenir d'autres fichiers/clés privées hors de ce dépôt).
chmod a+rX "$REPO_ROOT"
chmod -R a+rX "$KERNEL_DIR" "$REPO_ROOT/dists"
[[ -f "$KEYRING_ASC" ]] && chmod a+r "$KEYRING_ASC"
[[ -f "$KEYRING_GPG" ]] && chmod a+r "$KEYRING_GPG"

if [[ "$DEPLOY" == "1" ]]; then
  [[ -n "$DEPLOY_TARGET" ]] || die "DEPLOY=1 mais DEPLOY_TARGET est vide."
  echo
  echo "[10/10] Déploiement vers ${DEPLOY_TARGET}..."
  if [[ "$DEPLOY_TARGET" == *:* ]]; then
    rsync -a --delete "$REPO_ROOT/" "${DEPLOY_TARGET%/}/"
  else
    mkdir -p "$DEPLOY_TARGET"
    rsync -a --delete "$REPO_ROOT/" "${DEPLOY_TARGET%/}/"
  fi
fi

############################################################
# Fin
############################################################
echo
echo "=================================================="
echo " Dépôt généré avec succès"
echo "=================================================="
echo
echo "Paquets actuellement dans le dépôt:"
ls -1 "$KERNEL_DIR"/*.deb 2>/dev/null | sed 's/^/  /' || echo "  (aucun)"
echo

if [[ "$SIGN" == "1" ]]; then
  echo "Configuration côté client (dépôt signé):"
  echo
  echo "  sudo wget -O /usr/share/keyrings/${KEYRING_BASENAME}.gpg \\"
  echo "       ${PUBLIC_REPO_URL}/${KEYRING_BASENAME}.gpg"
  echo
  echo "  echo 'deb [signed-by=/usr/share/keyrings/${KEYRING_BASENAME}.gpg arch=amd64] ${PUBLIC_REPO_URL} ${DIST} main' \\"
  echo "       | sudo tee /etc/apt/sources.list.d/${SOURCES_LIST_NAME}.list"
  echo
else
  echo "Configuration côté client (non signé):"
  echo "  deb [trusted=yes arch=amd64] ${PUBLIC_REPO_URL} ${DIST} main"
  echo
fi

echo "Test:"
echo "  sudo apt update"
for meta_profile in "${META_PROFILES[@]}"; do
  IFS=':' read -r _meta_flavour meta_package _meta_arches <<< "$meta_profile"
  echo "  apt-cache policy ${meta_package}"
done
echo
