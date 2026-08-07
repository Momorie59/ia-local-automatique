#!/usr/bin/env bash
# ================================================================
#  lib/gpu_drivers.sh — Installation des drivers GPU (NVIDIA/ROCm),
#  de Docker, du NVIDIA Container Toolkit, et téléchargement sécurisé
#  du script Ollama (vérification SHA256 contre GitHub).
#  Dépend de lib/os_detect.sh (detect_os, pkg_*, svc_*) et de
#  lib/common.sh (confirm, log/warn/step...).
# ================================================================


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
