#!/usr/bin/env bash
# Menus secondaires
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 6070-6294)

#  MENUS SECONDAIRES
# ================================================================

menu_models() {
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  title "GESTION DES MODÈLES IA"

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
  load_config   # déclare HW/CFG/PLAN/PLAN_DESC/PLAN_REBOOT avant de sourcer
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
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  title "RÉINSTALLATION COMPOSANT"
  analyse_hardware
  echo -e "  ${GREEN}[1]${NC} Drivers GPU"
  echo -e "  ${GREEN}[2]${NC} Docker + Runtime GPU"
  echo -e "  ${GREEN}[3]${NC} Ollama"
  echo -e "  ${GREEN}[4]${NC} Open WebUI"
  echo -e "  ${GREEN}[5]${NC} Dashboard + Administration web (réinstaller)"
  echo -e "  ${GREEN}[6]${NC} Qdrant (mémoire IA)"
  read -rp "$(echo -e "${YELLOW}  >>> : ${NC}")" C
  load_config   # déclare HW/CFG/PLAN/PLAN_DESC/PLAN_REBOOT avant de sourcer
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
    6) [ -z "${CFG[qdrant_dir]:-}" ] && CFG[qdrant_dir]="${CFG[hdd_mount]:-/mnt/ia}/qdrant"
       execute_step "QDRANT" ;;
  esac
}

# ================================================================
