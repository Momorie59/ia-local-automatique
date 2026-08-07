#!/usr/bin/env bash
# ================================================================
#  lib/os_detect.sh — Détection de la distribution + abstraction
#  des gestionnaires de paquets (apt/dnf/pacman/zypper/xbps/apk/emerge)
#  et des services (systemd/openrc). Utilisé par tous les autres
#  modules qui installent quelque chose.
# ================================================================

#!/usr/bin/env bash
# Détection OS et abstraction du gestionnaire de paquets
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 104-1026)

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
    arch|manjaro|endeavouros|garuda|artix|blackarch|parabola|archcraft|cachyos|arcolinux|archbang|rebornos)
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
      # Détection par fallback sur les gestionnaires disponibles — pour toute
      # distro dérivée non listée explicitement ci-dessus (ex: CachyOS avant
      # qu'on l'ajoute). PKG_QUERY et NVIDIA_DRIVER_METHOD doivent être
      # renseignés ici aussi, sinon les vérifications "paquet déjà installé"
      # et l'installation des drivers GPU échouent silencieusement partout.
      if   command -v apt     &>/dev/null; then
        OS_FAMILY="debian"; PKG_MGR="apt"; PKG_QUERY="dpkg -l"; NVIDIA_DRIVER_METHOD="ubuntu-drivers"
      elif command -v dnf     &>/dev/null; then
        OS_FAMILY="rhel";   PKG_MGR="dnf"; PKG_QUERY="rpm -q"; NVIDIA_DRIVER_METHOD="dnf-rpmfusion"
      elif command -v yum     &>/dev/null; then
        OS_FAMILY="rhel";   PKG_MGR="yum"; PKG_QUERY="rpm -q"; NVIDIA_DRIVER_METHOD="dnf-rpmfusion"
      elif command -v pacman  &>/dev/null; then
        OS_FAMILY="arch";   PKG_MGR="pacman"; PKG_QUERY="pacman -Q"; NVIDIA_DRIVER_METHOD="pacman-nvidia"
        if   command -v yay    &>/dev/null; then AUR_HELPER="yay"
        elif command -v paru   &>/dev/null; then AUR_HELPER="paru"
        elif command -v trizen &>/dev/null; then AUR_HELPER="trizen"
        fi
      elif command -v zypper  &>/dev/null; then
        OS_FAMILY="suse";   PKG_MGR="zypper"; PKG_QUERY="rpm -q"; NVIDIA_DRIVER_METHOD="zypper-nvidia"
      elif command -v xbps-install &>/dev/null; then
        OS_FAMILY="void";   PKG_MGR="xbps-install"; PKG_QUERY="xbps-query"; NVIDIA_DRIVER_METHOD="xbps-nvidia"
      elif command -v apk    &>/dev/null; then
        OS_FAMILY="alpine"; PKG_MGR="apk"; PKG_QUERY="apk info -e"; NVIDIA_DRIVER_METHOD="apk-nvidia"; HAS_SYSTEMD=0
      else
        OS_FAMILY="unknown"; PKG_MGR="unknown"
        warn "Distribution '$OS_DISTRO' non reconnue et aucun gestionnaire de paquets connu détecté."
      fi
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
  local PKG; PKG="$(_pkg_translate "$1")"
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
