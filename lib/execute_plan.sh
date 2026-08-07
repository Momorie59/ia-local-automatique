#!/usr/bin/env bash
# Exécution des étapes du plan
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 5131-5872)

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
      # Le chown ci-dessus écrase TOUT le disque monté (pratique pour que
      # $REAL_USER gère backups/webui sans sudo) — mais ça casse le dossier
      # des modèles Ollama, qui doit rester à l'utilisateur système "ollama"
      # (sinon le service ne peut plus y écrire au prochain démarrage).
      # On le rétablit systématiquement ici, que ce DISK_SETUP tourne seul
      # (réinstallation partielle) ou dans une install complète.
      if id ollama &>/dev/null; then
        chown -R ollama:ollama "${CFG[ollama_dir]}"
        chmod 755 "${CFG[hdd_mount]}" "${CFG[ollama_dir]}" 2>/dev/null || true
      fi
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
      cd "$LLAMA_BUILD" || { warn "Impossible d'accéder à $LLAMA_BUILD"; return 1; }

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
      cd - > /dev/null || true
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
      progress_docker_pull "$LA_IMAGE"

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
      progress_docker_pull "vllm/vllm-openai:latest"

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
    QDRANT)
      title "QDRANT — BASE VECTORIELLE (MÉMOIRE IA)"
      CURRENT_STEP="QDRANT"

      local QDRANT_DIR="${CFG[qdrant_dir]:-${CFG[hdd_mount]:-/mnt/ia}/qdrant}"
      local QDRANT_PORT="${CFG[qdrant_port]:-$QDRANT_PORT_DEFAULT}"
      mkdir -p "$QDRANT_DIR/storage"

      svc_active docker || svc_start docker
      sleep 1

      info "Téléchargement de l'image Qdrant..."
      progress_docker_pull "$QDRANT_IMAGE"

      docker stop qdrant 2>/dev/null || true
      docker rm -f qdrant 2>/dev/null || true

      docker run -d \
        --name qdrant \
        --restart unless-stopped \
        -p "${QDRANT_PORT}:6333" \
        -p "${QDRANT_GRPC_PORT_DEFAULT}:6334" \
        -v "${QDRANT_DIR}/storage:/qdrant/storage" \
        "$QDRANT_IMAGE"

      sleep 2
      if docker ps --format '{{.Names}}' | grep -qx qdrant; then
        ok "Qdrant démarré — API sur le port ${QDRANT_PORT} (données : ${QDRANT_DIR})"
      else
        warn "Qdrant ne semble pas avoir démarré — vérifie : docker logs qdrant"
      fi
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
