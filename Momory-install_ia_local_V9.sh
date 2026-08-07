#!/usr/bin/env bash
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
#  INSTALLATEUR IA LOCAL — INTELLIGENT & ADAPTATIF v9.0
#  Analyse complète du matériel → Plan d'installation optimal
#  Compatible : Ubuntu, Pop!_OS, Debian, Fedora, Arch, openSUSE,
#               Void, Alpine — toute distro Linux x86_64/arm64
#  GPU        : NVIDIA (CUDA) / AMD (ROCm) / Intel Arc / CPU
#  Usage      : sudo bash install_ia_local.sh
#  Reprise    : automatique après erreur ou reboot (systemd/openrc)
#  Docker     : --network=host + OLLAMA_BASE_URL (référence)
# ================================================================
#
#  ⚠  EN CAS DE PERTE DE DONNÉES APRÈS UNE MAJ OPEN WEBUI :
#  Le chemin des données est celui choisi lors de l'installation
#  (voir /var/lib/ia-installer/config.env, clé webui_dir).
#  Pour relancer avec la bonne commande :
#    sudo bash install_ia_local.sh  → [Option 7] Réparer WebUI
# ================================================================

# ── Chargement des modules (l'ordre reflète les dépendances) ────
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

source "$LIB_DIR/common.sh"        # logging, couleurs, config, privilèges
load_settings                        # config/defaults.conf + config.env utilisateur
check_privileges                   # exige root, résout REAL_USER/REAL_HOME

source "$LIB_DIR/os_detect.sh"     # detect_os, pkg_*, svc_*
detect_os

SCRIPT_PATH="$(realpath "$0")"
ensure_script_symlink "$SCRIPT_PATH"
init_state_and_logging

source "$LIB_DIR/gpu_drivers.sh"        # drivers NVIDIA/ROCm, Docker, Ollama sécurisé
source "$LIB_DIR/dashboard.sh"          # déploiement web/ + service systemd dashboard
source "$LIB_DIR/hud.sh"                # panneau HUD terminal (stats temps réel)
source "$LIB_DIR/state.sh"              # reprise après reboot/erreur
source "$LIB_DIR/hardware_analysis.sh"  # analyse matériel (GPU/RAM/VRAM)
source "$LIB_DIR/backend_choice.sh"     # choix du backend d'inférence
source "$LIB_DIR/plan.sh"               # bilan et plan d'installation
source "$LIB_DIR/models_catalog.sh"     # catalogue et sélection des modèles
source "$LIB_DIR/execute_plan.sh"       # exécution des étapes du plan
source "$LIB_DIR/interactive_config.sh" # configuration interactive
source "$LIB_DIR/full_install.sh"       # installation complète (orchestration)
source "$LIB_DIR/menus.sh"              # menus secondaires
source "$LIB_DIR/update.sh"             # vérification et mise à jour
source "$LIB_DIR/cleanup.sh"            # nettoyage complet
source "$LIB_DIR/repair_webui.sh"       # réparation rapide Open WebUI

#  POINT D'ENTRÉE
# ================================================================

CURRENT_STATE=$(load_state)

# ── Validation de l'état chargé (anti-falsification du fichier state) ────────
# Le fichier state ne doit contenir que des valeurs attendues : START, EXEC:N,
# RESUME:N, ERROR:*, ou être vide. Toute autre valeur est ignorée.
if [[ -n "$CURRENT_STATE" ]] &&    ! [[ "$CURRENT_STATE" =~ ^(START|EXEC:[0-9]+|RESUME:[A-Z0-9_:]+|ERROR:[A-Z0-9_:]+)$ ]]; then
  warn "Fichier state corrompu ou falsifié ('$CURRENT_STATE') — réinitialisation."
  rm -f "$IA_STATE_FILE"
  CURRENT_STATE="START"
fi

# ── CAS 1 : Reprise après reboot ──────────────────────────────
if [[ "$CURRENT_STATE" == RESUME:* ]]; then
  RESUME_AT="${CURRENT_STATE#RESUME:}"
  load_config
  title "REPRISE APRÈS REBOOT → $RESUME_AT"
  log "Configuration rechargée depuis $IA_CONFIG_FILE"
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
  echo -e "  Log d'erreurs : $IA_STATE_DIR/errors.log"
  [ -f "$IA_STATE_DIR/errors.log" ] && tail -5 "$IA_STATE_DIR/errors.log" | sed 's/^/  /'
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
        rm -f "$IA_STATE_FILE" "$IA_STATE_DIR/errors.log"
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
if [ -f "$IA_CONFIG_FILE" ] && [ -s "$IA_CONFIG_FILE" ]; then
  load_config

  title "INSTALLATION PRÉCÉDENTE DÉTECTÉE"

  # ── Lire le contexte réel du système ──────────────────────────
  # Date d'installation
  PREV_DATE=$(stat -c "%y" "$IA_CONFIG_FILE" 2>/dev/null | cut -d. -f1 || echo "?")

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
      LAST_EXEC=$(cat "$IA_STATE_FILE" 2>/dev/null || echo "EXEC:0")
      [ "${#PLAN[@]}" -eq 0 ] && build_install_plan
      run_full_install "$LAST_EXEC"
      exit 0 ;;
    5)
      clean_install
      ;; # Continue vers le menu
  esac
fi


# ================================================================
