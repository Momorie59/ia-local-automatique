#!/usr/bin/env bash
# Choix du backend d'inférence IA
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 4542-4669)

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
