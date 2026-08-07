#!/usr/bin/env bash
# Bilan et plan d'installation
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 4670-4894)

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

  # Étape 11b : Qdrant (base vectorielle — mémoire longue durée pour assistants type Momory)
  # Optionnel : pas tout le monde n'en a besoin, donc on demande plutôt que d'imposer.
  echo ""
  if confirm "Installer Qdrant (base vectorielle pour la mémoire IA — RAG, assistants type Momory) ?"; then
    PLAN+=("QDRANT")
    PLAN_DESC["QDRANT"]="Qdrant — base vectorielle (mémoire longue durée)"
    PLAN_REBOOT["QDRANT"]="non"
  fi

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
