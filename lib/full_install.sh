#!/usr/bin/env bash
# Installation complète
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 5962-6069)

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

    # ── Config prête à l'emploi pour Momory CLI (sur une autre machine) ──
    step "Connecter Momory CLI (momory config --setup)"
    local _LAN_IP
    _LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
    local _MODELS_LIST; _MODELS_LIST=$(ollama list 2>/dev/null | awk 'NR>1{print $1}')
    local _CHAT_MODEL; _CHAT_MODEL=$(echo "$_MODELS_LIST" | grep -im1 'llama\|mistral\|gemma' || echo "$_MODELS_LIST" | head -1)
    local _CODER_MODEL; _CODER_MODEL=$(echo "$_MODELS_LIST" | grep -im1 'coder\|code' || echo "$_CHAT_MODEL")
    echo -e "  ${CYAN}Adresse${NC}  : ${_LAN_IP:-?}"
    echo -e "  ${CYAN}Port${NC}     : 11434"
    echo -e "  ${CYAN}Chat${NC}     : ${_CHAT_MODEL:-aucun modèle trouvé}"
    echo -e "  ${CYAN}Coder${NC}    : ${_CODER_MODEL:-aucun modèle trouvé}"
    if [ -n "${CFG[qdrant_port]:-}" ]; then
      echo -e "  ${CYAN}Qdrant${NC}   : ${_LAN_IP:-?}:${CFG[qdrant_port]}"
    fi
    echo -e "  ${DIM}→ Ces valeurs sont aussi visibles dans le dashboard web, onglet Accès & Notes.${NC}"
  fi
}

# ================================================================
