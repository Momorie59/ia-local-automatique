#!/usr/bin/env bash
# Catalogue et sélection des modèles
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 4895-5130)

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
