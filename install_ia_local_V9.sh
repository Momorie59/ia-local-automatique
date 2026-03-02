#!/usr/bin/env bash
# ia-local — install_ia_local_V9.sh
# Copyright (C) 2025 Momorie
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# ================================================================
#  INSTALLATEUR IA LOCAL — INTELLIGENT & ADAPTATIF v8.0
#  Auteur    : Momorie con Claude IA
#  Analyse complète du matériel → Plan d'installation optimal
#  Compatible : Ubuntu, Pop!_OS, Debian, Fedora, Arch, openSUSE,
#               Void, Alpine — toute distro Linux x86_64/arm64
#  GPU        : NVIDIA (CUDA) / AMD (ROCm) / Intel Arc / CPU
#  Usage      : sudo bash install_ia_local.sh
#  Reprise    : automatique après erreur ou reboot (systemd/openrc)
#  Logs       : /var/log/ia-installer/install-YYYYMMDD.log
#  Docker     : --network=host + OLLAMA_BASE_URL (référence)
# ================================================================
#
#  ⚠  EN CAS DE PERTE DE DONNÉES APRÈS UNE MAJ OPEN WEBUI :
#  Les données sont dans : /mnt/ia_toshiba/open-webui/
#  Pour relancer avec la bonne commande :
#    sudo bash install_ia_local.sh  → [Option 7] Réparer WebUI

# ================================================================

# NE PAS utiliser set -e ici : on gère les erreurs via trap ERR
set -uo pipefail
umask 027   # Nouveaux fichiers : rw-r----- (640), répertoires : rwxr-x--- (750)
# PATH sécurisé : uniquement des chemins absolus connus
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
IFS=$'\n\t'

# ── Couleurs ────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';    DIM='\033[2m';      NC='\033[0m'
RESET='\033[0m'

# ── Helpers affichage (définis tôt pour être disponibles immédiatement) ────────
log()     { local MSG="[$(date +%H:%M:%S)] [OK]   $1"; echo -e "${GREEN}${MSG}${NC}"; }
warn()    { local MSG="[$(date +%H:%M:%S)] [WARN] $1"; echo -e "${YELLOW}${MSG}${NC}" >&2; }
err_msg() { local MSG="[$(date +%H:%M:%S)] [ERR]  $1"; echo -e "${RED}${MSG}${NC}" >&2; }
info()    { local MSG="[$(date +%H:%M:%S)] [INFO] $1"; echo -e "${CYAN}${MSG}${NC}"; }
step()    { echo -e "\n${MAGENTA}[>>>]${NC}  ${BOLD}$1${NC}"; }
ok()      { echo -e "  ${GREEN}✓${NC} $1"; }
nok()     { echo -e "  ${RED}✗${NC} $1"; }
neutral() { echo -e "  ${CYAN}→${NC} $1"; }
hr()      { echo -e "${DIM}  $(printf '─%.0s' {1..60})${NC}"; }

error() {
  err_msg "$1"
  echo -e "${RED}  Script arrêté. Consulte le log : $LOG_FILE${NC}" >&2
  exit 1
}

# ── Gestion des droits root/sudo ────────────────────────────────
_check_privileges() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERR]${NC} Ce script requiert les droits administrateur."
    echo ""
    echo -e "  Lance-le de l'une de ces façons :"
    echo -e "  ${CYAN}  sudo bash $0${NC}         ← recommandé"
    echo -e "  ${CYAN}  sudo bash $(realpath "$0")${NC}"
    echo ""
    echo -e "  ${DIM}Ton utilisateur doit être dans le groupe sudo.${NC}"
    echo -e "  ${DIM}Pour vérifier : groups \$(whoami)${NC}"
    exit 1
  fi
  # Récupérer l'utilisateur réel même sous sudo
  if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
  elif [ -n "${PKEXEC_UID:-}" ]; then
    REAL_USER=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
  else
    REAL_USER="$USER"
  fi
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
  # Fallback sûr sans eval (évite injection via nom utilisateur)
  [ -z "$REAL_HOME" ] && REAL_HOME="/home/$REAL_USER"
  # Garde-fou : on refuse de définir REAL_USER=root (ne pas chowner en root)
  if [ "$REAL_USER" = "root" ]; then
    warn "Impossible de déterminer l'utilisateur réel (REAL_USER=root)."
    warn "Lancez avec 'sudo bash $0' depuis un compte non-root."
    REAL_USER=""
    REAL_HOME=""
  fi
  export REAL_USER REAL_HOME
}

_check_privileges

# ================================================================
#  DÉTECTION OS & ABSTRACTION DU GESTIONNAIRE DE PAQUETS
# ================================================================

# Variables globales OS — remplies par detect_os()
OS_FAMILY=""      # debian | rhel | arch | suse | void | alpine | unknown
OS_DISTRO=""      # ubuntu | pop | debian | fedora | arch | manjaro | ...
OS_VERSION=""     # numéro de version
OS_CODENAME=""    # jammy / focal / bullseye / ...
PKG_MGR=""        # apt | dnf | yum | pacman | zypper | xbps-install | apk
PKG_QUERY=""      # commande pour tester si un paquet est installé
HAS_SYSTEMD=1     # 0 sur Alpine/Void avec openrc
NVIDIA_DRIVER_METHOD=""  # ubuntu-drivers | dnf-rpmfusion | pacman | zypper-nvidia
AUR_HELPER=""          # yay | paru | trizen (Arch uniquement)

detect_os() {
  # Source /etc/os-release (universel Linux)
  if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_DISTRO="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-?}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-?}}"
  else
    OS_DISTRO=$(uname -s | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(uname -r)
    OS_CODENAME="?"
  fi

  # Déterminer la famille
  case "$OS_DISTRO" in
    ubuntu|pop|debian|linuxmint|kali|mx|raspbian|elementary|zorin|neon|parrot|deepin)
      OS_FAMILY="debian" ; PKG_MGR="apt"
      PKG_QUERY="dpkg -l"
      NVIDIA_DRIVER_METHOD="ubuntu-drivers"
      # Sur Debian pur, ubuntu-drivers n'existe pas
      [ "$OS_DISTRO" = "debian" ] && NVIDIA_DRIVER_METHOD="apt-nvidia"
      ;;
    fedora|rhel|centos|rocky|almalinux|oracle|amzn|eurolinux|springdale)
      OS_FAMILY="rhel"
      # Fedora ≥22 utilise dnf, CentOS7/RHEL7 utilisent yum
      if command -v dnf &>/dev/null; then PKG_MGR="dnf"
      else PKG_MGR="yum"; fi
      PKG_QUERY="rpm -q"
      NVIDIA_DRIVER_METHOD="dnf-rpmfusion"
      ;;
    arch|manjaro|endeavouros|garuda|artix|blackarch|parabola|archcraft)
      OS_FAMILY="arch" ; PKG_MGR="pacman"
      PKG_QUERY="pacman -Q"
      NVIDIA_DRIVER_METHOD="pacman-nvidia"
      # Détecter AUR helper
      if   command -v yay   &>/dev/null; then AUR_HELPER="yay"
      elif command -v paru  &>/dev/null; then AUR_HELPER="paru"
      elif command -v trizen &>/dev/null; then AUR_HELPER="trizen"
      else AUR_HELPER=""; fi
      ;;
    opensuse*|suse|sles)
      OS_FAMILY="suse" ; PKG_MGR="zypper"
      PKG_QUERY="rpm -q"
      NVIDIA_DRIVER_METHOD="zypper-nvidia"
      ;;
    void)
      OS_FAMILY="void" ; PKG_MGR="xbps-install"
      PKG_QUERY="xbps-query"
      NVIDIA_DRIVER_METHOD="xbps-nvidia"
      # Void peut avoir openrc ou runit
      command -v systemctl &>/dev/null && HAS_SYSTEMD=1 || HAS_SYSTEMD=0
      ;;
    alpine)
      OS_FAMILY="alpine" ; PKG_MGR="apk"
      PKG_QUERY="apk info -e"
      NVIDIA_DRIVER_METHOD="apk-nvidia"
      HAS_SYSTEMD=0
      ;;
    gentoo|funtoo)
      OS_FAMILY="gentoo" ; PKG_MGR="emerge"
      PKG_QUERY="qlist -I"
      NVIDIA_DRIVER_METHOD="portage-nvidia"
      ;;
    *)
      # Détection par fallback sur les gestionnaires disponibles
      if   command -v apt     &>/dev/null; then OS_FAMILY="debian"; PKG_MGR="apt"
      elif command -v dnf     &>/dev/null; then OS_FAMILY="rhel";   PKG_MGR="dnf"
      elif command -v yum     &>/dev/null; then OS_FAMILY="rhel";   PKG_MGR="yum"
      elif command -v pacman  &>/dev/null; then OS_FAMILY="arch";   PKG_MGR="pacman"
      elif command -v zypper  &>/dev/null; then OS_FAMILY="suse";   PKG_MGR="zypper"
      elif command -v xbps-install &>/dev/null; then OS_FAMILY="void"; PKG_MGR="xbps-install"
      elif command -v apk    &>/dev/null; then OS_FAMILY="alpine";  PKG_MGR="apk"
      else OS_FAMILY="unknown"; PKG_MGR="unknown"; fi
      ;;
  esac

  export OS_FAMILY OS_DISTRO OS_VERSION OS_CODENAME PKG_MGR HAS_SYSTEMD NVIDIA_DRIVER_METHOD
}

# ── Wrappers abstraits du gestionnaire de paquets ────────────────

pkg_update() {
  local MSG="Mise à jour de la liste des paquets ($PKG_MGR)"
  case "$PKG_MGR" in
    apt)
      run_with_spinner "DEBIAN_FRONTEND=noninteractive apt update -y" "$MSG"
      ;;
    dnf)
      # dnf check-update can return 100 if updates are available, which is normal.
      # We still want the spinner.
      run_with_spinner "dnf check-update -y || true" "$MSG"
      ;;
    yum)
      run_with_spinner "yum check-update -y || true" "$MSG"
      ;;
    pacman)
      run_with_spinner "pacman -Sy --noconfirm" "$MSG"
      ;;
    zypper)
      run_with_spinner "zypper refresh" "$MSG"
      ;;
    xbps-install)
      run_with_spinner "xbps-install -S" "$MSG"
      ;;
    apk)
      run_with_spinner "apk update" "$MSG"
      ;;
    emerge)
      run_with_spinner "emerge --sync" "$MSG"
      ;;
    *)
      warn "Gestionnaire $PKG_MGR non supporté pour update."
      return 1
      ;;
  esac
  return $? # Return the exit code of the spinner function
}

pkg_upgrade() {
  local MSG="Mise à niveau du système ($PKG_MGR)"
  case "$PKG_MGR" in
    apt)
      run_with_spinner "DEBIAN_FRONTEND=noninteractive apt full-upgrade -y" "$MSG"
      ;;
    dnf)
      run_with_spinner "dnf upgrade -y" "$MSG"
      ;;
    yum)
      run_with_spinner "yum update -y" "$MSG"
      ;;
    pacman)
      run_with_spinner "pacman -Su --noconfirm" "$MSG"
      ;;
    zypper)
      run_with_spinner "zypper update -y" "$MSG"
      ;;
    xbps-install)
      run_with_spinner "xbps-install -u" "$MSG"
      ;;
    apk)
      run_with_spinner "apk upgrade" "$MSG"
      ;;
    emerge)
      run_with_spinner "emerge -uDN @world" "$MSG"
      ;;
    *)
      warn "Gestionnaire $PKG_MGR non supporté pour upgrade."
      return 1
      ;;
  esac
  return $?
}

pkg_install() {
  # Usage : pkg_install paquet1 paquet2 ...
  # Traduit automatiquement les noms génériques vers les noms réels
  local PKGS_TO_INSTALL=()
  for P in "$@"; do
    PKGS_TO_INSTALL+=("$(_pkg_translate "$P")")
  done
  # Filtrer les paquets vides (non traduits = non disponibles sur cette distro)
  local REAL_PKGS=()
  for P in "${PKGS_TO_INSTALL[@]}"; do
    [ -n "$P" ] && REAL_PKGS+=("$P")
  done
  [ "${#REAL_PKGS[@]}" -eq 0 ] && { ok "Pas de paquets à installer."; return 0; }

  local MSG="Installation de ${REAL_PKGS[*]} via $PKG_MGR"
  local CMD=""

  case "$PKG_MGR" in
    apt)
      CMD="DEBIAN_FRONTEND=noninteractive apt install -y ${REAL_PKGS[*]}"
      ;;
    dnf)
      CMD="dnf install -y ${REAL_PKGS[*]}"
      ;;
    yum)
      CMD="yum install -y ${REAL_PKGS[*]}"
      ;;
    pacman)
      CMD="pacman -S --noconfirm --needed ${REAL_PKGS[*]}"
      ;;
    zypper)
      CMD="zypper install -y ${REAL_PKGS[*]}"
      ;;
    xbps-install)
      CMD="xbps-install -y ${REAL_PKGS[*]}"
      ;;
    apk)
      CMD="apk add ${REAL_PKGS[*]}"
      ;;
    emerge)
      CMD="emerge ${REAL_PKGS[*]}"
      ;;
    *)
      warn "Gestionnaire $PKG_MGR non supporté pour l'installation."
      return 1
      ;;
  esac

  run_with_spinner "$CMD" "$MSG"
  return $?
}

pkg_remove() {
  local PKGS=()
  for P in "$@"; do PKGS+=("$(_pkg_translate "$P")"); done
  case "$PKG_MGR" in
    apt)    DEBIAN_FRONTEND=noninteractive apt remove -y "${PKGS[@]}" ;;
    dnf)    dnf remove -y "${PKGS[@]}" ;;
    yum)    yum remove -y "${PKGS[@]}" ;;
    pacman) pacman -R --noconfirm "${PKGS[@]}" 2>/dev/null || true ;;
    zypper) zypper remove -y "${PKGS[@]}" ;;
    apk)    apk del "${PKGS[@]}" ;;
    *)      warn "pkg_remove: $PKG_MGR non supporté." ;;
  esac
}

pkg_autoremove() {
  local MSG="Nettoyage des paquets orphelins ($PKG_MGR)"
  case "$PKG_MGR" in
    apt)    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt autoremove -y; apt autoclean -y" "$MSG" ;;
    dnf)    run_with_spinner "dnf autoremove -y" "$MSG" ;;
    yum)    run_with_spinner "yum autoremove -y" "$MSG" ;;
    pacman) run_with_spinner "pacman -Rns \"$(pacman -Qdtq)\" --noconfirm 2>/dev/null || true" "$MSG" ;; # Needs proper quoting
    zypper) run_with_spinner "zypper clean" "$MSG" ;;
    apk)    run_with_spinner "apk cache clean" "$MSG" ;;
    *)      warn "pkg_autoremove: $PKG_MGR non supporté." ;;
  esac
  return $?
}

pkg_installed() {
  # Retourne 0 si le paquet est installé
  local PKG="$(_pkg_translate "$1")"
  [ -z "$PKG" ] && return 1
  case "$PKG_MGR" in
    apt)          dpkg -l "$PKG" 2>/dev/null | grep -q "^ii" ;;
    dnf|yum)      rpm -q "$PKG" &>/dev/null ;;
    pacman)       pacman -Q "$PKG" &>/dev/null ;;
    zypper)       rpm -q "$PKG" &>/dev/null ;;
    xbps-install) xbps-query "$PKG" &>/dev/null ;;
    apk)          apk info -e "$PKG" &>/dev/null ;;
    *)            command -v "$PKG" &>/dev/null ;;
  esac
}

pkg_count_upgradable() {
  # Retourne le nombre de paquets pouvant être mis à jour (entier garanti)
  local _N=0
  case "$PKG_MGR" in
    apt)
      # apt list inclut une ligne "Listing..." → grep -c 'upgradable' filtre proprement
      _N=$(apt list --upgradable 2>/dev/null | grep -c '/.*upgradable' || echo 0)
      ;;
    dnf)
      # dnf list updates retourne code 100 si MAJ dispo → || true
      _N=$(dnf list updates 2>/dev/null | grep -c '^[^L]' || echo 0)
      ;;
    yum)
      _N=$(yum list updates 2>/dev/null | grep -c '^[^L]' || echo 0)
      ;;
    pacman)
      _N=$(pacman -Qu 2>/dev/null | grep -c '.' || echo 0)
      ;;
    zypper)
      _N=$(zypper list-updates 2>/dev/null | grep -c '^v' || echo 0)
      ;;
    apk)
      _N=$(apk version -l '<' 2>/dev/null | grep -c '<' || echo 0)
      ;;
    *)
      _N=0
      ;;
  esac
  # Sanitiser : extraire uniquement les chiffres, fallback 0
  _N=$(echo "$_N" | tr -cd '0-9' | head -c 6)
  echo "${_N:-0}"
}

# ── Traduction des noms de paquets génériques → distro ──────────
_pkg_translate() {
  local GENERIC="$1"
  case "$OS_FAMILY:$GENERIC" in

    # ── curl ──
    *:curl)              echo "curl" ;;

    # ── wget ──
    *:wget)              echo "wget" ;;

    # ── git ──
    *:git)               echo "git" ;;

    # ── htop ──
    *:htop)              echo "htop" ;;

    # ── nvtop (moniteur GPU) ──
    debian:nvtop)        echo "nvtop" ;;
    rhel:nvtop)          echo "nvtop" ;;
    arch:nvtop)          echo "nvtop" ;;
    suse:nvtop)          echo "nvtop" ;;
    *:nvtop)             echo "nvtop" ;;

    # ── pciutils (lspci) ──
    debian:pciutils)     echo "pciutils" ;;
    rhel:pciutils)       echo "pciutils" ;;
    arch:pciutils)       echo "pciutils" ;;
    suse:pciutils)       echo "pciutils" ;;
    void:pciutils)       echo "pciutils" ;;
    alpine:pciutils)     echo "pciutils" ;;

    # ── smartmontools ──
    debian:smartmontools) echo "smartmontools" ;;
    rhel:smartmontools)   echo "smartmontools" ;;
    arch:smartmontools)   echo "smartmontools" ;;
    suse:smartmontools)   echo "smartmontools" ;;
    void:smartmontools)   echo "smartmontools" ;;
    alpine:smartmontools) echo "smartctl" ;;

    # ── dmidecode ──
    debian:dmidecode)    echo "dmidecode" ;;
    rhel:dmidecode)      echo "dmidecode" ;;
    arch:dmidecode)      echo "dmidecode" ;;
    suse:dmidecode)      echo "dmidecode" ;;
    void:dmidecode)      echo "dmidecode" ;;
    alpine:dmidecode)    echo "" ;;  # non dispo sur Alpine

    # ── build-essential / compilateurs ──
    debian:build-essential)  echo "build-essential" ;;
    rhel:build-essential)    echo "gcc gcc-c++ make kernel-devel" ;;
    arch:build-essential)    echo "base-devel" ;;
    suse:build-essential)    echo "gcc gcc-c++ make" ;;
    void:build-essential)    echo "base-devel" ;;
    alpine:build-essential)  echo "build-base" ;;

    # ── python3-pip ──
    debian:python3-pip)  echo "python3-pip" ;;
    rhel:python3-pip)    echo "python3-pip" ;;
    arch:python3-pip)    echo "python-pip" ;;
    suse:python3-pip)    echo "python3-pip" ;;
    void:python3-pip)    echo "python3-pip" ;;
    alpine:python3-pip)  echo "py3-pip" ;;

    # ── python3-dev / headers ──
    debian:python3-dev)  echo "python3-dev" ;;
    rhel:python3-dev)    echo "python3-devel" ;;
    arch:python3-dev)    echo "python" ;;
    suse:python3-dev)    echo "python3-devel" ;;
    alpine:python3-dev)  echo "python3-dev" ;;

    # ── ca-certificates ──
    debian:ca-certificates)  echo "ca-certificates" ;;
    rhel:ca-certificates)    echo "ca-certificates" ;;
    arch:ca-certificates)    echo "ca-certificates" ;;
    suse:ca-certificates)    echo "ca-certificates" ;;
    alpine:ca-certificates)  echo "ca-certificates" ;;

    # ── gnupg ──
    debian:gnupg)        echo "gnupg" ;;
    rhel:gnupg)          echo "gnupg2" ;;
    arch:gnupg)          echo "gnupg" ;;
    suse:gnupg)          echo "gpg2" ;;
    alpine:gnupg)        echo "gnupg" ;;

    # ── apt-transport-https (Debian uniquement) ──
    debian:apt-transport-https) echo "apt-transport-https" ;;
    *:apt-transport-https)      echo "" ;;  # pas besoin ailleurs

    # ── software-properties-common ──
    debian:software-properties-common)
      [ "$OS_DISTRO" = "debian" ] && echo "software-properties-common"                                    || echo "software-properties-common" ;;
    rhel:software-properties-common)  echo "" ;;
    arch:software-properties-common)  echo "" ;;
    *:software-properties-common)     echo "" ;;

    # ── unzip / zip ──
    *:unzip)             echo "unzip" ;;
    *:zip)               echo "zip" ;;
    *:p7zip-full)
      case "$OS_FAMILY" in
        debian) echo "p7zip-full" ;;
        rhel)   echo "p7zip p7zip-plugins" ;;
        arch)   echo "p7zip" ;;
        suse)   echo "p7zip" ;;
        alpine) echo "p7zip" ;;
        *)      echo "p7zip" ;;
      esac ;;

    # ── net-tools ──
    debian:net-tools)    echo "net-tools" ;;
    rhel:net-tools)      echo "net-tools" ;;
    arch:net-tools)      echo "net-tools" ;;
    suse:net-tools)      echo "net-tools" ;;
    alpine:net-tools)    echo "" ;;  # iproute2 suffisant

    # ── ethtool ──
    *:ethtool)           echo "ethtool" ;;

    # ── mokutil (Secure Boot) ──
    debian:mokutil)      echo "mokutil" ;;
    rhel:mokutil)        echo "mokutil" ;;
    arch:mokutil)        echo "mokutil" ;;
    *:mokutil)           echo "" ;;

    # ── docker.io / docker ──
    debian:docker.io)
      # Sur Ubuntu/Debian on peut utiliser docker.io ou le repo officiel Docker
      echo "docker.io" ;;
    rhel:docker.io)      echo "docker" ;;
    arch:docker.io)      echo "docker" ;;
    suse:docker.io)      echo "docker" ;;
    void:docker.io)      echo "docker" ;;
    alpine:docker.io)    echo "docker" ;;

    # ── docker-compose ──
    debian:docker-compose)  echo "docker-compose" ;;
    rhel:docker-compose)    echo "docker-compose" ;;
    arch:docker-compose)    echo "docker-compose" ;;
    suse:docker-compose)    echo "docker-compose" ;;
    *:docker-compose)       echo "docker-compose" ;;

    # ── firmware AMD ──
    debian:firmware-amd-graphics)
      [ "$OS_DISTRO" = "debian" ] && echo "firmware-amd-graphics" || echo "linux-firmware" ;;
    rhel:firmware-amd-graphics)    echo "linux-firmware" ;;
    arch:firmware-amd-graphics)    echo "linux-firmware" ;;
    suse:firmware-amd-graphics)    echo "kernel-firmware-amdgpu" ;;
    void:firmware-amd-graphics)    echo "linux-firmware-amd" ;;
    alpine:firmware-amd-graphics)  echo "linux-firmware-amdgpu" ;;

    # ── linux-firmware ──
    debian:linux-firmware)  echo "linux-firmware" ;;
    rhel:linux-firmware)    echo "linux-firmware" ;;
    arch:linux-firmware)    echo "linux-firmware" ;;
    suse:linux-firmware)    echo "kernel-firmware" ;;
    void:linux-firmware)    echo "linux-firmware" ;;
    alpine:linux-firmware)  echo "linux-firmware-none" ;;

    # ── cmake ──
    *:cmake)             echo "cmake" ;;

    # Paquet inconnu → retourner tel quel
    *)                   echo "$GENERIC" ;;
  esac
}

# ── Gestion des services (systemd vs openrc vs runit) ────────────
svc_enable()  {
  local SVC="$1"
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl enable --now "$SVC" 2>/dev/null || true
  else
    # openrc (Alpine, Void sans systemd, Gentoo...)
    rc-update add "$SVC" default 2>/dev/null || true
    rc-service "$SVC" start 2>/dev/null || true
  fi
}

svc_start()   {
  local SVC="$1"
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl start "$SVC" 2>/dev/null || true
  elif command -v rc-service &>/dev/null; then
    rc-service "$SVC" start 2>/dev/null || true
  fi
}

svc_stop()    {
  local SVC="$1"
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl stop "$SVC" 2>/dev/null || true
  elif command -v rc-service &>/dev/null; then
    rc-service "$SVC" stop 2>/dev/null || true
  fi
}

svc_restart() {
  local SVC="$1"
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl restart "$SVC" 2>/dev/null || true
  elif command -v rc-service &>/dev/null; then
    rc-service "$SVC" restart 2>/dev/null || true
  fi
}

svc_active()  {
  local SVC="$1"
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl is-active --quiet "$SVC" 2>/dev/null
  else
    rc-service "$SVC" status 2>/dev/null | grep -q "started"
  fi
}

svc_daemon_reload() {
  [ "$HAS_SYSTEMD" -eq 1 ] && systemctl daemon-reload || true
}


# ── Téléchargement sécurisé du script Ollama avec vérification SHA256 ────────
_install_ollama_secure() {
  local _OLLAMA_SCRIPT; _OLLAMA_SCRIPT=$(mktemp /tmp/ollama-XXXXXX.sh)
  local _LOCAL_SHA _REMOTE_SHA

  step "Téléchargement du script d'installation Ollama..."
  if ! curl -fsSL --max-time 120 -o "$_OLLAMA_SCRIPT" https://ollama.com/install.sh; then
    rm -f "$_OLLAMA_SCRIPT"; warn "Téléchargement échoué."; return 1
  fi

  step "Vérification de l'intégrité SHA256..."
  _LOCAL_SHA=$(sha256sum "$_OLLAMA_SCRIPT" | cut -d' ' -f1)
  _REMOTE_SHA=$(curl -sf --max-time 15     "https://api.github.com/repos/ollama/ollama/contents/install.sh"     | python3 -c "
import sys,json,base64,hashlib
d=json.load(sys.stdin)
c=base64.b64decode(d['content']).decode('utf-8',errors='replace')
print(hashlib.sha256(c.encode('utf-8')).hexdigest())
" 2>/dev/null || echo "")

  if [ -z "$_REMOTE_SHA" ]; then
    warn "Vérification SHA256 impossible (GitHub inaccessible)."
    warn "SHA256 local : $_LOCAL_SHA"
    if ! confirm "Continuer sans vérification d'intégrité ?"; then
      rm -f "$_OLLAMA_SCRIPT"; return 1
    fi
  elif [ "$_LOCAL_SHA" != "$_REMOTE_SHA" ]; then
    rm -f "$_OLLAMA_SCRIPT"
    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  ⛔  ALERTE INTÉGRITÉ — INSTALLATION ANNULÉE             ║${NC}"
    echo -e "  ${RED}║                                                          ║${NC}"
    echo -e "  ${RED}║  Le script Ollama téléchargé ne correspond PAS           ║${NC}"
    echo -e "  ${RED}║  à la version officielle sur GitHub (MITM possible).     ║${NC}"
    echo -e "  ${RED}║                                                          ║${NC}"
    printf  "  ${RED}║  SHA256 local  : %-40s${RED}║${NC}
" "${_LOCAL_SHA:0:38}…"
    printf  "  ${RED}║  SHA256 GitHub : %-40s${RED}║${NC}
" "${_REMOTE_SHA:0:38}…"
    echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    return 1
  else
    ok "Intégrité vérifiée ✓  SHA256: ${_LOCAL_SHA:0:32}…"
  fi

  chmod 700 "$_OLLAMA_SCRIPT"
  step "Exécution du script Ollama (root)..."
  sh "$_OLLAMA_SCRIPT"; local _RC=$?
  rm -f "$_OLLAMA_SCRIPT"
  [ $_RC -eq 0 ] && ok "Ollama installé." || warn "Script Ollama erreur code $_RC"
  return $_RC
}

# ── Installation Docker selon la distro ──────────────────────────
install_docker_proper() {
  if command -v docker &>/dev/null; then
    log "Docker déjà installé."
    return 0
  fi

  case "$OS_FAMILY" in
    debian)
      # Méthode officielle Docker (plus à jour que docker.io du dépôt)
      info "Installation Docker via dépôt officiel..."
      pkg_install ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL --max-time 30 https://download.docker.com/linux/${OS_DISTRO}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
      chmod a+r /etc/apt/keyrings/docker.gpg
      local CODENAME="${OS_CODENAME}"
      # Remapper les dérivés vers leur base Ubuntu/Debian
      case "$OS_DISTRO" in
        pop)       CODENAME=$(lsb_release -c 2>/dev/null | cut -f2 || echo "jammy") ;;
        linuxmint) CODENAME=$(grep UBUNTU_CODENAME /etc/os-release | cut -d= -f2 || echo "jammy") ;;
        kali)      CODENAME="bookworm" ;;  # Kali est basé sur Debian Testing
      esac
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_DISTRO:-ubuntu} $CODENAME stable"         > /etc/apt/sources.list.d/docker.list 2>/dev/null ||       echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable"         > /etc/apt/sources.list.d/docker.list
      pkg_update
      DEBIAN_FRONTEND=noninteractive apt install -y         docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin         2>/dev/null || pkg_install docker.io docker-compose
      ;;

    rhel)
      info "Installation Docker via dépôt officiel RHEL/Fedora..."
      # Ajouter le dépôt Docker CE
      if command -v dnf &>/dev/null; then
        dnf config-manager --add-repo           https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null ||         dnf config-manager --add-repo           https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      else
        yum install -y docker
      fi
      ;;

    arch)
      info "Installation Docker sur Arch..."
      pacman -S --noconfirm --needed docker docker-compose
      ;;

    suse)
      info "Installation Docker sur openSUSE..."
      zypper install -y docker docker-compose
      ;;

    void)
      info "Installation Docker sur Void..."
      xbps-install -y docker docker-compose
      ;;

    alpine)
      info "Installation Docker sur Alpine..."
      apk add docker docker-compose
      ;;

    *)
      warn "Famille OS $OS_FAMILY inconnue — tentative générique..."
      pkg_install docker.io docker-compose || pkg_install docker docker-compose
      ;;
  esac

  svc_enable docker
  usermod -aG docker "$REAL_USER"
  log "Docker installé."
}

# ── Installation drivers NVIDIA selon la distro ──────────────────
install_nvidia_driver() {
  local DRIVER_PKG="${HW[gpu_driver_pkg]:-auto}"

  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    log "Driver NVIDIA déjà actif."
    return 0
  fi

  info "Installation driver NVIDIA ($DRIVER_PKG) sur $OS_DISTRO..."

  case "$NVIDIA_DRIVER_METHOD" in

    ubuntu-drivers)
      pkg_install ubuntu-drivers-common
      if [ "$DRIVER_PKG" = "auto" ]; then
        ubuntu-drivers autoinstall
      else
        pkg_install "$DRIVER_PKG" || ubuntu-drivers autoinstall
      fi
      # Blacklist nouveau
      echo -e "blacklist nouveau
options nouveau modeset=0"         > /etc/modprobe.d/blacklist-nouveau.conf
      update-initramfs -u 2>/dev/null || true
      ;;

    apt-nvidia)
      # Debian pur — pas d'ubuntu-drivers
      info "Debian : activation du dépôt non-free pour NVIDIA..."
      # Ajouter non-free si pas déjà présent
      sed -i 's/main$/main contrib non-free non-free-firmware/'         /etc/apt/sources.list 2>/dev/null || true
      pkg_update
      pkg_install nvidia-driver firmware-misc-nonfree
      echo -e "blacklist nouveau
options nouveau modeset=0"         > /etc/modprobe.d/blacklist-nouveau.conf
      update-initramfs -u 2>/dev/null || true
      ;;

    dnf-rpmfusion)
      info "RHEL/Fedora : installation NVIDIA via RPM Fusion..."
      local VER="${OS_VERSION%%.*}"
      # Ajouter RPM Fusion
      if command -v dnf &>/dev/null; then
        dnf install -y           "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${VER}.noarch.rpm"           "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${VER}.noarch.rpm"           2>/dev/null ||         dnf install -y           "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-${VER}.noarch.rpm"           "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-${VER}.noarch.rpm"           2>/dev/null || true
        dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda 2>/dev/null ||         dnf install -y xorg-x11-drv-nvidia 2>/dev/null || true
      else
        yum install -y kmod-nvidia || true
      fi
      # Blacklist nouveau
      echo -e "blacklist nouveau
options nouveau modeset=0"         > /etc/modprobe.d/blacklist-nouveau.conf
      dracut --force 2>/dev/null || true
      ;;

    pacman-nvidia)
      info "Arch : installation NVIDIA via pacman..."
      # Détecter si noyau standard ou LTS
      local KERNEL_PKG="nvidia"
      uname -r | grep -q "lts" && KERNEL_PKG="nvidia-lts"
      pacman -S --noconfirm --needed "$KERNEL_PKG" nvidia-utils nvidia-settings opencl-nvidia
      # Si GPU plus ancien (avant Maxwell)
      echo "${HW[gpu_model]:-}" | grep -qiE "GTX [0-9]{3}[^0-9]|GT [0-9]{3}" && \
        pacman -S --noconfirm --needed nvidia-390xx-dkms 2>/dev/null || true
      echo -e "blacklist nouveau
options nouveau modeset=0"         > /etc/modprobe.d/blacklist-nouveau.conf
      mkinitcpio -P 2>/dev/null || true
      ;;

    zypper-nvidia)
      info "openSUSE : installation NVIDIA via dépôt officiel..."
      local SUSE_CODENAME
      SUSE_CODENAME=$(grep -oP "(?<=VERSION_CODENAME=).*" /etc/os-release | tr -d '"' || echo "tumbleweed")
      zypper addrepo --refresh         "https://download.nvidia.com/opensuse/${SUSE_CODENAME}" NVIDIA 2>/dev/null || true
      zypper install -y nvidia-gfxG05-kmp-default nvidia-glG05 nvidia-computeG05 2>/dev/null ||       zypper install -y nvidia-gfxG06-kmp-default nvidia-glG06 2>/dev/null || true
      ;;

    xbps-nvidia)
      info "Void Linux : installation NVIDIA..."
      # Activer le dépôt nonfree
      xbps-install -y void-repo-nonfree 2>/dev/null || true
      xbps-install -S
      xbps-install -y nvidia 2>/dev/null || xbps-install -y nvidia390 2>/dev/null || true
      ;;

    apk-nvidia)
      warn "Alpine Linux : support NVIDIA limité — edge/testing requis."
      apk add --no-cache linux-headers nvidia-smi 2>/dev/null || true
      ;;

    *)
      warn "Méthode NVIDIA inconnue pour $OS_FAMILY — tentative générique..."
      pkg_install "$DRIVER_PKG" || warn "Installation driver échouée."
      ;;
  esac
}

# ── Installation ROCm AMD selon la distro ────────────────────────
install_rocm() {
  case "$OS_FAMILY" in
    debian)
      info "ROCm sur Debian/Ubuntu..."
      pkg_install wget gnupg ca-certificates
      # Mapper le codename Ubuntu pour ROCm
      local ROCM_CODENAME="${OS_CODENAME}"
      [ "$OS_DISTRO" = "pop" ] && ROCM_CODENAME=$(lsb_release -c 2>/dev/null | cut -f2)
      wget -qO - --timeout=30 https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg 2>/dev/null
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.1 ${ROCM_CODENAME} main"         > /etc/apt/sources.list.d/rocm.list
      pkg_update
      pkg_install rocm-hip-libraries rocm-opencl-runtime
      ;;
    rhel)
      info "ROCm sur RHEL/Fedora..."
      local VER="${OS_VERSION%%.*}"
      tee /etc/yum.repos.d/rocm.repo << EOF
[rocm]
name=ROCm
baseurl=https://repo.radeon.com/rocm/rhel${VER}/6.1/main
enabled=1
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
EOF
      pkg_install rocm-hip-runtime rocm-opencl-runtime
      ;;
    arch)
      info "ROCm sur Arch..."
      if [ -n "${AUR_HELPER:-}" ]; then
        sudo -u "$REAL_USER" "$AUR_HELPER" -S --noconfirm rocm-opencl-runtime rocm-hip 2>/dev/null ||           pacman -S --noconfirm --needed rocm-opencl-runtime 2>/dev/null || true
      else
        pacman -S --noconfirm --needed rocm-opencl-runtime 2>/dev/null ||           warn "AUR helper requis pour ROCm complet. Installe yay ou paru."
      fi
      ;;
    suse)
      info "ROCm sur openSUSE..."
      zypper addrepo https://repo.radeon.com/rocm/zyp/6.1/main ROCm 2>/dev/null || true
      zypper install -y rocm-hip-runtime 2>/dev/null || warn "ROCm partiel sur openSUSE."
      ;;
    *)
      warn "ROCm : installation manuelle requise pour $OS_FAMILY."
      warn "Voir : https://rocm.docs.amd.com/en/latest/deploy/linux/"
      ;;
  esac
  usermod -aG video,render "$REAL_USER" 2>/dev/null || true
}

# ── NVIDIA Container Toolkit selon la distro ─────────────────────
install_nvidia_container_toolkit() {
  if pkg_installed nvidia-container-toolkit; then
    log "NVIDIA Container Toolkit déjà installé."
    return 0
  fi

  # Détecter l'architecture une seule fois (avant le case)
  local _NVARCH
  _NVARCH=$(dpkg --print-architecture 2>/dev/null     || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/;s/armv7l/arm64/')

  case "$OS_FAMILY" in
    debian)
      step "Ajout de la clé GPG NVIDIA..."
      curl -fsSL --max-time 30 https://nvidia.github.io/libnvidia-container/gpgkey         | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

      step "Création du dépôt APT NVIDIA Container Toolkit (arch: $_NVARCH)..."
      # On construit le fichier .list directement — le fichier téléchargé de NVIDIA
      # contient $(ARCH) littéral que apt ne sait pas résoudre (cause erreur 100)
      cat > /etc/apt/sources.list.d/nvidia-container-toolkit.list << NVSRCEOF
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/${_NVARCH} /
#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/experimental/deb/${_NVARCH} /
NVSRCEOF
      pkg_update
      pkg_install nvidia-container-toolkit
      ;;
    rhel|suse)
      step "Ajout de la clé GPG NVIDIA (RPM)..."
      curl -fsSL --max-time 30 https://nvidia.github.io/libnvidia-container/gpgkey         | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      # Dépôt RPM (contient déjà l'arch dans son URL)
      curl -s -L --max-time 30         https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo         > /etc/yum.repos.d/nvidia-container-toolkit.repo 2>/dev/null || true
      pkg_update
      pkg_install nvidia-container-toolkit
      ;;
    arch)
      if [ -n "${AUR_HELPER:-}" ]; then
        sudo -u "$REAL_USER" "$AUR_HELPER" -S --noconfirm nvidia-container-toolkit 2>/dev/null           || warn "nvidia-container-toolkit AUR échoué."
      else
        warn "AUR helper requis pour nvidia-container-toolkit sur Arch."
      fi
      ;;
    *)
      warn "NVIDIA Container Toolkit : installation manuelle pour $OS_FAMILY."
      warn "Voir : https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
      ;;
  esac

  # Configurer le runtime Docker pour NVIDIA
  if command -v nvidia-ctk &>/dev/null; then
    nvidia-ctk runtime configure --runtime=docker 2>/dev/null && ok "Runtime NVIDIA configuré pour Docker." || warn "nvidia-ctk runtime configure échoué."
  fi
  svc_restart docker
  ok "NVIDIA Container Toolkit installé."
}

# ── Appeler detect_os() immédiatement ────────────────────────────
detect_os


# ── Répertoires & chemins ────────────────────────────────────────
STATE_DIR="/var/lib/ia-installer"
LOG_DIR="/var/log/ia-installer"
DASHBOARD_PORT="${DASHBOARD_PORT:-7842}"
DASHBOARD_SCRIPT="/usr/local/bin/ia-dashboard.py"
DASHBOARD_SERVICE="ia-dashboard"
# Admin intégré dans le dashboard (port 7842 — onglet Administration)
ADMIN_CREDS_FILE="/var/lib/ia-installer/admin-credentials"
CREDS_FILE="$ADMIN_CREDS_FILE"          # Alias utilisé dans les fonctions de backup
SCRIPT_PATH="$(realpath "$0")"

# ── Lien symbolique canonique dans /home/$REAL_USER/ ────────────────────
# Le dashboard web cherche le script à cet emplacement pour lancer l'install
_ensure_script_link() {
  [ -z "${REAL_HOME:-}" ] && return
  local TARGET="${REAL_HOME}/install_ia_local.sh"
  # Sauvegarder le chemin réel dans l'état
  mkdir -p /var/lib/ia-installer 2>/dev/null || true
  echo "$SCRIPT_PATH" > /var/lib/ia-installer/installer-path.txt 2>/dev/null || true
  # Si le script est déjà à la bonne place → rien à faire
  [ "$SCRIPT_PATH" = "$TARGET" ] && return
  # Si le lien/fichier cible existe déjà → mettre à jour le lien
  if [ -L "$TARGET" ] || [ -f "$TARGET" ]; then
    rm -f "$TARGET" 2>/dev/null || true
  fi
  # Créer le lien symbolique
  if ln -sf "$SCRIPT_PATH" "$TARGET" 2>/dev/null; then
    [ -n "${REAL_USER:-}" ] && chown "$REAL_USER" "$TARGET" 2>/dev/null || true
    echo "[IA Local] Lien symbolique créé : $TARGET → $SCRIPT_PATH"
  else
    echo "[IA Local] Impossible de créer le lien dans $REAL_HOME (permissions ?)"
  fi
}
_ensure_script_link
mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true   # Lisibles root uniquement

# ── Fichier de log ───────────────────────────────────────────────
LOG_DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/install-${LOG_DATE}.log"
# Créer le fichier de log avec permissions restreintes avant la redirection
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || true
LOG_LATEST="$LOG_DIR/install-latest.log"

# Redirection stdout+stderr vers log ET console
exec > >(tee -a "$LOG_FILE") 2>&1
ln -sf "$LOG_FILE" "$LOG_LATEST"

_log_header() {
  echo "================================================================"
  echo " INSTALLATEUR IA LOCAL v8.0"
  echo " Date    : $(date)"
  echo " User    : $REAL_USER (home: $REAL_HOME)"
  echo " OS      : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || lsb_release -d 2>/dev/null | cut -f2 || uname -o)"
  echo " Kernel  : $(uname -r)"
  echo " Log     : $LOG_FILE"
  echo "================================================================"
  echo ""
}
_log_header



confirm() {
  read -rp "$(echo -e "${YELLOW}  >>> $1 [oui/NON] : ${NC}")" R
  [[ "$R" =~ ^[Oo][Uu][Ii]$ ]]
}

title() {
  local LEN=${#1}
  local PAD=$(( (56 - LEN) / 2 ))
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
  printf  "${BLUE}║${NC}%*s${BOLD}%s${NC}%*s${BLUE}║${NC}\n" $PAD "" "$1" $PAD ""
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
}

box_line() { printf "${CYAN}  │${NC}  %-20s : ${BOLD}%-32s${NC}${CYAN}│${NC}\n" "$1" "$2"; }
box_sep()  { echo -e "${CYAN}  ├──────────────────────────────────────────────────────┤${NC}"; }
box_top()  { echo -e "${CYAN}  ┌──────────────────────────────────────────────────────┐${NC}"; }
box_bot()  { echo -e "${CYAN}  └──────────────────────────────────────────────────────┘${NC}"; }

# ================================================================
#  PANNEAU HUD — STATS SYSTÈME EN TEMPS RÉEL (coin haut-droit)
# ================================================================
#  Dessiné via codes ANSI de positionnement — zéro dépendance.
#  Tourne dans un sous-process background, rafraîchi toutes les 2s.
#  Compatible tous terminaux ≥ 80 colonnes.
# ================================================================

HUD_PID=""       # PID du sous-process HUD (vide = HUD arrêté)
HUD_WIDTH=34     # Largeur du panneau en colonnes
HUD_ROWS=18      # Hauteur réservée en haut pour le panneau

# Variables delta CPU/réseau partagées via fichier tmp (sous-process)
_HUD_STAT_FILE="/tmp/ia_installer_hud_$$.stat"

# ── Dessiner UNE ligne de contenu dans le panneau ───────────────
# _hud_line ROW LABEL VALUE [COULEUR_VALEUR]
_hud_line() {
  local ROW="$1" LABEL="$2" VAL="$3" VCOL="${4:-$CYAN}"
  local TCOLS; TCOLS=$(_term_cols)
  local COL=$(( TCOLS - HUD_WIDTH ))
  [ "$COL" -lt 1 ] && return
  local MAX=$(( HUD_WIDTH - 14 ))
  [ "${#VAL}" -gt "$MAX" ] && VAL="${VAL:0:$(( MAX - 1 ))}…"
  printf "\033[s\033[%d;%dH\033[K${BLUE}│${NC}${DIM} %-9s ${NC}${VCOL}%-*s${NC}${BLUE}│${NC}\033[u" \
    "$ROW" "$COL" "$LABEL" "$MAX" "$VAL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Dessiner UNE ligne de séparateur ────────────────────────────
_hud_sep() {
  local ROW="$1"
  local TCOLS; TCOLS=$(_term_cols)
  local COL=$(( TCOLS - HUD_WIDTH ))
  [ "$COL" -lt 1 ] && return
  local INNER=$(( HUD_WIDTH - 2 ))
  printf "\033[s\033[%d;%dH\033[K${BLUE}├$(printf '─%.0s' $(seq 1 $INNER))┤${NC}\033[u" "$ROW" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Dessiner le cadre complet ────────────────────────────────────
_hud_frame() {
  local TCOLS; TCOLS=$(_term_cols)
  local COL=$(( TCOLS - HUD_WIDTH ))
  [ "$COL" -lt 1 ] && return
  local INNER=$(( HUD_WIDTH - 2 ))
  local W=$HUD_WIDTH

  # Top border
  printf "\033[s\033[1;%dH\033[K${BLUE}┌$(printf '─%.0s' $(seq 1 $INNER))┐${NC}\033[u" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  # Titre
  local T="  📊 STATS SYSTÈME  "
  local TLEN=${#T}
  local PAD=$(( (INNER - TLEN) / 2 ))
  local RPAD=$(( INNER - TLEN - PAD ))
  printf "\033[s\033[2;%dH\033[K${BLUE}│${NC}${BOLD}$(printf '%*s' $PAD '')${CYAN}%s${NC}$(printf '%*s' $RPAD '')${BLUE}│${NC}\033[u" \
    "$COL" "$T" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  # Séparateur sous titre
  printf "\033[s\033[3;%dH\033[K${BLUE}├$(printf '─%.0s' $(seq 1 $INNER))┤${NC}\033[u" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  # Bottom border (ligne HUD_ROWS)
  printf "\033[s\033[%d;%dH\033[K${BLUE}└$(printf '─%.0s' $(seq 1 $INNER))┘${NC}\033[u" \
    "$HUD_ROWS" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Lecture et affichage de toutes les stats ─────────────────────
_hud_update() {
  # ── CPU (delta depuis dernière lecture) ─────────────────────
  local CPU_IDLE CPU_TOTAL CPU_PCT=0
  local CPU_LINE; CPU_LINE=$(grep -E '^cpu ' /proc/stat 2>/dev/null | head -1)
  local _u _n _s _id _io _ir _si _st
  read -r _ _u _n _s _id _io _ir _si _st _ <<< "$CPU_LINE"
  CPU_TOTAL=$(( _u+_n+_s+_id+_io+_ir+_si+${_st:-0} ))
  CPU_IDLE=$_id

  if [ -f "$_HUD_STAT_FILE" ]; then
    local PT PI; read -r PT PI < "$_HUD_STAT_FILE" 2>/dev/null || { PT=0; PI=0; }
    local DT=$(( CPU_TOTAL - PT )); local DI=$(( CPU_IDLE - PI ))
    [ "$DT" -gt 0 ] && CPU_PCT=$(( (DT - DI) * 100 / DT ))
  fi
  echo "$CPU_TOTAL $CPU_IDLE" > "$_HUD_STAT_FILE"

  local CPU_COL="$GREEN"
  [ "$CPU_PCT" -ge 60 ] && CPU_COL="$YELLOW"
  [ "$CPU_PCT" -ge 85 ] && CPU_COL="$RED"

  # Fréquence
  local CPU_FREQ="?"
  CPU_FREQ=$(awk '{printf "%.1f GHz", $1/1000000}' \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) || \
  CPU_FREQ=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | \
    awk '{printf "%.0f MHz", $4}') || CPU_FREQ="?"

  # Température CPU
  local CPU_TEMP="N/A"
  for _F in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$_F" ] || continue
    local _T; _T=$(cat "$_F" 2>/dev/null) || continue
    [ "$_T" -gt 1000 ] 2>/dev/null && {
      CPU_TEMP="$(( _T / 1000 ))°C"; break; }
  done

  local TEMP_COL="$GREEN"
  local _TN; _TN=$(echo "$CPU_TEMP" | grep -oP '^\d+' || echo 0)
  [ "${_TN:-0}" -ge 70 ] && TEMP_COL="$YELLOW"
  [ "${_TN:-0}" -ge 85 ] && TEMP_COL="$RED"

  # ── RAM ────────────────────────────────────────────────────
  local MEM_TOTAL MEM_AVAIL MEM_USED MEM_PCT
  MEM_TOTAL=$(grep MemTotal     /proc/meminfo | awk '{print $2}')
  MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  MEM_USED=$(( (MEM_TOTAL - MEM_AVAIL) / 1024 ))
  local MEM_TOT_MB=$(( MEM_TOTAL / 1024 ))
  MEM_PCT=$(( MEM_USED * 100 / (MEM_TOT_MB > 0 ? MEM_TOT_MB : 1) ))
  local RAM_COL="$GREEN"
  [ "$MEM_PCT" -ge 70 ] && RAM_COL="$YELLOW"
  [ "$MEM_PCT" -ge 90 ] && RAM_COL="$RED"

  # Swap
  local SWAP_TOT SWAP_FREE SWAP_USED SWAP_MB
  SWAP_TOT=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  SWAP_FREE=$(grep SwapFree  /proc/meminfo | awk '{print $2}')
  SWAP_USED=$(( (SWAP_TOT - SWAP_FREE) / 1024 ))
  SWAP_MB=$(( SWAP_TOT / 1024 ))

  # ── GPU ────────────────────────────────────────────────────
  local GPU_UTIL="N/A" GPU_TEMP="N/A" GPU_MEM="N/A" GPU_COL="$DIM"
  if command -v nvidia-smi &>/dev/null; then
    local _GLINE
    _GLINE=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total \
      --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$_GLINE" ]; then
      local _GU _GT _GMU _GMT
      IFS=', ' read -r _GU _GT _GMU _GMT <<< "$_GLINE"
      GPU_UTIL="${_GU}%"
      GPU_TEMP="${_GT}°C"
      GPU_MEM="${_GMU}/${_GMT} Mo"
      GPU_COL="$GREEN"
      [ "${_GU:-0}" -ge 70 ] && GPU_COL="$YELLOW"
      [ "${_GU:-0}" -ge 90 ] && GPU_COL="$RED"
    fi
  elif command -v rocm-smi &>/dev/null; then
    GPU_UTIL="$(rocm-smi --showuse 2>/dev/null | grep -oP '\d+(?=%)' | head -1 || echo '?')%"
    GPU_COL="$CYAN"; GPU_MEM="ROCm"
  fi

  # ── Disques ───────────────────────────────────────────────
  local DISK_IA_STAT="N/A" DISK_IA_PCT=0 DISK_IA_COL="$GREEN"
  local DISK_ROOT_STAT="N/A"
  local _MOUNT="${CFG[hdd_mount]:-}"

  if [ -n "$_MOUNT" ] && mountpoint -q "$_MOUNT" 2>/dev/null; then
    local _DF; _DF=$(df -BG "$_MOUNT" 2>/dev/null | awk 'NR==2{print $3, $4, $5}')
    local _DU _DF2 _DPCT
    read -r _DU _DF2 _DPCT <<< "$_DF"
    DISK_IA_STAT="${_DU} us / ${_DF2} libre"
    DISK_IA_PCT=${_DPCT//%/}
    [ "${DISK_IA_PCT:-0}" -ge 80 ] && DISK_IA_COL="$YELLOW"
    [ "${DISK_IA_PCT:-0}" -ge 95 ] && DISK_IA_COL="$RED"
  fi

  local _RDF; _RDF=$(df -BG / 2>/dev/null | awk 'NR==2{print $3, $4}')
  local _RU _RF; read -r _RU _RF <<< "$_RDF"
  DISK_ROOT_STAT="${_RU} us / ${_RF} libre"

  # ── Réseau ────────────────────────────────────────────────
  local NET_RX="N/A" NET_TX="N/A"
  local _NETDEV; _NETDEV=$(ip route 2>/dev/null | awk '/^default/{print $5;exit}')
  if [ -n "$_NETDEV" ]; then
    local _RX _TX
    _RX=$(cat "/sys/class/net/${_NETDEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    _TX=$(cat "/sys/class/net/${_NETDEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
    local _NETF="/tmp/ia_hud_net_$$.stat"
    if [ -f "$_NETF" ]; then
      local _PRX _PTX; read -r _PRX _PTX < "$_NETF" 2>/dev/null || { _PRX=0; _PTX=0; }
      local DRX=$(( (_RX - _PRX) / 1024 / 2 ))   # /2 car rafraîchi toutes les 2s
      local DTX=$(( (_TX - _PTX) / 1024 / 2 ))
      [ "$DRX" -gt 1024 ] && NET_RX="↓$(( DRX/1024 ))M/s" || NET_RX="↓${DRX}K/s"
      [ "$DTX" -gt 1024 ] && NET_TX="↑$(( DTX/1024 ))M/s" || NET_TX="↑${DTX}K/s"
    else
      NET_RX="↓---" NET_TX="↑---"
    fi
    echo "$_RX $_TX" > "$_NETF"
  fi

  # ── Services (URLs avec ports) ────────────────────────────
  local WEBUI_PORT="${CFG[webui_port]:-8080}"
  local OLLAMA_PORT="11434"
  local WEBUI_URL="http://localhost:${WEBUI_PORT}"
  local OLLAMA_URL="http://localhost:${OLLAMA_PORT}"

  local WEBUI_STATUS WEBUI_COL OLLAMA_STATUS OLLAMA_COL

  # Vérifier Open WebUI
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    WEBUI_STATUS="✓ :${WEBUI_PORT} actif"
    WEBUI_COL="$GREEN"
  else
    WEBUI_STATUS="✗ :${WEBUI_PORT} arrêté"
    WEBUI_COL="$RED"
  fi

  # Vérifier API Ollama
  if curl -sf --max-time 1 "${OLLAMA_URL}/api/tags" &>/dev/null; then
    # Compter les modèles chargés
    local _NM
    _NM=$(curl -sf --max-time 2 "${OLLAMA_URL}/api/tags" 2>/dev/null \
      | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(len(d.get('models',[])))
except: print('?')" \
      2>/dev/null || echo "?")
    OLLAMA_STATUS="✓ :${OLLAMA_PORT} (${_NM} mod.)"
    OLLAMA_COL="$GREEN"
  else
    OLLAMA_STATUS="✗ :${OLLAMA_PORT} N/A"
    OLLAMA_COL="$RED"
  fi

  # ── Horloge & uptime ─────────────────────────────────────
  local NOW; NOW=$(date +"%H:%M:%S")
  local UPTIME_STR
  UPTIME_STR=$(awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if(d>0) printf "%dd %dh%dm",d,h,m; else printf "%dh %dm",h,m}' /proc/uptime 2>/dev/null)

  # ── Dessiner le panneau complet ───────────────────────────
  _hud_frame

  local R=4
  _hud_line $R "CPU"    "${CPU_PCT}%  ${CPU_FREQ}"       "$CPU_COL";  R=$(( R+1 ))
  _hud_line $R "Temp."  "$CPU_TEMP"                       "$TEMP_COL"; R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "RAM"    "${MEM_USED}/${MEM_TOT_MB} MB ${MEM_PCT}%" "$RAM_COL"; R=$(( R+1 ))
  _hud_line $R "Swap"   "${SWAP_USED}/${SWAP_MB} MB"     "$DIM";      R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "GPU"    "$GPU_UTIL  $GPU_TEMP"            "$GPU_COL";  R=$(( R+1 ))
  _hud_line $R "VRAM"   "$GPU_MEM"                        "$GPU_COL";  R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "WebUI"  "$WEBUI_STATUS"                   "$WEBUI_COL";  R=$(( R+1 ))
  _hud_line $R "Ollama" "$OLLAMA_STATUS"                  "$OLLAMA_COL"; R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "Disque" "$DISK_IA_STAT"                   "$DISK_IA_COL"; R=$(( R+1 ))
  _hud_line $R "Root"   "$DISK_ROOT_STAT"                 "$GREEN";    R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "Réseau" "${NET_RX}  ${NET_TX}"            "$CYAN";     R=$(( R+1 ))
  _hud_line $R "Uptime" "${UPTIME_STR}  ${NOW}"           "$DIM"
}

# ── Détection du VRAI terminal — robuste sous sudo, SSH, pipe ────
#
# Problème : sous "sudo ./script.sh", /dev/tty pointe sur le pseudo-
# terminal de sudo et non celui de l'utilisateur. stty, dd, et les
# séquences ANSI échouent ou ne fonctionnent pas correctement.
#
# Solution : détecter le vrai TTY en cascade et le stocker dans
# _REAL_TTY — variable utilisée partout à la place de /dev/tty.
# ─────────────────────────────────────────────────────────────────
_REAL_TTY=""

_detect_real_tty() {
  local _TTY=""

  # 1. sudo positionne $SUDO_TTY avec le tty de l'utilisateur appelant
  if [ -n "${SUDO_TTY:-}" ] && [ -w "$SUDO_TTY" ]; then
    _TTY="$SUDO_TTY"

  # 2. /proc/PID/fd/0 du shell parent (fonctionne en bash sous sudo)
  elif [ -r "/proc/${PPID}/fd/0" ]; then
    local _P; _P=$(readlink -f "/proc/${PPID}/fd/0" 2>/dev/null)
    [ -w "${_P:-}" ] && _TTY="$_P"

  # 3. $(tty) du process courant (valide si stdin n'est pas redirigé)
  elif _T=$(tty 2>/dev/null) && [ -w "$_T" ] && [[ "$_T" != "not a tty" ]]; then
    _TTY="$_T"

  # 4. /dev/tty — fallback POSIX standard
  elif [ -w "/dev/tty" ]; then
    _TTY="/dev/tty"
  fi

  _REAL_TTY="${_TTY:-}"
  export _REAL_TTY
}

# Appeler immédiatement à la définition
_detect_real_tty

# Vrai si un terminal interactif est disponible
_term_is_interactive() {
  [ -n "$_REAL_TTY" ] && [ -w "$_REAL_TTY" ] && return 0
  [ -t 1 ] && return 0
  return 1
}

# Nombre de colonnes du terminal
_term_cols() {
  local C
  if [ -n "$_REAL_TTY" ]; then
    C=$(stty size < "$_REAL_TTY" 2>/dev/null | awk '{print $2}')
    [ "${C:-0}" -gt 0 ] && echo "$C" && return
    C=$(tput cols 2>/dev/null)
    [ "${C:-0}" -gt 0 ] && echo "$C" && return
  fi
  [ -n "${COLUMNS:-}" ] && echo "$COLUMNS" && return
  echo 80
}

# Nombre de lignes du terminal
_term_rows() {
  local R
  if [ -n "$_REAL_TTY" ]; then
    R=$(stty size < "$_REAL_TTY" 2>/dev/null | awk '{print $1}')
    [ "${R:-0}" -gt 0 ] && echo "$R" && return
    R=$(tput lines 2>/dev/null)
    [ "${R:-0}" -gt 0 ] && echo "$R" && return
  fi
  [ -n "${LINES:-}" ] && echo "$LINES" && return
  echo 24
}

# Écrire une séquence ANSI sur le vrai terminal
_tty_write() { printf "%s" "$*" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true; }

# Lire depuis le vrai terminal (non-bloquant grâce au stty préalable)
_tty_read1() { dd bs=1 count=1 < "${_REAL_TTY:-/dev/tty}" 2>/dev/null; }

# ── Démarrer le HUD en arrière-plan ─────────────────────────────
hud_start() {
  # Le HUD ANSI nécessite un terminal qui supporte le positionnement
  _term_is_interactive || return 0
  local TCOLS; TCOLS=$(_term_cols)
  [ "$TCOLS" -lt 90 ] && return 0  # Terminal trop étroit pour le panneau

  # Réserver les lignes du haut : le texte scrollera en dessous
  local TROWS; TROWS=$(_term_rows)
  { tput csr $((HUD_ROWS + 1)) $(( TROWS - 1 )) 2>/dev/null     || printf "\033[%d;%dr" $((HUD_ROWS + 1)) $(( TROWS - 1 )); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
  { tput cup $((HUD_ROWS + 1)) 0 2>/dev/null     || printf "\033[%d;0H" $((HUD_ROWS + 1)); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  (
    sleep 1
    while true; do
      _hud_update 2>/dev/null || true
      sleep 2
    done
  ) &
  HUD_PID=$!
  export HUD_PID
}

# ── Arrêter le HUD et restaurer le terminal ──────────────────────
hud_stop() {
  [ -z "${HUD_PID:-}" ] && return 0
  kill "$HUD_PID" 2>/dev/null || true
  wait "$HUD_PID" 2>/dev/null || true
  HUD_PID=""
  rm -f "$_HUD_STAT_FILE" "/tmp/ia_hud_net_$$.stat" 2>/dev/null || true

  _term_is_interactive || return 0
  local TROWS; TROWS=$(_term_rows)
  local TCOLS; TCOLS=$(_term_cols)
  # Restaurer scroll region complète
  { tput csr 0 $(( TROWS - 1 )) 2>/dev/null     || printf "\033[0;%dr" $(( TROWS - 1 )); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
  # Effacer le panneau colonne par colonne
  local COL=$(( TCOLS - HUD_WIDTH ))
  local R
  for R in $(seq 1 $(( HUD_ROWS + 1 ))); do
    printf "\033[s\033[%d;%dH\033[K%*s\033[u" "$R" "$COL" "$(( HUD_WIDTH + 1 ))" "" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
  done
  { tput cup $(( HUD_ROWS + 2 )) 0 2>/dev/null     || printf "\033[%d;0H" $(( HUD_ROWS + 2 )); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Vue stats : contenu commun (texte pur, sans ANSI position) ──
_stats_draw_content() {
  local TCOLS="${1:-80}"

  # ── Header ──────────────────────────────────────────────────
  local TITLE="  ✦  STATS SYSTÈME EN TEMPS RÉEL  ✦  "
  printf "${BOLD}${CYAN}%-*s${NC}\n" "$TCOLS" "$TITLE"
  printf "${BLUE}"; printf '─%.0s' $(seq 1 "$TCOLS"); printf "${NC}\n"
  echo ""

  # ── CPU ────────────────────────────────────────────────────
  local CPU_LINE; CPU_LINE=$(grep -E '^cpu ' /proc/stat 2>/dev/null | head -1)
  local _u _n _s _id _io _ir _si _st
  read -r _ _u _n _s _id _io _ir _si _st _ <<< "$CPU_LINE"
  local CPU_TOTAL=$(( _u+_n+_s+_id+_io+_ir+_si+${_st:-0} ))
  local CPU_IDLE=$_id
  local CPU_PCT=0
  if [ -f "$_HUD_STAT_FILE" ]; then
    local PT PI; read -r PT PI < "$_HUD_STAT_FILE" 2>/dev/null || { PT=0; PI=0; }
    local DT=$(( CPU_TOTAL - PT )); local DI=$(( CPU_IDLE - PI ))
    [ "$DT" -gt 0 ] && CPU_PCT=$(( (DT - DI) * 100 / DT ))
  fi
  echo "$CPU_TOTAL $CPU_IDLE" > "$_HUD_STAT_FILE"

  local CPU_FREQ
  CPU_FREQ=$(awk '{printf "%.2f GHz", $1/1000000}' \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) || \
  CPU_FREQ=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{printf "%.0f MHz",$4}') || \
  CPU_FREQ="?"
  local CPU_TEMP="N/A"
  for _F in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$_F" ] && { local _T; _T=$(cat "$_F" 2>/dev/null)
      [ "${_T:-0}" -gt 1000 ] && { CPU_TEMP="$(( _T/1000 ))°C"; break; }; }
  done

  local CPU_COL="$GREEN"
  [ "$CPU_PCT" -ge 60 ] && CPU_COL="$YELLOW"
  [ "$CPU_PCT" -ge 85 ] && CPU_COL="$RED"
  local CFILL=$(( CPU_PCT * 40 / 100 )); local CEMPTY=$(( 40 - CFILL ))
  local CBAR="${CPU_COL}"; for i in $(seq 1 $CFILL); do CBAR+="█"; done
  CBAR+="${DIM}"; for i in $(seq 1 $CEMPTY); do CBAR+="░"; done; CBAR+="${NC}"
  printf "  ${BOLD}CPU${NC}    [%b] ${CPU_COL}%3d%%${NC}   Fréq: %s   Temp: %s\n" \
    "$CBAR" "$CPU_PCT" "${CPU_FREQ:-?}" "$CPU_TEMP"

  # CPU par cœur
  local CORES_DISPLAY=""
  while IFS= read -r CORE_LINE; do
    local _CID _CU _CN _CS _CID2 _CIO _CIR _CSI
    read -r _CID _CU _CN _CS _CID2 _CIO _CIR _CSI _ <<< "$CORE_LINE"
    local CT=$(( _CU+_CN+_CS+_CID2+_CIO+_CIR+_CSI ))
    local CP=0; [ "$CT" -gt 0 ] && CP=$(( (_CU+_CN+_CS) * 100 / CT ))
    local CC="$GREEN"; [ "$CP" -ge 60 ] && CC="$YELLOW"; [ "$CP" -ge 85 ] && CC="$RED"
    CORES_DISPLAY+="  ${DIM}${_CID#cpu}${NC}:${CC}${CP}%${NC}"
  done < <(grep -E '^cpu[0-9]+' /proc/stat 2>/dev/null | head -16)
  echo -e "  ${DIM}Cœurs :${NC}$CORES_DISPLAY"
  echo ""

  # ── RAM & SWAP ──────────────────────────────────────────────
  local MEM_TOTAL MEM_AVAIL MEM_USED MEM_TOT_MB MEM_PCT
  MEM_TOTAL=$(grep MemTotal     /proc/meminfo | awk '{print $2}')
  MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  MEM_USED=$(( (MEM_TOTAL - MEM_AVAIL) / 1024 ))
  MEM_TOT_MB=$(( MEM_TOTAL / 1024 ))
  MEM_PCT=$(( MEM_USED * 100 / (MEM_TOT_MB > 0 ? MEM_TOT_MB : 1) ))
  local SWAP_TOT SWAP_FREE SWAP_USED SWAP_MB SWAP_PCT=0
  SWAP_TOT=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  SWAP_FREE=$(grep SwapFree  /proc/meminfo | awk '{print $2}')
  SWAP_USED=$(( (SWAP_TOT - SWAP_FREE) / 1024 ))
  SWAP_MB=$(( SWAP_TOT / 1024 ))
  [ "$SWAP_MB" -gt 0 ] && SWAP_PCT=$(( SWAP_USED * 100 / SWAP_MB ))

  local RAM_COL="$GREEN"
  [ "$MEM_PCT" -ge 70 ] && RAM_COL="$YELLOW"; [ "$MEM_PCT" -ge 90 ] && RAM_COL="$RED"
  local RFILL=$(( MEM_PCT * 40 / 100 )); local REMPTY=$(( 40 - RFILL ))
  local RBAR="${RAM_COL}"; for i in $(seq 1 $RFILL); do RBAR+="█"; done
  RBAR+="${DIM}"; for i in $(seq 1 $REMPTY); do RBAR+="░"; done; RBAR+="${NC}"
  printf "  ${BOLD}RAM${NC}    [%b] ${RAM_COL}%3d%%${NC}   %d/%d Mo\n" "$RBAR" "$MEM_PCT" "$MEM_USED" "$MEM_TOT_MB"

  local SFILL=$(( SWAP_PCT * 40 / 100 )); local SEMPTY=$(( 40 - SFILL ))
  local SBAR="${DIM}"; for i in $(seq 1 $SFILL); do SBAR+="█"; done
  SBAR+="${DIM}"; for i in $(seq 1 $SEMPTY); do SBAR+="░"; done; SBAR+="${NC}"
  printf "  ${BOLD}Swap${NC}   [%b] ${DIM}%3d%%${NC}   %d/%d Mo\n" "$SBAR" "$SWAP_PCT" "$SWAP_USED" "$SWAP_MB"
  echo ""

  # ── GPU ────────────────────────────────────────────────────
  printf "  ${BOLD}GPU${NC}\n"
  if command -v nvidia-smi &>/dev/null; then
    local _GLINE
    _GLINE=$(nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw \
      --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$_GLINE" ]; then
      local _GN _GU _GT _GMU _GMT _GPW
      IFS=', ' read -r _GN _GU _GT _GMU _GMT _GPW <<< "$_GLINE"
      local GC="$GREEN"
      [ "${_GU:-0}" -ge 70 ] && GC="$YELLOW"; [ "${_GU:-0}" -ge 90 ] && GC="$RED"
      local GFILL=$(( ${_GU:-0} * 40 / 100 )); local GEMPTY=$(( 40 - GFILL ))
      local GBAR="${GC}"; for i in $(seq 1 $GFILL); do GBAR+="█"; done
      GBAR+="${DIM}"; for i in $(seq 1 $GEMPTY); do GBAR+="░"; done; GBAR+="${NC}"
      printf "  ${DIM}%-30s${NC}\n" "${_GN:-NVIDIA}"
      printf "  Utilisation  [%b] ${GC}%3d%%${NC}\n" "$GBAR" "${_GU:-0}"
      printf "  VRAM         ${MAGENTA}%s / %s Mo${NC}   Temp: %s°C   Puissance: %s W\n" \
        "${_GMU:-?}" "${_GMT:-?}" "${_GT:-?}" "${_GPW:-?}"
    else
      echo "  ${DIM}GPU NVIDIA détecté mais nvidia-smi ne répond pas.${NC}"
    fi
  elif command -v rocm-smi &>/dev/null; then
    echo "  ${CYAN}AMD GPU (ROCm)${NC}"
    rocm-smi --showuse --showtemp 2>/dev/null | grep -v '^$' | head -5 | sed 's/^/  /'
  else
    echo "  ${DIM}Aucun GPU dédié détecté (CPU-only mode)${NC}"
  fi
  echo ""

  # ── SERVICES ───────────────────────────────────────────────
  local WEBUI_PORT="${CFG[webui_port]:-8080}"
  local OLLAMA_HOST="${CFG[ollama_host]:-0.0.0.0}"
  local WEBUI_URL="http://localhost:${WEBUI_PORT}"
  local OLLAMA_URL="http://${OLLAMA_HOST}:11434"
  [ "$OLLAMA_HOST" = "0.0.0.0" ] && OLLAMA_URL="http://localhost:11434"

  printf "  ${BOLD}SERVICES${NC}\n"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    printf "  ${GREEN}✓${NC}  Open WebUI    ${GREEN}actif${NC}  →  ${CYAN}%s${NC}\n" "$WEBUI_URL"
  else
    printf "  ${RED}✗${NC}  Open WebUI    ${RED}arrêté${NC}  →  ${DIM}%s${NC}\n" "$WEBUI_URL"
  fi
  if curl -sf --max-time 1 "http://127.0.0.1:11434/api/tags" &>/dev/null; then
    local _NM
    _NM=$(curl -sf --max-time 2 "http://127.0.0.1:11434/api/tags" 2>/dev/null \
      | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); print(len(d.get('models',[])))\nexcept: print(chr(63))" 2>/dev/null || echo "?")
    printf "  ${GREEN}✓${NC}  Ollama API    ${GREEN}actif${NC}   →  ${CYAN}%s${NC}  ${DIM}(%s modèles)${NC}\n" \
      "$OLLAMA_URL" "$_NM"
    # Afficher aussi l'URL LAN si écoute externe
    if [ "${CFG[ollama_host]:-}" = "0.0.0.0" ]; then
      local _LIP; _LIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' \
        || hostname -I 2>/dev/null | awk '{print $1}')
      printf "  ${DIM}   ↳ réseau LAN  →  ${CYAN}http://%s:11434${NC}\n" "${_LIP:-<IP>}"
    fi
  else
    printf "  ${RED}✗${NC}  Ollama API    ${RED}N/A${NC}     →  ${DIM}%s${NC}\n" "$OLLAMA_URL"
  fi
  if docker info &>/dev/null 2>&1; then
    local _NC; _NC=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    printf "  ${GREEN}✓${NC}  Docker        ${GREEN}actif${NC}   →  ${DIM}%s container(s)${NC}\n" "$_NC"
  else
    printf "  ${RED}✗${NC}  Docker        ${RED}arrêté${NC}\n"
  fi
  echo ""

  # ── DISQUES ────────────────────────────────────────────────
  printf "  ${BOLD}DISQUES${NC}\n"
  df -h 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|udev|/dev/loop|Filesystem)' | while IFS= read -r _DL; do
    local _FS _SZ _US _AV _PC _MT
    read -r _FS _SZ _US _AV _PC _MT <<< "$_DL"
    local _P=${_PC//%/}
    local _DC="$GREEN"
    [ "${_P:-0}" -ge 80 ] && _DC="$YELLOW"; [ "${_P:-0}" -ge 95 ] && _DC="$RED"
    local _DFILL=$(( ${_P:-0} * 20 / 100 )); local _DEMPTY=$(( 20 - _DFILL ))
    local _DBAR="${_DC}"; for i in $(seq 1 $_DFILL); do _DBAR+="█"; done
    _DBAR+="${DIM}"; for i in $(seq 1 $_DEMPTY); do _DBAR+="░"; done; _DBAR+="${NC}"
    printf "  [%b] ${_DC}%4s${NC}  %-20s  %s us / %s lib  %s\n" \
      "$_DBAR" "$_PC" "${_FS:0:20}" "$_US" "$_AV" "$_MT"
  done
  echo ""

  # ── RÉSEAU ────────────────────────────────────────────────
  local _NETDEV; _NETDEV=$(ip route 2>/dev/null | awk '/^default/{print $5;exit}')
  if [ -n "$_NETDEV" ]; then
    local _IP; _IP=$(ip -4 addr show "$_NETDEV" 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)
    printf "  ${BOLD}RÉSEAU${NC}  ${DIM}%s${NC}  IP: ${CYAN}%s${NC}\n" "$_NETDEV" "${_IP:-?}"
    local _NETF="/tmp/ia_hud_net_$$.stat"
    local _RX _TX
    _RX=$(cat "/sys/class/net/${_NETDEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    _TX=$(cat "/sys/class/net/${_NETDEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
    if [ -f "$_NETF" ]; then
      local _PRX _PTX; read -r _PRX _PTX < "$_NETF" 2>/dev/null || { _PRX=0; _PTX=0; }
      local DRX=$(( (_RX - _PRX) / 1024 / 2 )) DTX=$(( (_TX - _PTX) / 1024 / 2 ))
      local RXS TXS
      [ "$DRX" -gt 1024 ] && RXS="$(( DRX/1024 )) Mo/s" || RXS="${DRX} Ko/s"
      [ "$DTX" -gt 1024 ] && TXS="$(( DTX/1024 )) Mo/s" || TXS="${DTX} Ko/s"
      printf "  ↓ Réception : ${CYAN}%-12s${NC}   ↑ Émission : ${DIM}%-12s${NC}\n" "$RXS" "$TXS"
    fi
    echo "$_RX $_TX" > "$_NETF"
  fi
  echo ""

  # ── Footer ──────────────────────────────────────────────────
  local _UPTIME
  _UPTIME=$(awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if(d>0) printf "%d jour(s) %dh%02dm",d,h,m; else printf "%dh %02dm",h,m}' /proc/uptime 2>/dev/null)
  printf "${BLUE}"; printf '─%.0s' $(seq 1 "$TCOLS"); printf "${NC}\n"
  printf "  Uptime : ${DIM}%s${NC}   Heure : ${BOLD}%s${NC}" \
    "$_UPTIME" "$(date +"%H:%M:%S")"
}

# ── Vue plein écran des stats (menu_stats_live) ──────────────────
# Fonctionne en mode interactif (ANSI, rafraîchissement en place)
# ET en mode non-interactif (SSH sans TTY, pipe, nohup) — sortie texte simple.
menu_stats_live() {
  declare -gA CFG=(); source "$CONFIG_FILE" 2>/dev/null || true

  local TCOLS; TCOLS=$(_term_cols)
  local TROWS; TROWS=$(_term_rows)

  if _term_is_interactive; then
    # ────────────────────────────────────────────────────────
    # MODE INTERACTIF : plein écran avec rafraîchissement ANSI
    # ────────────────────────────────────────────────────────

    # Flag de sortie partagé entre la boucle et le trap
    local _STATS_EXIT=0   # 0=continuer  1=retour menu  2=quitter script

    # Restauration propre du terminal (appelée par trap ET sortie normale)
    local _STTY_SAVE=""
    _STTY_SAVE=$(stty -g < "${_REAL_TTY:-/dev/tty}" 2>/dev/null) || true

    _stats_restore_term() {
      _tty_write "\033[?25h"          # Rendre le curseur visible
      _tty_write "\033[r"             # Restaurer scroll region
      _tty_write "\033[999;1H"        # Curseur en bas
      if [ -n "$_STTY_SAVE" ]; then
        stty "$_STTY_SAVE" < "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
      else
        stty sane < "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
      fi
    }

    # Ctrl+C : sortir proprement de la boucle → retour menu
    trap '_STATS_EXIT=1' INT

    # Masquer curseur + vider écran
    _tty_write "\033[?25l"
    clear

    local _REFRESH=3    # secondes entre deux rafraîchissements auto
    local _ELAPSED=0

    while [ "$_STATS_EXIT" -eq 0 ]; do

      # Redessiner depuis le haut sans effacer (évite le flash)
      _tty_write "\033[1;1H"
      TCOLS=$(_term_cols)
      _stats_draw_content "$TCOLS" 2>/dev/null

      # Barre de commandes
      printf "\n"
      printf "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
      printf "  ${BOLD}[Entrée]${NC} Menu   ${BOLD}[r]${NC} Rafraîchir   ${BOLD}[q]${NC} Quitter   ${DIM}↻ %ds${NC}   \n" \
        $(( _REFRESH - _ELAPSED ))

      # ── Lecture d'une touche avec timeout 1s ──────────────────
      # read -t fonctionne nativement en bash sans manipulation stty
      # Retourne 1 si timeout (aucune touche), 0 si touche lue
      local KEY=""
      if [ -n "$_REAL_TTY" ]; then
        IFS= read -r -s -n1 -t1 KEY < "$_REAL_TTY" 2>/dev/null || true
      else
        IFS= read -r -s -n1 -t1 KEY 2>/dev/null || true
      fi

      # Incrémenter compteur de temps écoulé
      _ELAPSED=$(( _ELAPSED + 1 ))
      [ "$_ELAPSED" -ge "$_REFRESH" ] && _ELAPSED=0

      # Traiter la touche
      case "$KEY" in
        q|Q)
          _STATS_EXIT=2
          ;;
        $'\n'|$'\r')
          # Entrée → retour menu
          _STATS_EXIT=1
          ;;
        r|R)
          # Rafraîchir immédiatement
          _ELAPSED=0
          ;;
        # Toute autre touche ou timeout → reboucler
      esac

    done

    # ── Nettoyage ─────────────────────────────────────────────
    trap - INT
    _stats_restore_term
    rm -f "$_HUD_STAT_FILE" "/tmp/ia_hud_net_$$.stat" 2>/dev/null || true
    clear

    # Action selon la raison de sortie
    if [ "$_STATS_EXIT" -eq 2 ]; then
      echo -e "${CYAN}Au revoir !${NC}"
      exit 0
    fi
    # _STATS_EXIT=1 → return 0 → retour au menu (ci-dessous)

  else
    # ────────────────────────────────────────────────────────
    # MODE NON-INTERACTIF : sortie texte une seule fois
    # Parfait pour SSH sans TTY, pipe, cron, nohup
    # ────────────────────────────────────────────────────────
    warn "Terminal non-interactif détecté — affichage texte unique (pas de rafraîchissement)"
    echo ""
    _stats_draw_content "$TCOLS" 2>/dev/null
    echo ""
    info "Pour le mode rafraîchissement, lance le script dans un terminal interactif."
    rm -f "$_HUD_STAT_FILE" "/tmp/ia_hud_net_$$.stat" 2>/dev/null || true
  fi
}


# ════════════════════════════════════════════════════════════════════
#  DASHBOARD WEB — Serveur de stats temps réel (port 7842)
# ════════════════════════════════════════════════════════════════════

# Installer le script Python du dashboard sur le système
install_dashboard_script() {
  # Écrire le script Python dans /usr/local/bin/
  cat > "$DASHBOARD_SCRIPT" << 'DASHBOARD_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""IA Local — Dashboard + Admin unifié — port 7842"""
import hashlib,http.server,json,os,re,secrets,socket,subprocess,threading,time,urllib.request
from pathlib import Path
from urllib.parse import urlparse

PORT=int(os.environ.get("DASHBOARD_PORT",7842))
BIND=os.environ.get("DASHBOARD_BIND","0.0.0.0")   # Toutes interfaces (LAN + localhost)
CFG_FILE="/var/lib/ia-installer/config.env"
CREDS_FILE="/var/lib/ia-installer/admin-credentials"
PROGRESS_FILE="/var/lib/ia-installer/progress.json"
SESSION_TTL=86400   # 24h par défaut — modifiable via ADMIN_SESSION_TTL dans config.env
# Lire la durée de session depuis la config si définie
try:
    import re as _re2; _m=_re2.search(r"ADMIN_SESSION_TTL\s*=\s*(\d+)",open(CFG_FILE).read())
    if _m: SESSION_TTL=max(300,min(int(_m.group(1)),604800))  # Clamp: 5min–7jours
except: pass

# ── Config ───────────────────────────────────────────────────────────────────
def _cfg():
    c={}
    try:
        for l in Path(CFG_FILE).read_text().splitlines():
            l=l.strip()
            if "=" in l and not l.startswith("#"):
                k,_,v=l.partition("="); c[k.strip()]=v.strip().strip('"')
    except: pass
    return c

def _run(cmd,t=3):
    try: return subprocess.run(cmd,shell=True,capture_output=True,text=True,timeout=t).stdout.strip()
    except: return ""

def _runx(cmd,t=15):
    try:
        r=subprocess.run(cmd,shell=True,capture_output=True,text=True,timeout=t)
        return {"ok":r.returncode==0,"out":r.stdout.strip(),"err":r.stderr.strip()}
    except Exception as e: return {"ok":False,"out":"","err":str(e)}

def _r(p,d="0"):
    try: return Path(p).read_text().strip()
    except: return d

# ── Auth ─────────────────────────────────────────────────────────────────────
def _load_creds():
    DEFAULT_HASH=hashlib.sha256(b"ia-local-admin").hexdigest()
    try:
        d=json.loads(Path(CREDS_FILE).read_text())
        if "user" in d and "hash" in d:
            d["is_default"]=(d["hash"]==DEFAULT_HASH)
            return d
    except: pass
    c={"user":"admin","hash":DEFAULT_HASH,"is_default":True}
    try: Path(CREDS_FILE).write_text(json.dumps({"user":"admin","hash":DEFAULT_HASH})); Path(CREDS_FILE).chmod(0o600)
    except: pass
    return c

def _check_pw(user,pw):
    c=_load_creds()
    return c["user"]==user and c["hash"]==hashlib.sha256(pw.encode()).hexdigest()

def _save_creds(user,pw):
    h=hashlib.sha256(pw.encode()).hexdigest()
    d={"user":user,"hash":h}
    Path(CREDS_FILE).write_text(json.dumps(d)); Path(CREDS_FILE).chmod(0o600)

_sess={}; _sl=threading.Lock()

# ── Rate limiting login (anti brute-force) ────────────────────────────────────
# Max 5 tentatives par IP sur 5 minutes — blocage 15 minutes après dépassement
_rl={}; _rl_lock=threading.Lock()
RL_MAX=5; RL_WINDOW=300; RL_BLOCK=900   # 5 essais / 5min → bloqué 15min

def _rl_check(ip):
    """Retourne (autorisé:bool, secondes_restantes:int)"""
    now=time.time()
    with _rl_lock:
        r=_rl.get(ip,{"tries":[],"blocked_until":0})
        if r["blocked_until"] > now:
            return False, int(r["blocked_until"]-now)
        # Nettoyer les tentatives hors fenêtre
        r["tries"]=[t for t in r["tries"] if now-t < RL_WINDOW]
        if len(r["tries"]) >= RL_MAX:
            r["blocked_until"]=now+RL_BLOCK
            _rl[ip]=r
            return False, RL_BLOCK
        return True, 0

def _rl_record(ip):
    now=time.time()
    with _rl_lock:
        r=_rl.get(ip,{"tries":[],"blocked_until":0})
        r["tries"].append(now)
        _rl[ip]=r

def _rl_reset(ip):
    with _rl_lock:
        _rl.pop(ip,None)

def _new_sess():
    tok=secrets.token_hex(32)
    with _sl: _sess[tok]=time.time()
    return tok

def _valid_sess(tok):
    if not tok: return False
    with _sl:
        ts=_sess.get(tok,0)
        if time.time()-ts<SESSION_TTL:
            _sess[tok]=time.time(); return True
        _sess.pop(tok,None)
    return False

def _del_sess(tok):
    with _sl: _sess.pop(tok,None)

def _get_tok(hdrs):
    for p in hdrs.get("Cookie","").split(";"):
        k,_,v=p.strip().partition("=")
        if k.strip()=="ia_sess": return v.strip()
    return ""

# ── Collecte stats ────────────────────────────────────────────────────────────
_cp={}
def get_cpu():
    res={"pct":0,"freq_mhz":0,"temp_c":None,"cores":[],"model":""}
    try:
        stats={}
        for l in Path("/proc/stat").read_text().splitlines():
            if l.startswith("cpu"):
                p=l.split();n=p[0];v=list(map(int,p[1:8]))
                stats[n]=(sum(v),v[3]+v[4])
        global _cp
        if _cp:
            for n,(tot,idl) in stats.items():
                pt,pi=_cp.get(n,(tot,idl));dt=tot-pt;di=idl-pi
                pc=round((dt-di)*100/dt,1) if dt>0 else 0.
                if n=="cpu": res["pct"]=pc
                else: res["cores"].append({"name":n,"pct":pc})
        _cp=stats
        f=_r("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
        if f and f!="0": res["freq_mhz"]=round(int(f)/1000)
        else:
            m=re.search(r"cpu MHz\s*:\s*([\d.]+)",_r("/proc/cpuinfo",""))
            if m: res["freq_mhz"]=round(float(m.group(1)))
        for z in sorted(Path("/sys/class/thermal").glob("thermal_zone*/temp")):
            try:
                t=int(z.read_text().strip())/1000
                if t>0: res["temp_c"]=round(t,1); break
            except: pass
        for l in Path("/proc/cpuinfo").read_text().splitlines():
            if l.startswith("model name"): res["model"]=l.split(":",1)[1].strip(); break
    except: pass
    return res

def get_mem():
    res={"ram_total_mb":0,"ram_used_mb":0,"ram_pct":0,"swap_total_mb":0,"swap_used_mb":0,"swap_pct":0}
    try:
        mi={}
        for l in Path("/proc/meminfo").read_text().splitlines():
            k,_,v=l.partition(":"); mi[k.strip()]=int(v.split()[0]) if v.strip() else 0
        tot=mi.get("MemTotal",0);av=mi.get("MemAvailable",0);u=tot-av
        res["ram_total_mb"]=round(tot/1024);res["ram_used_mb"]=round(u/1024)
        res["ram_pct"]=round(u*100/tot,1) if tot else 0
        st=mi.get("SwapTotal",0);sf=mi.get("SwapFree",0);su=st-sf
        res["swap_total_mb"]=round(st/1024);res["swap_used_mb"]=round(su/1024)
        res["swap_pct"]=round(su*100/st,1) if st else 0
    except: pass
    return res

def get_gpu():
    res={"available":False,"brand":"none"}
    try:
        out=_run("nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,power.limit --format=csv,noheader,nounits",t=4)
        if out:
            p=[x.strip() for x in out.split(",")]
            tot=int(p[4]) if len(p)>4 else 1
            res.update({"available":True,"brand":"nvidia","name":p[0] if p else "NVIDIA",
                "util_pct":float(p[1]) if len(p)>1 else 0,"temp_c":float(p[2]) if len(p)>2 else 0,
                "mem_used_mb":int(p[3]) if len(p)>3 else 0,"mem_total_mb":tot,
                "mem_pct":round(int(p[3])*100/tot,1) if len(p)>3 else 0,
                "power_w":float(p[5]) if len(p)>5 else 0,"power_limit_w":float(p[6]) if len(p)>6 else 0})
            return res
    except: pass
    try:
        out=_run("rocm-smi --showuse 2>/dev/null",t=4)
        if out and "GPU" in out:
            u=re.search(r"(\d+)%",out)
            res.update({"available":True,"brand":"amd","name":"AMD GPU","util_pct":int(u.group(1)) if u else 0})
    except: pass
    return res

_dp={}
def get_disks():
    disks=[]
    try:
        out=_run("df -BM --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2")
        for l in out.splitlines():
            p=l.split()
            if len(p)<6: continue
            src=p[0]
            if any(x in src for x in ("tmpfs","devtmpfs","udev","loop","overlay","none")): continue
            pct=int(p[4].replace("%","")) if p[4].replace("%","").isdigit() else 0
            dev=src.replace("/dev/","").split("/")[-1]; io={}
            try:
                sl2=_run(f"grep ' {dev} ' /proc/diskstats 2>/dev/null | head -1")
                if sl2:
                    sp=sl2.split()
                    if len(sp)>=14:
                        rd=int(sp[5]);wr=int(sp[9]);now=time.time()
                        prev=_dp.get(dev)
                        if prev:
                            dt=now-prev[2]
                            if dt>0:
                                io["read_kb_s"]=round((rd-prev[0])*512/1024/dt)
                                io["write_kb_s"]=round((wr-prev[1])*512/1024/dt)
                        _dp[dev]=(rd,wr,now)
            except: pass
            disks.append({"device":src,"size_mb":int(p[1].replace("M","")),
                          "used_mb":int(p[2].replace("M","")),"avail_mb":int(p[3].replace("M","")),
                          "pct":pct,"mount":p[5],**io})
    except: pass
    return disks

_np={}
def get_net():
    res={"interfaces":[],"default_iface":"","local_ip":""}
    try:
        df=_run("ip route 2>/dev/null | awk '/^default/{print $5;exit}'")
        res["default_iface"]=df
        if df:
            m=re.search(r"inet ([\d.]+)",_run(f"ip -4 addr show {df} 2>/dev/null"))
            if m: res["local_ip"]=m.group(1)
        global _np; now=time.time()
        for l in Path("/proc/net/dev").read_text().splitlines()[2:]:
            p=l.split()
            if len(p)<10: continue
            n=p[0].rstrip(":")
            if n=="lo": continue
            rx=int(p[1]);tx=int(p[9])
            prev=_np.get(n); dt=now-_np.get("__ts__",now)
            rxr=round((rx-prev[0])/1024/max(dt,.1)) if prev else 0
            txr=round((tx-prev[1])/1024/max(dt,.1)) if prev else 0
            _np[n]=(rx,tx)
            res["interfaces"].append({"name":n,"rx_kb_s":max(0,rxr),"tx_kb_s":max(0,txr),
                "rx_total_mb":round(rx/1024/1024,1),"tx_total_mb":round(tx/1024/1024,1)})
        _np["__ts__"]=now
    except: pass
    return res

def get_svc():
    cfg=_cfg()
    wp=cfg.get("webui_port","8080"); oh=cfg.get("ollama_host","127.0.0.1")
    if oh=="0.0.0.0": oh="127.0.0.1"
    res={"ollama":{"active":False,"url":f"http://{oh}:11434","models":[],"model_count":0},
         "webui":{"active":False,"url":f"http://localhost:{wp}"},
         "docker":{"active":False,"containers":0}}
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags",timeout=1) as r:
            d=json.loads(r.read()); ms=[m["name"] for m in d.get("models",[])]
            res["ollama"].update({"active":True,"models":ms,"model_count":len(ms)})
    except: pass
    try:
        ps=_run("docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null",t=2); c=0
        for l in ps.splitlines():
            if not l.strip(): continue
            c+=1; nm,_,st=l.partition("|")
            if nm.strip()=="open-webui": res["webui"].update({"active":"Up" in st,"status":st.strip()})
        res["docker"].update({"active":True,"containers":c})
    except: pass
    return res

def get_up():
    try:
        s=float(_r("/proc/uptime").split()[0])
        d,h,m,sc=int(s//86400),int((s%86400)//3600),int((s%3600)//60),int(s%60)
        return {"seconds":int(s),"human":f"{d}j {h:02d}h{m:02d}m" if d else f"{h:02d}h{m:02d}m{sc:02d}s"}
    except: return {"seconds":0,"human":"?"}

def get_progress():
    """Lit le fichier progress.json écrit par le script bash pendant l'installation."""
    try:
        d=json.loads(Path(PROGRESS_FILE).read_text())
        if isinstance(d,dict) and d.get("active"): return d
    except: pass
    return None   # Pas d'installation en cours

def collect():
    pg=get_progress()
    return {"ts":time.time(),"cpu":get_cpu(),"memory":get_mem(),"gpu":get_gpu(),
            "disks":get_disks(),"network":get_net(),"services":get_svc(),
            "uptime":get_up(),"hostname":socket.gethostname(),
            "progress":pg,             # Utilisé par la bannière de progression JS
            "install_progress":pg}     # Rétrocompatibilité

_cache={}; _lock=threading.Lock()
def _worker():
    # 1er collect initialise _cp sans delta — on attend 1s pour un vrai delta CPU
    try: collect()
    except: pass
    time.sleep(1)
    while True:
        try:
            with _lock: globals()["_cache"]=collect()
        except: pass
        time.sleep(2)

# ── API Admin ─────────────────────────────────────────────────────────────────
def api_admin_status():
    creds=_load_creds()
    cfg=_cfg(); wp=cfg.get("webui_port","8080"); oh=cfg.get("ollama_host","127.0.0.1")
    if oh=="0.0.0.0": oh="127.0.0.1"
    def svc_on(n): return _runx(f"systemctl is-active --quiet {n}",t=3)["ok"]
    def ctr_on(n): return n in _run(f"docker ps --filter name=^{n}$ --format '{{{{.Names}}}}' 2>/dev/null",t=3)
    models=[]
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags",timeout=1) as r:
            models=[m["name"] for m in json.loads(r.read()).get("models",[])]
    except: pass
    return {
        "is_default_password":creds.get("is_default",False),
        "admin_user":creds.get("user","admin"),
        "services":{
            "ollama":{"active":svc_on("ollama"),"url":f"http://{oh}:11434",
                      "version":_run("ollama --version 2>/dev/null | grep -oP '[\\d.]+' | head -1",t=3) or "?"},
            "webui": {"active":ctr_on("open-webui"),"url":f"http://localhost:{wp}"},
            "docker":{"active":svc_on("docker")},
            "dashboard":{"active":svc_on("ia-dashboard"),"url":f"http://localhost:{PORT}"},
        },
        "models":models,
        "disk":_run("df -h / 2>/dev/null | tail -1 | awk '{print $3\"/\"$2\" (\"$5\")}' ",t=3) or "?",
        "hostname":socket.gethostname(),
        "uptime":_run("uptime -p 2>/dev/null",t=2) or "?",
    }

def api_svc_action(body):
    act=body.get("action",""); svc=body.get("service","")
    MAP={"ollama":("sys","ollama"),"docker":("sys","docker"),
         "dashboard":("sys","ia-dashboard"),"webui":("docker","open-webui")}
    if act not in {"start","stop","restart"} or svc not in MAP:
        return {"ok":False,"msg":"Paramètre invalide"}
    kind,name=MAP[svc]
    if kind=="sys":
        r=_runx(f"systemctl {act} {name}",t=30)
    else:
        cmds={"start":f"docker start {name}","stop":f"docker stop {name}",
              "restart":f"docker stop {name} && docker start {name}"}
        r=_runx(cmds[act],t=30)
    return {"ok":r["ok"],"msg":r["out"] or r["err"] or ("OK" if r["ok"] else "Erreur")}

def api_update(body):
    target=body.get("target","")
    # Whitelist des cibles autorisées
    if target not in {"ollama","webui","system"}:
        return {"ok":False,"msg":"Cible invalide"}
    if target=="ollama":
        # Téléchargement + vérification SHA256 avant exécution
        chk=_runx(
            "set -e; "
            "TMP=$(mktemp /tmp/ollama-XXXXXX.sh); "
            "curl -fsSL --max-time 120 -o $TMP https://ollama.com/install.sh; "
            "LOCAL=$(sha256sum $TMP | cut -d' ' -f1); "
            "REMOTE=$(curl -sf --max-time 15 "
            "'https://api.github.com/repos/ollama/ollama/contents/install.sh' "
            "| python3 -c \"import sys,json,base64,hashlib;d=json.load(sys.stdin);"
            "c=base64.b64decode(d[\'content\']).decode(\'utf-8\',errors=\'replace\');"
            "print(hashlib.sha256(c.encode(\'utf-8\')).hexdigest())\" 2>/dev/null || echo ''); "
            "if [ -n \"$REMOTE\" ] && [ \"$LOCAL\" != \"$REMOTE\" ]; then "
            "  echo INTEGRITY_FAIL:local=$LOCAL:remote=$REMOTE; rm -f $TMP; exit 1; fi; "
            "chmod 700 $TMP && sh $TMP; rm -f $TMP",
            t=360)
        if not chk['ok'] and 'INTEGRITY_FAIL' in chk.get('out',''):
            return {"ok":False,"msg":"⛔ Intégrité du script Ollama non vérifiée — MAJ annulée par sécurité.\n"+chk['out']}
        r=chk
        return {"ok":r["ok"],"msg":r["out"] or r["err"]}
    if target=="webui":
        cfg=_cfg(); img=cfg.get("gpu_docker_img","ghcr.io/open-webui/open-webui:main")
        # Valider le format de l'image Docker (évite injection de commandes)
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._/:-]{5,150}$",img):
            return {"ok":False,"msg":f"Format d'image Docker invalide : {img}"}
        r1=_runx(f"docker pull {img}",t=600)
        if not r1["ok"]: return {"ok":False,"msg":r1["err"]}
        dd=cfg.get("webui_dir","/opt/open-webui"); pp=cfg.get("webui_port","8080")
        nt=cfg.get("docker_network","host")
        _runx("docker stop open-webui 2>/dev/null",t=15)
        _runx("docker rm   open-webui 2>/dev/null",t=10)
        if nt=="host":
            # Note sécurité : OLLAMA_BASE_URL et PORT ne sont pas des secrets
            # (URL locale + port) — visible dans 'docker inspect' mais non sensible
            cmd=f"docker run -d --network=host -v {dd}:/app/backend/data -e OLLAMA_BASE_URL=http://127.0.0.1:11434 -e PORT={pp} --name open-webui --restart unless-stopped {img}"
        else:
            cmd=f"docker run -d -p {pp}:8080 --add-host=host.docker.internal:host-gateway -v {dd}:/app/backend/data -e OLLAMA_BASE_URL=http://127.0.0.1:11434 --name open-webui --restart unless-stopped {img}"
        r2=_runx(cmd,t=30)
        return {"ok":r2["ok"],"msg":(r1["out"]+"\n"+r2.get("out","")).strip()}
    if target=="system":
        if os.path.exists("/usr/bin/apt"):
            r=_runx("DEBIAN_FRONTEND=noninteractive apt update && apt upgrade -y",t=600)
        elif os.path.exists("/usr/bin/dnf"):
            r=_runx("dnf upgrade -y",t=600)
        elif os.path.exists("/usr/bin/pacman"):
            r=_runx("pacman -Syu --noconfirm",t=600)
        else: return {"ok":False,"msg":"Gestionnaire de paquets non reconnu"}
        return {"ok":r["ok"],"msg":r["out"] or r["err"]}
    return {"ok":False,"msg":"Cible inconnue"}

def api_models(body):
    act=body.get("action","list")
    if act=="list":
        try:
            with urllib.request.urlopen("http://127.0.0.1:11434/api/tags",timeout=3) as r:
                return {"ok":True,"models":json.loads(r.read()).get("models",[])}
        except Exception as e: return {"ok":False,"models":[],"msg":str(e)}
    if act=="pull":
        nm=body.get("name","").strip()
        if not nm or not re.match(r'^[\w./:+-]+$',nm): return {"ok":False,"msg":"Nom invalide"}
        subprocess.Popen(["ollama","pull",nm],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return {"ok":True,"msg":f"Téléchargement de {nm} lancé…"}
    if act=="delete":
        nm=body.get("name","").strip()
        if not nm or not re.match(r'^[\w./:+-]+$',nm): return {"ok":False,"msg":"Nom invalide"}
        r=_runx(f"ollama rm {nm}",t=30)
        return {"ok":r["ok"],"msg":r["out"] or r["err"] or "OK"}
    return {"ok":False,"msg":"Action inconnue"}

def api_logs(body):
    # Whitelist stricte source — aucune valeur arbitraire acceptée
    VALID_SRCS={"ollama","webui","docker","dashboard","syslog","kernel","install"}
    src=body.get("source","ollama")
    if src not in VALID_SRCS: src="ollama"
    # Nombre de lignes : entier strict entre 10 et 500
    try: n=max(10,min(int(str(body.get("lines",100)).strip()),500))
    except: n=100
    cmds={"install":f"tail -n {n} /var/log/ia-installer/web-install.log 2>/dev/null || echo 'Log non disponible'",
          "ollama":f"journalctl -u ollama -n {n} --no-pager 2>/dev/null",
          "webui": f"docker logs --tail {n} open-webui 2>&1",
          "docker":f"journalctl -u docker -n {n} --no-pager 2>/dev/null",
          "dashboard":f"journalctl -u ia-dashboard -n {n} --no-pager 2>/dev/null",
          "syslog":f"journalctl -n {n} --no-pager 2>/dev/null",
          "kernel":f"journalctl -k -n {n} --no-pager 2>/dev/null"}
    r=_runx(cmds[src],t=15)
    return {"ok":True,"lines":r["out"].splitlines()}

def api_system_action(body):
    """Reboot, shutdown, mise à jour système depuis le dashboard."""
    action=body.get("action","")
    if action not in {"reboot","shutdown","update_system"}:
        return {"ok":False,"msg":"Action inconnue"}
    try:
        if action=="reboot":
            import threading
            def _do(): import time; time.sleep(2); subprocess.run(["shutdown","-r","now"])
            threading.Thread(target=_do,daemon=True).start()
            return {"ok":True,"msg":"🔄 Redémarrage dans 2 secondes…"}
        elif action=="shutdown":
            import threading
            def _do(): import time; time.sleep(2); subprocess.run(["shutdown","-h","now"])
            threading.Thread(target=_do,daemon=True).start()
            return {"ok":True,"msg":"⏻ Arrêt dans 2 secondes…"}
        elif action=="update_system":
            import threading,shutil
            def _do():
                try:
                    if shutil.which("apt"):
                        subprocess.run(["apt","update","-y"],timeout=120,capture_output=True)
                        subprocess.run(["apt","upgrade","-y","--auto-remove"],timeout=300,capture_output=True)
                    elif shutil.which("dnf"):
                        subprocess.run(["dnf","upgrade","-y"],timeout=300,capture_output=True)
                    elif shutil.which("pacman"):
                        subprocess.run(["pacman","-Syu","--noconfirm"],timeout=300,capture_output=True)
                    elif shutil.which("zypper"):
                        subprocess.run(["zypper","update","-y"],timeout=300,capture_output=True)
                except: pass
            threading.Thread(target=_do,daemon=True).start()
            return {"ok":True,"msg":"📦 Mise à jour système lancée en arrière-plan…"}
    except Exception as e:
        return {"ok":False,"msg":str(e)}

def api_launch_install(body):
    """Lance le script installateur en arrière-plan depuis le dashboard web."""
    import os, glob, pwd

    def _find_script():
        # 1. Chemin sauvegardé par le script bash au démarrage
        try:
            p = Path("/var/lib/ia-installer/installer-path.txt").read_text().strip()
            if p and os.path.isfile(p): return p
        except: pass
        # 2. Chercher dans /home/*/  et /root/
        for p in (
            glob.glob("/home/*/install_ia_local.sh") +
            glob.glob("/root/install_ia_local.sh") +
            glob.glob("/home/*/*/install_ia_local.sh") +
            ["/usr/local/bin/install_ia_local.sh","/opt/install_ia_local.sh"]
        ):
            if os.path.isfile(p): return p
        # 3. find système (dernier recours)
        found = _run("find / -maxdepth 6 -name 'install_ia_local.sh' -not -path '*/proc/*' -not -path '*/sys/*' 2>/dev/null | head -1", t=3)
        if found and os.path.isfile(found): return found
        return None

    script = _find_script()

    # Si trouvé mais pas dans /home/$user/ → créer le lien symbolique
    if script:
        try:
            # Trouver le home du premier utilisateur non-root
            for entry in pwd.getpwall():
                if entry.pw_uid >= 1000 and os.path.isdir(entry.pw_dir):
                    canonical = os.path.join(entry.pw_dir, "install_ia_local.sh")
                    if script != canonical and not os.path.isfile(canonical):
                        try:
                            os.symlink(script, canonical)
                            os.chown(canonical, entry.pw_uid, entry.pw_gid)
                            Path("/var/lib/ia-installer/installer-path.txt").write_text(script)
                        except: pass
                    break
        except: pass

    if not script:
        return {"ok":False,"msg":"Script install_ia_local.sh introuvable.\n\nLancez d'abord depuis le terminal :\n  sudo bash install_ia_local.sh\nLe dashboard retiendra ensuite son emplacement."}
    # Vérifier qu'une installation n'est pas déjà en cours
    try:
        d2 = json.loads(Path(PROGRESS_FILE).read_text())
        if d2.get("active"):
            return {"ok":False,"msg":"Installation déjà en cours — suivez la progression ci-dessus."}
    except: pass
    # Préparer le log
    log_dir = "/var/log/ia-installer"
    log_file = log_dir + "/web-install.log"
    try: os.makedirs(log_dir, exist_ok=True)
    except: pass
    try:
        with open(log_file,"a") as lf:
            subprocess.Popen(
                ["bash", script, "--web-install"],
                stdout=lf, stderr=lf,
                close_fds=True,
                start_new_session=True
            )
        return {"ok":True,"msg":"✅ Installation lancée ! Suivez la progression dans l'onglet ci-dessus."}
    except Exception as e:
        return {"ok":False,"msg":f"Erreur lancement : {e}"}

def api_change_pw(body):
    old=body.get("old",""); new=body.get("new",""); user=body.get("user","").strip()
    # Validation nom d'utilisateur : alphanum + tirets uniquement, 2-32 car.
    if not re.match(r"^[a-zA-Z0-9_-]{2,32}$",user):
        return {"ok":False,"msg":"Nom d'utilisateur invalide (2-32 car., alphanum et -_)"}
    if not _check_pw(_load_creds()["user"],old): return {"ok":False,"msg":"Mot de passe actuel incorrect"}
    if len(new)<6: return {"ok":False,"msg":"Nouveau mot de passe trop court (6 car. min)"}
    if len(new)>128: return {"ok":False,"msg":"Nouveau mot de passe trop long (128 car. max)"}
    _save_creds(user or _load_creds()["user"], new)
    with _sl: _sess.clear()
    return {"ok":True,"msg":"Mot de passe changé."}

HTML=r"""<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>IA Local · Dashboard</title>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&family=Fira+Code:wght@300;400;500&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#080c14;--s1:#0c1220;--s2:#111928;--s3:#162035;
  --br:rgba(255,255,255,.06);--br2:rgba(255,255,255,.11);
  --neon:#00ffb3;--blue:#4d9fff;--purple:#a855f7;
  --orange:#f97316;--red:#ef4444;--yellow:#eab308;
  --text:#e2e8f0;--muted:#64748b;--muted2:#374151;
  --font:'Space Grotesk',sans-serif;--mono:'Fira Code',monospace;
}
html{background:var(--bg);color:var(--text);font-family:var(--font);font-size:14px;
  scrollbar-width:thin;scrollbar-color:#1e2d45 transparent}
body{min-height:100vh;background:
  radial-gradient(ellipse 120% 80% at -10% -20%,rgba(0,255,179,.04),transparent 50%),
  radial-gradient(ellipse 80% 60% at 110% 110%,rgba(77,159,255,.04),transparent 50%),var(--bg)}

/* ── Topbar ── */
nav{position:sticky;top:0;z-index:200;display:flex;align-items:center;justify-content:space-between;
  padding:0 24px;height:52px;background:rgba(8,12,20,.9);backdrop-filter:blur(20px);
  border-bottom:1px solid var(--br)}
.nav-l{display:flex;align-items:center;gap:12px}
.pulse{width:8px;height:8px;border-radius:50%;background:var(--neon);
  box-shadow:0 0 0 0 rgba(0,255,179,.6);animation:hb 2s ease-in-out infinite}
@keyframes hb{0%{box-shadow:0 0 0 0 rgba(0,255,179,.6)}50%{box-shadow:0 0 0 8px rgba(0,255,179,0)}100%{box-shadow:0 0 0 0 rgba(0,255,179,0)}}
.brand{font-size:14px;font-weight:700;color:#fff}.brand b{color:var(--neon)}
.nav-chips{display:flex;gap:6px}
.chip{font-family:var(--mono);font-size:10px;padding:2px 9px;border-radius:20px;
  background:var(--s2);border:1px solid var(--br2);color:var(--muted)}
.chip.live{color:var(--neon);border-color:rgba(0,255,179,.3);background:rgba(0,255,179,.05)}
.nav-r{display:flex;align-items:center;gap:8px}
#ntime{font-family:var(--mono);font-size:12px;color:var(--muted)}

/* ── Tabs ── */
.tabs{display:flex;gap:2px;padding:0 24px;
  background:rgba(8,12,20,.7);border-bottom:1px solid var(--br);
  backdrop-filter:blur(12px);position:sticky;top:52px;z-index:150}
.tab{padding:10px 20px;font-size:12px;font-weight:600;letter-spacing:.04em;
  cursor:pointer;border-bottom:2px solid transparent;
  color:var(--muted);transition:color .2s,border-color .2s;user-select:none;
  display:flex;align-items:center;gap:7px}
.tab:hover{color:var(--text)}
.tab.active{color:#fff;border-bottom-color:var(--neon)}
.tab .tic{font-size:14px}
.tab-lock{font-size:10px;font-family:var(--mono);padding:1px 6px;border-radius:10px;
  background:rgba(168,85,247,.1);color:var(--purple);border:1px solid rgba(168,85,247,.25)}

/* ── Panels ── */
.panel{display:none;padding:16px 20px}.panel.active{display:block}

/* ── Dashboard layout ── */
#p-stats main{display:grid;gap:12px;grid-template-columns:repeat(12,1fr);
  grid-template-areas:
    "top top top top top top top top top top top top"
    "cpu cpu cpu cpu cpu mem mem mem mem gpu gpu gpu"
    "svc svc svc svc net net net dsk dsk dsk dsk dsk"}
#rt{grid-area:top;display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.ms{background:var(--s1);border:1px solid var(--br);border-radius:12px;padding:14px 18px;
  display:flex;align-items:center;gap:14px;position:relative;overflow:hidden;transition:border-color .2s}
.ms::before{content:'';position:absolute;inset:0;background:linear-gradient(135deg,rgba(255,255,255,.02),transparent 60%);pointer-events:none}
.ms:hover{border-color:var(--br2)}
.mi{width:36px;height:36px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:17px;flex-shrink:0}
.ml{font-size:9px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:var(--muted);margin-bottom:2px}
.mv{font-size:20px;font-weight:700;line-height:1;color:#fff}
.msb{font-size:10px;color:var(--muted);font-family:var(--mono);margin-top:2px}
.card{background:var(--s1);border:1px solid var(--br);border-radius:14px;padding:18px 20px;
  position:relative;overflow:hidden;transition:border-color .25s}
.card:hover{border-color:var(--br2)}
.card::after{content:'';position:absolute;inset:0;background:linear-gradient(160deg,rgba(255,255,255,.025),transparent 40%);pointer-events:none}
#cc{grid-area:cpu}#cm{grid-area:mem}#cg{grid-area:gpu}#cs{grid-area:svc}#cn{grid-area:net}#cd{grid-area:dsk}
.ch{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}
.ct{display:flex;align-items:center;gap:8px;font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
.gw{display:flex;align-items:center;gap:20px;margin-bottom:10px}
.gsvg{flex-shrink:0}
.gtrack{fill:none;stroke:var(--s3);stroke-width:8;stroke-linecap:round}
.gfill{fill:none;stroke-width:8;stroke-linecap:round;transition:stroke-dashoffset 1s cubic-bezier(.4,0,.2,1),stroke .5s}
.gpc{font-family:var(--font);font-weight:700;font-size:19px;fill:#fff;text-anchor:middle;dominant-baseline:middle}
.gu{font-family:var(--mono);font-size:9px;fill:var(--muted);text-anchor:middle;dominant-baseline:middle}
.gi{flex:1}.gbig{font-size:26px;font-weight:700;color:#fff;line-height:1}
.gbig span{font-size:13px;font-weight:400;color:var(--muted)}
.gsub{font-size:11px;color:var(--muted);font-family:var(--mono);margin-top:4px}
.bg{margin:7px 0}
.br_{display:flex;justify-content:space-between;font-size:10px;color:var(--muted);font-family:var(--mono);margin-bottom:4px}
.bt{height:5px;background:var(--s3);border-radius:3px;overflow:hidden}
.bf{height:100%;border-radius:3px;transition:width 1s cubic-bezier(.4,0,.2,1)}
.fn{background:linear-gradient(90deg,#009966,var(--neon))}.fb{background:linear-gradient(90deg,#2266cc,var(--blue))}
.fp{background:linear-gradient(90deg,#7733cc,var(--purple))}.fy{background:linear-gradient(90deg,#996600,var(--yellow))}
.fr{background:linear-gradient(90deg,#991111,var(--red))}
.sw{margin-top:12px;height:48px}
.sw svg{width:100%;height:100%;overflow:visible}
.sl{fill:none;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round}
.sa{opacity:.12}
.cg2{display:grid;grid-template-columns:repeat(auto-fill,minmax(46px,1fr));gap:4px;margin-top:10px}
.ci{background:var(--s2);border:1px solid var(--br);border-radius:7px;padding:5px 6px;text-align:center}
.cin{font-size:8px;color:var(--muted);font-family:var(--mono)}
.civ{font-size:11px;font-weight:600;font-family:var(--mono)}
.cib{height:3px;background:var(--s3);border-radius:2px;margin-top:3px;overflow:hidden}
.cif{height:100%;border-radius:2px;transition:width 1s ease}
.gg{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:4px}
.gb{background:var(--s2);border:1px solid var(--br);border-radius:9px;padding:10px 12px}
.gbl{font-size:9px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}
.gbv{font-size:19px;font-weight:700;font-family:var(--mono);margin-top:2px}
.sl2{display:flex;flex-direction:column;gap:9px}
.sr{background:var(--s2);border:1px solid var(--br);border-radius:10px;padding:11px 14px;
  display:flex;align-items:center;gap:11px;transition:border-color .2s}
.sr:hover{border-color:var(--br2)}
.sd{width:8px;height:8px;border-radius:50%;flex-shrink:0;transition:all .3s}
.sd.on{background:var(--neon);box-shadow:0 0 9px rgba(0,255,179,.5)}
.sd.off{background:var(--red);box-shadow:0 0 9px rgba(239,68,68,.4)}
.sb{flex:1;min-width:0}
.sn{font-size:13px;font-weight:600;color:#fff}
.sm{font-size:10px;color:var(--muted);font-family:var(--mono);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.slink{font-size:10px;font-family:var(--mono);color:var(--blue);text-decoration:none;
  background:rgba(77,159,255,.08);border:1px solid rgba(77,159,255,.2);padding:3px 8px;border-radius:5px;transition:all .2s;flex-shrink:0}
.slink:hover{background:rgba(77,159,255,.15)}
.mp{display:flex;flex-wrap:wrap;gap:3px;margin-top:5px}
.mtag{font-size:9px;font-family:var(--mono);background:rgba(0,255,179,.06);border:1px solid rgba(0,255,179,.15);color:var(--neon);padding:2px 7px;border-radius:20px}
.nt{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:9px}
.nb{background:var(--s2);border:1px solid var(--br);border-radius:9px;padding:10px 12px}
.nd{font-size:9px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin-bottom:3px}
.nv{font-size:21px;font-weight:700;font-family:var(--mono);color:#fff}
.nu{font-size:11px;color:var(--muted);margin-left:3px}
.ntot{font-size:9px;color:var(--muted2);font-family:var(--mono);margin-top:2px}
.ni2{display:flex;gap:14px;font-size:10px;color:var(--muted);font-family:var(--mono);margin-bottom:7px}
.ni2 span{color:var(--text)}
.dl{display:flex;flex-direction:column;gap:7px}
.dr{background:var(--s2);border:1px solid var(--br);border-radius:9px;padding:10px 13px}
.dh{display:flex;align-items:center;justify-content:space-between;margin-bottom:7px}
.dd{font-size:12px;font-weight:600;font-family:var(--mono);color:#fff}
.dm{font-size:10px;color:var(--muted);font-family:var(--mono)}
.dns{display:flex;gap:10px;margin-top:4px;font-size:10px;color:var(--muted);font-family:var(--mono)}
.dio{font-size:10px;color:var(--muted2);font-family:var(--mono);margin-top:2px}
.badge{display:inline-flex;font-size:9px;font-weight:600;letter-spacing:.06em;font-family:var(--mono);padding:2px 8px;border-radius:20px}
.bok{background:rgba(0,255,179,.08);color:var(--neon);border:1px solid rgba(0,255,179,.2)}
.bwn{background:rgba(234,179,8,.08);color:var(--yellow);border:1px solid rgba(234,179,8,.2)}
.bct{background:rgba(239,68,68,.08);color:var(--red);border:1px solid rgba(239,68,68,.2)}
@media(max-width:1200px){#p-stats main{grid-template-columns:repeat(6,1fr);grid-template-areas:"top top top top top top" "cpu cpu cpu mem mem mem" "gpu gpu gpu gpu gpu gpu" "svc svc svc net net net" "dsk dsk dsk dsk dsk dsk"}#rt{grid-template-columns:repeat(2,1fr)}}
@media(max-width:700px){#p-stats main{grid-template-columns:1fr;grid-template-areas:"top""cpu""mem""gpu""svc""net""dsk"}#rt{grid-template-columns:1fr 1fr}.gw{flex-direction:column;align-items:flex-start}}

/* ── Admin panel ── */
#p-admin{padding:20px 24px}

/* Login overlay */
#adm-login{display:flex;align-items:center;justify-content:center;min-height:60vh}
.login-box{width:340px;background:var(--s1);border:1px solid var(--br);border-radius:14px;padding:32px 28px}
.login-title{font-size:16px;font-weight:700;color:#fff;margin-bottom:4px}
.login-sub{font-size:11px;color:var(--muted);font-family:var(--mono);margin-bottom:24px}
.lf-label{font-size:10px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin-bottom:5px}
.lf-input{width:100%;background:var(--s2);border:1px solid rgba(255,255,255,.08);border-radius:8px;
  padding:9px 12px;color:var(--text);font-family:var(--mono);font-size:13px;outline:none;
  transition:border-color .2s;margin-bottom:12px}
.lf-input:focus{border-color:rgba(0,255,179,.35)}
.lf-btn{width:100%;background:var(--neon);color:#030a06;font-weight:700;font-family:var(--font);
  font-size:13px;border:none;border-radius:8px;padding:10px;cursor:pointer;transition:opacity .2s;margin-top:4px}
.lf-btn:hover{opacity:.85}
.lf-err{font-size:11px;font-family:var(--mono);color:var(--red);text-align:center;margin-top:10px;min-height:16px}

/* Admin content */
#adm-content{display:none}
.adm-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px}
.adm-title{font-size:18px;font-weight:700;color:#fff}
.adm-user{font-size:11px;font-family:var(--mono);color:var(--muted)}
.btn-logout{font-size:11px;font-family:var(--mono);padding:4px 12px;border-radius:6px;
  background:rgba(239,68,68,.07);color:var(--red);border:1px solid rgba(239,68,68,.2);cursor:pointer;transition:all .2s}
.btn-logout:hover{background:rgba(239,68,68,.14)}

/* Admin sub-tabs */
.atabs{display:flex;gap:6px;margin-bottom:20px;flex-wrap:wrap}
.atab{padding:6px 16px;font-size:11px;font-weight:600;letter-spacing:.04em;border-radius:8px;
  cursor:pointer;background:var(--s2);border:1px solid var(--br);color:var(--muted);
  transition:all .2s;user-select:none}
.atab:hover{border-color:var(--br2);color:var(--text)}
.atab.active{background:rgba(0,255,179,.08);color:var(--neon);border-color:rgba(0,255,179,.25)}
.asect{display:none}.asect.active{display:block}

/* Service cards admin */
.svc-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:10px;margin-bottom:14px}
.svc-card{background:var(--s2);border:1px solid var(--br);border-radius:10px;padding:14px;transition:border-color .2s}
.svc-card:hover{border-color:var(--br2)}
.svc-hd{display:flex;align-items:center;gap:9px;margin-bottom:8px}
.sled{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.sled.on{background:var(--neon);box-shadow:0 0 7px rgba(0,255,179,.5)}
.sled.off{background:var(--red);box-shadow:0 0 7px rgba(239,68,68,.4)}
.svc-nm{font-size:13px;font-weight:600;color:#fff}
.svc-mt{font-size:10px;color:var(--muted);font-family:var(--mono);margin-bottom:10px;min-height:14px}
.svc-bts{display:flex;gap:5px;flex-wrap:wrap}
.btn-s{font-size:10px;font-family:var(--mono);padding:4px 10px;border-radius:5px;
  border:1px solid transparent;cursor:pointer;transition:all .2s;font-weight:500}
.btn-go{background:rgba(0,255,179,.07);color:var(--neon);border-color:rgba(0,255,179,.2)}
.btn-go:hover{background:rgba(0,255,179,.14)}
.btn-stop{background:rgba(239,68,68,.07);color:var(--red);border-color:rgba(239,68,68,.2)}
.btn-stop:hover{background:rgba(239,68,68,.14)}
.btn-re{background:rgba(234,179,8,.07);color:var(--yellow);border-color:rgba(234,179,8,.2)}
.btn-re:hover{background:rgba(234,179,8,.14)}
a.btn-s{text-decoration:none}
.btn-lnk{background:rgba(77,159,255,.07);color:var(--blue);border-color:rgba(77,159,255,.2)}
.btn-lnk:hover{background:rgba(77,159,255,.14)}

/* Update rows */
.upd-row{background:var(--s2);border:1px solid var(--br);border-radius:10px;padding:14px 16px;
  display:flex;align-items:center;gap:14px;margin-bottom:9px;transition:border-color .2s}
.upd-row:hover{border-color:var(--br2)}
.upd-ico{font-size:26px;flex-shrink:0}
.upd-body{flex:1;min-width:0}
.upd-name{font-size:13px;font-weight:600;color:#fff}
.upd-desc{font-size:10px;color:var(--muted);font-family:var(--mono);margin-top:2px}
.btn-upd{padding:7px 16px;background:var(--neon);color:#030a06;font-weight:700;
  font-family:var(--mono);font-size:11px;border:none;border-radius:7px;cursor:pointer;
  white-space:nowrap;transition:opacity .2s;flex-shrink:0}
.btn-upd:hover{opacity:.85}
.btn-upd:disabled{opacity:.4;cursor:wait}
.upd-out{background:var(--bg);border:1px solid var(--br);border-radius:8px;
  padding:12px 14px;font-family:var(--mono);font-size:10px;line-height:1.7;
  color:#7dd3fc;max-height:220px;overflow-y:auto;white-space:pre-wrap;
  margin-top:10px;display:none}

/* Model list */
.model-pull{display:flex;gap:8px;margin-bottom:14px}
.mp-in{flex:1;background:var(--s2);border:1px solid rgba(255,255,255,.08);border-radius:8px;
  padding:8px 12px;color:var(--text);font-family:var(--mono);font-size:12px;outline:none;
  transition:border-color .2s}
.mp-in:focus{border-color:rgba(0,255,179,.35)}
.btn-pull{padding:8px 16px;background:var(--neon);color:#030a06;font-weight:700;
  font-family:var(--mono);font-size:11px;border:none;border-radius:7px;cursor:pointer;transition:opacity .2s}
.btn-pull:hover{opacity:.85}
.model-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px}
.mc{background:var(--s2);border:1px solid var(--br);border-radius:9px;padding:11px 13px;
  display:flex;align-items:center;gap:10px}
.mc-ico{font-size:20px;flex-shrink:0}
.mc-b{flex:1;min-width:0}
.mc-n{font-size:12px;font-weight:600;font-family:var(--mono);color:var(--neon);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mc-s{font-size:9px;color:var(--muted);font-family:var(--mono);margin-top:2px}
.mc-del{font-size:10px;font-family:var(--mono);padding:3px 9px;border-radius:5px;
  background:rgba(239,68,68,.07);color:var(--red);border:1px solid rgba(239,68,68,.2);
  cursor:pointer;flex-shrink:0;transition:all .2s}
.mc-del:hover{background:rgba(239,68,68,.16)}

/* Log viewer */
.log-bar{display:flex;align-items:center;gap:8px;margin-bottom:10px;flex-wrap:wrap}
.log-sel{background:var(--s2);border:1px solid rgba(255,255,255,.1);border-radius:7px;
  padding:5px 10px;color:var(--text);font-family:var(--mono);font-size:11px;outline:none}
.btn-ref{padding:5px 12px;background:rgba(77,159,255,.07);color:var(--blue);
  border:1px solid rgba(77,159,255,.2);border-radius:6px;font-family:var(--mono);
  font-size:11px;cursor:pointer;transition:all .2s}
.btn-ref:hover{background:rgba(77,159,255,.14)}
.log-box{background:var(--bg);border:1px solid var(--br);border-radius:8px;
  padding:12px 14px;font-family:var(--mono);font-size:11px;line-height:1.7;
  color:#7dd3fc;height:440px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.ll{display:block}.ll.err{color:var(--red)}.ll.warn{color:var(--yellow)}.ll.ok2{color:var(--neon)}

/* Settings */
.sfield{display:grid;grid-template-columns:130px 1fr;align-items:center;gap:10px;margin-bottom:9px}
.sf-label{font-size:10px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.sf-in{background:var(--s2);border:1px solid rgba(255,255,255,.08);border-radius:7px;
  padding:7px 11px;color:var(--text);font-family:var(--mono);font-size:12px;outline:none;
  transition:border-color .2s;width:100%}
.sf-in:focus{border-color:rgba(0,255,179,.35)}
.btn-save{padding:8px 20px;background:var(--neon);color:#030a06;font-weight:700;
  font-family:var(--font);font-size:12px;border:none;border-radius:7px;cursor:pointer;
  transition:opacity .2s;margin-top:6px}
.btn-save:hover{opacity:.85}
.acard{background:var(--s1);border:1px solid var(--br);border-radius:12px;padding:16px 18px;margin-bottom:12px}
.acard-t{font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;
  color:var(--muted);margin-bottom:12px}

/* Toast */
#toast{position:fixed;bottom:20px;right:20px;z-index:9999;padding:10px 18px;border-radius:9px;
  font-size:12px;font-family:var(--mono);opacity:0;transition:opacity .3s,transform .3s;
  transform:translateY(6px);pointer-events:none;max-width:320px}
#toast.show{opacity:1;transform:none}
#toast.ok{background:#0d2e1e;color:var(--neon);border:1px solid rgba(0,255,179,.2)}
#toast.err{background:#2e0d0d;color:var(--red);border:1px solid rgba(239,68,68,.2)}
#toast.inf{background:#0d1e2e;color:var(--blue);border:1px solid rgba(77,159,255,.2)}

.spin{display:inline-block;width:10px;height:10px;border:2px solid rgba(255,255,255,.2);
  border-top-color:#fff;border-radius:50%;animation:spin .6s linear infinite;margin-right:5px;vertical-align:middle}
@keyframes spin{to{transform:rotate(360deg)}}


/* ── Bannière installation ── */
#install-banner{display:none;margin:12px 20px 0;border-radius:12px;overflow:hidden;
  border:1px solid rgba(0,255,179,.25);background:rgba(0,255,179,.04);
  animation:up .4s ease both}
.ib-top{display:flex;align-items:center;gap:12px;padding:14px 18px;
  border-bottom:1px solid rgba(0,255,179,.1)}
.ib-pulse{width:10px;height:10px;border-radius:50%;background:var(--neon);flex-shrink:0;
  box-shadow:0 0 0 0 rgba(0,255,179,.6);animation:hb 1.5s ease-in-out infinite}
.ib-title{font-size:13px;font-weight:700;color:#fff;flex:1}
.ib-step{font-size:10px;font-family:var(--mono);color:var(--neon)}
.ib-body{padding:12px 18px 14px}
.ib-bar-wrap{height:6px;background:var(--s3);border-radius:3px;overflow:hidden;margin-bottom:8px}
.ib-bar{height:100%;background:linear-gradient(90deg,#009966,var(--neon));border-radius:3px;
  transition:width .8s cubic-bezier(.4,0,.2,1);width:0%}
.ib-info{display:flex;justify-content:space-between;align-items:center}
.ib-label{font-size:11px;font-family:var(--mono);color:var(--text)}
.ib-pct{font-size:22px;font-weight:700;font-family:var(--mono);color:var(--neon)}
.ib-steps{display:flex;gap:4px;margin-top:8px;flex-wrap:wrap}
.ib-dot{width:18px;height:4px;border-radius:2px;background:var(--s3);transition:background .4s}
.ib-dot.done{background:var(--neon)}.ib-dot.curr{background:var(--yellow);animation:pulse-bar 1s ease infinite}
@keyframes pulse-bar{0%,100%{opacity:1}50%{opacity:.4}}
footer{text-align:center;padding:12px 0 18px;font-size:10px;color:var(--muted2);
  font-family:var(--mono);border-top:1px solid var(--br);margin-top:4px}
::-webkit-scrollbar{width:4px;height:4px}
::-webkit-scrollbar-thumb{background:var(--muted2);border-radius:2px}
.card,.ms{animation:up .35s ease both}
@keyframes up{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.ms:nth-child(1){animation-delay:.04s}.ms:nth-child(2){animation-delay:.08s}
.ms:nth-child(3){animation-delay:.12s}.ms:nth-child(4){animation-delay:.16s}
</style></head><body>

<nav>
  <div class="nav-l">
    <div class="pulse" id="lp"></div>
    <div class="brand">IA <b>LOCAL</b></div>
    <div class="nav-chips">
      <span class="chip live">LIVE</span>
      <span class="chip" id="ch">—</span>
      <span class="chip" id="cu">—</span>
    </div>
  </div>
  <div class="nav-r">
    <div id="ntime" style="font-family:var(--mono);font-size:12px;color:var(--muted)">—</div>
  </div>
</nav>

<!-- ═══ BANNIÈRE INSTALLATION EN COURS ═══ -->
<div id="install-banner">
  <div class="ib-top">
    <div class="ib-pulse"></div>
    <div class="ib-title">⚙️ Installation en cours…</div>
    <div class="ib-step" id="ib-step">Étape — / —</div>
  </div>
  <div class="ib-body">
    <div class="ib-bar-wrap"><div class="ib-bar" id="ib-bar"></div></div>
    <div class="ib-info">
      <div class="ib-label" id="ib-label">Initialisation…</div>
      <div class="ib-pct"><span id="ib-pct">0</span>%</div>
    </div>
    <div class="ib-steps" id="ib-dots"></div>
  </div>
</div>


<!-- TABS -->
<div class="tabs">
  <div class="tab active" id="tab-stats" onclick="switchTab('stats')">
    <span class="tic">📊</span> Statistiques
  </div>
  <div class="tab" id="tab-admin" onclick="switchTab('admin')">
    <span class="tic">⚙️</span> Administration
    <span class="tab-lock" id="tab-lock">🔒</span>
  </div>
</div>

<!-- ═══ STATS PANEL ═══ -->
<div class="panel active" id="p-stats">
<main>
<div id="rt">
  <div class="ms"><div class="mi" style="background:rgba(0,255,179,.08)">🖥️</div><div><div class="ml">CPU</div><div class="mv"><span id="mt-cpu">—</span><span style="font-size:13px;color:var(--muted)">%</span></div><div class="msb" id="mt-cpu-s">—</div></div></div>
  <div class="ms"><div class="mi" style="background:rgba(77,159,255,.08)">💾</div><div><div class="ml">RAM</div><div class="mv" id="mt-ram">—</div><div class="msb" id="mt-ram-s">—</div></div></div>
  <div class="ms"><div class="mi" style="background:rgba(168,85,247,.08)">⚡</div><div><div class="ml">GPU</div><div class="mv" id="mt-gpu">—</div><div class="msb" id="mt-gpu-s">—</div></div></div>
  <div class="ms"><div class="mi" style="background:rgba(249,115,22,.08)">🌐</div><div><div class="ml">Réseau</div><div class="mv" id="mt-net">—</div><div class="msb" id="mt-net-s">—</div></div></div>
</div>
<div class="card" id="cc">
  <div class="ch"><div class="ct"><span>🖥️</span>PROCESSEUR</div><span id="cb" class="badge bok">OK</span></div>
  <div class="gw">
    <svg class="gsvg" width="100" height="100" viewBox="0 0 110 110">
      <circle class="gtrack" cx="55" cy="55" r="42" stroke-dasharray="226" stroke-dashoffset="56"/>
      <circle class="gfill" cx="55" cy="55" r="42" id="cg-g" stroke="var(--neon)" stroke-dasharray="226" stroke-dashoffset="226" transform="rotate(-210 55 55)"/>
      <text class="gpc" x="55" y="51" id="cg-p">0%</text><text class="gu" x="55" y="65">CPU</text>
    </svg>
    <div class="gi"><div class="gbig" id="cf">—<span> MHz</span></div><div class="gsub" id="ct2">—</div><div class="gsub" style="margin-top:5px;font-size:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:190px" id="cm2">—</div></div>
  </div>
  <div class="sw"><svg id="spc" viewBox="0 0 300 48" preserveAspectRatio="none"><defs><linearGradient id="gn" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#00ffb3" stop-opacity=".5"/><stop offset="100%" stop-color="#00ffb3" stop-opacity="0"/></linearGradient></defs><path class="sa" fill="url(#gn)" id="spc-a" d=""/><path class="sl" stroke="var(--neon)" id="spc-l" d=""/></svg></div>
  <div class="cg2" id="cores"></div>
</div>
<div class="card" id="cm">
  <div class="ch"><div class="ct"><span>💾</span>MÉMOIRE</div><span id="rb" class="badge bok">OK</span></div>
  <div class="gw">
    <svg class="gsvg" width="100" height="100" viewBox="0 0 110 110">
      <circle class="gtrack" cx="55" cy="55" r="42" stroke-dasharray="226" stroke-dashoffset="56"/>
      <circle class="gfill" cx="55" cy="55" r="42" id="rg-g" stroke="var(--blue)" stroke-dasharray="226" stroke-dashoffset="226" transform="rotate(-210 55 55)"/>
      <text class="gpc" x="55" y="51" id="rg-p">0%</text><text class="gu" x="55" y="65">RAM</text>
    </svg>
    <div class="gi"><div class="gbig" id="ru">—<span> Mo</span></div><div class="gsub" id="rt2">—</div></div>
  </div>
  <div class="bg"><div class="br_"><span>RAM</span><span id="rpl">—%</span></div><div class="bt"><div class="bf fb" id="rb_" style="width:0%"></div></div></div>
  <div class="bg"><div class="br_"><span>Swap</span><span id="spl">—%</span></div><div class="bt"><div class="bf fp" id="sb_" style="width:0%"></div></div></div>
  <div class="sw"><svg id="spr" viewBox="0 0 300 48" preserveAspectRatio="none"><defs><linearGradient id="gb" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#4d9fff" stop-opacity=".5"/><stop offset="100%" stop-color="#4d9fff" stop-opacity="0"/></linearGradient></defs><path class="sa" fill="url(#gb)" id="spr-a" d=""/><path class="sl" stroke="var(--blue)" id="spr-l" d=""/></svg></div>
</div>
<div class="card" id="cg"><div class="ch"><div class="ct"><span>⚡</span>GPU</div><span id="gpb" class="badge bwn">—</span></div><div id="gpd"><div style="color:var(--muted);font-size:12px;padding:16px 0">Détection...</div></div></div>
<div class="card" id="cs">
  <div class="ch"><div class="ct"><span>🔧</span>SERVICES</div></div>
  <div class="sl2">
    <div class="sr"><div class="sd" id="do"></div><div class="sb"><div class="sn">Ollama</div><div class="sm" id="mo">—</div><div class="mp" id="mw"></div></div><a class="slink" id="lo" href="#" target="_blank">API ↗</a></div>
    <div class="sr"><div class="sd" id="dw"></div><div class="sb"><div class="sn">Open WebUI</div><div class="sm" id="mw2">—</div></div><a class="slink" id="lw" href="#" target="_blank">↗</a></div>
    <div class="sr"><div class="sd" id="dd"></div><div class="sb"><div class="sn">Docker</div><div class="sm" id="md">—</div></div></div>
  </div>
</div>
<div class="card" id="cn">
  <div class="ch"><div class="ct"><span>🌐</span>RÉSEAU</div></div>
  <div class="ni2"><div>Iface <span id="ni">—</span></div><div>IP <span id="nip">—</span></div></div>
  <div class="nt">
    <div class="nb"><div class="nd">↓ Réception</div><div><span class="nv" id="nrx">—</span><span class="nu" id="nrxu">Ko/s</span></div><div class="ntot" id="nrxt">—</div></div>
    <div class="nb"><div class="nd">↑ Émission</div><div><span class="nv" id="ntx">—</span><span class="nu" id="ntxu">Ko/s</span></div><div class="ntot" id="ntxt">—</div></div>
  </div>
  <div class="sw"><svg id="spn" viewBox="0 0 300 48" preserveAspectRatio="none"><defs><linearGradient id="go" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#f97316" stop-opacity=".4"/><stop offset="100%" stop-color="#f97316" stop-opacity="0"/></linearGradient></defs><path class="sa" fill="url(#go)" id="spn-a" d=""/><path class="sl" stroke="var(--orange)" id="spn-l" d=""/><path class="sl" stroke="var(--yellow)" stroke-dasharray="4,3" id="spn-t" d=""/></svg></div>
</div>
<div class="card" id="cd"><div class="ch"><div class="ct"><span>💿</span>STOCKAGE</div></div><div class="dl" id="dl2"></div></div>
</main>
</div><!-- /#p-stats -->

<!-- ═══ ADMIN PANEL ═══ -->
<div class="panel" id="p-admin">

  <!-- Login -->
  <div id="adm-login">
    <div class="login-box">
      <div class="login-title">⚙️ Administration</div>
      <div class="login-sub">Connectez-vous pour accéder au panneau</div>
      <div class="lf-label">Identifiant</div>
      <input class="lf-input" id="adm-user" type="text" placeholder="admin" autocomplete="username">
      <div class="lf-label">Mot de passe</div>
      <input class="lf-input" id="adm-pass" type="password" placeholder="••••••••" autocomplete="current-password"
        onkeydown="if(event.key==='Enter')doLogin()">
      <button class="lf-btn" onclick="doLogin()">Connexion</button>
      <div class="lf-err" id="lf-err"></div>
    </div>
  </div>

  <!-- Content (hidden until auth) -->
  <div id="adm-content" style="display:none">
    <!-- Alerte mot de passe par défaut -->
    <div id="adm-pw-alert" style="display:none;background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.4);
      border-radius:10px;padding:12px 18px;margin:0 0 14px;color:var(--red);font-size:13px;
      display:flex;align-items:center;gap:10px">
      <span style="font-size:20px">⚠️</span>
      <span><strong>Mot de passe par défaut non changé !</strong>
      Allez dans <strong>🔐 Paramètres</strong> pour le modifier dès maintenant.</span>
    </div>
    <div class="adm-head">
      <div class="adm-title">Administration système</div>
      <div style="display:flex;align-items:center;gap:10px">
        <span class="adm-user" id="adm-username">—</span>
        <button class="btn-logout" onclick="doLogout()">Déconnexion</button>
      </div>
    </div>

    <!-- Sub-tabs -->
    <div class="atabs">
      <div class="atab active" data-s="svcs" onclick="aTab(this)">⚙️ Services</div>
      <div class="atab" data-s="upd"  onclick="aTab(this)">🔄 Mises à jour</div>
      <div class="atab" data-s="mdl"  onclick="aTab(this)">🧠 Modèles</div>
      <div class="atab" data-s="logs" onclick="aTab(this)">📋 Logs</div>
      <div class="atab" data-s="inst" onclick="aTab(this)">🚀 Installation</div>
      <div class="atab" data-s="sys"  onclick="aTab(this)">🖥️ Système</div>
      <div class="atab" data-s="set"  onclick="aTab(this)">🔐 Paramètres</div>
    </div>

    <!-- SERVICES -->
    <div class="asect active" id="as-svcs">
      <div class="svc-grid" id="adm-svc-grid"></div>
    </div>

    <!-- MISES À JOUR -->
    <div class="asect" id="as-upd">
      <div class="upd-row">
        <div class="upd-ico">🦙</div>
        <div class="upd-body"><div class="upd-name">Ollama</div><div class="upd-desc">Script officiel — dernière version stable</div></div>
        <button class="btn-upd" onclick="doUpd('ollama',this)">Mettre à jour</button>
      </div>
      <div class="upd-row">
        <div class="upd-ico">🐋</div>
        <div class="upd-body"><div class="upd-name">Open WebUI</div><div class="upd-desc">Pull dernière image Docker + recréation container</div></div>
        <button class="btn-upd" onclick="doUpd('webui',this)">Mettre à jour</button>
      </div>
      <div class="upd-row">
        <div class="upd-ico">🐧</div>
        <div class="upd-body"><div class="upd-name">Système</div><div class="upd-desc">apt / dnf / pacman — mise à jour complète</div></div>
        <button class="btn-upd" onclick="doUpd('system',this)">Mettre à jour</button>
      </div>
      <div class="upd-out" id="upd-out"></div>
    </div>

    <!-- MODÈLES -->
    <div class="asect" id="as-mdl">
      <div class="acard">
        <div class="acard-t">Télécharger un modèle</div>
        <div class="model-pull">
          <input class="mp-in" id="pull-nm" placeholder="llama3.2:3b · mistral · gemma2:9b · deepseek-r1:7b"
            onkeydown="if(event.key==='Enter')doPull()">
          <button class="btn-pull" onclick="doPull()">Pull</button>
        </div>
        <div style="font-size:10px;color:var(--muted);font-family:var(--mono)">Téléchargement en arrière-plan — rafraîchissez dans quelques minutes.</div>
      </div>
      <div class="acard">
        <div class="acard-t" style="display:flex;justify-content:space-between">
          <span>Modèles installés</span>
          <span id="mdl-count" style="color:var(--neon)"></span>
        </div>
        <div class="model-grid" id="mdl-grid"><div style="color:var(--muted);font-size:12px">Chargement…</div></div>
      </div>
    </div>

    <!-- LOGS -->
    <div class="asect" id="as-logs">
      <div class="acard">
        <div class="log-bar">
          <select class="log-sel" id="log-src" onchange="loadLogs()">
            <option value="ollama">Ollama</option>
            <option value="webui">Open WebUI</option>
            <option value="docker">Docker</option>
            <option value="dashboard">Dashboard</option>
            <option value="syslog">Syslog</option>
            <option value="kernel">Kernel</option>
          </select>
          <select class="log-sel" style="width:80px" id="log-n" onchange="loadLogs()">
            <option value="50">50</option><option value="100" selected>100</option>
            <option value="200">200</option><option value="500">500</option>
          </select>
          <button class="btn-ref" onclick="loadLogs()">↻ Refresh</button>
          <span style="font-size:10px;font-family:var(--mono);color:var(--muted)">Auto 10s</span>
        </div>
        <div class="log-box" id="log-box"></div>
      </div>
    </div>

    <!-- INSTALLATION -->
    <div class="asect" id="as-inst">
      <div class="acard" style="margin-bottom:16px">
        <div class="acard-t">🚀 Lancer l'installation complète</div>
        <p style="color:var(--muted);font-size:13px;margin:8px 0 16px">
          Lance le script d'installation en arrière-plan. La progression s'affiche en temps réel dans le Tableau de bord.
        </p>
        <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">
          <button class="btn-upd" style="background:var(--neon);color:#000;font-weight:700;font-size:14px;padding:10px 24px"
            onclick="doInstall()">🚀 Démarrer l'installation</button>
          <button class="btn-upd" style="background:var(--purple);padding:10px 16px"
            onclick="checkInstallStatus()">🔄 État</button>
        </div>
        <div style="margin-top:12px">
          <div style="font-size:10px;color:var(--muted);font-family:var(--mono);margin-bottom:5px">
            Chemin du script (si introuvable automatiquement) :
          </div>
          <div style="display:flex;gap:8px">
            <input id="script-path-in" class="lf-input" style="flex:1;margin:0;font-size:11px"
              placeholder="/root/install_ia_local.sh"
              value="">
            <button class="btn-s btn-go" style="padding:8px 14px;font-size:11px"
              onclick="saveScriptPath()">Enregistrer</button>
          </div>
        </div>
        <div id="inst-out" style="margin-top:10px;font-family:var(--mono);font-size:12px;color:var(--neon);min-height:20px"></div>
      </div>
      <div class="acard" id="inst-progress-sec" style="display:none">
        <div class="acard-t">📊 Progression en temps réel</div>
        <div id="inst-progress" style="margin-top:10px;color:var(--muted);font-size:13px"></div>
      </div>
      <div class="acard" id="inst-log-sec" style="display:none">
        <div class="acard-t">📋 Log d'installation</div>
        <button class="btn-ref" onclick="loadInstallLog()" style="margin-bottom:8px">↻ Rafraîchir</button>
        <pre id="inst-log" style="background:#0a0a0a;border:1px solid var(--border);border-radius:6px;
          padding:12px;font-size:11px;color:#888;max-height:220px;overflow-y:auto;white-space:pre-wrap;margin:0"></pre>
      </div>
    </div>

    <!-- SYSTÈME -->
    <div class="asect" id="as-sys">
      <div class="acard" style="margin-bottom:14px">
        <div class="acard-t">🖥️ Contrôle de la machine</div>
        <p style="color:var(--muted);font-size:12px;margin:6px 0 14px">
          Actions système — confirmation demandée avant exécution.</p>
        <div style="display:flex;gap:10px;flex-wrap:wrap">
          <button class="btn-upd" style="background:rgba(234,179,8,.1);color:var(--yellow);border:1px solid rgba(234,179,8,.3);padding:10px 18px"
            onclick="sysDo('reboot')">🔄 Redémarrer</button>
          <button class="btn-upd" style="background:rgba(239,68,68,.1);color:var(--red);border:1px solid rgba(239,68,68,.3);padding:10px 18px"
            onclick="sysDo('shutdown')">⏻ Éteindre</button>
          <button class="btn-upd" style="background:rgba(77,159,255,.1);color:var(--blue);border:1px solid rgba(77,159,255,.3);padding:10px 18px"
            onclick="sysDo('update_system')">📦 Mettre à jour le système</button>
        </div>
        <div id="sys-result" style="margin-top:12px;font-size:13px;font-family:var(--mono);color:var(--neon);min-height:18px"></div>
      </div>
      <div class="acard">
        <div class="acard-t">ℹ️ Informations système</div>
        <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:8px;margin-top:10px" id="adm-sysinfo2"></div>
      </div>
    </div>

    <!-- PARAMÈTRES -->
    <div class="asect" id="as-set">
      <div class="acard">
        <div class="acard-t">Changer les identifiants</div>
        <div class="sfield"><div class="sf-label">Utilisateur</div><input class="sf-in" id="new-user" type="text" placeholder="admin"></div>
        <div class="sfield"><div class="sf-label">Mot de passe actuel</div><input class="sf-in" id="old-pw" type="password" placeholder="••••••••"></div>
        <div class="sfield"><div class="sf-label">Nouveau mdp</div><input class="sf-in" id="new-pw" type="password" placeholder="6 caractères minimum"></div>
        <div class="sfield"><div class="sf-label">Confirmation</div><input class="sf-in" id="conf-pw" type="password" placeholder="Répéter"></div>
        <button class="btn-save" onclick="changePw()">Enregistrer</button>
      </div>
    </div>
  </div><!-- /#adm-content -->
</div><!-- /#p-admin -->

<footer>IA Local · Port <strong>__PORT__</strong> · Stats 2s · <span id="ft">—</span></footer>
<div id="toast"></div>

<script>
// ── Tab navigation ────────────────────────────────────────────────────────
let activeTab='stats';
function switchTab(t){
  activeTab=t;
  document.querySelectorAll('.tab').forEach(e=>e.classList.remove('active'));
  document.querySelectorAll('.panel').forEach(e=>e.classList.remove('active'));
  document.getElementById('tab-'+t).classList.add('active');
  document.getElementById('p-'+t).classList.add('active');
  if(t==='admin' && !_admAuth) document.getElementById('adm-user').focus();
  if(t==='admin' && _admAuth) admLoadStatus();
}
function aTab(el){
  document.querySelectorAll('.atab').forEach(e=>e.classList.remove('active'));
  document.querySelectorAll('.asect').forEach(e=>e.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('as-'+el.dataset.s).classList.add('active');
  if(el.dataset.s==='mdl') loadModels();
  if(el.dataset.s==='logs') loadLogs();
}

// ── Toast ─────────────────────────────────────────────────────────────────
let _tt;
function toast(msg,type='ok'){
  const e=document.getElementById('toast');
  e.textContent=msg; e.className='show '+type;
  clearTimeout(_tt); _tt=setTimeout(()=>e.className='',4000);
}

// ── Helpers ───────────────────────────────────────────────────────────────
function st(id,v){const e=document.getElementById(id);if(e)e.textContent=v}
function setDot(id,on){const e=document.getElementById(id);if(e)e.className='sd '+(on?'on':'off')}
const pCol=p=>p>=85?'var(--red)':p>=65?'var(--yellow)':'var(--neon)';
const fCls=p=>p>=85?'fr':p>=65?'fy':'fn';
const bCls=p=>p>=85?'badge bct':p>=65?'badge bwn':'badge bok';
const bTxt=p=>p>=85?'CRITIQUE':p>=65?'ÉLEVÉ':'OK';
function fKB(kb){if(kb>=1024*100)return{v:(kb/1024/1024).toFixed(2),u:'Go/s'};if(kb>=1024)return{v:(kb/1024).toFixed(1),u:'Mo/s'};return{v:kb,u:'Ko/s'}}
function fMB(mb){return mb>=1024?(mb/1024).toFixed(1)+' Go':mb+' Mo'}
function setBar(id,p){const e=document.getElementById(id);if(!e)return;e.style.width=p+'%';e.className='bf '+fCls(p)}
function sBdg(id,p,lbl=null){const e=document.getElementById(id);if(!e)return;e.className=bCls(p);e.textContent=lbl||bTxt(p)}

// ── Sparklines ────────────────────────────────────────────────────────────
const N=60,H={cpu:[],ram:[],rx:[],tx:[]};
const push=(k,v)=>{H[k].push(v);if(H[k].length>N)H[k].shift()};
function spPaths(d,w=300,h=48,mx=null){
  if(d.length<2)return{l:'',a:''};
  const M=mx??Math.max(...d,1),step=w/(N-1);
  const pad=Array(N-d.length).fill(0).concat(d);
  const pts=pad.map((v,i)=>[i*step,h-(v/M)*(h*.88)-h*.06]);
  const l=pts.map((p,i)=>(i===0?`M${p[0].toFixed(1)},${p[1].toFixed(1)}`:`L${p[0].toFixed(1)},${p[1].toFixed(1)}`)).join('');
  return{l,a:l+` L${pts[pts.length-1][0].toFixed(1)},${h} L0,${h} Z`};
}
function setSp(li,ai,d,mx=null){const{l,a}=spPaths(d,300,48,mx);const le=document.getElementById(li),ae=ai?document.getElementById(ai):null;if(le)le.setAttribute('d',l);if(ae)ae.setAttribute('d',a)}

// ── Gauge ─────────────────────────────────────────────────────────────────
const CIRC=2*Math.PI*42,ARC=CIRC*(240/360);
function setG(id,pct,col){const e=document.getElementById(id);if(!e)return;const off=ARC-(pct/100)*ARC;e.style.strokeDasharray=`${ARC} ${CIRC-ARC}`;e.style.strokeDashoffset=off;e.style.stroke=col}

// ── Stats update ──────────────────────────────────────────────────────────
function update(d){
  if(!d)return;
  updateBanner(d.install_progress||null);
  st('ch',d.hostname||'—');st('cu',d.uptime?.human||'—');
  const cpu=d.cpu||{},cp=cpu.pct||0; push('cpu',cp);
  st('mt-cpu',Math.round(cp));st('mt-cpu-s',`${cpu.freq_mhz>0?cpu.freq_mhz:'N/A'} MHz · ${cpu.temp_c?cpu.temp_c+'°C':'N/A'}`);
  st('cg-p',Math.round(cp)+'%');setG('cg-g',cp,pCol(cp));
  st('cf',cpu.freq_mhz>0?cpu.freq_mhz:'N/A');st('ct2',cpu.temp_c?`Temp: ${cpu.temp_c}°C`:'Temp: N/A');st('cm2',cpu.model||'—');
  sBdg('cb',cp);setSp('spc-l','spc-a',H.cpu,100);
  const cg=document.getElementById('cores');
  if(cpu.cores?.length)cg.innerHTML=cpu.cores.map(c=>{const p=Math.round(c.pct||0);return`<div class="ci"><div class="cin">${c.name.replace('cpu','c')}</div><div class="civ" style="color:${pCol(p)}">${p}%</div><div class="cib"><div class="cif" style="width:${p}%;background:${pCol(p)}"></div></div></div>`}).join('');
  const mem=d.memory||{},rp=mem.ram_pct||0; push('ram',rp);
  st('mt-ram',fMB(mem.ram_used_mb||0));st('mt-ram-s',`${fMB(mem.ram_used_mb||0)} / ${fMB(mem.ram_total_mb||0)}`);
  st('rg-p',Math.round(rp)+'%');setG('rg-g',rp,pCol(rp));
  st('ru',fMB(mem.ram_used_mb||0));st('rt2',`/ ${fMB(mem.ram_total_mb||0)} total`);
  st('rpl',(rp||0).toFixed(1)+'%');st('spl',(mem.swap_pct||0).toFixed(1)+'%');
  setBar('rb_',rp);setBar('sb_',mem.swap_pct||0);sBdg('rb',rp);setSp('spr-l','spr-a',H.ram,100);
  const gpu=d.gpu||{},gd=document.getElementById('gpd');
  if(gpu.available){
    const gp=gpu.util_pct||0,mp=gpu.mem_pct||0,tp=gpu.temp_c||0;
    sBdg('gpb',gp,gpu.name?.split(' ')[0]||'GPU');st('mt-gpu',Math.round(gp)+'%');st('mt-gpu-s',`VRAM ${fMB(gpu.mem_used_mb||0)} · ${tp}°C`);
    gd.innerHTML=`<div style="font-size:11px;color:var(--muted);font-family:var(--mono);margin-bottom:10px">${gpu.name||'GPU'}</div><div class="gg"><div class="gb"><div class="gbl">Utilisation</div><div class="gbv" style="color:${pCol(gp)}">${Math.round(gp)}<span style="font-size:13px;color:var(--muted)">%</span></div><div class="bg" style="margin-top:5px"><div class="bt"><div class="bf ${fCls(gp)}" style="width:${gp}%"></div></div></div></div><div class="gb"><div class="gbl">Température</div><div class="gbv" style="color:${tp>=80?'var(--red)':tp>=70?'var(--yellow)':'var(--neon)'}">${tp}<span style="font-size:12px;color:var(--muted)">°C</span></div></div><div class="gb"><div class="gbl">VRAM</div><div class="gbv" style="color:var(--purple);font-size:15px">${fMB(gpu.mem_used_mb||0)}<span style="font-size:9px;color:var(--muted)"> / ${fMB(gpu.mem_total_mb||0)}</span></div><div class="bg" style="margin-top:5px"><div class="bt"><div class="bf fp" style="width:${mp}%"></div></div></div></div><div class="gb"><div class="gbl">Puissance</div><div class="gbv" style="font-size:15px">${Math.round(gpu.power_w||0)}<span style="font-size:10px;color:var(--muted)"> W</span></div>${gpu.power_limit_w?`<div style="font-size:9px;color:var(--muted);font-family:var(--mono);margin-top:2px">/ ${Math.round(gpu.power_limit_w)} W max</div>`:''}</div></div>`;
  }else{document.getElementById('gpb').textContent='N/A';document.getElementById('gpb').className='badge bwn';st('mt-gpu','N/A');st('mt-gpu-s','CPU only');gd.innerHTML='<div style="color:var(--muted);font-size:12px;padding:16px 0">Aucun GPU dédié</div>'}
  const svc=d.services||{};
  setDot('do',svc.ollama?.active);setDot('dw',svc.webui?.active);setDot('dd',svc.docker?.active);
  const ou=svc.ollama?.url||'http://localhost:11434',wu=svc.webui?.url||'http://localhost:8080';
  const lo=document.getElementById('lo'),lw=document.getElementById('lw');
  if(lo)lo.href=ou;if(lw)lw.href=wu;
  st('mo',svc.ollama?.active?`${svc.ollama.model_count||0} modèle(s) · ${ou}`:'Arrêté');
  st('mw2',svc.webui?.active?svc.webui.status||'actif':'Container arrêté');
  st('md',svc.docker?.active?`${svc.docker.containers||0} container(s)`:'Arrêté');
  const mw=document.getElementById('mw'),ms=svc.ollama?.models||[];
  if(mw)mw.innerHTML=ms.slice(0,6).map(m=>`<span class="mtag">${m.split(':')[0]}</span>`).join('')+(ms.length>6?`<span class="mtag" style="opacity:.5">+${ms.length-6}</span>`:'');
  const net=d.network||{};st('ni',net.default_iface||'—');st('nip',net.local_ip||'—');
  const iface=(net.interfaces||[]).find(i=>i.name===net.default_iface)||(net.interfaces||[])[0];
  if(iface){
    const rx=fKB(iface.rx_kb_s||0),tx=fKB(iface.tx_kb_s||0);
    push('rx',iface.rx_kb_s||0);push('tx',iface.tx_kb_s||0);
    st('nrx',rx.v);st('nrxu',rx.u);st('ntx',tx.v);st('ntxu',tx.u);
    st('nrxt',`Total: ${iface.rx_total_mb} Mo`);st('ntxt',`Total: ${iface.tx_total_mb} Mo`);
    st('mt-net',rx.v+' '+rx.u);st('mt-net-s',`↓ ${rx.v}${rx.u} · ↑ ${tx.v}${tx.u}`);
    const nm=Math.max(...H.rx,...H.tx,1);setSp('spn-l','spn-a',H.rx,nm);setSp('spn-t',null,H.tx,nm);
  }
  const dl=document.getElementById('dl2');
  if(dl)dl.innerHTML=(d.disks||[]).map(dk=>{const p=dk.pct||0;const io=(dk.read_kb_s!=null)?`R: ${fKB(dk.read_kb_s).v}${fKB(dk.read_kb_s).u} · W: ${fKB(dk.write_kb_s||0).v}${fKB(dk.write_kb_s||0).u}`:'';return`<div class="dr"><div class="dh"><div><div class="dd">${dk.device.replace('/dev/','')}</div><div class="dm">${dk.mount}</div></div><span class="${bCls(p)}">${bTxt(p)}</span></div><div style="display:flex;justify-content:space-between;font-size:10px;color:var(--muted);font-family:var(--mono);margin-bottom:4px"><span>${fMB(dk.used_mb)} utilisé</span><span>${p}%</span></div><div class="bt"><div class="bf ${fCls(p)}" style="width:${p}%"></div></div><div class="dns"><span>Libre: ${fMB(dk.avail_mb)}</span><span>Total: ${fMB(dk.size_mb)}</span></div>${io?`<div class="dio">${io}</div>`:''}</div>`;}).join('');
}


// ── Bannière installation ─────────────────────────────────────────────────
function updateBanner(prog){
  const bEl=document.getElementById('install-banner');
  if(!prog||!prog.active){bEl.style.display='none';return}
  bEl.style.display='block';
  const pct=prog.pct||0;
  document.getElementById('ib-bar').style.width=pct+'%';
  document.getElementById('ib-pct').textContent=pct;
  document.getElementById('ib-label').textContent=prog.label||(prog.step_desc||prog.step_name||'Installation…');
  const sc=prog.step_current||0,st=prog.step_total||0;
  document.getElementById('ib-step').textContent=st?`Étape ${sc}/${st}`:'';
  // Points de progression
  const dotsEl=document.getElementById('ib-dots');
  if(prog.plan&&prog.plan.length){
    dotsEl.innerHTML=prog.plan.map((_,i)=>{
      const cls=i<sc-1?'ib-dot done':i===sc-1?'ib-dot curr':'ib-dot';
      return`<div class="${cls}" title="${prog.plan[i]}"></div>`;
    }).join('');
  }
}

// ── Stats polling ─────────────────────────────────────────────────────────
let _errs=0;
async function pollStats(){
  try{
    const r=await fetch('/api/stats');
    if(!r.ok)throw new Error(r.status);
    const d=await r.json();
    if(d&&Object.keys(d).length>1){  // cache rempli (plus que {ts:...})
      update(d);_errs=0;
      document.getElementById('lp').style.background='var(--neon)';
    }
  }catch(e){
    _errs++;
    document.getElementById('lp').style.background=_errs>3?'var(--red)':'var(--yellow)';
  }
}

// ── Clock ─────────────────────────────────────────────────────────────────
function clk(){const t=new Date().toLocaleTimeString('fr-FR');st('ntime',t);st('ft',t)}
setInterval(clk,1000);clk();

// ══════════════════════════════════════════════════════════════════════════
// ADMIN
// ══════════════════════════════════════════════════════════════════════════
let _admAuth=false, _admUser='';

async function _aapi(ep,body={}){
  try{
    const r=await fetch(ep,{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify(body)
    });
    if(!r.ok) return {ok:false,msg:'HTTP '+r.status};
    return await r.json();
  }catch(e){
    console.warn('[api]',ep,e.message);
    return {ok:false,msg:'Réseau: '+e.message};
  }
}

// Login
async function doLogin(){
  const u=document.getElementById('adm-user').value.trim();
  const p=document.getElementById('adm-pass').value;
  document.getElementById('lf-err').textContent='';
  const d=await _aapi('/api/admin/login',{user:u,pass:p});
  if(d?.ok){
    _admAuth=true;_admUser=u;
    document.getElementById('adm-login').style.display='none';
    document.getElementById('adm-content').style.display='block';
    document.getElementById('adm-username').textContent=u;
    document.getElementById('tab-lock').textContent='🔓';
    admLoadStatus();
  }else{
    document.getElementById('lf-err').textContent=d?.msg||'Identifiants incorrects';
  }
}

function doLogout(){
  _admAuth=false;
  document.getElementById('adm-login').style.display='flex';
  document.getElementById('adm-content').style.display='none';
  document.getElementById('adm-pass').value='';
  document.getElementById('tab-lock').textContent='🔒';
  _aapi('/api/admin/logout');
}

// Services admin
async function admLoadStatus(){
  const d=await _aapi('/api/admin/status');
  if(!d||!d.ok) return;
  const s=d.data||{};
  const SVCS=[
    {k:'ollama',    ic:'🦙',nm:'Ollama'},
    {k:'webui',     ic:'🖥️',nm:'Open WebUI'},
    {k:'docker',    ic:'🐋',nm:'Docker'},
    {k:'dashboard', ic:'📊',nm:'Dashboard'},
  ];
  document.getElementById('adm-svc-grid').innerHTML=SVCS.map(({k,ic,nm})=>{
    const sv=s.services?.[k]||{};const on=sv.active;
    const mt=[sv.version?`v${sv.version}`:null].filter(Boolean).join(' ')|| (on?'actif':'arrêté');
    const lnk=sv.url?`<a class="btn-s btn-lnk" href="${sv.url}" target="_blank">↗</a>`:'';
    return`<div class="svc-card"><div class="svc-hd"><div class="sled ${on?'on':'off'}"></div><div class="svc-nm">${ic} ${nm}</div></div><div class="svc-mt">${mt}</div><div class="svc-bts"><button class="btn-s btn-go" onclick="svcAct('${k}','start')">Démarrer</button><button class="btn-s btn-stop" onclick="svcAct('${k}','stop')">Arrêter</button><button class="btn-s btn-re" onclick="svcAct('${k}','restart')">Redémarrer</button>${lnk}</div></div>`;
  }).join('');
  // Afficher/cacher l'alerte mot de passe par défaut
  const pwAlert=document.getElementById('adm-pw-alert');
  if(pwAlert) pwAlert.style.display=s.is_default_password?'flex':'none';
  // Infos système (onglet Système)
  const sysInfo=[
    {k:'Hôte',    v:s.hostname||'—'},
    {k:'Uptime',  v:s.uptime||'—'},
    {k:'Disque',  v:s.disk||'—'},
    {k:'Modèles', v:(s.models?.length||0)+' installé(s)'},
    {k:'Admin',   v:s.admin_user||'admin'},
    {k:'MDP',     v:s.is_default_password?'⚠ Défaut':'✓ Personnalisé'},
  ];
  const sysEl=document.getElementById('adm-sysinfo2')||document.getElementById('adm-sysinfo');
  if(sysEl) sysEl.innerHTML=sysInfo.map(i=>`<div style="background:var(--s2);border:1px solid var(--br);border-radius:8px;padding:9px 12px"><div style="font-size:9px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin-bottom:3px">${i.k}</div><div style="font-size:12px;font-family:var(--mono);color:${i.k==='MDP'&&i.v.includes('⚠')?'var(--red)':'#fff'}">${i.v}</div></div>`).join('');
}

async function svcAct(svc,act){
  toast(`${act} ${svc}…`,'inf');
  const d=await _aapi('/api/admin/service',{action:act,service:svc});
  toast(d?.msg||(d?.ok?'OK':'Erreur'),d?.ok?'ok':'err');
  setTimeout(admLoadStatus,1500);
}

// Updates
async function doUpd(t,btn){
  btn.disabled=true;btn.innerHTML='<span class="spin"></span>En cours…';
  const out=document.getElementById('upd-out');
  out.style.display='block';out.textContent='Mise à jour en cours, patientez…';
  const d=await _aapi('/api/admin/update',{target:t});
  colorLog2(out,d?.msg||'');
  toast(d?.ok?'Mise à jour terminée ✓':'Erreur lors de la MAJ',d?.ok?'ok':'err');
  btn.disabled=false;btn.textContent='Mettre à jour';
}

// Models
async function loadModels(){
  const g=document.getElementById('mdl-grid');g.innerHTML='<div style="color:var(--muted);font-size:12px">Chargement…</div>';
  const d=await _aapi('/api/admin/models',{action:'list'});
  const ms=d?.models||[];
  st('mdl-count',ms.length?`${ms.length} modèle(s)`:'');
  if(!ms.length){g.innerHTML='<div style="color:var(--muted);font-size:12px;padding:12px 0">Aucun modèle installé</div>';return}
  g.innerHTML=ms.map(m=>{const nm=m.name||m;const sz=m.size?(m.size/1e9).toFixed(1)+' Go':'?';return`<div class="mc"><div class="mc-ico">🧠</div><div class="mc-b"><div class="mc-n">${nm}</div><div class="mc-s">${sz}</div></div><button class="mc-del" onclick="delMdl('${nm}',this)">Suppr.</button></div>`}).join('');
}

async function doPull(){
  const nm=document.getElementById('pull-nm').value.trim();if(!nm)return;
  toast(`Pull ${nm} lancé…`,'inf');
  const d=await _aapi('/api/admin/models',{action:'pull',name:nm});
  toast(d?.msg||(d?.ok?'OK':'Erreur'),d?.ok?'ok':'err');
  document.getElementById('pull-nm').value='';
}

async function delMdl(nm,btn){
  if(!confirm(`Supprimer "${nm}" ?`))return;
  btn.disabled=true;btn.textContent='…';
  const d=await _aapi('/api/admin/models',{action:'delete',name:nm});
  toast(d?.msg||(d?.ok?'Supprimé':'Erreur'),d?.ok?'ok':'err');
  loadModels();
}

// Logs
function colorLog2(el,text){
  el.innerHTML='';
  (Array.isArray(text)?text:String(text).split('\n')).forEach(line=>{
    const s=document.createElement('span');s.className='ll';
    if(/error|fail|crit|fatal/i.test(line))s.classList.add('err');
    else if(/warn/i.test(line))s.classList.add('warn');
    else if(/start|ready|active|ok|success/i.test(line))s.classList.add('ok2');
    s.textContent=line;el.appendChild(s);el.appendChild(document.createTextNode('\n'));
  });
  el.scrollTop=el.scrollHeight;
}

async function loadLogs(){
  const src=document.getElementById('log-src').value;
  const n=document.getElementById('log-n').value;
  const d=await _aapi('/api/admin/logs',{source:src,lines:parseInt(n)});
  colorLog2(document.getElementById('log-box'),d?.lines||[]);
}

// ── Installation depuis l'interface web ───────────────────────────────
async function saveScriptPath(){
  const p=document.getElementById('script-path-in').value.trim();
  if(!p){toast('Entrez un chemin','err');return}
  const d=await _aapi('/api/admin/set-installer-path',{path:p});
  toast(d?.msg||(d?.ok?'Chemin enregistré':'Erreur'),d?.ok?'ok':'err');
}
async function doInstall(){
  const btn=event.target; btn.disabled=true;
  const out=document.getElementById('inst-out');
  out.textContent='⏳ Lancement en cours…';
  try{
    const d=await _aapi('/api/admin/install',{action:'full'});
    out.style.color=d.ok?'var(--neon)':'var(--red)';
    out.textContent=d.msg||'Erreur inconnue';
    if(d.ok){ setTimeout(checkInstallStatus,2000); }
  }catch(e){
    out.style.color='var(--red)'; out.textContent='Erreur réseau: '+e;
  }finally{ btn.disabled=false; }
}

async function checkInstallStatus(){
  try{
    const r=await fetch('/api/stats');
    if(!r.ok) return;
    const d=await r.json();
    const pg=d.progress||{};
    const sec=document.getElementById('inst-progress-sec');
    const logSec=document.getElementById('inst-log-sec');
    const div=document.getElementById('inst-progress');
    if(pg.active){
      // Afficher les sections seulement si installation en cours
      if(sec) sec.style.display='block';
      if(logSec) logSec.style.display='block';
      const pct=pg.pct||0;
      const bar='█'.repeat(Math.round(pct/5))+'░'.repeat(20-Math.round(pct/5));
      if(div) div.innerHTML=`
        <div style="font-size:13px;color:var(--neon);margin-bottom:8px">
          ${pg.step_name||'En cours'} — ${pg.step_desc||''}
        </div>
        <div style="font-family:var(--mono);font-size:14px;color:var(--yellow);margin-bottom:8px">
          [${bar}] ${pct}%
        </div>
        <div style="font-size:12px;color:var(--muted)">
          Étape ${pg.step_current||0}/${pg.step_total||0} · ${pg.label||'Installation en cours'}
        </div>`;
      loadInstallLog();
    } else {
      // Cacher les sections quand pas d'installation
      if(sec) sec.style.display='none';
      if(logSec) logSec.style.display='none';
    }
  }catch(e){}
}

async function loadInstallLog(){
  try{
    const d=await _aapi('/api/admin/logs',{source:'install',lines:60});
    const pre=document.getElementById('inst-log');
    pre.textContent=(d.lines||[]).join('\n')||'Aucun log disponible.';
    pre.scrollTop=pre.scrollHeight;
  }catch(e){}
}

// Rafraîchir l'état d'installation toutes les 3s quand l'onglet est actif
setInterval(()=>{
  const sect=document.getElementById('as-inst');
  if(sect && sect.classList.contains('active')) checkInstallStatus();
},3000);

async function sysDo(action){
  const labels={reboot:'Redémarrer la machine ?',shutdown:'Éteindre la machine ?',update_system:'Lancer la mise à jour système ?'};
  if(!confirm(labels[action]||'Confirmer ?')) return;
  const el=document.getElementById('sys-result');
  if(el) el.textContent='⏳ En cours…';
  const d=await _aapi('/api/admin/system',{action});
  if(el) el.textContent=d?.msg||(d?.ok?'✓ OK':'✗ Erreur');
}
async function changePw(){
  const u=document.getElementById('new-user').value.trim();
  const o=document.getElementById('old-pw').value;
  const n=document.getElementById('new-pw').value;
  const c=document.getElementById('conf-pw').value;
  if(n!==c){toast('Mots de passe différents','err');return}
  const d=await _aapi('/api/admin/change-password',{user:u,old:o,'new':n});
  toast(d?.msg||(d?.ok?'OK':'Erreur'),d?.ok?'ok':'err');
  if(d?.ok){setTimeout(()=>{_admAuth=false;doLogout()},2000)}
}

// Auto-refresh logs
setInterval(()=>{
  if(activeTab==='admin'&&_admAuth&&document.getElementById('as-logs').classList.contains('active'))
    loadLogs();
},10000);

// ── Init ──────────────────────────────────────────────────────────────────
// Poll rapide les 5 premières secondes (cache Python met 1-2s à se remplir)
let _sp=0;
(function _ip(){pollStats();if(++_sp<5)setTimeout(_ip,700);else setInterval(pollStats,2000);})();
</script></body></html>
</script></body></html>"""

# ── HTTP Handler ──────────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def _tok(self): return _get_tok(dict(self.headers))
    def _body(self):
        n=int(self.headers.get("Content-Length",0))
        if not n: return {}
        try: return json.loads(self.rfile.read(n))
        except: return {}
    # Headers de sécurité HTTP appliqués à toutes les réponses HTML
    _SEC_HEADERS={
        "X-Content-Type-Options":  "nosniff",
        "X-Frame-Options":         "DENY",
        "X-XSS-Protection":        "1; mode=block",
        "Referrer-Policy":         "no-referrer",
        "Content-Security-Policy": (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://fonts.gstatic.com; "
            "font-src https://fonts.gstatic.com; "
            "connect-src 'self'; "
            "img-src 'self' data:; "
            "frame-ancestors 'none'"
        ),
        "Cache-Control": "no-store, no-cache, must-revalidate",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    }

    def _send(self,c,ct,b,ex={}):
        if isinstance(b,str): b=b.encode()
        self.send_response(c)
        self.send_header("Content-Type",ct)
        self.send_header("Content-Length",str(len(b)))
        # Même origine — pas de CORS externe
        # Headers sécurité HTML uniquement
        if "text/html" in ct:
            for k,v in self._SEC_HEADERS.items(): self.send_header(k,v)
        for k,v in ex.items(): self.send_header(k,v)
        self.end_headers()
        self.wfile.write(b)
    def _j(self,d,c=200): self._send(c,"application/json; charset=utf-8",json.dumps(d,default=str))
    def _jauth(self,d):
        """JSON avec Set-Cookie"""
        b=json.dumps(d,default=str).encode()
        self.send_response(200)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
        for k,v in d.get("_headers",{}).items(): self.send_header(k,v)
        self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        p=urlparse(self.path).path
        if p=="/api/stats":
            with _lock: data=dict(_cache)
            self._send(200,"application/json; charset=utf-8",
                       json.dumps(data,default=str),{"Cache-Control":"no-store"})
        elif p in("/","/index.html"):
            html=HTML.replace("__PORT__",str(PORT)).encode()
            self._send(200,"text/html; charset=utf-8",html)
        else: self.send_response(404); self.end_headers()

    def do_POST(self):
        p=urlparse(self.path).path; body=self._body()

        # ── Public : login/logout ──
        if p=="/api/admin/login":
            u=body.get("user",""); pw=body.get("pass","")
            # Rate limiting : extraire l'IP du client
            client_ip=self.client_address[0]
            allowed,wait=_rl_check(client_ip)
            if not allowed:
                mins=wait//60; secs=wait%60
                self._j({"ok":False,"msg":f"Trop de tentatives. Réessayez dans {mins}min {secs}s."},429)
                return
            if _check_pw(u,pw):
                _rl_reset(client_ip)   # Succès → réinitialiser le compteur
                tok=_new_sess()
                b=json.dumps({"ok":True}).encode()
                self.send_response(200)
                self.send_header("Content-Type","application/json")
                self.send_header("Content-Length",str(len(b)))
                self.send_header("Set-Cookie",f"ia_sess={tok}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}")
                self.end_headers(); self.wfile.write(b)
            else:
                _rl_record(client_ip)   # Échec → enregistrer la tentative
                self._j({"ok":False,"msg":"Identifiants incorrects"},401)
            return

        if p=="/api/admin/logout":
            _del_sess(self._tok())
            b=json.dumps({"ok":True}).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b)))
            self.send_header("Set-Cookie","ia_sess=; Path=/; Max-Age=0")
            self.end_headers(); self.wfile.write(b)
            return

        # ── Protected ──
        if not p.startswith("/api/admin/"): self.send_response(404); self.end_headers(); return
        if not _valid_sess(self._tok()):
            self._j({"ok":False,"msg":"Session expirée"},401); return

        try:
            if p=="/api/admin/status":
                self._j({"ok":True,"data":api_admin_status()})
            elif p=="/api/admin/service":
                self._j(api_svc_action(body))
            elif p=="/api/admin/update":
                self._j(api_update(body))
            elif p=="/api/admin/models":
                self._j(api_models(body))
            elif p=="/api/admin/logs":
                self._j(api_logs(body))
            elif p=="/api/admin/change-password":
                self._j(api_change_pw(body))
            elif p=="/api/admin/install":
                self._j(api_launch_install(body))
            elif p=="/api/admin/set-installer-path":
                pth=body.get("path","").strip()
                if pth and os.path.isfile(pth):
                    try:
                        Path("/var/lib/ia-installer/installer-path.txt").write_text(pth)
                        self._j({"ok":True,"msg":f"Chemin enregistré : {pth}"})
                    except Exception as e:
                        self._j({"ok":False,"msg":str(e)})
                else:
                    self._j({"ok":False,"msg":f"Fichier introuvable : {pth}"})
            elif p=="/api/admin/system":
                self._j(api_system_action(body))
            else:
                self.send_response(404); self.end_headers()
        except Exception as e:
            self._j({"ok":False,"msg":str(e)},500)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length","0")
        self.end_headers()

    def do_HEAD(self): self.do_GET()

class Srv(http.server.ThreadingHTTPServer): pass

if __name__=="__main__":
    # Worker démarre immédiatement (fait 2 collect() avec sleep(1) entre les deux)
    threading.Thread(target=_worker,daemon=True).start()
    # Serveur HTTP démarre sans attendre le cache
    # Le cache sera prêt dans ~3s, les polls JS patienteront
    srv=Srv((BIND,PORT),Handler)
    lip=_run("ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[^ ]+'") or socket.gethostbyname(socket.gethostname())
    creds=_load_creds()
    print(f"[IA Dashboard+Admin] http://127.0.0.1:{PORT}")
    if lip and lip!="127.0.0.1": print(f"[IA Dashboard+Admin] http://{lip}:{PORT}  (LAN)")
    print(f"[IA Dashboard+Admin] Identifiant admin : {creds['user']} / ia-local-admin")
    try: srv.serve_forever()
    except KeyboardInterrupt: srv.shutdown()

DASHBOARD_EOF
  chmod 700 "$DASHBOARD_SCRIPT"   # Lecture root uniquement (contient la logique admin)
  # Mettre à jour le lien symbolique et le chemin sauvegardé
  _ensure_script_link
  ok "Dashboard Python installé : $DASHBOARD_SCRIPT"
}

# Créer et activer le service systemd du dashboard
install_dashboard_service() {
  local _PORT="${DASHBOARD_PORT:-7842}"
  # BIND toujours 0.0.0.0 : le dashboard doit être accessible depuis le LAN
  # même avant que la config soit chargée
  local _BIND="0.0.0.0"

  cat > /etc/systemd/system/ia-dashboard.service << SVCEOF
[Unit]
Description=IA Local — Dashboard système temps réel
After=network.target
# Pas de dépendance à ollama/docker : le dashboard démarre avant l'installation

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${DASHBOARD_SCRIPT}
Environment="DASHBOARD_PORT=${_PORT}"
Environment="DASHBOARD_BIND=${_BIND}"
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  svc_daemon_reload
  svc_enable  "$DASHBOARD_SERVICE"
  svc_restart "$DASHBOARD_SERVICE"
  sleep 2
}

# Récupérer l'IP LAN pour affichage
_dashboard_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+'     || hostname -I 2>/dev/null | awk '{print $1}'
}

# Menu de gestion du dashboard
menu_dashboard() {
  while true; do
    title "DASHBOARD WEB — STATS TEMPS RÉEL"

    local _PORT="${DASHBOARD_PORT:-7842}"
    local _LIP; _LIP=$(_dashboard_lan_ip)
    local _ACTIVE=0
    svc_active "$DASHBOARD_SERVICE" 2>/dev/null && _ACTIVE=1

    # ── Statut ──────────────────────────────────────────────────
    step "Statut du dashboard"
    if [ "$_ACTIVE" -eq 1 ]; then
      ok  "Dashboard : ${GREEN}actif${NC}"
      echo -e ""
      echo -e "  ${BOLD}Accès local  :${NC}  ${CYAN}http://127.0.0.1:${_PORT}${NC}"
      [ -n "$_LIP" ] &&       echo -e "  ${BOLD}Accès réseau :${NC}  ${CYAN}http://${_LIP}:${_PORT}${NC}"
      echo ""
      # Test rapide de connectivité
      if curl -sf --max-time 2 "http://127.0.0.1:${_PORT}/api/stats" &>/dev/null; then
        ok "API /api/stats répond correctement"
      else
        warn "Le service est actif mais ne répond pas encore (démarrage en cours ?)"
      fi
    else
      nok "Dashboard : ${RED}arrêté${NC}"
      echo ""
    fi

    # ── Menu ────────────────────────────────────────────────────
    echo -e "${BOLD}  ── Actions ────────────────────────────────────────────${NC}"
    if [ "$_ACTIVE" -eq 1 ]; then
      echo -e "  ${CYAN}[1]${NC}  Ouvrir dans le navigateur ${DIM}(si dispo)${NC}"
      echo -e "  ${CYAN}[2]${NC}  ${RED}Arrêter${NC} le dashboard"
      echo -e "  ${CYAN}[3]${NC}  ${YELLOW}Redémarrer${NC} le dashboard"
    else
      echo -e "  ${CYAN}[1]${NC}  ${GREEN}Démarrer${NC} le dashboard"
      echo -e "  ${CYAN}[2]${NC}  Installer / Réinstaller le dashboard"
    fi
    echo -e "  ${CYAN}[4]${NC}  Voir les logs du dashboard"
    echo -e "  ${CYAN}[5]${NC}  Changer le port ${DIM}(actuel: ${_PORT})${NC}"
    echo -e "  ${CYAN}[q]${NC}  Retour au menu principal"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Action : ${NC}")" _DCHOICE

    case "${_DCHOICE:-}" in

      1)
        if [ "$_ACTIVE" -eq 1 ]; then
          # Ouvrir dans le navigateur
          local _URL="http://127.0.0.1:${_PORT}"
          if command -v xdg-open &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            xdg-open "$_URL" &>/dev/null &
            ok "Navigateur ouvert → ${CYAN}${_URL}${NC}"
          else
            info "Ouvre manuellement : ${CYAN}${_URL}${NC}"
          fi
        else
          step "Démarrage du dashboard..."
          # Installer le script si absent
          if [ ! -f "$DASHBOARD_SCRIPT" ]; then
            install_dashboard_script
          fi
          # Créer le service si absent
          if [ ! -f "/etc/systemd/system/ia-dashboard.service" ]; then
            install_dashboard_service
          else
            svc_restart "$DASHBOARD_SERVICE"
          fi
          sleep 2
          if svc_active "$DASHBOARD_SERVICE" 2>/dev/null; then
            ok "Dashboard démarré → ${CYAN}http://127.0.0.1:${_PORT}${NC}"
            [ -n "$_LIP" ] && ok "Réseau LAN    → ${CYAN}http://${_LIP}:${_PORT}${NC}"
          else
            warn "Échec démarrage. Lance : journalctl -u ia-dashboard -n 30"
          fi
        fi
        sleep 2
        ;;

      2)
        if [ "$_ACTIVE" -eq 1 ]; then
          step "Arrêt du dashboard..."
          svc_stop "$DASHBOARD_SERVICE" && ok "Dashboard arrêté." || warn "Échec."
          sleep 1
        else
          step "Installation / Réinstallation du dashboard..."
          install_dashboard_script
          install_dashboard_service
          sleep 2
          svc_active "$DASHBOARD_SERVICE"             && ok "Dashboard installé et démarré → ${CYAN}http://127.0.0.1:${_PORT}${NC}"             || warn "Voir les logs : journalctl -u ia-dashboard -n 30"
        fi
        sleep 2
        ;;

      3)
        if [ "$_ACTIVE" -eq 1 ]; then
          step "Redémarrage du dashboard..."
          svc_restart "$DASHBOARD_SERVICE" && ok "Redémarré." || warn "Échec."
          sleep 2
        fi
        ;;

      4)
        echo ""
        journalctl -u "$DASHBOARD_SERVICE" -n 40 --no-pager 2>/dev/null           || warn "journalctl non disponible"
        echo ""
        read -rp "$(echo -e "${DIM}  Appuie sur Entrée pour continuer...${NC}")" _P
        ;;

      5)
        echo ""
        _ask_port "Nouveau port (actuel: ${_PORT})" "$_PORT" _NEWPORT
        DASHBOARD_PORT="$_NEWPORT"
        sed -i "s/DASHBOARD_PORT=[0-9]*/DASHBOARD_PORT=${_NEWPORT}/"           /etc/systemd/system/ia-dashboard.service 2>/dev/null || true
        svc_daemon_reload; svc_restart "$DASHBOARD_SERVICE"
        ok "Port changé → ${_NEWPORT}. Dashboard redémarré."
        sleep 2
        ;;

      q|Q) break ;;
      *) ;;
    esac
  done
}

# ── Trap de sortie global ─────────────────────────────────────────
_hud_exit_trap() {
  hud_stop
  tput cnorm 2>/dev/null || true    # Restaurer curseur visible
  printf "\033[r" 2>/dev/null || true  # Restaurer scroll region complète
  tput rmcup 2>/dev/null || true    # Restaurer l'écran si altscreen utilisé
}
trap '_hud_exit_trap' EXIT INT TERM PIPE HUP



# ── Barre de progression ─────────────────────────────────────────

# ── Validation d'un numéro de port saisi par l'utilisateur ───────────────────
# Vérifie : numérique, entre 1024 et 65535, pas déjà utilisé par le système

# ── Validation d'un chemin de montage / répertoire donné par l'utilisateur ───
# Bloque les chemins dangereux : /, /boot, /etc, /usr, /var, /sys, etc.

# ── Wrapper sécurisé pour rm -rf ─────────────────────────────────────────────
# Refuse de supprimer /, /boot, /etc et autres chemins système critiques.
# Toujours utiliser _safe_rm à la place de rm -rf dans ce script.
_safe_rm() {
  local TARGET="$1"
  local REAL_TARGET
  REAL_TARGET=$(realpath -m "$TARGET" 2>/dev/null || echo "$TARGET")

  # Refuse si vide
  if [ -z "$REAL_TARGET" ] || [ "$REAL_TARGET" = "/" ]; then
    warn "_safe_rm : cible vide ou racine refusée ('$TARGET')"
    return 1
  fi

  # Refuse les chemins système
  for _SAFE_D in / /boot /etc /usr /var /sys /proc /dev /run /root /bin /sbin /lib /lib64 /home; do
    if [ "$REAL_TARGET" = "$_SAFE_D" ]; then
      warn "_safe_rm : chemin système protégé refusé ('$TARGET')"
      return 1
    fi
  done

  # Refuse les chemins trop courts (moins de 8 caractères pour éviter /tmp/x)
  if [ ${#REAL_TARGET} -lt 8 ] && [ -d "$REAL_TARGET" ]; then
    warn "_safe_rm : chemin suspect trop court refusé ('$TARGET')"
    return 1
  fi

  rm -rf "$TARGET"
}

_validate_data_path() {
  local PATH_VAL="$1"
  local DANGEROUS="/|/boot|/etc|/usr|/var|/sys|/proc|/dev|/run|/tmp|/root|/bin|/sbin|/lib"

  # Chemin non vide
  if [ -z "$PATH_VAL" ]; then
    warn "Chemin vide non autorisé."
    return 1
  fi

  # Chemin absolu obligatoire
  if [[ "$PATH_VAL" != /* ]]; then
    warn "Chemin relatif non autorisé : '$PATH_VAL' (doit commencer par /)"
    return 1
  fi

  # Blocage des répertoires système critiques
  local _CLEAN; _CLEAN=$(realpath -m "$PATH_VAL" 2>/dev/null || echo "$PATH_VAL")
  for _D in / /boot /etc /usr /var /sys /proc /dev /run /tmp /root /bin /sbin /lib /lib64; do
    if [ "$_CLEAN" = "$_D" ] || [[ "$_CLEAN" == "$_D/"* && ${#_CLEAN} -le $(( ${#_D} + 3 )) ]]; then
      warn "Chemin système protégé non autorisé : '$PATH_VAL'"
      return 1
    fi
  done

  # Refus des path traversal
  if echo "$PATH_VAL" | grep -q '\.\.'; then
    warn "Chemin avec '..' non autorisé : '$PATH_VAL'"
    return 1
  fi

  return 0
}

_validate_port() {
  local PORT_VAL="$1"
  local RESERVED_PORTS="22 25 53 80 443 3306 5432 6379 8443 27017"

  # Vérification numérique
  if ! [[ "$PORT_VAL" =~ ^[0-9]+$ ]]; then
    warn "Port invalide : '$PORT_VAL' n'est pas un nombre."
    return 1
  fi

  # Plage autorisée
  if [ "$PORT_VAL" -lt 1024 ] || [ "$PORT_VAL" -gt 65535 ]; then
    warn "Port hors plage : $PORT_VAL (autorisé : 1024–65535)"
    return 1
  fi

  # Ports réservés / sensibles
  for _RP in $RESERVED_PORTS; do
    if [ "$PORT_VAL" -eq "$_RP" ]; then
      warn "Port $PORT_VAL réservé — choisissez un autre port."
      return 1
    fi
  done

  # Vérifier si le port est déjà utilisé
  if ss -tlnp 2>/dev/null | grep -q ":$PORT_VAL "; then
    warn "Port $PORT_VAL déjà utilisé par un autre processus."
    if ! confirm "Utiliser quand même le port $PORT_VAL ?"; then
      return 1
    fi
  fi

  return 0
}

# Demande un port avec validation et retry
_ask_port() {
  local PROMPT="$1"
  local DEFAULT="$2"
  local RESULT_VAR="$3"
  local ATTEMPTS=0

  while [ $ATTEMPTS -lt 3 ]; do
    read -rp "$(echo -e "${YELLOW}  >>> $PROMPT [${DEFAULT}] : ${NC}")" _PORT_INPUT
    _PORT_INPUT="${_PORT_INPUT:-$DEFAULT}"
    if _validate_port "$_PORT_INPUT"; then
      printf -v "$RESULT_VAR" '%s' "$_PORT_INPUT"
      return 0
    fi
    ATTEMPTS=$(( ATTEMPTS + 1 ))
    [ $ATTEMPTS -lt 3 ] && warn "Réessayez ($ATTEMPTS/3)..."
  done
  warn "Port invalide après 3 tentatives — valeur par défaut utilisée : $DEFAULT"
  printf -v "$RESULT_VAR" '%s' "$DEFAULT"
  return 0
}

PROGRESS_TOTAL=0
PROGRESS_CURRENT=0
PROGRESS_LABEL=""

progress_init() {
  PROGRESS_TOTAL="${1:-10}"
  PROGRESS_CURRENT=0
  PROGRESS_LABEL="${2:-Installation}"
  progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
}

progress_step() {
  PROGRESS_CURRENT=$(( PROGRESS_CURRENT + 1 ))
  PROGRESS_LABEL="${1:-$PROGRESS_LABEL}"
  local PCT=$(( PROGRESS_CURRENT * 100 / PROGRESS_TOTAL ))
  progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
  local FILLED=$(( PCT * 40 / 100 ))
  local EMPTY=$(( 40 - FILLED ))
  local BAR=""
  BAR+="${GREEN}"
  for ((i=0; i<FILLED; i++)); do BAR+="█"; done
  BAR+="${DIM}"
      for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
      BAR+="${NC}"
  printf "\r  [%b] %3d%%  %s%-40s" "$BAR" "$PCT" "" "$PROGRESS_LABEL"
  [ "$PROGRESS_CURRENT" -ge "$PROGRESS_TOTAL" ] && echo ""
}

progress_write_json() {
  # Écrit l'état de progression dans un fichier JSON lu par le dashboard
  # Appelé automatiquement par progress_init et progress_step
  local STEP_NAME="${1:-$CURRENT_STEP}"
  local STEP_DESC="${2:-${PLAN_DESC[$CURRENT_STEP]:-}}"
  local PCT=0
  [ "${PROGRESS_TOTAL:-0}" -gt 0 ] && PCT=$(( PROGRESS_CURRENT * 100 / PROGRESS_TOTAL ))
  python3 -c "
import json,time
d={
  'active': True,
  'step_name': '${STEP_NAME}',
  'step_desc': '${STEP_DESC}',
  'step_current': ${PROGRESS_CURRENT:-0},
  'step_total': ${PROGRESS_TOTAL:-0},
  'pct': ${PCT},
  'label': '${PROGRESS_LABEL:-Installation en cours}',
  'ts': time.time(),
  'plan': [$(printf '"%%s",' ${PLAN[@]+"${PLAN[@]}"} | sed 's/,$//')]
}
print(json.dumps(d))
" > "$PROGRESS_FILE" 2>/dev/null || true
  chmod 640 "$PROGRESS_FILE" 2>/dev/null || true   # root:rw, group:r
}

progress_clear_json() {
  # Supprime le fichier de progression — la bannière disparaît du dashboard
  rm -f "$PROGRESS_FILE"
}

progress_apt() {
  # Exécute apt avec parsing de la progression
  local CMD=("$@")
  local PKG_COUNT=0 PKG_DONE=0
  DEBIAN_FRONTEND=noninteractive "${CMD[@]}" 2>&1 | while IFS= read -r LINE; do
    echo "$LINE" >> "$LOG_FILE"   # toujours logger
    if echo "$LINE" | grep -q "^Get:"; then
      PKG_COUNT=$(( PKG_COUNT + 1 ))
    elif echo "$LINE" | grep -q "^Unpacking\|^Setting up"; then
      PKG_DONE=$(( PKG_DONE + 1 ))
      [ "$PKG_COUNT" -gt 0 ] && {
        local PCT=$(( PKG_DONE * 100 / (PKG_COUNT > 0 ? PKG_COUNT : 1) ))
        printf "\r  ${GREEN}[apt]${NC} %d%%  %s" "$PCT" "$(echo "$LINE" | cut -c1-50)"
      }
    fi
  done
  echo ""
}

progress_ollama_pull() {
  # Validation stricte du nom de modèle avant exécution
  local MODEL="$1"
  # Format autorisé : alphanum + : / . - _ uniquement (ex: llama3.2:3b, deepseek-r1:7b)
  if ! echo "$MODEL" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{1,99}$'; then
    warn "Nom de modèle invalide ou trop long : '$MODEL'"
    warn "Caractères autorisés : lettres, chiffres, :  /  .  -  _"
    return 1
  fi
  ollama pull "$MODEL" 2>&1 | while IFS= read -r LINE; do
    echo "$LINE" >> "$LOG_FILE"
    if echo "$LINE" | grep -qE "[0-9]+%"; then
      local PCT
      PCT=$(echo "$LINE" | grep -oE "[0-9]+%" | tail -1 | tr -d '%')
      local FILLED=$(( PCT * 30 / 100 ))
      local EMPTY=$(( 30 - FILLED ))
      local BAR="${GREEN}"
      for ((i=0; i<FILLED; i++)); do BAR+="█"; done
      BAR+="${DIM}"
      for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
      BAR+="${NC}"
      printf "\r  Pull %-25s [%b] %3d%%" "$MODEL" "$BAR" "$PCT"
    fi
  done
  echo ""
}

# New helper function for generic background command with spinner
run_with_spinner() {
  local CMD_TO_RUN="$1"
  local MSG="$2"
  local PID
  local SPINNER_CHARS="/-\|"
  local SPIN_IDX=0
  local EXIT_CODE=0
  local TMP_OUTPUT_FILE="/tmp/spinner_output_$$.log"

  info "$MSG"
  # Run command in background
  eval "$CMD_TO_RUN" > "$TMP_OUTPUT_FILE" 2>&1 &
  PID=$!

  while kill -0 "$PID" 2>/dev/null; do
    SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER_CHARS} ))
    printf "\r  %s %s" "${SPINNER_CHARS:$SPIN_IDX:1}" "$MSG"
    sleep 0.1
  done

  wait "$PID"
  EXIT_CODE=$?

  printf "\r%-80s\r" "" # Clear the line (portable, sans tput)
  cat "$TMP_OUTPUT_FILE" >> "$LOG_FILE" # Append full output to log file
  rm "$TMP_OUTPUT_FILE"

  if [ "$EXIT_CODE" -ne 0 ]; then
    nok "$MSG (Échec avec code $EXIT_CODE)"
    return 1
  else
    ok "$MSG (Terminé)"
    return 0
  fi
}
# ── Trap ERR : gestion des erreurs par étape ────────────────────
CURRENT_STEP="INIT"
LAST_ERROR_LINE=0
LAST_ERROR_CMD=""

trap '_trap_error "$LINENO" "$BASH_COMMAND"' ERR

_trap_error() {
  local LINE="$1"
  local CMD="$2"
  LAST_ERROR_LINE="$LINE"
  LAST_ERROR_CMD="$CMD"

  # ── Ignorer les erreurs non critiques pendant la phase INIT ──────
  # Pendant INIT, beaucoup de commandes peuvent échouer sans gravité
  # (détection matériel, vérifications optionnelles, etc.)
  # On n'écrit PAS dans le state pour ne pas bloquer les prochains lancements.
  if [ "$CURRENT_STEP" = "INIT" ]; then
    # Juste logger discrètement, sans interrompre ni sauvegarder l'état
    echo "[$(date +%H:%M:%S)] [TRAP/INIT] ligne $LINE : $CMD" >> "$STATE_DIR/errors.log" 2>/dev/null || true
    return 0
  fi

  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ❌  ERREUR DÉTECTÉE                                      ║${NC}"
  echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
  printf  "${RED}║${NC}  Étape   : %-45s${RED}║${NC}\n" "$CURRENT_STEP"
  printf  "${RED}║${NC}  Ligne   : %-45s${RED}║${NC}\n" "$LINE"
  printf  "${RED}║${NC}  Commande: %-45s${RED}║${NC}\n" "${CMD:0:45}"
  printf  "${RED}║${NC}  Log     : %-45s${RED}║${NC}\n" "$LOG_FILE"
  echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Sauvegarder l'erreur dans le state (seulement pour les vraies étapes)
  echo "ERROR:${CURRENT_STEP}:${LINE}:${CMD}" >> "$STATE_DIR/errors.log"
  save_state "ERROR:$CURRENT_STEP"

  echo -e "${BOLD}Que faire ?${NC}"
  echo -e "  ${GREEN}[1]${NC} Réessayer cette étape"
  echo -e "  ${GREEN}[2]${NC} Ignorer et continuer"
  echo -e "  ${GREEN}[3]${NC} Abandonner (état sauvegardé pour reprise)"
  echo -e "  ${GREEN}[4]${NC} Ouvrir un shell de débogage"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix [1-4] : ${NC}")" ERR_CHOICE

  case "${ERR_CHOICE:-3}" in
    1)
      info "Reprise de l'étape $CURRENT_STEP..."
      save_state "EXEC:${PLAN_STEP_IDX:-0}"
      return 0
      ;;
    2)
      warn "Étape $CURRENT_STEP ignorée — continuation..."
      return 0
      ;;
    4)
      warn "Shell de débogage — tape 'exit' pour continuer."
      bash || true
      return 0
      ;;
    3|*)
      err_msg "Installation suspendue à l'étape $CURRENT_STEP."
      info "Pour reprendre : sudo bash $SCRIPT_PATH"
      exit 1
      ;;
  esac
}

# ================================================================
#  GESTION D'ÉTAT (reprise après reboot / erreur)
# ================================================================

STATE_FILE="$STATE_DIR/state"
PROGRESS_FILE="$STATE_DIR/progress.json"   # Lu par le dashboard en temps réel
CONFIG_FILE="$STATE_DIR/config.env"

save_state()  { echo "$1" > "$STATE_FILE"; }
load_state()  { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "START"; }

PLAN_STEP_IDX=0  # index courant dans le plan (pour le trap)

# Sérialisation robuste des tableaux associatifs en fichier sourceable
save_config() {
  {
    echo "# Config sauvegardée $(date)"
    # HW : tableau associatif matériel
    for K in "${!HW[@]}"; do
      printf 'HW[%s]=%q\n' "$K" "${HW[$K]}"
    done
    # CFG : tableau associatif configuration
    for K in "${!CFG[@]}"; do
      printf 'CFG[%s]=%q\n' "$K" "${CFG[$K]}"
    done
    # PLAN : tableau indexé des étapes
    echo "PLAN=($(printf '"%s" ' "${PLAN[@]}"))"
    # PLAN_DESC et PLAN_REBOOT
    for K in "${!PLAN_DESC[@]}"; do
      printf 'PLAN_DESC[%s]=%q\n' "$K" "${PLAN_DESC[$K]}"
    done
    for K in "${!PLAN_REBOOT[@]}"; do
      printf 'PLAN_REBOOT[%s]=%q\n' "$K" "${PLAN_REBOOT[$K]}"
    done
  } > "$CONFIG_FILE"
}

load_config() {
  # Initialiser les tableaux avant de sourcer
  declare -gA HW=() CFG=() PLAN_DESC=() PLAN_REBOOT=()
  declare -ga PLAN=()
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || true
}

# Enregistrement d'un reboot avec reprise
reboot_and_resume() {
  local NEXT="$1"
  local REASON="${2:-Reboot requis}"

  save_state "RESUME:$NEXT"
  save_config

  cat > /etc/systemd/system/ia-installer-resume.service << EOF
[Unit]
Description=Reprise Installateur IA Locale
After=network-online.target multi-user.target
Wants=network-online.target
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
ExecStart=/bin/bash "$SCRIPT_PATH"
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ia-installer-resume.service

  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  🔄  REBOOT PROGRAMMÉ                                    ║${NC}"
  echo -e "${YELLOW}║  Raison  : $REASON$(printf '%*s' $((44 - ${#REASON})) '')║${NC}"
  echo -e "${YELLOW}║  Reprise : Phase $NEXT$(printf '%*s' $((43 - ${#NEXT})) '')║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  sleep 4
  reboot
}

cleanup_resume() {
  systemctl disable ia-installer-resume.service 2>/dev/null || true
  rm -f /etc/systemd/system/ia-installer-resume.service
  systemctl daemon-reload
  rm -f "$STATE_FILE"
}

# ── Fonction centrale : lancement Open WebUI ─────────────────────
# Respecte EXACTEMENT la commande de référence de l'utilisateur :
# docker run -d --network=host -v /mnt/.../open-webui:/app/backend/data
#   -e OLLAMA_BASE_URL=http://127.0.0.1:11434
#   --name open-webui --restart always ghcr.io/open-webui/open-webui:main
_docker_run_webui() {
  local IMG="${1:-${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}}"
  # Validation format image Docker : doit correspondre à registry/image:tag
  if ! echo "$IMG" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._/:-]{5,150}$'; then
    warn "Format d'image Docker invalide : '$IMG' — utilisation de l'image par défaut."
    IMG="ghcr.io/open-webui/open-webui:main"
  fi
  local DATA_DIR="${2:-${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}}"
  local PORT="${3:-${CFG[webui_port]:-8080}}"
  local NET_MODE="${4:-${CFG[docker_network]:-host}}"
  local OLLAMA_URL="http://127.0.0.1:11434"

  # Arrêter et supprimer l'ancien container si existant
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    info "Arrêt du container open-webui existant..."
    docker stop open-webui 2>/dev/null || true
    docker rm   open-webui 2>/dev/null || true
  fi

  # Vérifier que le dossier data existe
  mkdir -p "$DATA_DIR"
  chown -R "$REAL_USER:$REAL_USER" "$DATA_DIR" 2>/dev/null || true

  info "Image     : $IMG"
  info "Data      : $DATA_DIR"
  info "Réseau    : $NET_MODE"
  info "Ollama URL: $OLLAMA_URL"

      # Construire la commande selon le mode réseau
      if [ "$NET_MODE" = "host" ]; then
        # Mode host : PAS de -p (incompatible avec --network=host sous Docker)
        docker run -d \
          --network=host \
          -v "${DATA_DIR}:/app/backend/data" \
          -e OLLAMA_BASE_URL="$OLLAMA_URL" \
          -e PORT="${PORT}" \
          --name open-webui \
          --restart unless-stopped \
          "$IMG"
      else
    # Mode bridge : port mapping + add-host pour atteindre Ollama sur l'hôte
    docker run -d \
      -p "${PORT}:8080" \
      --add-host=host.docker.internal:host-gateway \
      -v "${DATA_DIR}:/app/backend/data" \
      -e OLLAMA_BASE_URL="$OLLAMA_URL" \
      --name open-webui \
      --restart unless-stopped \
      "$IMG"
  fi

  local EXIT_CODE=$?
  if [ "$EXIT_CODE" -ne 0 ]; then
    warn "docker run a retourné le code $EXIT_CODE"
    warn "Vérifie : docker logs open-webui"
    return 1
  fi

  # Attendre que le container démarre
  local WAIT=0
  while [ "$WAIT" -lt 15 ]; do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && break
    sleep 1; WAIT=$(( WAIT + 1 ))
  done

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    if [ "$NET_MODE" = "host" ]; then
      log "Open WebUI actif → http://localhost:8080"
    else
      log "Open WebUI actif → http://localhost:$PORT"
    fi
    return 0
  else
    warn "Open WebUI ne semble pas démarré."
    warn "Diagnostic : docker logs open-webui"
    docker logs --tail 20 open-webui 2>/dev/null || true
    return 1
  fi
}


# ── Service systemd pour Open WebUI ──────────────────────────────────────
# Garantit l'ordre de démarrage : Docker → Ollama (prêt) → WebUI
# Remplace le simple "--restart always" qui ne connaît pas Ollama
_install_webui_service() {
  local PORT="${1:-${CFG[webui_port]:-8080}}"
  local DATA_DIR="${2:-${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}}"
  local IMG="${3:-${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}}"
  local NET_MODE="${4:-${CFG[docker_network]:-host}}"
  local OLLAMA_URL="http://127.0.0.1:11434"

  [ "$HAS_SYSTEMD" -ne 1 ] && return 0  # Pas systemd → le --restart gère

  cat > /etc/systemd/system/open-webui.service << WUEOF
[Unit]
Description=Open WebUI — Interface IA locale
Documentation=https://github.com/open-webui/open-webui
# Attendre que Docker ET Ollama soient actifs
After=docker.service ollama.service network-online.target
Requires=docker.service
Wants=ollama.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Attendre qu'Ollama soit réellement prêt (API qui répond) avant de lancer WebUI
# Timeout 120s pour les machines lentes qui chargent un modèle au démarrage
ExecStartPre=/bin/bash -c '  echo "[open-webui] Attente Ollama...";   i=0;   while [ \$i -lt 60 ]; do     curl -sf --max-time 2 http://127.0.0.1:11434/api/tags > /dev/null 2>&1 && break;     sleep 2; i=\$((i+1));   done;   if [ \$i -ge 60 ]; then     echo "[open-webui] WARN: Ollama non prêt après 120s, démarrage WebUI quand même";   else     echo "[open-webui] Ollama prêt après \$((i*2))s";   fi'

# Démarrer le container (le créer s'il n'existe pas, sinon le démarrer)
ExecStart=/bin/bash -c '  if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^open-webui\$"; then     docker start open-webui;   else     echo "[open-webui] Container absent — création impossible au boot, voir install";     exit 1;   fi'

ExecStop=/usr/bin/docker stop open-webui

# Redémarrer si Docker redémarre ou si Ollama redémarre
ExecStartPost=/bin/bash -c '  sleep 5;   if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^open-webui\$"; then     echo "[open-webui] Container démarré avec succès";   else     echo "[open-webui] WARN: Container non présent dans docker ps après démarrage";   fi'

Restart=on-failure
RestartSec=10
TimeoutStartSec=150

[Install]
WantedBy=multi-user.target
WUEOF

  svc_daemon_reload
  systemctl enable open-webui.service
  ok "Service systemd open-webui.service créé et activé au boot"
  ok "Ordre garanti : Docker → Ollama (API prête) → Open WebUI"
}

# ── Sauvegarde données WebUI avant MAJ ───────────────────────────
_backup_webui_before_update() {
  local DATA_DIR="${1:-${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}}"
  local BACKUP_DIR="${CFG[backup_dir]:-$(dirname "$DATA_DIR")/backups}"
  local STAMP; STAMP=$(date +%Y%m%d_%H%M%S)
  local BACKUP_PATH="$BACKUP_DIR/webui_pre_update_$STAMP"

  mkdir -p "$BACKUP_DIR"
  if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    info "Sauvegarde des données WebUI avant MAJ..."
    cp -r "$DATA_DIR" "$BACKUP_PATH" &&       ok "Backup créé : $BACKUP_PATH ($(du -sh "$BACKUP_PATH" | cut -f1))" ||       warn "Backup échoué — MAJ continue quand même."
    echo "$BACKUP_PATH" > "$STATE_DIR/last_webui_backup"
  else
    info "Dossier WebUI vide ou inexistant — pas de backup nécessaire."
  fi
}



# ================================================================
#  SECTION 1 : ANALYSE COMPLÈTE DU MATÉRIEL
# ================================================================

analyse_hardware() {
  title "ANALYSE COMPLÈTE DU MATÉRIEL"
  info "Analyse en cours, patiente quelques secondes...\n"

  declare -gA HW=()   # Hardware détecté
  declare -gA SYS=()  # État du système (ce qui est déjà installé)

  # ── CPU ─────────────────────────────────────────────────────────
  step "Processeur"
  HW[cpu_model]=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
  HW[cpu_cores]=$(nproc --all)
  HW[cpu_threads]=$(grep -c 'processor' /proc/cpuinfo)
  HW[cpu_arch]=$(uname -m)
  HW[cpu_vendor]=$(grep -m1 'vendor_id' /proc/cpuinfo | cut -d: -f2 | xargs)
  HW[cpu_avx]=$(grep -m1 'flags' /proc/cpuinfo | grep -c 'avx2' || echo "0")
  HW[cpu_freq_mhz]=$(grep -m1 'cpu MHz' /proc/cpuinfo | cut -d: -f2 | xargs | cut -d. -f1 || echo "?")

  ok "${HW[cpu_model]}"
  ok "${HW[cpu_cores]} cœurs physiques / ${HW[cpu_threads]} threads"
  [ "${HW[cpu_avx]}" = "1" ] && ok "AVX2 supporté (optimisations inférence CPU)" \
                               || warn "AVX2 non détecté — inférence CPU plus lente"

  # ── RAM ─────────────────────────────────────────────────────────
  step "Mémoire RAM"
  HW[ram_kb]=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  HW[ram_gb]=$(( HW[ram_kb] / 1024 / 1024 ))
  HW[ram_mb]=$(( HW[ram_kb] / 1024 ))
  HW[ram_free_gb]=$(( $(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
  HW[swap_gb]=$(( $(grep SwapTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))

  # Détail des barrettes si dmidecode disponible
  if command -v dmidecode &>/dev/null; then
    HW[ram_type]=$(dmidecode -t memory 2>/dev/null | grep -m1 'Type:' | grep -v 'Unknown' | awk '{print $2}' || echo "?")
    HW[ram_speed]=$(dmidecode -t memory 2>/dev/null | grep -m1 'Speed:' | awk '{print $2" "$3}' || echo "?")
    HW[ram_slots_used]=$(dmidecode -t memory 2>/dev/null | grep -c 'Size:.*MB\|Size:.*GB' || echo "?")
    ok "${HW[ram_gb]} Go ${HW[ram_type]} @ ${HW[ram_speed]} (${HW[ram_slots_used]} barrette(s))"
  else
    ok "${HW[ram_gb]} Go RAM disponible"
  fi

  [ "${HW[ram_gb]}" -lt 8 ]  && warn "RAM faible (<8 Go) — inférence limitée aux petits modèles"
  [ "${HW[ram_gb]}" -ge 16 ] && ok "RAM suffisante pour modèles 7-8B en CPU fallback"
  [ "${HW[ram_gb]}" -ge 32 ] && ok "RAM confortable — modèles 13B+ en CPU fallback possibles"

  # ── GPU ─────────────────────────────────────────────────────────
  step "Carte Graphique (GPU)"
  HW[gpu_brand]="none"
  HW[gpu_model]="Aucun GPU dédié"
  HW[gpu_vram_gb]=0
  HW[gpu_vram_source]="none"
  HW[gpu_driver_pkg]=""
  HW[gpu_driver_installed]="non"
  HW[gpu_docker_img]="ghcr.io/open-webui/open-webui:main"
  HW[gpu_docker_flags]=""
  HW[gpu_rocm_capable]=0
  HW[gpu_cuda_capable]=0

  local GPU_PCI=""
  GPU_PCI=$(lspci 2>/dev/null | grep -iE "VGA|3D controller|Display" || true)

  if echo "$GPU_PCI" | grep -qi "nvidia"; then
    HW[gpu_brand]="nvidia"
    HW[gpu_model]=$(echo "$GPU_PCI" | grep -i nvidia | head -1 | sed 's/.*: //' | sed 's/ (.*//')
    HW[gpu_cuda_capable]=1
    HW[gpu_docker_img]="ghcr.io/open-webui/open-webui:cuda"
    HW[gpu_docker_flags]="--gpus all"

    # Drivers déjà installés ?
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
      HW[gpu_driver_installed]="oui"
      local VRAM_MB
      VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
      HW[gpu_vram_gb]=$(( VRAM_MB / 1024 ))
      HW[gpu_vram_source]="nvidia-smi"
      HW[gpu_driver_current]=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "?")
      ok "Driver NVIDIA ${HW[gpu_driver_current]} déjà installé"
    else
      HW[gpu_driver_installed]="non"
      # VRAM depuis base de données
      _detect_vram_from_db "${HW[gpu_model]}"
      HW[gpu_vram_gb]=$VRAM_DB_RESULT
      HW[gpu_vram_source]="${VRAM_DB_SOURCE}"
    fi

    # Driver recommandé selon génération
    local M="${HW[gpu_model]}"
    if   echo "$M" | grep -qiE "RTX 50|B[0-9]{3}";                        then HW[gpu_driver_pkg]="nvidia-driver-570"
    elif echo "$M" | grep -qiE "RTX 40|Ada|L4[0-9]|H[0-9]{2}|A[0-9]{3}"; then HW[gpu_driver_pkg]="nvidia-driver-550"
    elif echo "$M" | grep -qiE "RTX 3[0-9]{3}|RTX 2[0-9]{3}|GTX 16[0-9]{2}"; then HW[gpu_driver_pkg]="nvidia-driver-545"
    elif echo "$M" | grep -qiE "GTX 10[0-9]{2}";                          then HW[gpu_driver_pkg]="nvidia-driver-535"
    elif echo "$M" | grep -qiE "GTX 9[0-9]{2}|GTX 7[0-9]{2}|GTX 8[0-9]{2}"; then HW[gpu_driver_pkg]="nvidia-driver-470"
    elif echo "$M" | grep -qiE "GTX [0-9]{3}[^0-9]|GT [0-9]{3}";         then HW[gpu_driver_pkg]="nvidia-driver-390"
    else HW[gpu_driver_pkg]="auto"; fi

    ok "${HW[gpu_model]}"
    ok "VRAM : ${HW[gpu_vram_gb]} Go (${HW[gpu_vram_source]})"
    ok "Driver recommandé : ${HW[gpu_driver_pkg]}"

  elif echo "$GPU_PCI" | grep -qiE "amd|radeon|advanced micro"; then
    HW[gpu_brand]="amd"
    HW[gpu_model]=$(echo "$GPU_PCI" | grep -iE "amd|radeon" | head -1 | sed 's/.*: //' | sed 's/ (.*//')

    if command -v rocm-smi &>/dev/null; then
      HW[gpu_driver_installed]="oui"
      local VRAM_AMD
      VRAM_AMD=$(rocm-smi --showmeminfo vram 2>/dev/null | grep "Total Memory" | awk '{print $NF}' | head -1 || echo "0")
      HW[gpu_vram_gb]=$(( VRAM_AMD / 1024 ))
      HW[gpu_vram_source]="rocm-smi"
    else
      _detect_vram_from_db "${HW[gpu_model]}"
      HW[gpu_vram_gb]=$VRAM_DB_RESULT
      HW[gpu_vram_source]="${VRAM_DB_SOURCE}"
    fi

    # ROCm compatible ?
    local M="${HW[gpu_model]}"
    if echo "$M" | grep -qiE "RX [5-9][0-9]{3}|RX 7[0-9]{3}|Vega|MI[0-9]|W[0-9]{4}"; then
      HW[gpu_rocm_capable]=1
      HW[gpu_docker_img]="ghcr.io/open-webui/open-webui:rocm"
      HW[gpu_docker_flags]="--device /dev/kfd --device /dev/dri --group-add video --group-add render"
    fi

    ok "${HW[gpu_model]}"
    ok "VRAM : ${HW[gpu_vram_gb]} Go (${HW[gpu_vram_source]})"
    [ "${HW[gpu_rocm_capable]}" = "1" ] && ok "ROCm compatible — accélération GPU disponible" \
                                         || warn "Carte ancienne — pas de ROCm, inférence CPU"

  elif echo "$GPU_PCI" | grep -qiE "intel.*arc"; then
    HW[gpu_brand]="intel"
    HW[gpu_model]=$(echo "$GPU_PCI" | grep -i "intel.*arc" | head -1 | sed 's/.*: //')
    _detect_vram_from_db "${HW[gpu_model]}"
    HW[gpu_vram_gb]=$VRAM_DB_RESULT
    ok "${HW[gpu_model]}"
    warn "Intel Arc : support IA partiel, inférence principalement CPU"
  else
    warn "Aucun GPU dédié détecté — inférence sur CPU uniquement"
  fi

  # ── STOCKAGE ────────────────────────────────────────────────────
  step "Stockage"
  declare -ga DISKS=()
  declare -gA DISK_SIZE DISK_MODEL DISK_TYPE DISK_HEALTH

  while IFS= read -r LINE; do
    local DNAME DSIZE DTYPE DMODEL
    DNAME=$(echo "$LINE" | awk '{print $1}')
    DSIZE=$(echo "$LINE" | awk '{print $2}')
    DTYPE=$(echo "$LINE" | awk '{print $3}')
    DMODEL=$(echo "$LINE" | awk '{$1=$2=$3=""; print $0}' | xargs)
    DISKS+=("/dev/$DNAME")
    DISK_SIZE["/dev/$DNAME"]="$DSIZE"
    DISK_MODEL["/dev/$DNAME"]="$DMODEL"
    DISK_TYPE["/dev/$DNAME"]="$DTYPE"

    # Santé SMART
    local SMART_STATUS="?"
    if command -v smartctl &>/dev/null; then
      SMART_STATUS=$(smartctl -H "/dev/$DNAME" 2>/dev/null | grep -oP 'PASSED|FAILED|OK' | head -1 || echo "?")
    fi
    DISK_HEALTH["/dev/$DNAME"]="$SMART_STATUS"

    # Détecter si SSD ou HDD
    local ROT
    ROT=$(cat "/sys/block/$DNAME/queue/rotational" 2>/dev/null || echo "?")
    [ "$ROT" = "0" ] && DTYPE="SSD" || [ "$ROT" = "1" ] && DTYPE="HDD"
    DISK_TYPE["/dev/$DNAME"]="$DTYPE"

    ok "/dev/$DNAME — $DSIZE ($DTYPE) — $DMODEL [SMART: $SMART_STATUS]"
  done < <(lsblk -dno NAME,SIZE,TYPE,MODEL | grep -v loop)

  # ── RÉSEAU ──────────────────────────────────────────────────────
  step "Réseau"
  HW[net_interfaces]=$(ip -o link show | grep -v "lo\|docker\|veth" | awk '{print $2}' | tr -d ':' | tr '\n' ' ')
  HW[net_connected]="non"
  if ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    HW[net_connected]="oui"
    ok "Connexion Internet disponible"
  else
    warn "Pas de connexion Internet détectée"
    warn "Les téléchargements (drivers, modèles) seront impossibles"
  fi

  # ── SYSTÈME ─────────────────────────────────────────────────────
  step "Système d'exploitation"
  HW[os_name]=$(lsb_release -d 2>/dev/null | cut -f2 || echo "Inconnu")
  HW[os_version]=$(lsb_release -r 2>/dev/null | cut -f2 || echo "?")
  HW[os_codename]=$(lsb_release -c 2>/dev/null | cut -f2 || echo "?")
  HW[kernel]=$(uname -r)
  HW[arch]=$(uname -m)
  HW[uefi]=$([ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS")
  HW[secure_boot]=$(mokutil --sb-state 2>/dev/null | grep -oi 'enabled\|disabled' || echo "?")
  HW[user]="${SUDO_USER:-$USER}"
  HW[user_home]=$(eval echo "~${HW[user]}")

  ok "${HW[os_name]} (kernel ${HW[kernel]})"
  ok "Architecture : ${HW[arch]} | Boot : ${HW[uefi]} | Secure Boot : ${HW[secure_boot]}"

  # Secure Boot peut bloquer les drivers NVIDIA
  [ "${HW[secure_boot]}" = "enabled" ] && \
    warn "Secure Boot ACTIVÉ — peut bloquer les drivers NVIDIA/ROCm. Désactive-le dans le BIOS si problème."

  # ── CE QUI EST DÉJÀ INSTALLÉ ─────────────────────────────────
  step "Logiciels déjà installés"
  declare -gA SYS

  command -v docker &>/dev/null      && SYS[docker]="oui"        || SYS[docker]="non"
  command -v ollama &>/dev/null      && SYS[ollama]="oui"        || SYS[ollama]="non"
  command -v nvidia-smi &>/dev/null  && SYS[nvidia_driver]="oui" || SYS[nvidia_driver]="non"
  command -v rocm-smi &>/dev/null    && SYS[rocm]="oui"          || SYS[rocm]="non"
  dpkg -l 2>/dev/null | grep -q "nvidia-container-toolkit" \
                                     && SYS[nv_toolkit]="oui"    || SYS[nv_toolkit]="non"
  [ -f /swapfile ]                   && SYS[swapfile]="oui"      || SYS[swapfile]="non"

  SYS[ollama_version]=$(ollama --version 2>/dev/null | head -1 || echo "-")
  SYS[docker_version]=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo "-")

  [ "${SYS[docker]}" = "oui" ]       && ok "Docker ${SYS[docker_version]} installé"       || neutral "Docker        : non installé"
  [ "${SYS[ollama]}" = "oui" ]       && ok "Ollama ${SYS[ollama_version]} installé"       || neutral "Ollama        : non installé"
  [ "${SYS[nvidia_driver]}" = "oui" ] && ok "Driver NVIDIA installé"                       || neutral "Driver NVIDIA : non installé"
  [ "${SYS[rocm]}" = "oui" ]         && ok "ROCm installé"                                 || neutral "ROCm          : non installé"
  [ "${SYS[nv_toolkit]}" = "oui" ]   && ok "NVIDIA Container Toolkit installé"             || neutral "NV Toolkit    : non installé"
  [ "${SYS[swapfile]}" = "oui" ]     && ok "Swapfile existant"                              || neutral "Swapfile      : non configuré"
}

# ── Base de données VRAM ────────────────────────────────────────
_detect_vram_from_db() {
  local M="$1"
  VRAM_DB_RESULT=0
  VRAM_DB_SOURCE="db"

  # NVIDIA RTX 50xx
  echo "$M" | grep -qiE "RTX 5090"              && VRAM_DB_RESULT=32 && return
  echo "$M" | grep -qiE "RTX 5080"              && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 5070 Ti"           && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 5070 Super"        && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 5070[^TS ]|RTX 5070$" && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 5060 Ti"           && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 5060[^T ]|RTX 5060$" && VRAM_DB_RESULT=8 && return
  # NVIDIA RTX 40xx
  echo "$M" | grep -qiE "RTX 4090"              && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RTX 4080 Super"        && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4080[^S ]|RTX 4080$" && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4070 Ti Super"     && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4070 Ti[^S ]"      && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 4070 Super"        && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 4070[^TS ]|RTX 4070$" && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 4060 Ti 16"        && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4060 Ti[^1 ]|RTX 4060 Ti$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 4060[^T ]|RTX 4060$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 4050"              && VRAM_DB_RESULT=6  && return
  # NVIDIA RTX 30xx
  echo "$M" | grep -qiE "RTX 3090 Ti"           && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RTX 3090[^T ]|RTX 3090$" && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RTX 3080 Ti"           && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 3080 12"           && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 3080[^T1 ]|RTX 3080$" && VRAM_DB_RESULT=10 && return
  echo "$M" | grep -qiE "RTX 3070 Ti"           && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 3070[^T ]|RTX 3070$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 3060 Ti"           && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 3060[^T ]|RTX 3060$" && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 3050"              && VRAM_DB_RESULT=8  && return
  # NVIDIA RTX 20xx
  echo "$M" | grep -qiE "RTX 2080 Ti"           && VRAM_DB_RESULT=11 && return
  echo "$M" | grep -qiE "RTX 2080 Super"        && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 2080[^TS ]|RTX 2080$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 2070 Super"        && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 2070[^S ]|RTX 2070$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 2060 Super"        && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 2060[^S ]|RTX 2060$" && VRAM_DB_RESULT=6 && return
  # NVIDIA GTX 16xx
  echo "$M" | grep -qiE "GTX 1660 Ti"           && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 1660 Super"        && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 1660[^TS ]|GTX 1660$" && VRAM_DB_RESULT=6 && return
  echo "$M" | grep -qiE "GTX 1650 Super"        && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 1650[^S ]|GTX 1650$" && VRAM_DB_RESULT=4 && return
  # NVIDIA GTX 10xx
  echo "$M" | grep -qiE "GTX 1080 Ti"           && VRAM_DB_RESULT=11 && return
  echo "$M" | grep -qiE "GTX 1080[^T ]|GTX 1080$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "GTX 1070 Ti"           && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "GTX 1070[^T ]|GTX 1070$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "GTX 1060 6"            && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 1060 3"            && VRAM_DB_RESULT=3  && return
  echo "$M" | grep -qiE "GTX 1060[^36 ]|GTX 1060$" && VRAM_DB_RESULT=6 && return
  echo "$M" | grep -qiE "GTX 1050 Ti"           && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 1050[^T ]|GTX 1050$" && VRAM_DB_RESULT=2 && return
  echo "$M" | grep -qiE "GTX 1030"              && VRAM_DB_RESULT=2  && return
  # NVIDIA GTX 9xx
  echo "$M" | grep -qiE "GTX 980 Ti"            && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 980[^T ]|GTX 980$" && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 970"               && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 960"               && VRAM_DB_RESULT=2  && return
  # AMD RX 7xxx
  echo "$M" | grep -qiE "RX 7900 XTX"           && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RX 7900 GRE"           && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 7900 XT[^X ]|RX 7900 XT$" && VRAM_DB_RESULT=20 && return
  echo "$M" | grep -qiE "RX 7800 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 7700 XT"            && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RX 7600 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 7600[^X ]|RX 7600$" && VRAM_DB_RESULT=8 && return
  # AMD RX 6xxx
  echo "$M" | grep -qiE "RX 6950 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6900 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6800 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6800[^X ]|RX 6800$" && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6700 XT"            && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RX 6700[^X ]|RX 6700$" && VRAM_DB_RESULT=10 && return
  echo "$M" | grep -qiE "RX 6650 XT"            && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 6600 XT"            && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 6600[^X ]|RX 6600$" && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 6500 XT"            && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "RX 6400"               && VRAM_DB_RESULT=4  && return
  # AMD RX 5xxx
  echo "$M" | grep -qiE "RX 5700 XT"            && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 5700[^X ]|RX 5700$" && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 5600 XT"            && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "RX 5500 XT 8"          && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 5500 XT[^8 ]"       && VRAM_DB_RESULT=4  && return
  # Professionnel
  echo "$M" | grep -qiE "A100.*80"              && VRAM_DB_RESULT=80 && return
  echo "$M" | grep -qiE "A100.*40"              && VRAM_DB_RESULT=40 && return
  echo "$M" | grep -qiE "H100.*80"              && VRAM_DB_RESULT=80 && return
  echo "$M" | grep -qiE "A40"                   && VRAM_DB_RESULT=48 && return
  echo "$M" | grep -qiE "A10[^0]|A10$"          && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "A30"                   && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "A16"                   && VRAM_DB_RESULT=16 && return
  # Estimations par génération si non trouvé
  VRAM_DB_SOURCE="estimation"
  echo "$M" | grep -qiE "RTX [45][0-9]{3}"      && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX [23][0-9]{3}"      && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "GTX 1[0-9]{3}"         && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "RX [5-7][0-9]{3}"      && VRAM_DB_RESULT=8  && return
  VRAM_DB_RESULT=4  # fallback minimal
}


# ══════════════════════════════════════════════════════════════════════
#  CHOIX DU BACKEND D'INFÉRENCE IA
# ══════════════════════════════════════════════════════════════════════
select_backend() {
  local PROFILE="${HW[profile]:-LOW}"
  local EFFECTIVE="${HW[effective_mem]:-4}"
  local GPU_BRAND="${HW[gpu_brand]:-none}"
  local CUDA="${HW[gpu_cuda_capable]:-0}"
  local ROCM="${HW[gpu_rocm_capable]:-0}"
  local RAM="${HW[ram_gb]:-8}"

  title "CHOIX DU BACKEND D'INFÉRENCE IA"
  echo ""
  echo -e "  ${BOLD}Profil détecté : ${GREEN}$PROFILE${NC}  ${DIM}(${EFFECTIVE} Go mémoire effective)${NC}"
  [ "$GPU_BRAND" != "none" ] && \
    echo -e "  ${BOLD}GPU            : ${CYAN}${GPU_BRAND^^} — ${HW[gpu_model]}${NC}"
  echo ""
  echo -e "  ${DIM}Le backend est le moteur qui fait tourner les modèles IA.${NC}"
  echo ""

  # ── Tableau backends : ID|label|RAM_min|need_CUDA|need_Docker|description
  local -a BACKENDS=(
    "ollama|Ollama|4|0|0|Universel · GPU+CPU · Recommandé · Simple"
    "llamacpp|llama.cpp|4|0|0|Performance max · Natif · Sans Docker"
    "localai|LocalAI|6|0|1|API OpenAI-compatible · Docker · Multi-modèles"
    "lmstudio|LM Studio|8|0|0|Interface graphique · Débutants · AppImage"
    "vllm|vLLM|16|1|1|Production GPU · Throughput max · CUDA requis"
  )

  local -a AVAIL_BACKENDS=()
  local IDX=1

  printf "  ${BOLD}%-4s %-14s %-22s %s${NC}\n" "N°" "Backend" "Points forts" "Compatibilité"
  echo "  ────────────────────────────────────────────────────────────────────"

  for ENTRY in "${BACKENDS[@]}"; do
    IFS='|' read -r BK_ID BK_LABEL BK_MIN_RAM BK_NEED_CUDA BK_NEED_DOCKER BK_DESC <<< "$ENTRY"

    local COMPAT=1 WHY=""
    [ "$RAM" -lt "$BK_MIN_RAM" ] \
      && COMPAT=0 && WHY="${RAM}Go RAM < ${BK_MIN_RAM}Go requis"
    [ "$BK_NEED_CUDA" = "1" ] && [ "$CUDA" != "1" ] \
      && COMPAT=0 && WHY="CUDA requis (GPU NVIDIA non détecté)"

    # Icône recommandation
    local STAR="" STAR_COL="$NC"
    case "$BK_ID" in
      ollama)
        STAR="⭐ Recommandé"; STAR_COL="$GREEN" ;;
      llamacpp)
        [ "$GPU_BRAND" = "none" ] && STAR="⭐ Idéal CPU"    && STAR_COL="$GREEN"
        [ "$CUDA$ROCM" != "00"  ] && STAR="✦ Perf native"  && STAR_COL="$CYAN" ;;
      vllm)
        [ "$CUDA" = "1" ] && [ "$EFFECTIVE" -ge 16 ] \
                           && STAR="⭐ GPU haute perf" && STAR_COL="$GREEN" ;;
      lmstudio) STAR="✦ Interface GUI";       STAR_COL="$CYAN" ;;
      localai)  STAR="✦ API OpenAI-compat";  STAR_COL="$CYAN" ;;
    esac

    if [ "$COMPAT" = "1" ]; then
      AVAIL_BACKENDS+=("$BK_ID")
      printf "  ${GREEN}[%d]${NC} ${BOLD}%-14s${NC} %b%-20s%b %s\n" \
        "$IDX" "$BK_LABEL" "$STAR_COL" "$STAR" "$NC" "$BK_DESC"
      IDX=$(( IDX + 1 ))
    else
      printf "  ${DIM}[--] %-14s ⚠  %s${NC}\n" "$BK_LABEL" "$WHY"
    fi
  done

  echo ""
  echo -e "  ${CYAN}── Aide au choix ────────────────────────────────────────────────────${NC}"
  echo ""
  echo -e "  ${GREEN}Ollama${NC}     Le + simple. GPU/CPU auto. Open WebUI intégré. ${BOLD}Recommandé.${NC}"
  echo -e "  ${GREEN}llama.cpp${NC}  Compilé natif — meilleur sur CPU (AVX2/AVX-512) ou GPU sans Docker."
  echo -e "  ${GREEN}LocalAI${NC}    API drop-in OpenAI (Continue.dev, Cursor…). Docker requis."
  echo -e "  ${GREEN}LM Studio${NC}  GUI complète (AppImage). Idéal débutants. Gestion visuelle des modèles."
  echo -e "  ${GREEN}vLLM${NC}       Production NVIDIA. Throughput max (batching). ≥16 Go VRAM requis."
  echo ""

  # Suggestion par défaut selon profil
  local DEFAULT_BK="ollama"
  case "$PROFILE" in
    MID)      [ "$GPU_BRAND" = "none" ] && DEFAULT_BK="llamacpp" ;;
    HIGH_END) [ "$CUDA" = "1" ] && DEFAULT_BK="vllm" ;;
  esac
  local DEFAULT_IDX=1
  for i in "${!AVAIL_BACKENDS[@]}"; do
    [ "${AVAIL_BACKENDS[$i]}" = "$DEFAULT_BK" ] && DEFAULT_IDX=$(( i + 1 ))
  done

  echo -e "  ${DIM}Entrée = suggestion par défaut : [${DEFAULT_IDX}] ${DEFAULT_BK}${NC}"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Ton choix [1-${#AVAIL_BACKENDS[@]}] : ${NC}")" BK_CHOICE
  BK_CHOICE="${BK_CHOICE:-$DEFAULT_IDX}"

  local CHOSEN="ollama"
  if [[ "$BK_CHOICE" =~ ^[0-9]+$ ]] \
      && [ "$BK_CHOICE" -ge 1 ] \
      && [ "$BK_CHOICE" -le "${#AVAIL_BACKENDS[@]}" ]; then
    CHOSEN="${AVAIL_BACKENDS[$(( BK_CHOICE - 1 ))]}"
  else
    warn "Choix invalide — Ollama sélectionné par défaut."
  fi

  HW[backend]="$CHOSEN"
  CFG[backend]="$CHOSEN"

  echo ""
  ok "Backend sélectionné : ${BOLD}${CHOSEN^^}${NC}"

  case "$CHOSEN" in
    llamacpp)
      info "llama.cpp sera compilé avec gcc/cmake (GPU si CUDA/ROCm détecté)."
      info "API REST sur http://localhost:8080 · Compatible Open WebUI." ;;
    localai)
      info "LocalAI via Docker · API OpenAI-compatible sur port 8080."
      info "Compatible Continue.dev, Cursor, Obsidian, SillyTavern…" ;;
    lmstudio)
      info "LM Studio AppImage (~500 Mo) téléchargé dans ~/Applications."
      warn "Le pull automatique des modèles ci-après s'effectuera via Ollama (coexistence)." ;;
    vllm)
      info "vLLM via Docker · API OpenAI-compatible sur port 8000."
      info "Optimisé throughput : paged attention + continuous batching." ;;
  esac
  echo ""
  sleep 1
}

# ================================================================
#  SECTION 2 : BILAN & PLAN D'INSTALLATION
# ================================================================

build_install_plan() {
  title "BILAN & PLAN D'INSTALLATION"

  declare -ga PLAN=()
  declare -gA PLAN_DESC=()
  declare -gA PLAN_REBOOT=()

  # ── Calcul mémoire effective pour les modèles ─────────────────
  local VRAM=${HW[gpu_vram_gb]:-0}
  local RAM=${HW[ram_gb]:-8}
  HW[effective_mem]=$VRAM
  [ "$VRAM" -eq 0 ] && HW[effective_mem]=$(( RAM * 60 / 100 ))

  # Profil matériel
  local PROFILE="LOW"
  [ "${HW[effective_mem]}" -ge 5  ] && PROFILE="LOW_MID"
  [ "${HW[effective_mem]}" -ge 8  ] && PROFILE="MID"
  [ "${HW[effective_mem]}" -ge 16 ] && PROFILE="UPPER_MID"
  [ "${HW[effective_mem]}" -ge 40 ] && PROFILE="HIGH_END"
  HW[profile]="$PROFILE"

  # ── Affichage récap matériel ──────────────────────────────────
  box_top
  box_line "CPU"           "${HW[cpu_model]:0:32}"
  box_line "Cœurs/Threads" "${HW[cpu_cores]}c / ${HW[cpu_threads]}t"
  box_line "RAM"           "${HW[ram_gb]} Go"
  box_sep
  box_line "GPU"           "${HW[gpu_model]:0:32}"
  box_line "Marque GPU"    "${HW[gpu_brand]^^}"
  [ "${HW[gpu_vram_gb]}" -gt 0 ] && box_line "VRAM" "${HW[gpu_vram_gb]} Go (${HW[gpu_vram_source]})"
  box_line "Accélération"  "$( [ "${HW[gpu_cuda_capable]}" = "1" ] && echo "CUDA" || [ "${HW[gpu_rocm_capable]}" = "1" ] && echo "ROCm" || echo "CPU only" )"
  box_sep
  box_line "Profil IA"     "$PROFILE (mém. eff. ${HW[effective_mem]} Go)"
  [ -n "${CFG[backend]:-}" ] &&     box_line "Backend IA"    "${CFG[backend]} (moteur d'inférence)"
  box_line "Image Docker"  "${HW[gpu_docker_img]##*/}"
  # Backend sera choisi juste après — affiché dans le récap final
  box_bot

  # ── Choix du backend d'inférence ─────────────────────────────
  select_backend
  local CHOSEN_BACKEND="${HW[backend]:-ollama}"

  # ── Construction du plan d'installation ──────────────────────
  step "Construction du plan d'installation"

  # Étape 1 : MAJ système (toujours)
  PLAN+=("UPDATE")
  PLAN_DESC["UPDATE"]="Mise à jour système ($OS_FAMILY / $PKG_MGR)"
  PLAN_REBOOT["UPDATE"]="non"

  # Étape 2 : Paquets de base (toujours)
  PLAN+=("BASE_PKGS")
  PLAN_DESC["BASE_PKGS"]="Installation paquets de base (curl, git, python3...)"
  PLAN_REBOOT["BASE_PKGS"]="non"

  # Étape 3 : Drivers GPU (selon marque et état)
  if [ "${HW[gpu_brand]}" = "nvidia" ] && [ "${HW[gpu_driver_installed]}" = "non" ]; then
    PLAN+=("DRIVER_NVIDIA")
    PLAN_DESC["DRIVER_NVIDIA"]="Driver NVIDIA ${HW[gpu_driver_pkg]} (${HW[gpu_model]})"
    PLAN_REBOOT["DRIVER_NVIDIA"]="oui"
    neutral "→ Driver NVIDIA nécessaire — reboot prévu après"

  elif [ "${HW[gpu_brand]}" = "amd" ] && [ "${HW[gpu_rocm_capable]}" = "1" ] && [ "${SYS[rocm]}" = "non" ]; then
    PLAN+=("DRIVER_AMD_FIRMWARE")
    PLAN_DESC["DRIVER_AMD_FIRMWARE"]="Firmware AMD + ROCm (${HW[gpu_model]})"
    PLAN_REBOOT["DRIVER_AMD_FIRMWARE"]="oui"
    neutral "→ ROCm AMD nécessaire — reboot prévu après"

  elif [ "${HW[gpu_brand]}" = "amd" ] && [ "${HW[gpu_rocm_capable]}" = "0" ]; then
    PLAN+=("DRIVER_AMD_FIRMWARE")
    PLAN_DESC["DRIVER_AMD_FIRMWARE"]="Firmware AMD amdgpu (${HW[gpu_model]})"
    PLAN_REBOOT["DRIVER_AMD_FIRMWARE"]="non"
    neutral "→ Firmware AMD (driver libre intégré au kernel)"

  elif [ "${HW[gpu_brand]}" = "nvidia" ] && [ "${HW[gpu_driver_installed]}" = "oui" ]; then
    ok "Driver NVIDIA déjà installé — étape ignorée"

  else
    neutral "Pas de driver GPU à installer"
  fi

  # Étape 4 : Docker
  if [ "${SYS[docker]}" = "non" ]; then
    PLAN+=("DOCKER")
    PLAN_DESC["DOCKER"]="Docker + Docker Compose"
    PLAN_REBOOT["DOCKER"]="non"
  else
    ok "Docker déjà installé — étape ignorée"
  fi

  # Étape 5 : Container runtime GPU
  if [ "${HW[gpu_brand]}" = "nvidia" ] && [ "${SYS[nv_toolkit]}" = "non" ]; then
    PLAN+=("NV_TOOLKIT")
    PLAN_DESC["NV_TOOLKIT"]="NVIDIA Container Toolkit (Docker GPU)"
    PLAN_REBOOT["NV_TOOLKIT"]="non"
  elif [ "${HW[gpu_brand]}" = "amd" ] && [ "${HW[gpu_rocm_capable]}" = "1" ]; then
    PLAN+=("AMD_DOCKER_RUNTIME")
    PLAN_DESC["AMD_DOCKER_RUNTIME"]="Configuration Docker pour ROCm AMD"
    PLAN_REBOOT["AMD_DOCKER_RUNTIME"]="non"
  fi

  # Étape 6 : Disque stockage
  PLAN+=("DISK_SETUP")
  PLAN_DESC["DISK_SETUP"]="Montage & configuration disque stockage IA"
  PLAN_REBOOT["DISK_SETUP"]="non"

  # Étape 7 : Swap
  if [ "${SYS[swapfile]}" = "non" ]; then
    local SWAP_SIZE="4G"
    [ "${HW[ram_gb]}" -le 8 ] && SWAP_SIZE="8G"
    PLAN+=("SWAP")
    PLAN_DESC["SWAP"]="Swapfile $SWAP_SIZE sur SSD (complément RAM)"
    PLAN_REBOOT["SWAP"]="non"
  else
    ok "Swapfile existant — étape ignorée"
  fi

  # Étape 8 : Backend d'inférence (selon choix)
  case "$CHOSEN_BACKEND" in

    ollama)
      if [ "${SYS[ollama]}" = "non" ]; then
        PLAN+=("OLLAMA")
        PLAN_DESC["OLLAMA"]="Ollama — moteur d'inférence local (installation)"
        PLAN_REBOOT["OLLAMA"]="non"
      else
        ok "Ollama déjà installé — mise à jour uniquement"
        PLAN+=("OLLAMA")
        PLAN_DESC["OLLAMA"]="Ollama — vérification + mise à jour"
        PLAN_REBOOT["OLLAMA"]="non"
      fi ;;

    llamacpp)
      PLAN+=("LLAMACPP")
      PLAN_DESC["LLAMACPP"]="llama.cpp — compilation native (CPU+GPU)"
      PLAN_REBOOT["LLAMACPP"]="non"
      # Ollama coexiste en optionnel pour le pull de modèles
      if [ "${SYS[ollama]}" = "non" ]; then
        PLAN+=("OLLAMA")
        PLAN_DESC["OLLAMA"]="Ollama — co-installation pour gestion des modèles"
        PLAN_REBOOT["OLLAMA"]="non"
        neutral "→ Ollama sera co-installé pour télécharger les modèles GGUF"
      fi ;;

    localai)
      PLAN+=("LOCALAI")
      PLAN_DESC["LOCALAI"]="LocalAI — Docker API OpenAI-compatible"
      PLAN_REBOOT["LOCALAI"]="non" ;;

    lmstudio)
      PLAN+=("LMSTUDIO")
      PLAN_DESC["LMSTUDIO"]="LM Studio — AppImage interface graphique"
      PLAN_REBOOT["LMSTUDIO"]="non"
      # Ollama co-installé pour pull des modèles depuis ce script
      PLAN+=("OLLAMA")
      PLAN_DESC["OLLAMA"]="Ollama — co-installation pour pull des modèles"
      PLAN_REBOOT["OLLAMA"]="non"
      neutral "→ Ollama sera co-installé pour le téléchargement des modèles" ;;

    vllm)
      PLAN+=("VLLM")
      PLAN_DESC["VLLM"]="vLLM — inférence GPU production (Docker+CUDA)"
      PLAN_REBOOT["VLLM"]="non" ;;

    *)
      warn "Backend inconnu '$CHOSEN_BACKEND' — Ollama par défaut."
      PLAN+=("OLLAMA")
      PLAN_DESC["OLLAMA"]="Ollama (moteur d'inférence local)"
      PLAN_REBOOT["OLLAMA"]="non" ;;
  esac

  # Étape 9 : Sélection + pull modèles
  PLAN+=("MODELS")
  PLAN_DESC["MODELS"]="Sélection & téléchargement des modèles IA"
  PLAN_REBOOT["MODELS"]="non"

  # Étape 10 : Open WebUI
  PLAN+=("WEBUI")
  PLAN_DESC["WEBUI"]="Open WebUI (interface web)"
  PLAN_REBOOT["WEBUI"]="non"

  # Étape 11 : Backup + crontab
  PLAN+=("BACKUP")
  PLAN_DESC["BACKUP"]="Script backup automatique + crontab"
  PLAN_REBOOT["BACKUP"]="non"

  # Étape 12 : Dashboard web (si python3 disponible)
  if command -v python3 &>/dev/null; then
    PLAN+=("DASHBOARD")
    PLAN_DESC["DASHBOARD"]="Dashboard web stats temps réel (port ${DASHBOARD_PORT:-7842})"
    PLAN_REBOOT["DASHBOARD"]="non"
  fi


  # ── Affichage backend retenu ─────────────────────────────────
  echo ""
  echo -e "  ${BOLD}Backend d'inférence retenu : ${GREEN}${HW[backend]:-ollama}${NC}"
  echo ""

  # ── Affichage du plan ─────────────────────────────────────────
  echo ""
  echo -e "${BOLD}  Plan d'installation généré :${NC}\n"

  local STEP_NUM=1
  local REBOOT_COUNT=0
  for STEP in "${PLAN[@]}"; do
    local REBOOT_ICON=""
    if [ "${PLAN_REBOOT[$STEP]:-non}" = "oui" ]; then
      REBOOT_ICON=" ${YELLOW}[🔄 reboot]${NC}"
      REBOOT_COUNT=$(( REBOOT_COUNT + 1 ))
    fi
    echo -e "  ${GREEN}[$STEP_NUM]${NC} ${PLAN_DESC[$STEP]}${REBOOT_ICON}"
    STEP_NUM=$(( STEP_NUM + 1 ))
  done

  echo ""
  [ "$REBOOT_COUNT" -gt 0 ] \
    && warn "$REBOOT_COUNT reboot(s) programmé(s) — reprise automatique à chaque fois" \
    || ok "Aucun reboot nécessaire"
}

# ================================================================
#  SECTION 3 : CATALOGUE & SÉLECTION DES MODÈLES
# ================================================================

select_models_smart() {
  title "SÉLECTION INTELLIGENTE DES MODÈLES"

  # Rafraîchir VRAM si drivers maintenant disponibles
  if [ "${HW[gpu_brand]}" = "nvidia" ] && command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    local FRESH
    FRESH=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    if [ "$FRESH" -gt 0 ]; then
      local NEW_VRAM=$(( FRESH / 1024 ))
      if [ "$NEW_VRAM" -ne "${HW[gpu_vram_gb]:-0}" ]; then
        warn "VRAM corrigée : ${HW[gpu_vram_gb]:-0} Go → $NEW_VRAM Go (nvidia-smi)"
        HW[gpu_vram_gb]=$NEW_VRAM
        HW[gpu_vram_source]="nvidia-smi"
        # Recalcul profil
        HW[effective_mem]=$NEW_VRAM
        [ "$NEW_VRAM" -ge 5  ] && HW[profile]="LOW_MID"
        [ "$NEW_VRAM" -ge 8  ] && HW[profile]="MID"
        [ "$NEW_VRAM" -ge 16 ] && HW[profile]="UPPER_MID"
        [ "$NEW_VRAM" -ge 40 ] && HW[profile]="HIGH_END"
      else
        ok "VRAM confirmée : ${HW[gpu_vram_gb]} Go (nvidia-smi = base de données ✓)"
      fi
    fi
  fi

  local EFFECTIVE=${HW[effective_mem]:-4}
  local RAM=${HW[ram_gb]:-8}
  local PROFILE="${HW[profile]:-LOW}"

  # Catalogue des modèles
  # ── Catalogue complet — format : nom:vram_go:ram_go:type:description:score/10
  # Types : general, code, reasoning, vision, embedding, multilingual, creative
  # Score : 1-10 (qualité globale dans la catégorie à taille équivalente)
  local -a CATALOG=(
    # ── Embedding & RAG ─────────────────────────────────────────────────────
    "nomic-embed-text:1:2:embedding:Embedding RAG — indispensable pour bases de docs:9"
    "mxbai-embed-large:1:2:embedding:Meilleur embedding open-source 2024:10"
    "all-minilm:1:2:embedding:Ultra-léger — bon pour CPU faible:7"
    # ── Très petits modèles (< 4 Go VRAM / < 6 Go RAM) ─────────────────────
    "qwen2.5:0.5b:1:2:general:Minuscule mais fonctionnel Qwen2.5:5"
    "smollm2:0.5b:1:2:general:HuggingFace SmolLM2 — le plus compact:5"
    "qwen2.5:1.5b:2:3:general:Ultra-léger Qwen2.5 1.5B:6"
    "smollm2:1.7b:2:3:general:SmolLM2 1.7B équilibré compact:6"
    "qwen2.5-coder:1.5b:2:3:code:Complétion code légère rapide:6"
    "phi4-mini:2:4:general:Microsoft Phi-4 Mini — excellent petit modèle:8"
    "phi3:mini:2:4:general:Microsoft Phi3 Mini efficace:7"
    "gemma3:1b:1:3:general:Google Gemma3 1B — très efficace:7"
    "gemma2:2b:2:4:general:Google Gemma2 2B compact:6"
    # ── Petits modèles (4-8 Go VRAM / 6-12 Go RAM) ──────────────────────────
    "llama3.2:3b:2:5:general:Llama 3.2 3B compact et efficace:7"
    "qwen2.5:3b:3:6:general:Qwen 3B bon équilibre:7"
    "mistral-nemo:4b:3:6:multilingual:Mistral Nemo 4B — excellent multilingue FR:9"
    "phi3:medium:4:8:general:Phi3 Medium — très bon rapport taille/perf:8"
    "phi4:4:8:general:Microsoft Phi-4 — meilleur modèle 4B:9"
    "gemma3:4b:4:8:general:Google Gemma3 4B — polyvalent:8"
    "gemma3:4b-it:4:8:general:Gemma3 4B instruct — dialogue optimisé:8"
    # ── Modèles 7-9B (5-10 Go VRAM / 10-16 Go RAM) ──────────────────────────
    "mistral:7b:5:10:general:Mistral 7B — référence généraliste:8"
    "mistral-nemo:12b:8:14:multilingual:Mistral Nemo 12B — excellent FR/EU:9"
    "qwen2.5:7b:5:10:general:Qwen 2.5 7B — excellent:8"
    "qwen2.5-coder:7b:5:10:code:Meilleur code 7B open-source:9"
    "llama3.1:8b:5:12:general:Llama 3.1 8B — modèle de référence:8"
    "llama3.3:8b:5:12:general:Llama 3.3 8B — dernière version Meta:9"
    "deepseek-coder:6.7b:5:10:code:DeepSeek Coder 6.7B spécialisé:8"
    "deepseek-r1:7b:5:12:reasoning:DeepSeek-R1 7B — raisonnement chaîné:9"
    "gemma3:9b:6:14:general:Google Gemma3 9B — polyvalent:8"
    "gemma2:9b:6:14:general:Google Gemma2 9B — solide:8"
    "llava:7b:5:12:vision:Vision + texte multimodal:7"
    "llava-llama3:8b:6:12:vision:Vision Llama3 — meilleure qualité:8"
    "moondream:1.8b:2:4:vision:Vision ultra-léger (photos simples):6"
    # ── Modèles 13-14B (9-18 Go VRAM / 16-28 Go RAM) ────────────────────────
    "qwen2.5:14b:9:18:general:Qwen 2.5 14B — haute qualité:9"
    "qwen2.5-coder:14b:9:18:code:Code 14B — état de l'art:10"
    "deepseek-r1:14b:9:18:reasoning:DeepSeek-R1 14B — raisonnement avancé:9"
    "llama3.1:13b:9:18:general:Llama 3.1 13B — très bon:8"
    "llama3.3:13b:9:18:general:Llama 3.3 13B — Meta 2025:9"
    "phi4:14b:9:18:general:Phi-4 14B — Microsoft excellence:10"
    "mistral:12b:8:16:general:Mistral 12B — excellent FR:9"
    "gemma3:12b:8:16:general:Gemma3 12B — polyvalent Google:9"
    "codestral:22b:14:24:code:Mistral Codestral — code professionnel:10"
    # ── Grands modèles (20-45 Go VRAM / 32-64 Go RAM) ────────────────────────
    "deepseek-r1:32b:20:40:reasoning:DeepSeek-R1 32B — expert raisonnement:10"
    "qwen2.5:32b:20:40:general:Qwen 2.5 32B — excellence:10"
    "mixtral:8x7b:24:48:general:Mixtral MoE 8x7B — diversité:9"
    "deepseek-v3:32b:20:40:general:DeepSeek-V3 — meilleur open-source 2025:10"
    "gemma3:27b:18:36:general:Google Gemma3 27B — très complet:9"
    # ── Très grands modèles (45+ Go VRAM / 64+ Go RAM) ───────────────────────
    "llama3.1:70b:45:80:general:Llama 3.1 70B — quasi GPT-4:10"
    "llama3.3:70b:45:80:general:Llama 3.3 70B — Meta 2025 flagship:10"
    "qwen2.5:72b:45:80:general:Qwen 2.5 72B — excellence:10"
    "deepseek-r1:70b:45:80:reasoning:DeepSeek-R1 70B — raisonnement maximal:10"
    "deepseek-v3:671b:200:400:general:DeepSeek-V3 full — cluster requis:10"
  )

  declare -ga COMPATIBLE_MODELS=()
  declare -ga AUTO_SUGGEST=("nomic-embed-text")
  declare -gA MODEL_TO_IDX_MAP=() # Nouvelle map pour nom de modèle -> index

  echo -e "${CYAN}  Mémoire effective : ${BOLD}${EFFECTIVE} Go${NC}"
  echo -e "${CYAN}  Profil matériel   : ${BOLD}${PROFILE}${NC}"
  [ "${HW[gpu_brand]}" != "none" ] && echo -e "${CYAN}  GPU               : ${BOLD}${HW[gpu_brand]^^} — ${HW[gpu_model]}${NC}"
  echo ""

  # En-tête tableau
  printf "  ${BOLD}%-4s %-26s %-10s %5s  %-8s %s${NC}\n" \
    "N°" "Modèle" "Type" "VRAM" "Score" "Description"
  hr

  local IDX=1
  for ENTRY in "${CATALOG[@]}"; do
    # Cette regex capture le nom complet du modèle (pouvant contenir des ':'),
    # suivi des 5 champs restants (VRAM_NEED, RAM_NEED, TYPE, DESC, SCORE).
    if [[ "$ENTRY" =~ ^(.*):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)$ ]]; then
      NAME="${BASH_REMATCH[1]}"
      VRAM_NEED="${BASH_REMATCH[2]}"
      RAM_NEED="${BASH_REMATCH[3]}"
      TYPE="${BASH_REMATCH[4]}"
      DESC="${BASH_REMATCH[5]}"
      SCORE="${BASH_REMATCH[6]}"
    else
      warn "Format de l'entrée du catalogue inattendu: $ENTRY"
      continue # Passe à l'entrée suivante si le format est incorrect
    fi

    if [ "$VRAM_NEED" -le "$EFFECTIVE" ] || [ "$RAM_NEED" -le "$RAM" ]; then
      COMPATIBLE_MODELS+=("$NAME")
      MODEL_TO_IDX_MAP["$NAME"]="$IDX" # Stocke le mappage nom -> index

      # Icône score
      local ICON=" "
      local COL="$NC"
      [ "$SCORE" -ge 9 ] && ICON="⭐" && COL="$GREEN"
      [ "$SCORE" -ge 7 ] && [ "$SCORE" -lt 9 ] && ICON="✦" && COL="$CYAN"
      [ "$TYPE" = "embedding" ] && ICON="📎" && COL="$MAGENTA"
      printf "  ${GREEN}[%2d]${NC} %-26s %-10s %3dGo  [%d/10] %b%s %s%b\n" \
        "$IDX" "$NAME" "$TYPE" "$VRAM_NEED" "$SCORE" "$COL" "$ICON" "$DESC" "$NC"
      IDX=$(( IDX + 1 ))
    fi
  done

  echo ""
  echo -e "${RED}  Modèles hors de portée (VRAM/RAM insuffisante) :${NC}"
  for ENTRY in "${CATALOG[@]}"; do
    # Le parsing est refait ici pour la cohérence, car la liste AUTO_SUGGEST n'est pas basée sur l'index des compatible_models.
    # Ceci garantit que $NAME est correctement défini pour l'affichage.
    if [[ "$ENTRY" =~ ^(.*):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)$ ]]; then
      NAME="${BASH_REMATCH[1]}"
      VRAM_NEED="${BASH_REMATCH[2]}"
      RAM_NEED="${BASH_REMATCH[3]}"
      TYPE="${BASH_REMATCH[4]}"
      DESC="${BASH_REMATCH[5]}"
      SCORE="${BASH_REMATCH[6]}"
    else
      continue # Passe à l'entrée suivante si le format est incorrect
    fi
    if [ "$VRAM_NEED" -gt "$EFFECTIVE" ] && [ "$RAM_NEED" -gt "$RAM" ]; then
      printf "  ${DIM}  [--] %-26s  %dGo requis — %s${NC}\n" "$NAME" "$VRAM_NEED" "$DESC"
    fi
  done

  # Suggestion auto par profil
  echo ""
  echo -e "${BOLD}  💡 Suggestion optimale pour profil $PROFILE :${NC}"
  case "$PROFILE" in
    LOW)
      AUTO_SUGGEST+=("smollm2:1.7b" "phi4-mini" "qwen2.5-coder:1.5b")
      warn "Matériel très limité — modèles ultra-légers seulement (<4 Go)"
      info "Conseil : phi4-mini ou smollm2:1.7b offrent le meilleur rapport qualité/taille" ;;
    LOW_MID)
      AUTO_SUGGEST+=("mistral-nemo:4b" "phi4" "qwen2.5-coder:7b" "deepseek-r1:7b" "moondream:1.8b")
      info "Config correcte — modèles 4-7B confortables en VRAM"
      info "Conseil : mistral-nemo:4b excellent pour le français" ;;
    MID)
      AUTO_SUGGEST+=("llama3.3:8b" "qwen2.5-coder:7b" "deepseek-r1:7b" "mistral-nemo:12b" "llava-llama3:8b")
      ok "Bonne config — 7-12B optimaux"
      info "Conseil : llama3.3:8b + qwen2.5-coder:7b + nomic-embed-text = combo parfait" ;;
    UPPER_MID)
      AUTO_SUGGEST+=("phi4:14b" "qwen2.5-coder:14b" "deepseek-r1:14b" "mistral-nemo:12b" "llava-llama3:8b")
      ok "Excellente config — 13-14B accessibles confortablement"
      info "Conseil : phi4:14b est actuellement le meilleur modèle open-source à cette taille" ;;
    HIGH_END)
      AUTO_SUGGEST+=("deepseek-v3:32b" "qwen2.5-coder:14b" "deepseek-r1:32b" "llama3.3:70b" "gemma3:27b")
      ok "Machine puissante — 32B-70B possibles"
      info "Conseil : deepseek-v3:32b rivalise avec GPT-4 sur de nombreux benchmarks" ;;
  esac

  for S in "${AUTO_SUGGEST[@]}"; do
    local SUGGESTED_IDX="${MODEL_TO_IDX_MAP["$S"]}"
    if [ -n "$SUGGESTED_IDX" ]; then
      echo -e "    ${GREEN}[$SUGGESTED_IDX]${NC} ${GREEN}✓${NC} $S"
    else
      echo -e "    ${GREEN}✓${NC} $S ${DIM}(non numéroté car pas dans la liste principale ou nom inexact)${NC}" # Fallback
    fi
  done

  echo ""
  echo -e "${BOLD}  Sélection :${NC}"
  echo -e "  ${DIM}Entrée seule = suggestion ci-dessus${NC}"
  echo -e "  ${DIM}Numéros séparés par espaces (ex: 1 3 7)${NC}"
  echo -e "  ${DIM}[+] = saisir un nom de modèle manuellement${NC}"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Ton choix : ${NC}")" MODEL_CHOICE

  declare -ga SELECTED_MODELS=()

  if [ -z "$MODEL_CHOICE" ]; then
    SELECTED_MODELS=("${AUTO_SUGGEST[@]}")
  else
    local I=1
    local _SAVE_IFS="$IFS"; IFS=' 	
'
    for M in "${COMPATIBLE_MODELS[@]}"; do
      for NUM in $MODEL_CHOICE; do
        if [ "$NUM" = "+" ]; then
          read -rp "$(echo -e "${YELLOW}    >>> Nom du modèle : ${NC}")" CUSTOM
          [ -n "$CUSTOM" ] && SELECTED_MODELS+=("$CUSTOM")
        elif [ "$NUM" = "$I" ]; then
          SELECTED_MODELS+=("$M")
        fi
      done
      I=$(( I + 1 ))
    done
    IFS="$_SAVE_IFS"
  fi

  [ "${#SELECTED_MODELS[@]}" -eq 0 ] && error "Aucun modèle sélectionné."

  echo ""
  ok "Modèles sélectionnés :"
  for M in "${SELECTED_MODELS[@]}"; do echo -e "    ${GREEN}→${NC} $M"; done
}

# ================================================================
#  SECTION 4 : EXÉCUTION DES ÉTAPES DU PLAN
# ================================================================


execute_step() {
  local STEP="$1"

  case "$STEP" in

    # ────────────────────────────────────────────────────────────
    UPDATE)
      title "MISE À JOUR SYSTÈME — $OS_DISTRO ($OS_FAMILY / $PKG_MGR)"
      CURRENT_STEP="UPDATE"
      pkg_update
      pkg_upgrade
      pkg_autoremove
      log "Système à jour."
      ;;

    # ────────────────────────────────────────────────────────────
    BASE_PKGS)
      title "PAQUETS DE BASE"
      CURRENT_STEP="BASE_PKGS"
      info "Distro : $OS_DISTRO | Famille : $OS_FAMILY | Gestionnaire : $PKG_MGR"
      echo ""

      local PKGS_TO_CHECK=(
        "curl" "wget" "git" "htop" "pciutils"
        "smartmontools" "dmidecode" "build-essential" "cmake"
        "ca-certificates" "gnupg" "unzip" "zip" "p7zip-full"
        "python3-pip" "python3-dev" "net-tools" "ethtool" "nvtop"
      )
      local FAILED_PKGS=0
      for P in "${PKGS_TO_CHECK[@]}"; do
        if ! pkg_installed "$P"; then
          if ! pkg_install "$P"; then
            warn "Échec d'installation de $P."
            FAILED_PKGS=$(( FAILED_PKGS + 1 ))
          fi
        else
          ok "$P déjà installé."
        fi
      done

      # Paquets spécifiques à certaines familles
      case "$OS_FAMILY" in
        debian)
          if ! pkg_installed lsb-release; then pkg_install lsb-release || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed software-properties-common; then pkg_install software-properties-common || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed apt-transport-https; then pkg_install apt-transport-https || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed python3-venv; then pkg_install python3-venv || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed mokutil; then pkg_install mokutil 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          ;;
        rhel)
          if ! pkg_installed epel-release; then pkg_install epel-release 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed python3-venv; then pkg_install python3-venv 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          ;;
        arch)
          if ! pkg_installed python-virtualenv; then pkg_install python-virtualenv 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          # Installer yay si aucun AUR helper présent
          if [ -z "${AUR_HELPER:-}" ]; then
            info "Installation de yay (AUR helper)..."
            local YAY_TMP; YAY_TMP=$(mktemp -d /tmp/yay-build-$$.XXXXXX)
            sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay-bin.git "$YAY_TMP" 2>/dev/null && {
              # Nettoyage garanti même si le build échoue
              trap 'rm -rf "$YAY_TMP" 2>/dev/null' RETURN
              cd "$YAY_TMP"
              sudo -u "$REAL_USER" makepkg -si --noconfirm && ok "yay installé." || { warn "yay non installé — certains paquets AUR indisponibles."; FAILED_PKGS=$((FAILED_PKGS+1)); }
              cd /
              AUR_HELPER="yay"
            } || { warn "yay non installé — certains paquets AUR indisponibles."; FAILED_PKGS=$((FAILED_PKGS+1)); }
          fi
          ;;
        suse)
          if ! pkg_installed python3-virtualenv; then pkg_install python3-virtualenv 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          ;;
        alpine)
          if ! pkg_installed python3-dev; then pkg_install python3-dev 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed py3-virtualenv; then pkg_install py3-virtualenv 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          if ! pkg_installed bash; then pkg_install bash 2>/dev/null || FAILED_PKGS=$((FAILED_PKGS+1)); fi
          ;;
      esac

      if [ "$FAILED_PKGS" -eq 0 ]; then
        log "Paquets de base installés."
        return 0 # Success
      else
        warn "$FAILED_PKGS paquet(s) de base n'ont pas pu être installés."
        return 1 # Failure
      fi
      ;;

    # ────────────────────────────────────────────────────────────
    DRIVER_NVIDIA)
      title "DRIVER NVIDIA — ${HW[gpu_model]}"
      CURRENT_STEP="DRIVER_NVIDIA"
      info "Carte  : ${HW[gpu_model]}"
      info "VRAM   : ${HW[gpu_vram_gb]} Go (${HW[gpu_vram_source]})"
      info "Driver : ${HW[gpu_driver_pkg]}"
      info "Méthode: $NVIDIA_DRIVER_METHOD (distro: $OS_DISTRO)"
      echo ""
      install_nvidia_driver
      log "Driver NVIDIA installé — reboot requis."
      ;;

    # ────────────────────────────────────────────────────────────
    DRIVER_AMD_FIRMWARE)
      title "DRIVER AMD — ${HW[gpu_model]}"
      CURRENT_STEP="DRIVER_AMD_FIRMWARE"
      info "Carte : ${HW[gpu_model]}"
      info "ROCm  : $([ "${HW[gpu_rocm_capable]}" = "1" ] && echo "oui" || echo "non (driver libre)")"
      echo ""
      pkg_install firmware-amd-graphics linux-firmware 2>/dev/null || true

      if [ "${HW[gpu_rocm_capable]}" = "1" ]; then
        info "Installation ROCm (distro: $OS_DISTRO / famille: $OS_FAMILY)..."
        install_rocm
        log "ROCm installé."
      else
        usermod -aG video "$REAL_USER" 2>/dev/null || true
        log "Firmware AMD installé (driver libre amdgpu)."
      fi
      ;;

    # ────────────────────────────────────────────────────────────
    DOCKER)
      title "DOCKER"
      CURRENT_STEP="DOCKER"
      install_docker_proper
      log "Docker prêt."
      ;;

    # ────────────────────────────────────────────────────────────
    NV_TOOLKIT)
      title "NVIDIA CONTAINER TOOLKIT"
      CURRENT_STEP="NV_TOOLKIT"
      install_nvidia_container_toolkit
      log "NVIDIA Container Toolkit prêt."
      ;;

    # ────────────────────────────────────────────────────────────
    AMD_DOCKER_RUNTIME)
      title "DOCKER RUNTIME AMD ROCm"
      CURRENT_STEP="AMD_DOCKER_RUNTIME"
      svc_restart docker
      log "Docker configuré pour ROCm (accès via --device /dev/kfd)."
      ;;

    # ────────────────────────────────────────────────────────────
    DISK_SETUP)
      title "CONFIGURATION DISQUE STOCKAGE"
      CURRENT_STEP="DISK_SETUP"
      mkdir -p "${CFG[hdd_mount]}"

      if ! mountpoint -q "${CFG[hdd_mount]}"; then
        local FS_TYPE
        FS_TYPE=$(blkid -o value -s TYPE "${CFG[hdd_dev]}" 2>/dev/null || echo "")
        if [ "$FS_TYPE" != "ext4" ]; then
          warn "Disque ${CFG[hdd_dev]} : filesystem '$FS_TYPE'."
          confirm "Formater en ext4 (EFFACE TOUTES LES DONNÉES) ?" && {
            mkfs.ext4 -L "${CFG[hdd_label]}" "${CFG[hdd_dev]}"
            log "Formatage terminé."
          } || warn "Formatage ignoré."
        fi
        mount "${CFG[hdd_dev]}" "${CFG[hdd_mount]}" || warn "Montage échoué."
        grep -qF "${CFG[hdd_label]}" /etc/fstab || \
          echo "LABEL=${CFG[hdd_label]}  ${CFG[hdd_mount]}  ext4  defaults,nofail  0  2" >> /etc/fstab
      else
        log "Disque déjà monté sur ${CFG[hdd_mount]}."
      fi

      mkdir -p "${CFG[ollama_dir]}/blobs" "${CFG[ollama_dir]}/manifests" \
               "${CFG[webui_dir]}" "${CFG[backup_dir]}"
      chown -R "$REAL_USER:$REAL_USER" "${CFG[hdd_mount]}"
      log "Arborescence créée sur ${CFG[hdd_mount]}."
      smartctl -H "${CFG[hdd_dev]}" 2>/dev/null \
        && ok "Santé disque SMART : OK" \
        || warn "SMART indisponible."
      ;;

    # ────────────────────────────────────────────────────────────
    SWAP)
      title "CONFIGURATION SWAP"
      CURRENT_STEP="SWAP"

      # Alpine : swap manuel recommandé
      [ "$OS_FAMILY" = "alpine" ] && { warn "Alpine : swap géré manuellement."; return 0; }

      local SWAP_SIZE="4G"
      [ "${HW[ram_gb]}" -le 8 ] && SWAP_SIZE="8G"
      local SWAPFILE="/swapfile"

      [ -f "$SWAPFILE" ] && { log "Swapfile existant."; return 0; }

      fallocate -l "$SWAP_SIZE" "$SWAPFILE" 2>/dev/null || \
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="${SWAP_SIZE%G}000" status=progress
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE"
      swapon "$SWAPFILE"
      grep -q "$SWAPFILE" /etc/fstab || \
        echo "$SWAPFILE  none  swap  sw  0  0" >> /etc/fstab
      log "Swap $SWAP_SIZE activé."
      ;;

    # ────────────────────────────────────────────────────────────
    OLLAMA)
      title "OLLAMA"
      CURRENT_STEP="OLLAMA"
      info "Distro : $OS_DISTRO | Famille : $OS_FAMILY"

      # ── Sauvegarde automatique avant installation Ollama ────────
      _auto_backup_before_update "ollama-install"

      # ── Avertissement durée d'installation ──────────────────────
      echo ""
      echo -e "  ${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
      echo -e "  ${YELLOW}║  ⏱  DURÉE D'INSTALLATION VARIABLE                       ║${NC}"
      echo -e "  ${YELLOW}║                                                          ║${NC}"
      echo -e "  ${YELLOW}║  Le téléchargement et l'installation d'Ollama peuvent    ║${NC}"
      echo -e "  ${YELLOW}║  prendre entre 5 et 45 minutes selon votre connexion     ║${NC}"
      echo -e "  ${YELLOW}║  réseau et les performances de votre machine.            ║${NC}"
      echo -e "  ${YELLOW}║                                                          ║${NC}"
      echo -e "  ${YELLOW}║  ${DIM}Ne fermez pas cette fenêtre pendant l'installation.${YELLOW}   ║${NC}"
      echo -e "  ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      sleep 2

      # Le script officiel Ollama détecte lui-même la distro
      _install_ollama_secure

      chown -R ollama:ollama "${CFG[ollama_dir]}" 2>/dev/null || true
      chmod -R 755 "${CFG[ollama_dir]}" 2>/dev/null || true

      # ── Demander si Ollama doit être accessible depuis le réseau local ──
      echo ""
      echo -e "  ${BOLD}Accessibilité réseau d'Ollama :${NC}"
      echo -e "  ${DIM}Par défaut Ollama écoute uniquement sur 127.0.0.1 (local).${NC}"
      echo -e "  ${DIM}Activer l'écoute externe permet d'accéder à l'API depuis${NC}"
      echo -e "  ${DIM}d'autres machines du réseau (ex: http://IP_MACHINE:11434).${NC}"
      echo -e "  ${YELLOW}⚠  À n'activer que sur un réseau de confiance (LAN privé).${NC}"
      echo ""
      local OLLAMA_BIND="127.0.0.1"
      if confirm "Autoriser l'accès externe à l'API Ollama (0.0.0.0:11434) ?"; then
        OLLAMA_BIND="0.0.0.0"
        ok "Ollama écoutera sur toutes les interfaces (0.0.0.0:11434)"
      else
        ok "Ollama restera local uniquement (127.0.0.1:11434)"
      fi
      CFG[ollama_host]="$OLLAMA_BIND"
      save_config

      if [ "$HAS_SYSTEMD" -eq 1 ]; then
        mkdir -p /etc/systemd/system/ollama.service.d

        # ── Calcul de l'adresse d'écoute ──────────────────────────────
        # "0.0.0.0:11434" force explicitement IPv4 sur toutes interfaces.
        # Sur certains kernels avec IPV6_V6ONLY=0 (dualstack), 0.0.0.0
        # peut être capturé par le socket IPv6 [::] en priorité.
        # Solution : écrire OLLAMA_HOST sans préfixe IP ("0.0.0.0") et
        # désactiver IPv6_V6ONLY pour que 0.0.0.0 couvre aussi IPv6.
        if [ "$OLLAMA_BIND" = "0.0.0.0" ]; then
          # Désactiver IPv6_V6ONLY globalement (si root) pour que 0.0.0.0
          # ouvre bien un socket dual-stack IPv4+IPv6
          sysctl -w net.ipv6.bindv6only=0 2>/dev/null || true
          # Persister le paramètre
          grep -qx 'net.ipv6.bindv6only=0' /etc/sysctl.conf 2>/dev/null             || echo 'net.ipv6.bindv6only=0' >> /etc/sysctl.conf 2>/dev/null || true
        fi

        cat > /etc/systemd/system/ollama.service.d/override.conf << SVCEOF
[Unit]
# S'assurer qu'Ollama attend le réseau (pour download de modèles)
After=network-online.target
Wants=network-online.target

[Service]
Environment="OLLAMA_MODELS=${CFG[ollama_dir]}"
Environment="OLLAMA_HOST=${OLLAMA_BIND}:11434"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
# Redémarrer automatiquement si crash
Restart=always
RestartSec=5
# Délai de démarrage plus long pour les machines avec disque lent
TimeoutStartSec=120
SVCEOF
        svc_daemon_reload
        svc_enable ollama
        svc_restart ollama

        # ── Vérifier que l'écoute est bien sur 0.0.0.0 et pas [::] ──
        sleep 3
        if [ "$OLLAMA_BIND" = "0.0.0.0" ]; then
          local _LISTEN
          _LISTEN=$(ss -tlnp 2>/dev/null | grep ':11434' | awk '{print $4}')
          if echo "$_LISTEN" | grep -q "^\[::\]:\|^:::"; then
            # Socket IPv6-only détecté → forcer via variable d'environnement
            warn "Socket IPv6-only détecté sur [::]:11434 — correction en cours..."
            # Certaines distros nécessitent l'adresse complète avec brackets supprimés
            # On peut aussi passer par la config Ollama directement
            if [ -f /usr/lib/systemd/system/ollama.service ]; then
              # Forcer via ExecStart override avec -a
              cat >> /etc/systemd/system/ollama.service.d/override.conf << SVCEOF2

# Forcer bind IPv4 explicite (contourne le dualstack kernel)
ExecStart=
ExecStart=/usr/bin/ollama serve
SVCEOF2
            fi
            svc_daemon_reload
            svc_restart ollama
            sleep 2
          fi
          _LISTEN=$(ss -tlnp 2>/dev/null | grep ':11434' | awk '{print $4}')
          ok "Ollama écoute sur : ${_LISTEN:-11434}"
        fi
      else
        # openrc / runit
        if [ -d /etc/conf.d ]; then
          cat > /etc/conf.d/ollama << CFGEOF
OLLAMA_MODELS="${CFG[ollama_dir]}"
OLLAMA_HOST="${OLLAMA_BIND}:11434"
OLLAMA_NUM_PARALLEL=1
OLLAMA_MAX_LOADED_MODELS=1
CFGEOF
        fi
        svc_enable ollama
        svc_restart ollama
      fi

      # ── Afficher l'IP locale pour info ──────────────────────────
      if [ "$OLLAMA_BIND" = "0.0.0.0" ]; then
        local _LOCAL_IP
        _LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
        echo ""
        ok "API Ollama accessible sur :"
        echo -e "  ${CYAN}→ http://127.0.0.1:11434${NC}  ${DIM}(local)${NC}"
        echo -e "  ${CYAN}→ http://${_LOCAL_IP:-<IP_MACHINE>}:11434${NC}  ${DIM}(réseau LAN)${NC}"
        echo -e "  ${DIM}Pense à ouvrir le port 11434 dans ton pare-feu si nécessaire.${NC}"
        # Ouvrir le port dans le pare-feu si ufw/firewalld disponible
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
          ufw allow 11434/tcp comment "Ollama API" 2>/dev/null && ok "Règle UFW ajoutée (11434/tcp)" || true
        elif command -v firewall-cmd &>/dev/null; then
          firewall-cmd --permanent --add-port=11434/tcp 2>/dev/null &&           firewall-cmd --reload 2>/dev/null && ok "Règle firewalld ajoutée (11434/tcp)" || true
        fi
      fi

      sleep 3
      svc_active ollama \
        && log "Ollama actif — modèles dans ${CFG[ollama_dir]}" \
        || warn "Ollama inactif. Vérifie les logs."
      ;;

    # ────────────────────────────────────────────────────────────
    DASHBOARD)
      title "DASHBOARD WEB"
      CURRENT_STEP="DASHBOARD"
      step "Installation du dashboard système..."
      install_dashboard_script
      install_dashboard_service
      local _LIP; _LIP=$(_dashboard_lan_ip)
      local _PORT="${DASHBOARD_PORT:-7842}"
      echo ""
      ok "Dashboard installé et démarré !"
      echo -e "  ${CYAN}→ http://127.0.0.1:${_PORT}${NC}  ${DIM}(local)${NC}"
      [ -n "$_LIP" ] && echo -e "  ${CYAN}→ http://${_LIP}:${_PORT}${NC}  ${DIM}(réseau LAN)${NC}"
      # Ouvrir le port dans le pare-feu si actif
      if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${_PORT}/tcp comment "IA Dashboard" 2>/dev/null && ok "Règle UFW ajoutée (${_PORT}/tcp)" || true
      elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${_PORT}/tcp 2>/dev/null &&         firewall-cmd --reload 2>/dev/null && ok "Règle firewalld ajoutée (${_PORT}/tcp)" || true
      fi
      ;;
    # ────────────────────────────────────────────────────────────
    MODELS)
      title "PULL DES MODÈLES IA"
      CURRENT_STEP="MODELS"
      select_models_smart

      local TOTAL=${#SELECTED_MODELS[@]}
      local IDX=1
      progress_init "$TOTAL" "Téléchargement modèles"

      for M in "${SELECTED_MODELS[@]}"; do
        progress_step "[$IDX/$TOTAL] $M"
        info "[$IDX/$TOTAL] Pull $M..."
        progress_ollama_pull "$M" \
          && ok "[$IDX/$TOTAL] $M ✓" \
          || warn "[$IDX/$TOTAL] $M échoué (réseau ?)."
        IDX=$(( IDX + 1 ))
      done

      if command -v ollama &>/dev/null; then
        log "Modèles installés :"
        ollama list 2>/dev/null || warn "Impossible de lister les modèles"
      else
        warn "Ollama non disponible — modèles non listés (redémarrez le service)"
      fi
      ;;


    # ────────────────────────────────────────────────────────────
    LLAMACPP)
      title "INSTALLATION llama.cpp"
      CURRENT_STEP="LLAMACPP"

      # Dépendances de compilation
      info "Installation des dépendances de compilation..."
      case "$OS_FAMILY" in
        debian) pkg_install build-essential cmake libcurl4-openssl-dev ;;
        rhel)   pkg_install gcc-c++ cmake libcurl-devel ;;
        arch)   pkg_install base-devel cmake libcurl-openssl ;;
        suse)   pkg_install gcc-c++ cmake libcurl-devel ;;
        *)      pkg_install gcc g++ cmake ;;
      esac

      local LLAMA_DIR="${CFG[hdd_mount]:-/opt}/llama.cpp"
      local LLAMA_BUILD="$LLAMA_DIR/build"
      _validate_data_path "$LLAMA_DIR" || LLAMA_DIR="/opt/llama.cpp"

      info "Clonage llama.cpp depuis GitHub..."
      if [ -d "$LLAMA_DIR/.git" ]; then
        git -C "$LLAMA_DIR" pull --quiet
      else
        git clone --depth=1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
      fi

      mkdir -p "$LLAMA_BUILD"
      cd "$LLAMA_BUILD"

      # Détection GPU pour compilation optimisée
      local CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON"
      if [ "${HW[gpu_cuda_capable]:-0}" = "1" ]; then
        CMAKE_FLAGS="$CMAKE_FLAGS -DGGML_CUDA=ON"
        info "Compilation avec support CUDA (NVIDIA GPU détecté)"
      elif [ "${HW[gpu_rocm_capable]:-0}" = "1" ]; then
        CMAKE_FLAGS="$CMAKE_FLAGS -DGGML_HIPBLAS=ON"
        info "Compilation avec support ROCm/HIP (AMD GPU détecté)"
      elif grep -q avx2 /proc/cpuinfo 2>/dev/null; then
        CMAKE_FLAGS="$CMAKE_FLAGS -DGGML_AVX2=ON"
        info "Compilation avec AVX2 (CPU optimisé)"
      fi

      info "Compilation llama.cpp (peut prendre 5-15 min)..."
      cmake .. $CMAKE_FLAGS && make -j"$(nproc)" llama-server llama-cli

      # Installation globale
      local LLAMA_SERVER="$LLAMA_BUILD/bin/llama-server"
      [ -f "$LLAMA_SERVER" ] || LLAMA_SERVER="$LLAMA_BUILD/llama-server"
      if [ -f "$LLAMA_SERVER" ]; then
        cp "$LLAMA_SERVER" /usr/local/bin/llama-server
        chmod 755 /usr/local/bin/llama-server
        ok "llama-server installé dans /usr/local/bin/"
      fi

      # Service systemd pour llama-server
      local LLAMA_PORT="${CFG[webui_port]:-8080}"
      local LLAMA_MODELS_DIR="${CFG[ollama_dir]:-/opt/models}"
      cat > /etc/systemd/system/llama-server.service << LLSEOF
[Unit]
Description=llama.cpp serveur HTTP
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/llama-server --host 127.0.0.1 --port ${LLAMA_PORT} --models-dir ${LLAMA_MODELS_DIR}
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
LLSEOF
      svc_enable  llama-server
      svc_start   llama-server
      ok "llama-server démarré sur http://127.0.0.1:${LLAMA_PORT}"
      info "Compatible Open WebUI — pointez OLLAMA_BASE_URL vers ce port."
      cd - > /dev/null
      ;;

    # ────────────────────────────────────────────────────────────
    LOCALAI)
      title "INSTALLATION LocalAI"
      CURRENT_STEP="LOCALAI"

      svc_active docker || { svc_start docker; sleep 3; }

      local LA_PORT="${CFG[webui_port]:-8080}"
      local LA_DIR="${CFG[webui_dir]:-${CFG[hdd_mount]:-/opt}/localai}"
      _validate_data_path "$LA_DIR" || LA_DIR="/opt/localai"
      mkdir -p "$LA_DIR/models" "$LA_DIR/config"
      chown -R "$REAL_USER:$REAL_USER" "$LA_DIR" 2>/dev/null || true

      # Choisir l'image selon GPU
      local LA_IMAGE="localai/localai:latest"
      [ "${HW[gpu_cuda_capable]:-0}" = "1" ]  && LA_IMAGE="localai/localai:latest-gpu-nvidia-cuda-12"
      [ "${HW[gpu_rocm_capable]:-0}"  = "1" ]  && LA_IMAGE="localai/localai:latest-gpu-hipblas"

      info "Téléchargement LocalAI image : $LA_IMAGE"
      docker pull "$LA_IMAGE"

      # Arrêter ancien conteneur si présent
      docker stop  localai 2>/dev/null || true
      docker rm -f localai 2>/dev/null || true

      local DOCKER_GPU_FLAGS=""
      [ "${HW[gpu_cuda_capable]:-0}" = "1" ] && \
        DOCKER_GPU_FLAGS="--gpus all"
      [ "${HW[gpu_rocm_capable]:-0}" = "1" ] && \
        DOCKER_GPU_FLAGS="--device=/dev/kfd --device=/dev/dri --group-add video --group-add render"

      docker run -d \
        --name localai \
        --restart unless-stopped \
        -p "${LA_PORT}:8080" \
        -v "${LA_DIR}/models:/build/models" \
        -v "${LA_DIR}/config:/build/config" \
        $DOCKER_GPU_FLAGS \
        "$LA_IMAGE"

      ok "LocalAI démarré — API OpenAI sur http://localhost:${LA_PORT}/v1"
      info "Compatible : Continue.dev, Cursor, Obsidian, SillyTavern, Open WebUI..."
      ;;

    # ────────────────────────────────────────────────────────────
    LMSTUDIO)
      title "INSTALLATION LM Studio"
      CURRENT_STEP="LMSTUDIO"

      local LMS_DIR="$REAL_HOME/Applications"
      mkdir -p "$LMS_DIR"

      # Récupérer la dernière version
      info "Recherche de la dernière version LM Studio..."
      local LMS_VERSION
      LMS_VERSION=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/lmstudio-ai/lmstudio-app-release/releases/latest" \
        | python3 -c "import sys,json
try: print(json.load(sys.stdin)['tag_name'])
except: print('0.3.6')" 2>/dev/null || echo "0.3.6")

      local LMS_FILE="LM-Studio-${LMS_VERSION}-linux-x86_64.AppImage"
      local LMS_URL="https://github.com/lmstudio-ai/lmstudio-app-release/releases/download/${LMS_VERSION}/${LMS_FILE}"
      local LMS_PATH="$LMS_DIR/LMStudio.AppImage"

      info "Téléchargement LM Studio ${LMS_VERSION}..."
      if curl -fL --max-time 300 --progress-bar "$LMS_URL" -o "$LMS_PATH"; then
        chmod +x "$LMS_PATH"
        chown "$REAL_USER:$REAL_USER" "$LMS_PATH"

        # Créer un lanceur .desktop si environnement graphique
        local DESKTOP_DIR="$REAL_HOME/.local/share/applications"
        mkdir -p "$DESKTOP_DIR"
        cat > "$DESKTOP_DIR/lmstudio.desktop" << LMSEOF
[Desktop Entry]
Name=LM Studio
Exec=$LMS_PATH --no-sandbox %U
Icon=lmstudio
Type=Application
Categories=Development;Science;
Comment=Run LLMs locally with a beautiful UI
LMSEOF
        chown "$REAL_USER:$REAL_USER" "$DESKTOP_DIR/lmstudio.desktop"

        ok "LM Studio ${LMS_VERSION} installé : $LMS_PATH"
        info "Lance-le depuis ton bureau ou avec : $LMS_PATH --no-sandbox"
        info "Depuis LM Studio : télécharge un modèle et active le serveur local (port 1234)."
        info "Open WebUI peut pointer vers http://localhost:1234/v1 (API OpenAI-compat)."
      else
        warn "Téléchargement LM Studio échoué."
        warn "Télécharge manuellement depuis : https://lmstudio.ai/download"
      fi
      ;;

    # ────────────────────────────────────────────────────────────
    VLLM)
      title "INSTALLATION vLLM"
      CURRENT_STEP="VLLM"

      svc_active docker || { svc_start docker; sleep 3; }

      # Vérifier NVIDIA Container Toolkit
      if ! docker info 2>/dev/null | grep -q nvidia; then
        warn "NVIDIA Container Toolkit non configuré — vLLM nécessite --gpus."
        if ! execute_step "NV_TOOLKIT"; then
          warn "NV_TOOLKIT échoué — vLLM peut ne pas démarrer."
        fi
      fi

      local VLLM_PORT="8000"
      local VLLM_DIR="${CFG[webui_dir]:-${CFG[hdd_mount]:-/opt}/vllm}"
      _validate_data_path "$VLLM_DIR" || VLLM_DIR="/opt/vllm"
      mkdir -p "$VLLM_DIR/models"
      chown -R "$REAL_USER:$REAL_USER" "$VLLM_DIR" 2>/dev/null || true

      # Choisir modèle de départ selon VRAM
      local VLLM_DEFAULT_MODEL="Qwen/Qwen2.5-7B-Instruct"
      [ "${HW[effective_mem]:-0}" -ge 40 ] && VLLM_DEFAULT_MODEL="meta-llama/Llama-3.1-70B-Instruct"
      [ "${HW[effective_mem]:-0}" -ge 20 ] && VLLM_DEFAULT_MODEL="Qwen/Qwen2.5-32B-Instruct"

      info "Téléchargement de l'image vLLM (GPU NVIDIA)..."
      docker pull vllm/vllm-openai:latest

      docker stop  vllm 2>/dev/null || true
      docker rm -f vllm 2>/dev/null || true

      docker run -d \
        --name vllm \
        --gpus all \
        --restart unless-stopped \
        -p "${VLLM_PORT}:8000" \
        -v "${VLLM_DIR}/models:/root/.cache/huggingface" \
        --ipc=host \
        vllm/vllm-openai:latest \
        --model "$VLLM_DEFAULT_MODEL" \
        --max-model-len 8192

      ok "vLLM démarré — API OpenAI sur http://localhost:${VLLM_PORT}/v1"
      info "Modèle par défaut : $VLLM_DEFAULT_MODEL"
      info "Compatible : Continue.dev, Open WebUI, LiteLLM, tout client OpenAI."
      warn "Premier démarrage : téléchargement du modèle depuis HuggingFace (~quelques Go)."
      ;;

    # ────────────────────────────────────────────────────────────
    WEBUI)
      title "OPEN WEBUI"
      CURRENT_STEP="WEBUI"

      # ── Sauvegarde automatique avant installation/MAJ ──────────
      _auto_backup_before_update "webui-install"

      # ── Avertissement durée d'installation ──────────────────────
      echo ""
      echo -e "  ${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
      echo -e "  ${YELLOW}║  ⏱  TÉLÉCHARGEMENT DE L'IMAGE DOCKER                    ║${NC}"
      echo -e "  ${YELLOW}║                                                          ║${NC}"
      echo -e "  ${YELLOW}║  L'image Open WebUI (~2 Go) peut prendre entre 10 et    ║${NC}"
      echo -e "  ${YELLOW}║  45 minutes à télécharger selon votre connexion.        ║${NC}"
      echo -e "  ${YELLOW}║                                                          ║${NC}"
      echo -e "  ${YELLOW}║  ${DIM}La progression s'affiche en temps réel ci-dessous.${YELLOW}    ║${NC}"
      echo -e "  ${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      sleep 2

      svc_active docker || svc_start docker
      sleep 2
      _docker_run_webui \
        "${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}" \
        "${CFG[webui_dir]}" \
        "${CFG[webui_port]:-8080}" \
        "${CFG[docker_network]:-host}"

      # ── Créer le service systemd open-webui pour le boot ─────────
      # Garantit l'ordre : Docker → Ollama prêt → WebUI
      # Remplace le simple --restart always qui ne connaît pas Ollama
      _install_webui_service \
        "${CFG[webui_port]:-8080}" \
        "${CFG[webui_dir]}" \
        "${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}" \
        "${CFG[docker_network]:-host}"
      ;;

    # ────────────────────────────────────────────────────────────
    BACKUP)
      title "BACKUP AUTOMATIQUE"
      CURRENT_STEP="BACKUP"
      _create_backup_script
      local CRON="0 3 * * 0 /bin/bash /usr/local/bin/backup_ia_local.sh >> ${CFG[backup_dir]}/cron.log 2>&1"
      crontab -l 2>/dev/null | grep -qF "backup_ia_local" || \
        { crontab -l 2>/dev/null; echo "$CRON"; } | crontab -
      log "Backup configuré — chaque dimanche à 3h."
      ;;
  esac
}

_create_backup_script() {
  local BSCRIPT="/usr/local/bin/backup_ia_local.sh"
  local HDD="${CFG[hdd_mount]}"
  local OLLM="${CFG[ollama_dir]}"
  local WEBUI="${CFG[webui_dir]}"
  local BKP="${CFG[backup_dir]}"

  cat > "$BSCRIPT" << 'BKPEOF'
#!/bin/bash
set -euo pipefail
GREEN='\033[0;32m';YELLOW='\033[1;33m';RED='\033[0;31m';NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}   $1"; }
[ "$EUID" -ne 0 ] && echo "sudo requis" && exit 1
BKPEOF

  # Injecter les variables de config (résolu au moment de la création)
  cat >> "$BSCRIPT" << BKPEOF2
HDD="$HDD"; OLLM="$OLLM"; WEBUI="$WEBUI"; BKP="$BKP"
BKPEOF2

  cat >> "$BSCRIPT" << 'BKPEOF3'
DATE=$(date +%Y%m%d_%H%M%S); DIR="$BKP/backup_$DATE"; LOG="$BKP/backup.log"
mountpoint -q "$HDD" || { echo "HDD non monté"; exit 1; }
DISPO=$(df -BG "$HDD" | awk 'NR==2{gsub("G","",$4); print $4}')
mkdir -p "$DIR"
touch "$LOG" 2>/dev/null; chmod 600 "$LOG" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1
echo "=== Backup $DATE ==="

# Arrêt services
docker stop open-webui 2>/dev/null || true
systemctl stop ollama 2>/dev/null || rc-service ollama stop 2>/dev/null || true
sleep 2

# Sauvegarde Ollama
mkdir -p "$DIR/ollama"
ollama list > "$DIR/ollama/models.txt" 2>/dev/null || true
cp -r "$OLLM/manifests" "$DIR/ollama/" 2>/dev/null || true
[ "$DISPO" -gt 20 ] && cp -r "$OLLM/blobs" "$DIR/ollama/" \
  && log "Blobs copiés" || warn "Blobs ignorés (<20Go libre)"

# Sauvegarde WebUI
[ -d "$WEBUI" ] && mkdir -p "$DIR/webui" && \
  tar -czf "$DIR/webui/data.tar.gz" -C "$(dirname "$WEBUI")" "$(basename "$WEBUI")" \
  && log "WebUI archivé"

# Config système
mkdir -p "$DIR/config"
cp /etc/fstab "$DIR/config/" 2>/dev/null || true
command -v dpkg   &>/dev/null && dpkg  --get-selections > "$DIR/config/pkgs.txt" 2>/dev/null || true
command -v rpm    &>/dev/null && rpm   -qa              > "$DIR/config/pkgs.txt" 2>/dev/null || true
command -v pacman &>/dev/null && pacman -Q              > "$DIR/config/pkgs.txt" 2>/dev/null || true

# Redémarrage services
systemctl start ollama 2>/dev/null || rc-service ollama start 2>/dev/null || true
sleep 3
docker start open-webui 2>/dev/null || true

# Rotation (garder 3 derniers)
COUNT=$(ls -d "$BKP"/backup_* 2>/dev/null | wc -l)
[ "$COUNT" -gt 3 ] && ls -dt "$BKP"/backup_* | tail -n $((COUNT-3)) | xargs rm -rf

log "Backup terminé : $(du -sh "$DIR" | cut -f1)"
BKPEOF3

  chmod +x "$BSCRIPT"
  log "Script backup créé : $BSCRIPT"
}

# ================================================================
#  SECTION 5 : CONFIGURATION INTERACTIVE
# ================================================================

configure_infra() {
  title "CONFIGURATION DE L'INFRASTRUCTURE"
  declare -gA CFG=()

  echo -e "${CYAN}  Appuie sur Entrée pour les valeurs détectées par défaut.\n${NC}"

  # Disques
  echo -e "${BOLD}=== DISQUES DISPONIBLES ===${NC}\n"
  printf "  ${BOLD}%-4s %-12s %-8s %-6s %s${NC}\n" "N°" "Disque" "Taille" "Type" "Modèle"
  hr
  local i=1
  for D in "${DISKS[@]}"; do
    local TYPE="${DISK_TYPE[$D]:-?}"
    local HEALTH="${DISK_HEALTH[$D]:-?}"
    local HEALTH_COL="$GREEN"
    [ "$HEALTH" = "FAILED" ] && HEALTH_COL="$RED"
    [ "$HEALTH" = "?" ] && HEALTH_COL="$YELLOW"
    printf "  ${GREEN}[%d]${NC} %-12s %-8s %-6s %s ${HEALTH_COL}[SMART:%s]${NC}\n" \
      "$i" "$D" "${DISK_SIZE[$D]:-?}" "$TYPE" "${DISK_MODEL[$D]:0:20}" "$HEALTH"
    i=$(( i + 1 ))
  done
  echo ""
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | grep -v loop | head -25
  echo ""

  # Détection défauts intelligents
  local DEF_OS="${DISKS[0]:-/dev/sda}"
  local DEF_STORE="${DISKS[1]:-${DISKS[0]:-/dev/sda}}"
  local DEF_BASE; DEF_BASE=$(basename "$DEF_STORE")
  local DEF_MOUNT="/mnt/ia_${DEF_BASE}"
  local DEF_LABEL="IA_$(echo "$DEF_BASE" | tr '[:lower:]' '[:upper:]')"

  read -rp "$(echo -e "${YELLOW}  [1/6] Disque OS            (Entrée = $DEF_OS)    : ${NC}")" TMP
  CFG[os_dev]="${TMP:-$DEF_OS}"

  read -rp "$(echo -e "${YELLOW}  [2/6] Disque stockage IA   (Entrée = $DEF_STORE) : ${NC}")" TMP
  CFG[hdd_dev]="${TMP:-$DEF_STORE}"
  [ -b "${CFG[hdd_dev]}" ] || warn "Disque ${CFG[hdd_dev]} introuvable."
  [ "${CFG[hdd_dev]}" = "${CFG[os_dev]}" ] && warn "Même disque pour OS et stockage IA."

  DEF_BASE=$(basename "${CFG[hdd_dev]}")
  DEF_MOUNT="/mnt/ia_${DEF_BASE}"
  DEF_LABEL="IA_$(echo "$DEF_BASE" | tr '[:lower:]' '[:upper:]')"

  read -rp "$(echo -e "${YELLOW}  [3/6] Point de montage     (Entrée = $DEF_MOUNT) : ${NC}")" TMP
  CFG[hdd_mount]="${TMP:-$DEF_MOUNT}"

  read -rp "$(echo -e "${YELLOW}  [3/6] Label disque         (Entrée = $DEF_LABEL) : ${NC}")" TMP
  CFG[hdd_label]="${TMP:-$DEF_LABEL}"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier modèles      (Entrée = ${CFG[hdd_mount]}/ollama_models) : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/ollama_models}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/ollama_models"
  CFG[ollama_dir]="$TMP"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier Open WebUI   (Entrée = ${CFG[hdd_mount]}/open-webui)    : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/open-webui}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/open-webui"
  CFG[webui_dir]="$TMP"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier backups      (Entrée = ${CFG[hdd_mount]}/backups)       : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/backups}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/backups"
  CFG[backup_dir]="$TMP"

  _ask_port "[5/6] Port Open WebUI" "8080" _WEBUI_PORT_TMP
  CFG[webui_port]="$_WEBUI_PORT_TMP"
  # Stocker l'image Docker dans la config (pour la retrouver lors des MAJ)
  CFG[docker_image]="${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}"

  # Mode réseau Docker — host est recommandé pour communiquer avec Ollama local
  echo ""
  echo -e "  ${DIM}Mode réseau Docker :${NC}"
  echo -e "    ${GREEN}[1]${NC}  --network=host  (recommandé — connexion directe à Ollama)  ← défaut"
  echo -e "    ${GREEN}[2]${NC}  -p PORT:8080    (bridge — si conflit de port)"
  read -rp "$(echo -e "${YELLOW}  [5b/6] Mode réseau         (Entrée = 1) : ${NC}")" NET_CHOICE
  case "${NET_CHOICE:-1}" in
    2)  CFG[docker_network]="bridge" ;;
    *)  CFG[docker_network]="host" ;;
  esac

  echo ""
  echo -e "${DIM}  [6/6] Sélection des modèles → après analyse matérielle${NC}"
}

# ================================================================
#  SECTION 6 : INSTALLATION COMPLÈTE
# ================================================================

run_full_install() {
  local START="${1:-ANALYSE}"

  if [ "$START" = "ANALYSE" ]; then
    # ── Marquer le début pour le dashboard ───────────────────────
    PROGRESS_CURRENT=0; PROGRESS_TOTAL=1; PROGRESS_LABEL="Analyse du matériel"
    CURRENT_STEP="ANALYSE"
    progress_write_json "ANALYSE" "Analyse du matériel et configuration"
    # ── Analyse + Config + Plan ──────────────────────────────────
    analyse_hardware
    configure_infra
    build_install_plan

    echo ""
    confirm "Plan validé ? Démarrer l'installation ?" || error "Annulé."
    save_config
    save_state "EXEC:0"
    START="EXEC:0"
  fi

  # ── Exécution du plan ────────────────────────────────────────
  if [[ "$START" == EXEC:* ]]; then
    local FROM_IDX="${START#EXEC:}"
    local CUR_IDX=0
    local TOTAL_STEPS=${#PLAN[@]}

    progress_init "$TOTAL_STEPS" "Installation en cours"

    for STEP in "${PLAN[@]}"; do
      if [ "$CUR_IDX" -ge "$FROM_IDX" ]; then
        echo ""
        CURRENT_STEP="$STEP"
        PLAN_STEP_IDX=$CUR_IDX
        progress_step "Étape $((CUR_IDX+1))/$TOTAL_STEPS : $STEP"
        info "━━━ [$((CUR_IDX+1))/$TOTAL_STEPS] $STEP ━━━"
        save_state "EXEC:$CUR_IDX"

        # Exécution avec retry sur erreur
        local RETRY=0
        local MAX_RETRY=2
        while true; do
          if execute_step "$STEP"; then
            break
          else
            RETRY=$(( RETRY + 1 ))
            if [ "$RETRY" -le "$MAX_RETRY" ]; then
              warn "Étape $STEP échouée — tentative $RETRY/$MAX_RETRY..."
              sleep 2
            else
              warn "Étape $STEP échouée après $MAX_RETRY tentatives — ignorée."
              break
            fi
          fi
        done

        # Reboot si nécessaire
        local NEEDS_REBOOT="${PLAN_REBOOT[$STEP]:-non}"
        if [ "$NEEDS_REBOOT" = "oui" ]; then
          local NEXT_IDX=$(( CUR_IDX + 1 ))
          save_config
          reboot_and_resume "EXEC:$NEXT_IDX" "Drivers $STEP installés"
        fi
      fi
      CUR_IDX=$(( CUR_IDX + 1 ))
    done

    # ── Vérifications finales ────────────────────────────────────
    progress_clear_json   # Efface la bannière de progression du dashboard
    title "✅ INSTALLATION TERMINÉE"
    cleanup_resume

    echo ""
    box_top
    box_line "OS"        "${HW[os_name]:0:32}"
    box_line "CPU"       "${HW[cpu_model]:0:32}"
    box_line "RAM"       "${HW[ram_gb]} Go"
    box_line "GPU"       "${HW[gpu_brand]^^} — ${HW[gpu_model]:0:24}"
    [ "${HW[gpu_vram_gb]:-0}" -gt 0 ] && box_line "VRAM" "${HW[gpu_vram_gb]} Go"
    box_sep
    box_line "Stockage"  "${CFG[hdd_mount]}"
    box_line "Modèles"   "${CFG[ollama_dir]}"
    box_line "WebUI"     "http://localhost:${CFG[webui_port]}"
    box_line "Backup"    "Dimanche 3h → ${CFG[backup_dir]}"
    box_bot
    echo ""

    step "Services"
    systemctl is-active ollama \
      && ok "Ollama actif" || nok "Ollama inactif"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" \
      && ok "Open WebUI actif → http://localhost:${CFG[webui_port]}" \
      || nok "Open WebUI inactif"

    step "Modèles installés"
    ollama list 2>/dev/null || warn "Ollama indisponible."

    if [ "${HW[gpu_brand]}" = "nvidia" ]; then
      step "GPU NVIDIA"
      nvidia-smi --query-gpu=name,memory.total,utilization.gpu,driver_version \
        --format=csv,noheader 2>/dev/null || warn "nvidia-smi indisponible."
    fi
  fi
}

# ================================================================
#  MENUS SECONDAIRES
# ================================================================

menu_models() {
  title "GESTION DES MODÈLES IA"
  CURRENT_STEP="MODELS_MENU"

  # ── Vérifications préalables ─────────────────────────────────
  if ! command -v ollama &>/dev/null; then
    warn "Ollama n'est pas installé."
    confirm "Installer Ollama maintenant ?" && execute_step "OLLAMA" || return 0
  fi
  systemctl is-active --quiet ollama 2>/dev/null || {
    info "Démarrage d'Ollama..."
    systemctl start ollama
    sleep 3
  }

  # ── Charger la config existante ──────────────────────────────
  declare -gA CFG=()
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true
  declare -gA HW=()
  analyse_hardware

  while true; do
    title "GESTION DES MODÈLES IA"

    # ── Afficher les modèles installés avec détails ──────────────
    echo ""
    step "Modèles actuellement installés"
    local INSTALLED_COUNT=0
    local TOTAL_SIZE_MB=0

    if ollama list 2>/dev/null | tail -n +2 | grep -q .; then
      printf "  ${BOLD}%-32s %-12s %-20s %s${NC}
" "NOM" "TAILLE" "MODIFIÉ" "ID"
      hr
      while IFS= read -r LINE; do
        local NAME SIZE MODIF ID
        NAME=$(echo "$LINE" | awk '{print $1}')
        ID=$(echo "$LINE"   | awk '{print $2}')
        SIZE=$(echo "$LINE" | awk '{print $3, $4}')
        MODIF=$(echo "$LINE"| awk '{print $5, $6, $7}')
        printf "  ${GREEN}%-32s${NC} %-12s %-20s ${DIM}%s${NC}
"           "$NAME" "$SIZE" "$MODIF" "$ID"
        INSTALLED_COUNT=$(( INSTALLED_COUNT + 1 ))
      done < <(ollama list 2>/dev/null | tail -n +2)
      hr
      echo -e "  ${DIM}$INSTALLED_COUNT modèle(s) installé(s)${NC}"
    else
      warn "Aucun modèle installé."
    fi

    echo ""
    echo -e "${BOLD}  Que veux-tu faire ?${NC}
"
    echo -e "  ${GREEN}[1]${NC}  Ajouter des modèles       (catalogue intelligent)"
    echo -e "  ${GREEN}[2]${NC}  Supprimer un modèle"
    echo -e "  ${GREEN}[3]${NC}  Mettre à jour les modèles (re-pull les plus récents)"
    echo -e "  ${GREEN}[4]${NC}  Tester un modèle          (chat rapide en terminal)"
    echo -e "  ${GREEN}[5]${NC}  Infos détaillées d'un modèle"
    echo -e "  ${CYAN}[7]${NC}  Changer de backend d'inférence IA"
    echo -e "  ${GREEN}[6]${NC}  Retour au menu principal"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Choix : ${NC}")" MC

    case "${MC:-6}" in

      1)  # ── Ajouter des modèles ────────────────────────────────
        title "AJOUTER DES MODÈLES"
        execute_step "MODELS"
        ;;

      2)  # ── Supprimer un modèle ────────────────────────────────
        step "Supprimer un modèle"
        echo ""
        local -a DEL_LIST=()
        local IDX=1
        while IFS= read -r LINE; do
          local NAME; NAME=$(echo "$LINE" | awk '{print $1}')
          local SIZE; SIZE=$(echo "$LINE" | awk '{print $3, $4}')
          echo -e "  ${RED}[$IDX]${NC}  $NAME  ${DIM}($SIZE)${NC}"
          DEL_LIST+=("$NAME")
          IDX=$(( IDX + 1 ))
        done < <(ollama list 2>/dev/null | tail -n +2)
        echo ""
        read -rp "$(echo -e "${YELLOW}  >>> N° à supprimer (ou nom exact) : ${NC}")" DEL_INPUT

        local DEL_NAME=""
        if [[ "$DEL_INPUT" =~ ^[0-9]+$ ]] && [ "$DEL_INPUT" -ge 1 ] && [ "$DEL_INPUT" -le "${#DEL_LIST[@]}" ]; then
          DEL_NAME="${DEL_LIST[$(( DEL_INPUT - 1 ))]}"
        else
          DEL_NAME="$DEL_INPUT"
        fi

        if [ -n "$DEL_NAME" ]; then
          echo ""
          confirm "Supprimer définitivement '$DEL_NAME' ?" && {
            ollama rm "$DEL_NAME" && ok "Modèle '$DEL_NAME' supprimé." || warn "Échec suppression."
          }
        fi
        ;;

      3)  # ── Mettre à jour les modèles ──────────────────────────
        step "Mise à jour des modèles"
        mapfile -t UPDT_MODELS < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
        if [ "${#UPDT_MODELS[@]}" -eq 0 ]; then
          warn "Aucun modèle à mettre à jour."
        else
          echo ""
          echo -e "${DIM}  Ollama re-pull chaque modèle et ne télécharge que les couches modifiées.${NC}"
          echo ""
          for M in "${UPDT_MODELS[@]}"; do
            echo -e "  ${CYAN}→${NC} $M"
          done
          echo ""
          confirm "Lancer la mise à jour de ${#UPDT_MODELS[@]} modèle(s) ?" && {
            local TOTAL=${#UPDT_MODELS[@]}
            local IDX2=1
            progress_init "$TOTAL" "MAJ modèles"
            for M in "${UPDT_MODELS[@]}"; do
              progress_step "[$IDX2/$TOTAL] $M"
              progress_ollama_pull "$M"                 && ok "[$IDX2/$TOTAL] $M à jour ✓"                 || warn "[$IDX2/$TOTAL] $M : échec pull."
              IDX2=$(( IDX2 + 1 ))
            done
            log "Mise à jour terminée."
            ollama list
          }
        fi
        ;;

      4)  # ── Test rapide d'un modèle ────────────────────────────
        step "Tester un modèle"
        mapfile -t TEST_MODELS < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
        [ "${#TEST_MODELS[@]}" -eq 0 ] && { warn "Aucun modèle installé."; continue; }
        echo ""
        local IDX=1
        for M in "${TEST_MODELS[@]}"; do
          echo -e "  ${GREEN}[$IDX]${NC}  $M"
          IDX=$(( IDX + 1 ))
        done
        echo ""
        read -rp "$(echo -e "${YELLOW}  >>> N° ou nom du modèle à tester : ${NC}")" TEST_INPUT
        local TEST_NAME=""
        if [[ "$TEST_INPUT" =~ ^[0-9]+$ ]] && [ "$TEST_INPUT" -ge 1 ] && [ "$TEST_INPUT" -le "${#TEST_MODELS[@]}" ]; then
          TEST_NAME="${TEST_MODELS[$(( TEST_INPUT - 1 ))]}"
        else
          TEST_NAME="$TEST_INPUT"
        fi
        if [ -n "$TEST_NAME" ]; then
          info "Lancement de $TEST_NAME (Ctrl+D ou /bye pour quitter)..."
          echo ""
          ollama run "$TEST_NAME" || warn "Test interrompu."
        fi
        ;;

      5)  # ── Infos détaillées ───────────────────────────────────
        step "Infos d'un modèle"
        mapfile -t INFO_MODELS < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
        [ "${#INFO_MODELS[@]}" -eq 0 ] && { warn "Aucun modèle installé."; continue; }
        echo ""
        local IDX=1
        for M in "${INFO_MODELS[@]}"; do
          echo -e "  ${GREEN}[$IDX]${NC}  $M"; IDX=$(( IDX + 1 ))
        done
        echo ""
        read -rp "$(echo -e "${YELLOW}  >>> N° ou nom : ${NC}")" INFO_INPUT
        local INFO_NAME=""
        if [[ "$INFO_INPUT" =~ ^[0-9]+$ ]] && [ "$INFO_INPUT" -ge 1 ] && [ "$INFO_INPUT" -le "${#INFO_MODELS[@]}" ]; then
          INFO_NAME="${INFO_MODELS[$(( INFO_INPUT - 1 ))]}"
        else
          INFO_NAME="$INFO_INPUT"
        fi
        [ -n "$INFO_NAME" ] && ollama show "$INFO_NAME" 2>/dev/null || warn "Modèle introuvable."
        ;;

      7)  # ── Changer de backend ─────────────────────────────────
        title "CHANGER DE BACKEND D'INFÉRENCE"
        declare -gA HW=(); analyse_hardware
        select_backend
        save_config
        ok "Backend changé → ${HW[backend]^^}"
        info "Relance l'installation complète ([1] du menu principal) pour l'appliquer."
        ;;

      6|*) break ;;
    esac

    echo ""
    read -rp "$(echo -e "${DIM}  Appuie sur Entrée pour continuer...${NC}")" _PAUSE
  done
}

menu_reinstall() {
  title "RÉINSTALLATION COMPOSANT"
  analyse_hardware
  echo -e "  ${GREEN}[1]${NC} Drivers GPU"
  echo -e "  ${GREEN}[2]${NC} Docker + Runtime GPU"
  echo -e "  ${GREEN}[3]${NC} Ollama"
  echo -e "  ${GREEN}[4]${NC} Open WebUI"
  echo -e "  ${GREEN}[5]${NC} Dashboard + Administration web (réinstaller)"
  read -rp "$(echo -e "${YELLOW}  >>> : ${NC}")" C
  declare -gA CFG; source "$CONFIG_FILE" 2>/dev/null || true
  case "$C" in
    1) [ "${HW[gpu_brand]}" = "nvidia" ] && execute_step "DRIVER_NVIDIA" \
       || execute_step "DRIVER_AMD_FIRMWARE"
       [ "${PLAN_REBOOT[DRIVER_NVIDIA]:-non}" = "oui" ] && reboot_and_resume "MENU" "Driver réinstallé" ;;
    2) execute_step "DOCKER"; [ "${HW[gpu_brand]}" = "nvidia" ] && execute_step "NV_TOOLKIT" \
       || execute_step "AMD_DOCKER_RUNTIME" ;;
    3) execute_step "OLLAMA" ;;
    4) execute_step "WEBUI" ;;
    5) execute_step "DASHBOARD"
       local _P="${DASHBOARD_PORT:-7842}"
       local _L; _L=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
       echo ""
       ok "Dashboard réinstallé !"
       echo -e "  ${CYAN}→ http://127.0.0.1:${_P}${NC}"
       [ -n "$_L" ] && echo -e "  ${CYAN}→ http://${_L}:${_P}${NC}  (réseau LAN)"
       echo ""
       echo -e "  ${YELLOW}Login : admin  /  Mot de passe : ia-local-admin${NC}"
       echo -e "  ${RED}  ⚠  Changez le mot de passe dans l'onglet ⚙️ Administration !${NC}" ;;
  esac
}

# ================================================================
#  FONCTION : VÉRIFICATION & MAJ (Ollama + Open WebUI + Modèles)
# ================================================================

menu_updates() {
  title "VÉRIFICATION & MISE À JOUR"
  CURRENT_STEP="UPDATES"
  declare -gA CFG=(); source "$CONFIG_FILE" 2>/dev/null || true
  declare -gA HW=()

  # Vérification connexion réseau
  step "Vérification réseau"
  if ! ping -c1 -W3 8.8.8.8 &>/dev/null 2>&1; then
    warn "Pas de connexion Internet — impossible de vérifier les mises à jour."
    return 0
  fi
  ok "Connexion Internet disponible"

  # ── Résumé des versions actuelles ──────────────────────────
  echo ""
  step "Versions actuellement installées"

  local OLLAMA_LOCAL="" OLLAMA_REMOTE="" OLLAMA_STATUS=""
  local WEBUI_LOCAL=""  WEBUI_REMOTE=""  WEBUI_STATUS=""
  local SYS_UPDATES=0

  # Ollama version locale — normaliser pour éviter les faux positifs
  if command -v ollama &>/dev/null; then
    # Extraire X.Y.Z et supprimer tout suffixe/espace résiduel
    OLLAMA_LOCAL=$(ollama --version 2>/dev/null       | grep -oP '\d+\.\d+\.\d+' | head -1       | tr -d '[:space:]' || echo "?")
    # Supprimer suffixe pré-release éventuel (-rc1, -beta, etc.)
    OLLAMA_LOCAL="${OLLAMA_LOCAL%%-*}"
    OLLAMA_LOCAL="${OLLAMA_LOCAL:-?}"
    ok "Ollama installé : v$OLLAMA_LOCAL"
  else
    warn "Ollama : non installé"
    OLLAMA_LOCAL="non installé"
  fi

  # Open WebUI version locale (via Docker)
  # Méthode robuste : label de version en priorité, puis digest si absent (cas fréquent avec :main)
  local WEBUI_LOCAL_DIGEST=""
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    local WEBUI_RUNNING
    WEBUI_RUNNING=$(docker inspect --format='{{.State.Status}}' open-webui 2>/dev/null || echo "?")

    # Essai via label standard
    WEBUI_LOCAL=$(docker inspect open-webui 2>/dev/null \
      | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); \
        labels=d[0].get('Config',{}).get('Labels',{}); \
        v=labels.get('org.opencontainers.image.version', \
          labels.get('build_version','')); \
        print(v if v else '')\nexcept: print(chr(63))" 2>/dev/null || echo "")

    # Si label absent (cas fréquent avec :main), on utilise le digest court
    if [ -z "$WEBUI_LOCAL" ] || [ "$WEBUI_LOCAL" = "?" ]; then
      WEBUI_LOCAL=$(docker inspect open-webui 2>/dev/null \
        | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); \
          img=d[0].get('Image',''); \
          print(img[7:26] if img.startswith('sha256:') else img[:12])\nexcept: print(chr(63))" \
        2>/dev/null || echo "?")
      WEBUI_LOCAL_DIGEST="$WEBUI_LOCAL"
      ok "Open WebUI installé — digest local: ${WEBUI_LOCAL} (état: $WEBUI_RUNNING)"
    else
      ok "Open WebUI installé : v$WEBUI_LOCAL (état: $WEBUI_RUNNING)"
    fi
  else
    warn "Open WebUI : non installé"
    WEBUI_LOCAL="non installé"
  fi

  # Paquets système en attente
  SYS_UPDATES=$(pkg_count_upgradable)
  # Forcer entier propre (évite erreur bash "[: entier attendu")
  SYS_UPDATES=$(echo "$SYS_UPDATES" | tr -cd '0-9' | head -c 6)
  SYS_UPDATES=${SYS_UPDATES:-0}
  if [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null; then
    warn "Système : $SYS_UPDATES paquet(s) en attente de mise à jour"
  else
    ok "Système : à jour"
  fi

  # ── Récupération des dernières versions disponibles ─────────
  echo ""
  step "Vérification des nouvelles versions disponibles"
  info "Interrogation des API GitHub / Docker Hub..."

  # Ollama : dernière version GitHub — normaliser identiquement à la version locale
  OLLAMA_REMOTE=$(curl -sf --max-time 8     "https://api.github.com/repos/ollama/ollama/releases/latest"     | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
tag = data.get('tag_name','?').lstrip('v').strip()
# Supprimer suffixe pré-release pour comparaison cohérente
tag = re.sub(r'[-+].*$', '', tag)
print(tag)
" 2>/dev/null || echo "?")

  # Open WebUI — récupération de la version distante
  # Pour :main on compare le digest distant vs local
  local IMG_USED="${CFG[docker_image]:-ghcr.io/open-webui/open-webui:main}"
  WEBUI_REMOTE=$(curl -sf --max-time 8 \
    "https://api.github.com/repos/open-webui/open-webui/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','?').lstrip('v'))" \
    2>/dev/null || echo "?")

  # Si on utilise :main : comparer le digest local vs le digest de l'image
  # actuellement disponible sur le registre (docker pull --dry-run equivalent)
  if [ -n "$WEBUI_LOCAL_DIGEST" ] && [[ "$IMG_USED" == *":main" ]]; then
    local WEBUI_REMOTE_DIGEST="?"

    # Méthode 1 : docker manifest inspect (disponible si Docker ≥ 20)
    if docker manifest inspect "$IMG_USED" &>/dev/null 2>&1; then
      WEBUI_REMOTE_DIGEST=$(docker manifest inspect "$IMG_USED" 2>/dev/null         | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # schemaVersion 2 : le digest est dans config.digest
    dig = d.get('config',{}).get('digest','')
    if not dig:
        # fallback : premier layer ou manifests[0]
        dig = (d.get('manifests') or [{}])[0].get('digest','')
    print(dig[7:26] if dig.startswith('sha256:') else dig[:19])
except: print('?')
" 2>/dev/null || echo "?")
    fi

    # Méthode 2 : ghcr.io API publique avec token anonyme
    if [ "$WEBUI_REMOTE_DIGEST" = "?" ]; then
      local _GHCR_TOKEN
      _GHCR_TOKEN=$(curl -sf --max-time 8         "https://ghcr.io/token?scope=repository:open-webui/open-webui:pull&service=ghcr.io"         | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))"         2>/dev/null || echo "")

      if [ -n "$_GHCR_TOKEN" ]; then
        WEBUI_REMOTE_DIGEST=$(curl -sf --max-time 10           "https://ghcr.io/v2/open-webui/open-webui/manifests/main"           -H "Authorization: Bearer $_GHCR_TOKEN"           -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json"           -D - -o /dev/null 2>/dev/null           | grep -i 'docker-content-digest:'           | grep -oP 'sha256:[a-f0-9]+' | head -1           | cut -c1-26 || echo "?")
      fi
    fi

    # Comparaison
    if [ "$WEBUI_REMOTE_DIGEST" != "?" ] && [ -n "$WEBUI_REMOTE_DIGEST" ]; then
      if [ "$WEBUI_LOCAL_DIGEST" = "$WEBUI_REMOTE_DIGEST" ]; then
        WEBUI_STATUS="${GREEN}✓ à jour${NC} (image :main identique)"
        WEBUI_REMOTE="$WEBUI_LOCAL"   # forcer égalité → pas de MAJ proposée
      else
        WEBUI_STATUS="${YELLOW}⬆ nouvelle image :main disponible${NC}"
        WEBUI_REMOTE="(nouvelle image :main)"
      fi
    else
      # Digest distant non récupérable → comparer via version GitHub comme fallback
      # (déjà dans WEBUI_REMOTE depuis l'appel précédent)
      info "Digest distant non disponible — comparaison via version GitHub"
      # On laisse WEBUI_STATUS vide → sera calculé par le bloc suivant
    fi
  fi

  # ── Tableau comparatif ───────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ┌─────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │  COMPOSANT         INSTALLÉ        DISPONIBLE    STATUT │${NC}"
  echo -e "${BOLD}  ├─────────────────────────────────────────────────────────┤${NC}"

  # Ollama
  if [ "$OLLAMA_REMOTE" != "?" ] && [ "$OLLAMA_LOCAL" != "?" ] && [ "$OLLAMA_LOCAL" != "non installé" ]; then
    # Comparaison sémantique segment par segment (évite "0.3.9" > "0.3.12" en strcmp)
    _ver_le() {
      # retourne 0 si $1 <= $2 (version A <= version B)
      local A="$1" B="$2"
      [ "$A" = "$B" ] && return 0
      local LOWER; LOWER=$(printf '%s
%s
' "$A" "$B"         | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
      [ "$LOWER" = "$A" ]
    }
    if [ "$OLLAMA_LOCAL" = "$OLLAMA_REMOTE" ]; then
      OLLAMA_STATUS="${GREEN}✓ à jour${NC}"
    elif _ver_le "$OLLAMA_REMOTE" "$OLLAMA_LOCAL"; then
      # Remote <= local : local est plus récent (dev/custom build)
      OLLAMA_STATUS="${GREEN}✓ à jour${NC} ${DIM}(local: v${OLLAMA_LOCAL})${NC}"
      OLLAMA_REMOTE="$OLLAMA_LOCAL"   # éviter faux positif dans HAS_UPDATE
    else
      OLLAMA_STATUS="${YELLOW}⬆ MAJ dispo${NC}"
    fi
  elif [ "$OLLAMA_LOCAL" = "non installé" ]; then
    OLLAMA_STATUS="${RED}✗ absent${NC}"
  else
    OLLAMA_STATUS="${DIM}? inconnu${NC}"
  fi

  printf "  │  %-18s %-15s %-13s " "Ollama" "v${OLLAMA_LOCAL}" "v${OLLAMA_REMOTE}"
  echo -e "${OLLAMA_STATUS}│"

  # Open WebUI (calcul du statut si pas encore fait par la logique digest)
  if [ -z "${WEBUI_STATUS:-}" ]; then
    if [ "$WEBUI_REMOTE" != "?" ] && [ "$WEBUI_LOCAL" != "?" ] && [ "$WEBUI_LOCAL" != "non installé" ]; then
      if [ "$WEBUI_LOCAL" = "$WEBUI_REMOTE" ]; then
        WEBUI_STATUS="${GREEN}✓ à jour${NC}"
      else
        WEBUI_STATUS="${YELLOW}⬆ MAJ dispo${NC}"
      fi
    elif [ "$WEBUI_LOCAL" = "non installé" ]; then
      WEBUI_STATUS="${RED}✗ absent${NC}"
    else
      WEBUI_STATUS="${DIM}? inconnu${NC}"
    fi
  fi

  printf "  │  %-18s %-15s %-13s " "Open WebUI" "v${WEBUI_LOCAL}" "v${WEBUI_REMOTE}"
  echo -e "${WEBUI_STATUS}│"

  # Système
  if [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null; then
    SYS_STATUS="${YELLOW}⬆ $SYS_UPDATES paquets${NC}"
  else
    SYS_STATUS="${GREEN}✓ à jour${NC}"
  fi
  printf "  │  %-18s %-15s %-13s " "Système ($PKG_MGR)" "-" "-"
  echo -e "${SYS_STATUS}│"

  echo -e "${BOLD}  └─────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # ── Proposer les mises à jour disponibles ───────────────────
  local HAS_UPDATE=0

  # Déclencher HAS_UPDATE uniquement si une MAJ est réellement disponible
  # (évite faux positifs si version locale = version remote après normalisation)
  { [ "$OLLAMA_LOCAL" != "$OLLAMA_REMOTE" ] && [ "$OLLAMA_REMOTE" != "?" ]     && [ "$OLLAMA_LOCAL" != "non installé" ]; } && HAS_UPDATE=1 || true
  { [ "$WEBUI_LOCAL"  != "$WEBUI_REMOTE"  ] && [ "$WEBUI_REMOTE"  != "?" ]     && [ "$WEBUI_LOCAL"  != "non installé" ]; } && HAS_UPDATE=1 || true
  [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null && HAS_UPDATE=1 || true

  if [ "$HAS_UPDATE" -eq 0 ]; then
    log "Tout est à jour — aucune mise à jour nécessaire."
    return 0
  fi

  echo -e "${BOLD}  Que veux-tu mettre à jour ?${NC}\n"

  local OPT=1
  declare -A UPDATE_MENU=()

  if [ "$OLLAMA_LOCAL" != "$OLLAMA_REMOTE" ] && [ "$OLLAMA_REMOTE" != "?" ]; then
    echo -e "  ${GREEN}[$OPT]${NC}  Ollama        v$OLLAMA_LOCAL → v$OLLAMA_REMOTE"
    UPDATE_MENU[$OPT]="OLLAMA"
    OPT=$(( OPT + 1 ))
  fi

  if [ "$WEBUI_LOCAL" != "$WEBUI_REMOTE" ] && [ "$WEBUI_REMOTE" != "?" ]; then
    echo -e "  ${GREEN}[$OPT]${NC}  Open WebUI    v$WEBUI_LOCAL → v$WEBUI_REMOTE"
    UPDATE_MENU[$OPT]="WEBUI"
    OPT=$(( OPT + 1 ))
  fi

  if [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "  ${GREEN}[$OPT]${NC}  Système $PKG_MGR   ($SYS_UPDATES paquets)"
    UPDATE_MENU[$OPT]="APT"
    OPT=$(( OPT + 1 ))
  fi

  echo -e "  ${GREEN}[$OPT]${NC}  Tout mettre à jour"
  local OPT_ALL=$OPT
  OPT=$(( OPT + 1 ))
  echo -e "  ${GREEN}[$OPT]${NC}  Annuler"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix (plusieurs possibles, ex: 1 2) : ${NC}")" UPD_CHOICES

  # Traiter les choix
  for CHOICE_U in $UPD_CHOICES; do
    local TARGET="${UPDATE_MENU[$CHOICE_U]:-}"
    [ "$CHOICE_U" = "$OPT_ALL" ] && TARGET="ALL"

    case "$TARGET" in

      OLLAMA|ALL)
        step "Mise à jour Ollama v$OLLAMA_LOCAL → v$OLLAMA_REMOTE"
        svc_stop ollama
        _install_ollama_secure
        svc_daemon_reload
        svc_restart ollama
        sleep 2
        local OLLAMA_NEW
        OLLAMA_NEW=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
        if [ "$OLLAMA_NEW" = "$OLLAMA_REMOTE" ]; then
          ok "Ollama mis à jour : v$OLLAMA_NEW ✓"
        else
          warn "Ollama version après MAJ : v$OLLAMA_NEW (attendu v$OLLAMA_REMOTE)"
        fi
        ;&  # fallthrough si ALL

      WEBUI|ALL)
        [ "$TARGET" = "OLLAMA" ] && continue  # skip si uniquement OLLAMA dans la boucle
        step "Mise à jour Open WebUI v$WEBUI_LOCAL → v$WEBUI_REMOTE"

        # Récupérer les paramètres depuis la config sauvegardée
        local WEBUI_DATA_CURR="${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}"
        local WEBUI_PORT_CURR="${CFG[webui_port]:-8080}"
        local WEBUI_NET_CURR="${CFG[docker_network]:-host}"

        # Toujours utiliser :main sauf config explicite autre
        local IMG="${CFG[docker_image]:-ghcr.io/open-webui/open-webui:main}"

        info "Image cible  : $IMG"
        info "Data      : $WEBUI_DATA_CURR"
        info "Réseau       : $WEBUI_NET_CURR"

        # ── ÉTAPE 1 : Backup des données AVANT toute modification ──
        echo ""
        warn "Les conversations et paramètres seront préservés si le volume est correct."
        info "Backup automatique en cours..."
        _backup_webui_before_update "$WEBUI_DATA_CURR"

        # ── ÉTAPE 2 : Pull de la nouvelle image ─────────────────────
        info "Téléchargement de la nouvelle image..."
        local DOCKER_PULL_OUTPUT_FILE="/tmp/docker_pull_$$.log"
        docker pull "$IMG" > "$DOCKER_PULL_OUTPUT_FILE" 2>&1 &
        local DOCKER_PULL_PID=$!
        local SPINNER_CHARS="/-\|"
        local SPIN_IDX=0

        while kill -0 "$DOCKER_PULL_PID" 2>/dev/null; do
          local CURRENT_PCT_LINE=$(grep -oE "[0-9]+%[[:space:]]+.*" "$DOCKER_PULL_OUTPUT_FILE" | tail -1)
          if [ -n "$CURRENT_PCT_LINE" ]; then
            printf "\r  Pull image : %-60s" "$CURRENT_PCT_LINE"
          else
            SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER_CHARS} ))
            printf "\r  Pull image : %s En attente..." "${SPINNER_CHARS:$SPIN_IDX:1}"
          fi
          sleep 0.2
        done
        wait "$DOCKER_PULL_PID"
        local DOCKER_PULL_EXIT_CODE=$?

        # Clear the line
        printf "\r%s\r" "$(tput el)"
        cat "$DOCKER_PULL_OUTPUT_FILE" >> "$LOG_FILE" # Append full output to main log
        rm "$DOCKER_PULL_OUTPUT_FILE"

        if [ "$DOCKER_PULL_EXIT_CODE" -ne 0 ]; then
          error "Échec du pull de l'image Docker pour Open WebUI."
          return 1
        else
          ok "Image Open WebUI tirée avec succès."
        fi

        # ── ÉTAPE 3 : Relancer avec les bons paramètres ─────────────
        info "Lancement du container Open WebUI..."
        if _docker_run_webui "$IMG" "$WEBUI_DATA_CURR" "$WEBUI_PORT_CURR" "$WEBUI_NET_CURR"; then
          ok "Open WebUI mis à jour et redémarré ✓"
          # Supprimer anciennes images non utilisées
          docker image prune -f 2>/dev/null || true
          ok "Anciennes images supprimées (espace libéré)"
        else
          warn "Open WebUI non démarré après MAJ."
          echo ""
          warn "Restauration depuis le backup disponible :"
          [ -f "$STATE_DIR/last_webui_backup" ] &&             warn "  Backup : $(cat "$STATE_DIR/last_webui_backup")"
          warn "  Commande manuelle : docker logs open-webui"
        fi
        ;;

      APT|ALL)
        { [ "$TARGET" = "OLLAMA" ] || [ "$TARGET" = "WEBUI" ]; } && continue
        step "Mise à jour système ($SYS_UPDATES paquets)"
        pkg_update
        pkg_upgrade
        pkg_autoremove
        ok "Système mis à jour."

        # Vérifier si reboot nécessaire après MAJ noyau
        if [ -f /var/run/reboot-required ]; then
          warn "Un reboot est recommandé suite à la mise à jour du noyau."
          confirm "Redémarrer maintenant ?" && reboot_and_resume "MENU" "MAJ système"
        fi
        ;;
    esac
  done

  echo ""
  log "Mise(s) à jour terminée(s). Log : $LOG_FILE"
}

menu_status() {
  declare -gA CFG; source "$CONFIG_FILE" 2>/dev/null || true

  # ── Détection GPU légère si HW non initialisé ────────────────────
  if [[ -z "${HW[gpu_brand]+set}" ]]; then
    declare -gA HW=()
    HW[gpu_brand]="none"
    HW[gpu_model]="Aucun GPU dédié"
    local _GPU_PCI
    _GPU_PCI=$(lspci 2>/dev/null | grep -iE "VGA|3D controller|Display" || true)
    if echo "$_GPU_PCI" | grep -qi "nvidia"; then
      HW[gpu_brand]="nvidia"
      HW[gpu_model]=$(echo "$_GPU_PCI" | grep -i nvidia | head -1 | sed 's/.*: //;s/ (.*//')
    elif echo "$_GPU_PCI" | grep -qiE "amd|radeon|advanced micro"; then
      HW[gpu_brand]="amd"
      HW[gpu_model]=$(echo "$_GPU_PCI" | grep -iE "amd|radeon" | head -1 | sed 's/.*: //;s/ (.*//')
    elif echo "$_GPU_PCI" | grep -qiE "intel.*arc"; then
      HW[gpu_brand]="intel"
      HW[gpu_model]=$(echo "$_GPU_PCI" | grep -i "intel.*arc" | head -1 | sed 's/.*: //')
    fi
  fi

  while true; do
    title "ÉTAT DU SYSTÈME IA"

    # ── Statut des services ──────────────────────────────────────
    step "Services"
    local _OLL_OK=0 _WUI_OK=0 _DOC_OK=0
    svc_active ollama 2>/dev/null  && _OLL_OK=1
    docker ps &>/dev/null          && _DOC_OK=1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && _WUI_OK=1

    local _WEBUI_PORT="${CFG[webui_port]:-8080}"
    local _OLLAMA_HOST="${CFG[ollama_host]:-0.0.0.0}"

    if [ "$_OLL_OK" -eq 1 ]; then
      local _NM; _NM=$(curl -sf --max-time 2 "http://127.0.0.1:11434/api/tags" 2>/dev/null         | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); print(len(d.get('models',[])))\nexcept: print(chr(63))" 2>/dev/null || echo "?")
      ok  "Ollama    : ${GREEN}actif${NC}  →  ${CYAN}http://${_OLLAMA_HOST}:11434${NC}  ${DIM}(${_NM} modèles)${NC}"
    else
      nok "Ollama    : ${RED}arrêté${NC}"
    fi

    if [ "$_WUI_OK" -eq 1 ]; then
      ok  "Open WebUI: ${GREEN}actif${NC}  →  ${CYAN}http://localhost:${_WEBUI_PORT}${NC}"
    else
      nok "Open WebUI: ${RED}arrêté${NC}"
    fi

    if [ "$_DOC_OK" -eq 1 ]; then
      local _NC; _NC=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
      ok  "Docker    : ${GREEN}actif${NC}  ${DIM}(${_NC} container(s))${NC}"
    else
      nok "Docker    : ${RED}arrêté${NC}"
    fi

    echo ""

    # ── Info réseau Ollama ──────────────────────────────────────
    if [ "${_OLLAMA_HOST}" = "0.0.0.0" ]; then
      local _LIP; _LIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
      info "Ollama accessible sur le réseau LAN : ${CYAN}http://${_LIP:-<IP>}:11434${NC}"
    fi

    # ── GPU ──────────────────────────────────────────────────────
    step "GPU"
    case "${HW[gpu_brand]:-none}" in
      nvidia) nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total                 --format=csv,noheader 2>/dev/null                 | awk -F', ' '{printf "  %-30s  Temp: %s°C  Charge: %s%%  VRAM: %s/%s Mo
",$1,$2,$3,$4,$5}'                 || warn "nvidia-smi indisponible" ;;
      amd)    command -v rocm-smi &>/dev/null && rocm-smi --showuse --showtemp 2>/dev/null                 | grep -v "^$" | head -6 | sed 's/^/  /' || lspci | grep -i amd | sed 's/^/  /' ;;
      *)      echo "  CPU only — pas de GPU dédié détecté" ;;
    esac

    echo ""
    step "Modèles installés"
    command -v ollama &>/dev/null && ollama list 2>/dev/null || warn "Ollama non disponible"

    echo ""
    step "Disques"
    df -h 2>/dev/null | grep -vE "^(tmpfs|devtmpfs|udev|/dev/loop|Filesystem)"       | awk '{printf "  %-22s %6s  utilisé: %5s  libre: %5s  (%s)
",$1,$2,$3,$4,$5}'

    echo ""
    step "RAM & Swap"
    free -h 2>/dev/null | awk '
      /^Mem:/  {printf "  RAM   : %s total  %s utilisé  %s libre
", $2,$3,$4}
      /^Swap:/ {printf "  Swap  : %s total  %s utilisé  %s libre
", $2,$3,$4}'

    # ══════════════════════════════════════════════════════════════
    # Sous-menu de contrôle des services
    # ══════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BOLD}  ── Contrôle des services ──────────────────────────────${NC}"
    echo -e "  ${CYAN}[1]${NC}  Ollama     — ${GREEN}Démarrer${NC}"
    echo -e "  ${CYAN}[2]${NC}  Ollama     — ${RED}Arrêter${NC}"
    echo -e "  ${CYAN}[3]${NC}  Ollama     — ${YELLOW}Redémarrer${NC}"
    echo -e "  ${CYAN}[4]${NC}  Open WebUI — ${GREEN}Démarrer${NC}"
    echo -e "  ${CYAN}[5]${NC}  Open WebUI — ${RED}Arrêter${NC}"
    echo -e "  ${CYAN}[6]${NC}  Open WebUI — ${YELLOW}Redémarrer${NC}"
    echo -e "  ${CYAN}[7]${NC}  Docker     — ${YELLOW}Redémarrer${NC}"
    echo -e "  ${CYAN}[8]${NC}  Tout       — ${GREEN}Démarrer${NC}  ${DIM}(Docker → Ollama → WebUI)${NC}"
    echo -e "  ${CYAN}[9]${NC}  Tout       — ${RED}Arrêter${NC}   ${DIM}(WebUI → Ollama → Docker)${NC}"
    echo -e "  ${CYAN}[r]${NC}  Rafraîchir l'affichage"
    echo -e "  ${CYAN}[q]${NC}  Retour au menu principal"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Action : ${NC}")" _SVC_CHOICE

    case "${_SVC_CHOICE:-r}" in

      1)  # Démarrer Ollama
          step "Démarrage Ollama..."
          svc_start ollama && ok "Ollama démarré." || warn "Échec démarrage Ollama."
          sleep 2 ;;

      2)  # Arrêter Ollama
          step "Arrêt Ollama..."
          svc_stop ollama && ok "Ollama arrêté." || warn "Échec arrêt Ollama."
          sleep 1 ;;

      3)  # Redémarrer Ollama
          step "Redémarrage Ollama..."
          svc_restart ollama && ok "Ollama redémarré." || warn "Échec redémarrage Ollama."
          sleep 2 ;;

      4)  # Démarrer Open WebUI
          step "Démarrage Open WebUI..."
          if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
            docker start open-webui && ok "Open WebUI démarré." || warn "Échec démarrage WebUI."
            # Recréer le service systemd si absent
            if [ "$HAS_SYSTEMD" -eq 1 ] && [ ! -f /etc/systemd/system/open-webui.service ]; then
              step "Création du service systemd open-webui..."
              _install_webui_service "${CFG[webui_port]:-8080}" "${CFG[webui_dir]}"                 "${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}"                 "${CFG[docker_network]:-host}"
            fi
          else
            warn "Container open-webui inexistant — utilise [Option 7] Réparer WebUI."
          fi
          sleep 2 ;;

      5)  # Arrêter Open WebUI
          step "Arrêt Open WebUI..."
          docker stop open-webui 2>/dev/null && ok "Open WebUI arrêté." || warn "Échec arrêt WebUI."
          sleep 1 ;;

      6)  # Redémarrer Open WebUI
          step "Redémarrage Open WebUI..."
          docker restart open-webui 2>/dev/null && ok "Open WebUI redémarré." || warn "Échec redémarrage WebUI."
          sleep 2 ;;

      7)  # Redémarrer Docker
          step "Redémarrage Docker..."
          warn "Ceci arrêtera TOUS les containers en cours."
          confirm "Confirmer le redémarrage Docker ?" && {
            svc_restart docker && ok "Docker redémarré." || warn "Échec redémarrage Docker."
          } || info "Annulé."
          sleep 3 ;;

      8)  # Tout démarrer
          step "Démarrage de tous les services..."
          svc_start docker  2>/dev/null || true; sleep 2
          svc_start ollama  2>/dev/null || true; sleep 2
          docker start open-webui 2>/dev/null || true; sleep 1
          ok "Séquence de démarrage terminée." ;;

      9)  # Tout arrêter
          step "Arrêt de tous les services..."
          confirm "Arrêter WebUI, Ollama et Docker ?" && {
            docker stop open-webui 2>/dev/null || true; sleep 1
            svc_stop ollama 2>/dev/null || true; sleep 1
            warn "Docker non arrêté (peut affecter d'autres containers)."
          } || info "Annulé." ;;

      q|Q) break ;;
      r|R|*) ;;  # Rafraîchir → reboucler
    esac
  done
}

# ================================================================
#  FONCTION : NETTOYAGE COMPLET (clean install)
# ================================================================

clean_install() {
  title "NETTOYAGE COMPLET — CLEAN INSTALL"

  echo -e "${RED}${BOLD}  ⚠️  ATTENTION — Cette opération va supprimer :${NC}"
  echo ""
  echo -e "  ${RED}✗${NC}  Container Open WebUI et son image Docker"
  echo -e "  ${RED}✗${NC}  Ollama + tous ses modèles installés"
  echo -e "  ${RED}✗${NC}  NVIDIA Container Toolkit"
  echo -e "  ${RED}✗${NC}  Dashboard IA + panneau Administration + credentials"
  echo -e "  ${RED}✗${NC}  Services systemd : open-webui, llama-server, ia-dashboard"
  echo -e "  ${RED}✗${NC}  Dépôts APT ajoutés (NVIDIA, ROCm, Docker)"
  echo -e "  ${RED}✗${NC}  Configuration systemd ollama override"
  echo -e "  ${RED}✗${NC}  Blacklist Nouveau + règle sysctl IPv6"
  echo -e "  ${RED}✗${NC}  Script de backup + crontab"
  echo -e "  ${RED}✗${NC}  État de l'installateur ($STATE_DIR)"
  echo ""
  echo -e "  ${YELLOW}⚠  Les données utilisateur (modèles téléchargés, base WebUI)${NC}"
  echo -e "  ${YELLOW}   sur le disque de stockage NE seront PAS supprimées.${NC}"
  echo -e "  ${YELLOW}   Pour les supprimer, fais-le manuellement.${NC}"
  echo ""

  confirm "Confirmer le nettoyage complet ?" || { info "Annulé."; return 0; }
  confirm "Vraiment ? Cette action est irréversible." || { info "Annulé."; return 0; }

  step "Arrêt des services..."
  svc_stop ollama
  docker stop open-webui 2>/dev/null || true
  docker rm   open-webui 2>/dev/null || true

  step "Suppression Open WebUI (image Docker)..."
  docker rmi ghcr.io/open-webui/open-webui:cuda 2>/dev/null || true
  docker rmi ghcr.io/open-webui/open-webui:rocm 2>/dev/null || true
  docker rmi ghcr.io/open-webui/open-webui:main 2>/dev/null || true

  step "Suppression Ollama..."
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl disable ollama 2>/dev/null || true
    rm -f /etc/systemd/system/ollama.service
    rm -f /etc/systemd/system/ollama.service.d/override.conf
    rm -fd /etc/systemd/system/ollama.service.d 2>/dev/null || true
    systemctl daemon-reload
  else
    rc-update del ollama 2>/dev/null || true
    rm -f /etc/init.d/ollama 2>/dev/null || true
    rm -f /etc/conf.d/ollama 2>/dev/null || true
  fi
  rm -f /usr/local/bin/ollama "$(command -v ollama 2>/dev/null)" 2>/dev/null || true

  step "Suppression NVIDIA Container Toolkit..."
  pkg_remove nvidia-container-toolkit 2>/dev/null || true
  # Debian/Ubuntu
  rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
  rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  # RHEL/Fedora
  rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo 2>/dev/null || true

  step "Suppression dépôts ROCm..."
  # Debian/Ubuntu
  rm -f /etc/apt/sources.list.d/rocm.list
  rm -f /etc/apt/keyrings/rocm.gpg
  # RHEL/Fedora
  rm -f /etc/yum.repos.d/rocm.repo 2>/dev/null || true
  # openSUSE
  zypper removerepo ROCm 2>/dev/null || true

  step "Suppression Dashboard IA + Administration..."
  # Arrêt propre
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl stop    "$DASHBOARD_SERVICE" 2>/dev/null || true
    systemctl disable "$DASHBOARD_SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/ia-dashboard.service
    systemctl daemon-reload 2>/dev/null || true
  elif command -v rc-service &>/dev/null; then
    rc-update del "$DASHBOARD_SERVICE" 2>/dev/null || true
  fi
  # Script Python + credentials admin
  rm -f "$DASHBOARD_SCRIPT"
  rm -f "$CREDS_FILE"
  ok "Dashboard supprimé."

  step "Suppression service Open WebUI (systemd)..."
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl stop    open-webui.service 2>/dev/null || true
    systemctl disable open-webui.service 2>/dev/null || true
    rm -f /etc/systemd/system/open-webui.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  step "Suppression service llama-server (si présent)..."
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl stop    llama-server.service 2>/dev/null || true
    systemctl disable llama-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/llama-server.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  step "Suppression dépôts Docker (APT)..."
  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.gpg
  # RHEL
  rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true

  step "Suppression règle blacklist Nouveau (NVIDIA)..."
  rm -f /etc/modprobe.d/blacklist-nouveau.conf

  step "Suppression configuration sysctl IPv6 (ajoutée pour Ollama)..."
  if [ -f /etc/sysctl.conf ]; then
    sed -i '/^net.ipv6.bindv6only=0$/d' /etc/sysctl.conf 2>/dev/null || true
  fi

  step "Suppression configuration backup..."
  rm -f /usr/local/bin/backup_ia_local.sh
  crontab -l 2>/dev/null | grep -v "backup_ia_local" | crontab - 2>/dev/null || true

  step "Suppression service de reprise..."
  if [ "${HAS_SYSTEMD:-0}" -eq 1 ]; then
    systemctl disable ia-installer-resume.service 2>/dev/null || true
    rm -f /etc/systemd/system/ia-installer-resume.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  step "Nettoyage état installateur..."
  _safe_rm "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  # Rafraîchir la liste des paquets après suppression des dépôts
  pkg_update 2>/dev/null || true

  ok "Nettoyage terminé. Le système est prêt pour une installation fraîche."
  info "Lance : sudo bash $SCRIPT_PATH"
}

# ================================================================
#  POINT D'ENTRÉE
# ================================================================

CURRENT_STATE=$(load_state)

# ── Validation de l'état chargé (anti-falsification du fichier state) ────────
# Le fichier state ne doit contenir que des valeurs attendues : START, EXEC:N,
# RESUME:N, ERROR:*, ou être vide. Toute autre valeur est ignorée.
if [[ -n "$CURRENT_STATE" ]] &&    ! [[ "$CURRENT_STATE" =~ ^(START|EXEC:[0-9]+|RESUME:[A-Z0-9_:]+|ERROR:[A-Z0-9_:]+)$ ]]; then
  warn "Fichier state corrompu ou falsifié ('$CURRENT_STATE') — réinitialisation."
  rm -f "$STATE_FILE"
  CURRENT_STATE="START"
fi

# ── CAS 1 : Reprise après reboot ──────────────────────────────
if [[ "$CURRENT_STATE" == RESUME:* ]]; then
  RESUME_AT="${CURRENT_STATE#RESUME:}"
  load_config
  title "REPRISE APRÈS REBOOT → $RESUME_AT"
  log "Configuration rechargée depuis $CONFIG_FILE"
  info "GPU    : ${HW[gpu_brand]:-?} — ${HW[gpu_model]:-?}"
  info "RAM    : ${HW[ram_gb]:-?} Go  |  VRAM : ${HW[gpu_vram_gb]:-?} Go"
  info "Profil : ${HW[profile]:-?}"
  echo ""

  [ "${#PLAN[@]}" -eq 0 ] && {
    warn "Plan vide → reconstruction..."
    build_install_plan
  }

  systemctl disable ia-installer-resume.service 2>/dev/null || true
  rm -f /etc/systemd/system/ia-installer-resume.service
  systemctl daemon-reload
  run_full_install "$RESUME_AT"
  exit 0
fi

# ── CAS 2 : Reprise après erreur ──────────────────────────────
if [[ "$CURRENT_STATE" == ERROR:* ]]; then
  FAILED_STEP="${CURRENT_STATE#ERROR:}"
  load_config
  title "ERREUR DÉTECTÉE — REPRISE POSSIBLE"
  echo ""
  warn "Le script a échoué à l'étape : ${BOLD}$FAILED_STEP${NC}"
  echo -e "  Log d'erreurs : $STATE_DIR/errors.log"
  [ -f "$STATE_DIR/errors.log" ] && tail -5 "$STATE_DIR/errors.log" | sed 's/^/  /'
  echo ""

  # ── Vérification automatique : est-ce que tout est déjà installé ? ──
  _ERR_DOCKER=$(command -v docker &>/dev/null && docker ps &>/dev/null && echo "oui" || echo "non")
  _ERR_OLLAMA=$(command -v ollama &>/dev/null && systemctl is-active --quiet ollama 2>/dev/null && echo "oui" || echo "non")
  _ERR_WEBUI=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && echo "oui" || echo "non")

  echo -e "  ${BOLD}Vérification rapide de l'état actuel :${NC}"
  [ "$_ERR_DOCKER" = "oui" ] && ok "Docker    : actif" || nok "Docker    : absent ou inactif"
  [ "$_ERR_OLLAMA" = "oui" ] && ok "Ollama    : actif" || nok "Ollama    : absent ou inactif"
  [ "$_ERR_WEBUI"  = "oui" ] && ok "Open WebUI : actif" || nok "Open WebUI : absent ou inactif"
  echo ""

  # Si tout est installé et actif → proposer de juste nettoyer l'état
  if [ "$_ERR_DOCKER" = "oui" ] && [ "$_ERR_OLLAMA" = "oui" ] && [ "$_ERR_WEBUI" = "oui" ]; then
    echo -e "  ${GREEN}${BOLD}✓ Tout semble déjà installé et actif !${NC}"
    echo -e "  ${DIM}L'erreur était probablement une fausse alerte (variable locale hors fonction,${NC}"
    echo -e "  ${DIM}commande non-critique, ou script interrompu manuellement).${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Effacer l'erreur et aller au menu principal${NC}  ${DIM}← recommandé${NC}"
    echo -e "  ${GREEN}[2]${NC}  Reprendre depuis l'étape échouée ($FAILED_STEP)"
    echo -e "  ${GREEN}[3]${NC}  Reprendre depuis le début"
    echo -e "  ${GREEN}[4]${NC}  Nettoyage complet + recommencer"
    echo -e "  ${GREEN}[5]${NC}  Ouvrir un shell de débogage"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Choix [1-5] : ${NC}")" ERR_ACTION
    case "${ERR_ACTION:-1}" in
      1)
        rm -f "$STATE_FILE" "$STATE_DIR/errors.log"
        ok "État d'erreur effacé — bienvenue au menu !"
        # Laisser le script continuer vers le CAS 3 / menu
        CURRENT_STATE="START"
        ;;
      2)
        [ "${#PLAN[@]}" -eq 0 ] && { load_config; build_install_plan; }
        IDX=0
        for S in "${PLAN[@]}"; do [ "$S" = "$FAILED_STEP" ] && break; IDX=$(( IDX + 1 )); done
        run_full_install "EXEC:$IDX"; exit 0 ;;
      3) run_full_install "ANALYSE"; exit 0 ;;
      4) clean_install; exit 0 ;;
      5) warn "Shell de débogage — tape 'exit' pour continuer."; bash || true ;;
    esac
  else
    # Tout n'est pas installé → afficher le menu de réparation classique
    echo -e "  ${GREEN}[1]${NC}  Reprendre depuis l'étape échouée ($FAILED_STEP)"
    echo -e "  ${GREEN}[2]${NC}  Reprendre depuis le début"
    echo -e "  ${GREEN}[3]${NC}  Nettoyage complet + recommencer"
    echo -e "  ${GREEN}[4]${NC}  Ouvrir un shell de débogage"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Choix [1-4] : ${NC}")" ERR_ACTION
    case "${ERR_ACTION:-4}" in
      1)
        [ "${#PLAN[@]}" -eq 0 ] && { load_config; build_install_plan; }
        IDX=0
        for S in "${PLAN[@]}"; do [ "$S" = "$FAILED_STEP" ] && break; IDX=$(( IDX + 1 )); done
        run_full_install "EXEC:$IDX"; exit 0 ;;
      2) run_full_install "ANALYSE"; exit 0 ;;
      3) clean_install; exit 0 ;;
      4) warn "Shell de débogage — tape 'exit' pour continuer."; bash || true ;;
    esac
  fi
fi

# ── CAS 3 : Installation précédente détectée ──────────────────
if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
  load_config

  title "INSTALLATION PRÉCÉDENTE DÉTECTÉE"

  # ── Lire le contexte réel du système ──────────────────────────
  # Date d'installation
  PREV_DATE=$(stat -c "%y" "$CONFIG_FILE" 2>/dev/null | cut -d. -f1 || echo "?")

  # État réel des services (pas juste la config)
  OLLAMA_RUNNING="non"
  WEBUI_RUNNING="non"
  OLLAMA_VER="?"
  WEBUI_VER="?"
  MODELS_COUNT=0
  WEBUI_IMG_ACTUAL="?"

  systemctl is-active --quiet ollama 2>/dev/null && OLLAMA_RUNNING="oui"
  command -v ollama &>/dev/null && OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP "\d+\.\d+\.\d+" | head -1 || echo "?")
  command -v ollama &>/dev/null && systemctl is-active --quiet ollama 2>/dev/null &&     MODELS_COUNT=$(ollama list 2>/dev/null | tail -n +2 | wc -l || echo "0")
  docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^open-webui$" && WEBUI_RUNNING="oui"
  WEBUI_IMG_ACTUAL=$(docker inspect open-webui --format "{{.Config.Image}}" 2>/dev/null || echo "?")
  WEBUI_VER=$(docker inspect open-webui     --format "{{index .Config.Labels "org.opencontainers.image.version"}}"     2>/dev/null || echo "?")

  # Espace disque sur le disque IA
  DISK_USAGE="?" DISK_FREE="?"
  if [ -n "${CFG[hdd_mount]:-}" ] && mountpoint -q "${CFG[hdd_mount]}" 2>/dev/null; then
    DISK_USAGE=$(df -h "${CFG[hdd_mount]}" 2>/dev/null | awk "NR==2{print \$3}")
    DISK_FREE=$(df -h  "${CFG[hdd_mount]}" 2>/dev/null | awk "NR==2{print \$4}")
  fi

  # Vérifier si MAJ disponible (rapide, sans bloquer)
  OLLAMA_LATEST="?" WEBUI_LATEST="?"
  if ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    OLLAMA_LATEST=$(curl -sf --max-time 5       "https://api.github.com/repos/ollama/ollama/releases/latest"       | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','?').lstrip('v'))"       2>/dev/null || echo "?")
    WEBUI_LATEST=$(curl -sf --max-time 5       "https://api.github.com/repos/open-webui/open-webui/releases/latest"       | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','?').lstrip('v'))"       2>/dev/null || echo "?")
  fi

  # ── Affichage du tableau de bord ──────────────────────────────
  echo ""
  echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${CYAN}  │              ÉTAT DE L'INSTALLATION EXISTANTE           │${NC}"
  echo -e "${BOLD}${CYAN}  ├──────────────────────┬──────────────────────────────────┤${NC}"

  # GPU & RAM
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "GPU" "${HW[gpu_brand]:-?} — ${HW[gpu_model]:0:28}"
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "RAM / VRAM" "${HW[ram_gb]:-?} Go RAM — ${HW[gpu_vram_gb]:-?} Go VRAM"
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "Profil IA" "${HW[profile]:-?}"

  echo -e "${CYAN}  ├──────────────────────┼──────────────────────────────────┤${NC}"

  # Ollama
  OLLAMA_COLOR="$GREEN"
  OLLAMA_ICON="✓"
  [ "$OLLAMA_RUNNING" = "non" ] && OLLAMA_COLOR="$RED" && OLLAMA_ICON="✗"
  OLLAMA_UPD=""
  [ "$OLLAMA_LATEST" != "?" ] && [ "$OLLAMA_VER" != "$OLLAMA_LATEST" ] &&     OLLAMA_UPD=" ${YELLOW}[⬆ $OLLAMA_LATEST]${NC}"
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  " "Ollama"
  echo -e "${OLLAMA_COLOR}${OLLAMA_ICON}${NC} v${OLLAMA_VER} (${OLLAMA_RUNNING})${OLLAMA_UPD}$(printf '%*s' $((26 - ${#OLLAMA_VER})) '')  ${CYAN}│${NC}"

  # Open WebUI
  WEBUI_COLOR="$GREEN"
  WEBUI_ICON="✓"
  [ "$WEBUI_RUNNING" = "non" ] && WEBUI_COLOR="$RED" && WEBUI_ICON="✗"
  WEBUI_UPD=""
  [ "$WEBUI_LATEST" != "?" ] && [ "$WEBUI_VER" != "?" ] && [ "$WEBUI_VER" != "$WEBUI_LATEST" ] &&     WEBUI_UPD=" ${YELLOW}[⬆ $WEBUI_LATEST]${NC}"
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  " "Open WebUI"
  echo -e "${WEBUI_COLOR}${WEBUI_ICON}${NC} v${WEBUI_VER} (${WEBUI_RUNNING})${WEBUI_UPD}$(printf '%*s' $((26 - ${#WEBUI_VER})) '')  ${CYAN}│${NC}"

  # Modèles
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "Modèles IA" "${MODELS_COUNT} installé(s)"

  # Stockage
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "Disque IA" "${CFG[hdd_mount]:-?} (utilisé: $DISK_USAGE / libre: $DISK_FREE)"
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "Open WebUI URL" "http://localhost:${CFG[webui_port]:-8080}"
  printf "${CYAN}  │${NC}  %-20s ${CYAN}│${NC}  %-30s  ${CYAN}│${NC}
"     "Installé le" "$PREV_DATE"

  echo -e "${CYAN}  └──────────────────────┴──────────────────────────────────┘${NC}"
  echo ""

  # Alertes MAJ
  HAS_UPDATE=0
  [ "$OLLAMA_LATEST" != "?" ] && [ "$OLLAMA_VER" != "$OLLAMA_LATEST" ] && {
    warn "Ollama : mise à jour disponible v$OLLAMA_VER → v$OLLAMA_LATEST"
    HAS_UPDATE=1
  }
  [ "$WEBUI_LATEST" != "?" ] && [ "$WEBUI_VER" != "?" ] && [ "$WEBUI_VER" != "$WEBUI_LATEST" ] && {
    warn "Open WebUI : mise à jour disponible v$WEBUI_VER → v$WEBUI_LATEST"
    HAS_UPDATE=1
  }
  [ "$HAS_UPDATE" -eq 1 ] && info "Lance [3] Mises à jour pour les appliquer." ||     ok "Tous les composants sont à jour."

  # Services arrêtés ?
  [ "$OLLAMA_RUNNING" = "non" ] && warn "Ollama est arrêté (systemctl start ollama)"
  [ "$WEBUI_RUNNING"  = "non" ] && warn "Open WebUI est arrêté (docker start open-webui)"

  # Vérifier que le service systemd open-webui existe pour le boot
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    if [ ! -f /etc/systemd/system/open-webui.service ]; then
      warn "Service systemd open-webui.service absent → démarrage au boot non garanti"
      if confirm "Créer le service systemd open-webui maintenant ?"; then
        load_config
        _install_webui_service "${CFG[webui_port]:-8080}" "${CFG[webui_dir]}"           "${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}"           "${CFG[docker_network]:-host}"
      fi
    else
      if systemctl is-enabled --quiet open-webui.service 2>/dev/null; then
        ok "Service systemd open-webui.service : activé au boot"
      else
        warn "Service open-webui.service présent mais non activé au boot"
        confirm "Activer le démarrage automatique ?" && systemctl enable open-webui.service && ok "Activé."
      fi
    fi
  fi

  echo ""
  echo -e "${BOLD}  Que veux-tu faire ?${NC}
"
  echo -e "  ${GREEN}[1]${NC}  Aller au menu principal"
  echo -e "  ${GREEN}[2]${NC}  Ajouter des modèles IA"
  echo -e "  ${GREEN}[3]${NC}  Vérifier & appliquer les mises à jour"
  echo -e "  ${GREEN}[4]${NC}  Continuer une installation incomplète"
  echo -e "  ${GREEN}[5]${NC}  Nettoyage complet + réinstallation from scratch"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix [1-5] : ${NC}")" PREV_CHOICE

  case "${PREV_CHOICE:-1}" in
    1)  ;; # Continue vers le menu principal
    2)
      menu_models
      ;;
    3)
      menu_updates
      ;;
    4)
      info "Reprise de l'installation..."
      LAST_EXEC=$(cat "$STATE_FILE" 2>/dev/null || echo "EXEC:0")
      [ "${#PLAN[@]}" -eq 0 ] && build_install_plan
      run_full_install "$LAST_EXEC"
      exit 0 ;;
    5)
      clean_install
      ;; # Continue vers le menu
  esac
fi


# ================================================================
#  RÉPARATION RAPIDE OPEN WEBUI (après MAJ ratée)
# ================================================================

menu_repair_webui() {
  title "🔧 RÉPARATION OPEN WEBUI"

  echo -e "${YELLOW}  Cet outil recrée le container Open WebUI avec les bons paramètres.${NC}"
  echo -e "${YELLOW}  Tes conversations et paramètres sont dans le dossier de données.${NC}"
  echo ""

  # ── Détecter l'état actuel ──────────────────────────────────
  step "Diagnostic"
  declare -gA CFG=(); [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true

  DATA_DIR="${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}"
  PORT="${CFG[webui_port]:-8080}"
  IMG="${CFG[docker_image]:-ghcr.io/open-webui/open-webui:main}"
  NET="${CFG[docker_network]:-host}"

  # Container actuel
  CUR_STATE; CUR_STATE=$(docker inspect --format="{{.State.Status}}" open-webui 2>/dev/null || echo "absent")
  CUR_IMG;   CUR_IMG=$(docker inspect  --format="{{.Config.Image}}"  open-webui 2>/dev/null || echo "?")
  CUR_VOL;   CUR_VOL=$(docker inspect  --format="{{range .Mounts}}{{.Source}}{{end}}" open-webui 2>/dev/null || echo "?")
  CUR_NET;   CUR_NET=$(docker inspect  --format="{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" open-webui 2>/dev/null | tr ' ' '
' | grep OLLAMA || echo "?")
  CUR_ENV;   CUR_ENV=$(docker inspect  --format='{{range .Config.Env}}{{println .}}{{end}}' open-webui 2>/dev/null | grep "OLLAMA_BASE_URL" || echo "?")

  echo -e "  ${BOLD}Container actuel :${NC}"
  printf "    %-20s %s
" "État :"     "$CUR_STATE"
  printf "    %-20s %s
" "Image :"    "$CUR_IMG"
  printf "    %-20s %s
" "Volume :"   "$CUR_VOL"
  printf "    %-20s %s
" "Réseau :"   "$CUR_NET"
  printf "    %-20s %s
" "OLLAMA URL:" "$CUR_ENV"
  echo ""

  # ── Afficher/corriger les paramètres cibles ─────────────────
  step "Paramètres cibles (ta commande de référence)"
  echo ""
  echo -e "  ${BOLD}Dossier données :${NC} $DATA_DIR"

  # Vérifier si le dossier existe et contient des données
  if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    ok "Données trouvées dans $DATA_DIR"
    DATA_SIZE; DATA_SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
    info "Taille : $DATA_SIZE"
    # Lister les fichiers importants
    [ -f "$DATA_DIR/webui.db" ]       && ok "webui.db présent (conversations ✓)"
    [ -d "$DATA_DIR/uploads" ]         && ok "uploads/ présent"
    [ -f "$DATA_DIR/config.json" ]     && ok "config.json présent"
  else
    warn "Dossier $DATA_DIR vide ou absent !"
    echo ""
    echo -e "  ${RED}Possible causes :${NC}"
    echo -e "   - Le dossier a été créé avec un chemin différent"
    echo -e "   - Le disque /mnt/ia_toshiba n'est pas monté"
    echo ""
    # Chercher des données dans des emplacements alternatifs
    step "Recherche de données dans des emplacements alternatifs..."
    FOUND_DATA=""
    for SEARCH_PATH in       /mnt/ia_toshiba/open-webui       /mnt/ia_sdb/open-webui       /mnt/ia_storage/open-webui       /root/.open-webui       /var/lib/open-webui; do
      if [ -d "$SEARCH_PATH" ] && [ -f "$SEARCH_PATH/webui.db" ]; then
        ok "Données trouvées dans : $SEARCH_PATH"
        FOUND_DATA="$SEARCH_PATH"
      fi
    done
    # Chercher aussi dans les volumes Docker nommés
    docker volume ls 2>/dev/null | grep -i webui | while read -r _ VOL; do
      warn "Volume Docker trouvé : $VOL"
    done

    if [ -n "$FOUND_DATA" ]; then
      warn "Données trouvées dans $FOUND_DATA mais attendues dans $DATA_DIR"
      confirm "Utiliser $FOUND_DATA comme source ?" && DATA_DIR="$FOUND_DATA"
    fi
  fi

  # Vérifier que le disque est monté
  if [[ "$DATA_DIR" == /mnt/* ]]; then
    MOUNT_POINT; MOUNT_POINT=$(echo "$DATA_DIR" | cut -d/ -f1-3)
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
      warn "Le point de montage $MOUNT_POINT n'est PAS monté !"
      warn "Monte le disque d'abord : mount /dev/sdb $MOUNT_POINT"
      confirm "Tenter de monter automatiquement via fstab ?" &&         mount "$MOUNT_POINT" 2>/dev/null && ok "Monté." || warn "Échec montage."
    fi
  fi

  echo ""
  echo -e "  ${BOLD}Image Docker :${NC} $IMG"
  echo -e "  ${BOLD}Réseau      :${NC} $NET (--network=host recommandé)"
  echo -e "  ${BOLD}Ollama URL  :${NC} OLLAMA_BASE_URL=http://127.0.0.1:11434"
  echo ""

  # Permettre de modifier les paramètres
  read -rp "$(echo -e "${YELLOW}  >>> Dossier données [Entrée=$DATA_DIR] : ${NC}")" TMP
  [ -n "$TMP" ] && DATA_DIR="$TMP"

  read -rp "$(echo -e "${YELLOW}  >>> Image Docker    [Entrée=$IMG] : ${NC}")" TMP
  [ -n "$TMP" ] && IMG="$TMP"

  echo ""
  echo -e "  ${BOLD}La commande qui sera exécutée :${NC}"
  echo -e "  ${CYAN}docker run -d --network=host \${NC}"
  echo -e "  ${CYAN}  -p ${PORT}:8080 \${NC}"
  echo -e "  ${CYAN}  -v ${DATA_DIR}:/app/backend/data \${NC}"
  echo -e "  ${CYAN}  -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \${NC}"
  echo -e "  ${CYAN}  --name open-webui --restart always \${NC}"
  echo -e "  ${CYAN}  $IMG${NC}"
  echo ""

  confirm "Appliquer cette configuration ?" || { info "Annulé."; return 0; }

  # ── Vérifier qu'Ollama tourne ───────────────────────────────
  step "Vérification Ollama"
  if svc_active ollama 2>/dev/null || systemctl is-active --quiet ollama 2>/dev/null; then
    ok "Ollama actif"
    # Tester l'API
    if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags &>/dev/null; then
      ok "API Ollama répond sur :11434"
      MODEL_COUNT=$(curl -sf --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null \
        | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); print(len(d.get('models',[])))\nexcept: print(chr(63))" 2>/dev/null || echo "?")
      ok "$MODEL_COUNT modèle(s) disponible(s) via Ollama"
    else
      warn "Ollama tourne mais l'API ne répond pas encore — attente..."
      sleep 5
    fi
  else
    warn "Ollama est arrêté — démarrage..."
    systemctl start ollama 2>/dev/null || svc_start ollama
    sleep 5
    curl -sf --max-time 3 http://127.0.0.1:11434/api/tags &>/dev/null       && ok "Ollama prêt" || warn "Ollama ne répond pas sur :11434"
  fi

  # ── Appliquer la réparation ─────────────────────────────────
  step "Recréation du container Open WebUI"
  _docker_run_webui "$IMG" "$DATA_DIR" "$PORT" "host"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    echo ""
    echo -e "${GREEN}${BOLD}  ✓ Open WebUI réparé !${NC}"
    echo ""
    echo -e "  Accès   : ${CYAN}http://localhost:8080${NC}"
    echo -e "  Données : $DATA_DIR"
    echo ""

    # Sauvegarder la config corrigée
    CFG[webui_dir]="$DATA_DIR"
    CFG[docker_image]="$IMG"
    CFG[docker_network]="host"
    save_config
    ok "Configuration mise à jour."
  fi
}

# ── Menu principal ─────────────────────────────────────────────
# Nettoyer un éventuel état ERROR:INIT résiduel avant d'afficher le menu
# (l'erreur INIT n'est jamais bloquante, c'est de l'initialisation)
if [ -f "$STATE_FILE" ]; then
  _STALE=$(cat "$STATE_FILE" 2>/dev/null || echo "")
  if [[ "$_STALE" == "ERROR:INIT" ]]; then
    rm -f "$STATE_FILE"
  fi
fi
unset _STALE



# ── Vérification de mise à jour du script installateur ───────────────────────
# Compare le hash local avec la version sur GitHub pour détecter les updates
_check_script_update() {
  local SCRIPT_PATH="${BASH_SOURCE[0]}"
  local GITHUB_RAW="${SCRIPT_UPDATE_URL:-}"   # Peut être défini dans config.env

  [ -z "$GITHUB_RAW" ] && return 0   # Pas d'URL configurée → skip silencieux

  local LOCAL_SHA; LOCAL_SHA=$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo "")
  local REMOTE_SHA
  REMOTE_SHA=$(curl -sf --max-time 10 "$GITHUB_RAW"     | sha256sum | cut -d' ' -f1 2>/dev/null || echo "")

  [ -z "$REMOTE_SHA" ] && return 0   # Pas de connexion → skip silencieux
  [ "$LOCAL_SHA" = "$REMOTE_SHA" ] && return 0   # Identique → rien à faire

  echo ""
  echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}║  🔄  MISE À JOUR DU SCRIPT DISPONIBLE                    ║${NC}"
  echo -e "  ${CYAN}║                                                          ║${NC}"
  echo -e "  ${CYAN}║  Une nouvelle version du script est disponible.          ║${NC}"
  echo -e "  ${CYAN}║  SHA256 local  : ${LOCAL_SHA:0:32}…  ║${NC}"
  echo -e "  ${CYAN}║  SHA256 distant: ${REMOTE_SHA:0:32}…  ║${NC}"
  echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if confirm "Télécharger et remplacer le script par la nouvelle version ?"; then
    local TMP_SCRIPT; TMP_SCRIPT=$(mktemp /tmp/ia-update-$$.sh)
    if curl -fsSL --max-time 60 "$GITHUB_RAW" -o "$TMP_SCRIPT"; then
      # Vérification intégrité du script téléchargé
      local DL_SHA; DL_SHA=$(sha256sum "$TMP_SCRIPT" | cut -d' ' -f1)
      if [ "$DL_SHA" = "$REMOTE_SHA" ]; then
        chmod 755 "$TMP_SCRIPT"
        cp "$TMP_SCRIPT" "$SCRIPT_PATH"
        ok "Script mis à jour. Redémarrez le script pour appliquer les changements."
        rm -f "$TMP_SCRIPT"
        exit 0
      else
        warn "SHA256 du fichier téléchargé ne correspond pas — mise à jour annulée."
        rm -f "$TMP_SCRIPT"
      fi
    else
      warn "Téléchargement échoué."
      rm -f "$TMP_SCRIPT"
    fi
  fi
}

# ── Lancement anticipé du dashboard au démarrage du script ───────────────────
# Démarre le dashboard en arrière-plan immédiatement pour que l'utilisateur
# puisse suivre l'installation via l'interface web dès le début.
_start_dashboard_early() {
  [ "$HAS_SYSTEMD" -ne 1 ] && return 0   # Pas systemd — pas de service
  local _PORT="${DASHBOARD_PORT:-7842}"
  local _LIP
  _LIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')

  # Installer le script Python dashboard si absent
  if [ ! -f "$DASHBOARD_SCRIPT" ]; then
    install_dashboard_script 2>/dev/null || true
  fi

  # Créer le service systemd si absent
  if [ ! -f "/etc/systemd/system/${DASHBOARD_SERVICE}.service" ]; then
    install_dashboard_service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi

  # Démarrer/redémarrer si pas actif
  if ! svc_active "$DASHBOARD_SERVICE" 2>/dev/null; then
    systemctl start "$DASHBOARD_SERVICE" 2>/dev/null || true
    sleep 2
  fi

  # Affichage d'accueil
  clear
  # Vérifier silencieusement si une mise à jour du script est disponible
  _check_script_update &>/dev/null &
  local _URL_LOCAL="http://127.0.0.1:${_PORT}"
  local _URL_LAN=""
  [ -n "$_LIP" ] && [ "$_LIP" != "127.0.0.1" ] && _URL_LAN="http://${_LIP}:${_PORT}"

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   🤖  IA LOCAL — Installateur v5.0                                  ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   Vous pouvez suivre et piloter l'installation de deux façons :      ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${GREEN}🌐  Via l'interface web${CYAN}  (recommandé)                            ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  printf  "   ${CYAN}║${NC}      ${BOLD}%-68s${CYAN}║${NC}
" "$_URL_LOCAL"
  if [ -n "$_URL_LAN" ]; then
  printf  "   ${CYAN}║${NC}      ${BOLD}%-68s${CYAN}║${NC}
" "$_URL_LAN  ← réseau local"
  fi
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║      Ouvrez cette adresse dans votre navigateur.                    ║${NC}"
  echo -e "${CYAN}║      La progression s'affichera en temps réel sur le dashboard.     ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${YELLOW}⌨️   Via ce terminal${CYAN}  (mode classique)                             ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║      Continuez ici pour une installation guidée en ligne de         ║${NC}"
  echo -e "${CYAN}║      commande. Les deux modes sont synchronisés en temps réel.      ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${YELLOW}🔐  Accès Administration (onglet ⚙️ du dashboard web)${CYAN}             ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  local _ADM_USER="admin" _ADM_IS_DEFAULT=1
  if [ -f "$CREDS_FILE" ]; then
    _ADM_USER=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d.get('user','admin'))" 2>/dev/null || echo "admin")
    _ADM_IS_DEFAULT=$(python3 -c "import json,hashlib; d=json.load(open('$CREDS_FILE')); print(1 if d.get('hash')==hashlib.sha256(b'ia-local-admin').hexdigest() else 0)" 2>/dev/null || echo "1")
  fi
  printf  "   ${CYAN}║${NC}      Login    : ${BOLD}%-53s${CYAN}║${NC}
" "$_ADM_USER"
  if [ "$_ADM_IS_DEFAULT" = "1" ]; then
  printf  "   ${CYAN}║${NC}      Password : ${YELLOW}%-53s${CYAN}║${NC}
" "ia-local-admin  ← À CHANGER !"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${RED}⚠  Mot de passe par défaut — changez-le dans Administration !${CYAN}   ║${NC}"
  else
  printf  "   ${CYAN}║${NC}      Password : ${GREEN}%-53s${CYAN}║${NC}
" "(mot de passe personnalisé ✓)"
  fi
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Tentative d'ouvrir automatiquement le navigateur (si desktop)
  if command -v xdg-open &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$_URL_LOCAL" &>/dev/null & disown
    echo -e "  ${GREEN}✓${NC}  Navigateur ouvert automatiquement"
  else
    echo -e "  ${YELLOW}→${NC}  Copiez l'URL ci-dessus dans votre navigateur pour accéder au dashboard"
  fi

  echo ""
  read -rp "$(echo -e "${YELLOW}  Appuyez sur Entrée pour continuer dans le terminal...${NC}")" _WPAUSE
}



# ── Mode --dry-run ────────────────────────────────────────────────────────────
# Simule l'installation sans rien modifier : analyse le matériel, construit
# le plan, affiche ce qui serait fait, mais n'exécute aucune commande système.
DRY_RUN=0
_dry_run_check() {
  [ "$DRY_RUN" -eq 1 ]
}

run_dry_run() {
  DRY_RUN=1
  title "MODE DRY-RUN — Simulation de l'installation"
  echo -e "  ${YELLOW}Aucune modification ne sera apportée au système.${NC}"
  echo -e "  ${DIM}Ce mode analyse le matériel et affiche le plan d'installation.${NC}"
  echo ""

  # Analyse complète (lecture seule — pas d'effets de bord)
  analyse_hardware

  # Poser les questions de config sans appliquer
  configure_infra

  # Construire le plan
  build_install_plan

  echo ""
  title "📋 PLAN D'INSTALLATION (simulation)"
  echo -e "  ${BOLD}${#PLAN[@]} étapes seraient exécutées :${NC}"
  echo ""
  local IDX=1
  for STEP in "${PLAN[@]}"; do
    local DESC="${PLAN_DESC[$STEP]:-}"
    local REBOOT="${PLAN_REBOOT[$STEP]:-non}"
    local REBOOT_TAG=""
    [ "$REBOOT" = "oui" ] && REBOOT_TAG=" ${YELLOW}[REBOOT]${NC}"
    printf "  ${GREEN}%2d.${NC}  ${BOLD}%-20s${NC}  ${DIM}%s${NC}%b
"       "$IDX" "$STEP" "$DESC" "$REBOOT_TAG"
    IDX=$(( IDX + 1 ))
  done
  echo ""
  echo -e "  ${CYAN}→ Aucune modification effectuée. Relancez sans --dry-run pour installer.${NC}"
  echo ""
  DRY_RUN=0
}

# ── Sauvegarde automatique avant mise à jour majeure ─────────────────────────
# Crée une archive compressée des données critiques avant toute opération
# destructive : MAJ WebUI, MAJ Ollama, réinstallation.
_auto_backup_before_update() {
  local REASON="${1:-update}"
  local BACKUP_BASE="${CFG[backup_dir]:-/mnt/ia_toshiba/backups}"
  local STAMP; STAMP=$(date +%Y%m%d_%H%M%S)
  local BACKUP_DIR="$BACKUP_BASE/auto_${REASON}_${STAMP}"

  info "Sauvegarde automatique avant $REASON..."
  mkdir -p "$BACKUP_DIR" 2>/dev/null || { warn "Impossible de créer le répertoire de backup."; return 0; }

  local SAVED=0

  # Données WebUI (conversations, paramètres, utilisateurs)
  local WEBUI_DATA="${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}"
  if [ -d "$WEBUI_DATA" ] && [ "$(ls -A "$WEBUI_DATA" 2>/dev/null)" ]; then
    cp -r "$WEBUI_DATA" "$BACKUP_DIR/webui-data" 2>/dev/null && SAVED=$(( SAVED + 1 )) || true
  fi

  # Modèles Ollama (seulement les métadonnées + blobs manifest — pas les poids)
  local OLLAMA_DATA="${CFG[ollama_dir]:-/mnt/ia_toshiba/ollama}"
  if [ -d "$OLLAMA_DATA/manifests" ]; then
    mkdir -p "$BACKUP_DIR/ollama-manifests"
    cp -r "$OLLAMA_DATA/manifests" "$BACKUP_DIR/ollama-manifests/" 2>/dev/null && SAVED=$(( SAVED + 1 )) || true
  fi

  # Configuration de l'installateur
  [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$BACKUP_DIR/" 2>/dev/null && SAVED=$(( SAVED + 1 )) || true
  # Copier les credentials avec permissions strictes (contient hash SHA256)
  if [ -f "$CREDS_FILE" ]; then
    cp "$CREDS_FILE" "$BACKUP_DIR/admin-credentials" 2>/dev/null &&       chmod 600 "$BACKUP_DIR/admin-credentials" 2>/dev/null &&       SAVED=$(( SAVED + 1 )) || true
  fi

  chmod -R 600 "$BACKUP_DIR" 2>/dev/null || true  # Backup lisible root uniquement

  if [ $SAVED -gt 0 ]; then
    local SIZE; SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "?")
    ok "Backup créé : $BACKUP_DIR ($SIZE)"
    echo "$BACKUP_DIR" > "$STATE_DIR/last_auto_backup"
  else
    rmdir "$BACKUP_DIR" 2>/dev/null || true
    info "Rien à sauvegarder."
  fi

  # Garder seulement les 5 derniers backups automatiques
  ls -dt "$BACKUP_BASE"/auto_* 2>/dev/null | tail -n +6 | xargs rm -rf 2>/dev/null || true
}

# ── Gestion des arguments de ligne de commande ───────────────────────────────
for _ARG in "$@"; do
  case "$_ARG" in
    --dry-run|-n)
      detect_os 2>/dev/null || true
      run_dry_run; exit 0 ;;
    --version|-v)
      echo "IA Local Installer v5.0 — Auteur: Momorie"; exit 0 ;;
    --check-update)
      SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-}"
      _check_script_update; exit 0 ;;
    --web-install)
      # Lancement non-interactif depuis l'interface web
      # Le script s'exécute sans menu : analyse + backend auto + plan + install
      detect_os 2>/dev/null || true
      analyse_hardware 2>/dev/null || true
      CFG[backend]="${CFG[backend]:-ollama}"
      HW[backend]="${HW[backend]:-ollama}"
      run_full_install "ANALYSE"
      exit 0 ;;

    --help|-h)
      echo "Usage: sudo bash $0 [OPTIONS]"
      echo "Options:"
      echo "  --dry-run, -n       Simuler l'installation sans rien modifier"
      echo "  --version, -v       Afficher la version"
      echo "  --check-update      Vérifier si une MAJ du script est disponible"
      echo "  --help, -h          Afficher cette aide"
      exit 0 ;;
  esac
done

_start_dashboard_early

while true; do
  title "INSTALLATEUR IA LOCAL v5.0"

  # Afficher un indicateur si un état d'erreur est présent
  _MENU_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")
  if [[ "$_MENU_STATE" == ERROR:* ]]; then
    echo -e "  ${RED}⚠  État d'erreur détecté : ${BOLD}${_MENU_STATE}${NC}"
    echo -e "  ${DIM}  Utilise [0] pour effacer si tout fonctionne correctement.${NC}"
    echo ""
  fi

  echo -e "  ${GREEN}[1]${NC}  Installation complète"
  echo -e "  ${GREEN}[2]${NC}  Gérer les modèles IA"
  echo -e "  ${GREEN}[3]${NC}  Vérifier & appliquer les mises à jour"
  echo -e "  ${GREEN}[4]${NC}  Réinstaller un composant"
  echo -e "  ${GREEN}[5]${NC}  État du système"
  echo -e "  ${GREEN}[6]${NC}  Nettoyage complet (clean install)"
  echo -e "  ${RED}[7]${NC}  ${BOLD}Réparer Open WebUI${NC}  ${DIM}← si conversations perdues ou modèles inaccessibles${NC}"
  echo -e "  ${GREEN}[8]${NC}  Voir les logs"
  echo -e "  ${CYAN}[s]${NC}  ${BOLD}Stats système en temps réel${NC}  ${DIM}← CPU · RAM · GPU · Services · Réseau${NC}"
  echo -e "  ${CYAN}[d]${NC}  ${BOLD}Dashboard web${NC}  ${DIM}← Stats temps réel sur http://localhost:${DASHBOARD_PORT:-7842}${NC}"
  echo -e "  ${YELLOW}[0]${NC}  ${BOLD}Effacer l'état d'erreur${NC}  ${DIM}← si tout fonctionne mais une erreur est affichée${NC}"
  echo -e "  ${GREEN}[9]${NC}  Quitter"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix [0-9/s/d] : ${NC}")" CHOICE
  case "$CHOICE" in
    1) run_full_install "ANALYSE" ;;
    2) menu_models        ;;
    3) menu_updates       ;;
    4) menu_reinstall     ;;
    5) menu_status        ;;
    6) clean_install      ;;
    7) menu_repair_webui  ;;
    s|S) menu_stats_live  ;;
    d|D) menu_dashboard   ;;
    8)
      echo -e "\n${BOLD}Logs disponibles :${NC}"
      ls -lht "$LOG_DIR"/*.log 2>/dev/null | head -10 || warn "Aucun log trouvé."
      echo ""
      read -rp "$(echo -e "${YELLOW}  >>> Voir le log (Entrée = dernier, ou nom fichier) : ${NC}")" LOG_CHOICE
      LOG_TO_VIEW="${LOG_CHOICE:-$LOG_LATEST}"
      [ -f "$LOG_TO_VIEW" ] && less "$LOG_TO_VIEW" || warn "Fichier introuvable."
      ;;
    0)
      title "🧹 NETTOYAGE DE L'ÉTAT D'ERREUR"
      _CUR=$(cat "$STATE_FILE" 2>/dev/null || echo "(aucun état)")
      echo -e "  ${BOLD}État actuel :${NC} $_CUR"
      echo ""
      if [ "$_CUR" = "(aucun état)" ] || [ -z "$_CUR" ]; then
        ok "Aucun état d'erreur à effacer."
      else
        echo -e "  ${YELLOW}Vérification rapide des services...${NC}"
        _CL_DOCKER=$(command -v docker &>/dev/null && docker ps &>/dev/null && echo "oui" || echo "non")
        _CL_OLLAMA=$(command -v ollama &>/dev/null && systemctl is-active --quiet ollama 2>/dev/null && echo "oui" || echo "non")
        _CL_WEBUI=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && echo "oui" || echo "non")
        [ "$_CL_DOCKER" = "oui" ] && ok "Docker    : actif" || warn "Docker    : inactif"
        [ "$_CL_OLLAMA" = "oui" ] && ok "Ollama    : actif" || warn "Ollama    : inactif"
        [ "$_CL_WEBUI"  = "oui" ] && ok "Open WebUI : actif" || warn "Open WebUI : inactif"
        echo ""
        confirm "Effacer l'état d'erreur ($_CUR) ?" && {
          rm -f "$STATE_FILE" "$STATE_DIR/errors.log"
          ok "État effacé. Le script démarrera normalement au prochain lancement."
        } || info "Annulé."
      fi
      echo ""
      read -rp "$(echo -e "${DIM}  Appuie sur Entrée pour continuer...${NC}")" _PAUSE
      ;;
    9) hud_stop 2>/dev/null || true; clear; echo -e "${CYAN}Au revoir !${NC}\n"; exit 0 ;;
    *) warn "Choix invalide." ;;
  esac
done