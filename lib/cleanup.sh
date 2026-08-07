#!/usr/bin/env bash
# Nettoyage complet (clean install)
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 6832-6966)

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
  echo -e "  ${RED}✗${NC}  État de l'installateur ($IA_STATE_DIR)"
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
  rm -f "$IA_CREDS_FILE"
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
  _safe_rm "$IA_STATE_DIR"
  mkdir -p "$IA_STATE_DIR"
  # Rafraîchir la liste des paquets après suppression des dépôts
  pkg_update 2>/dev/null || true

  ok "Nettoyage terminé. Le système est prêt pour une installation fraîche."
  info "Lance : sudo bash $SCRIPT_PATH"
}

# ================================================================
