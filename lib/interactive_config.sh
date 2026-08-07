#!/usr/bin/env bash
# Configuration interactive
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 5873-5961)

#  SECTION 5 : CONFIGURATION INTERACTIVE
# ================================================================

configure_infra() {
  title "CONFIGURATION DE L'INFRASTRUCTURE"
  declare -gA CFG=()

  echo -e "${CYAN}  Appuie sur Entrée pour les valeurs détectées par défaut.\n${NC}"

  # Disques
  echo -e "${BOLD}=== DISQUES DISPONIBLES ===${NC}\n"
  printf "  ${BOLD}%-4s %-12s %-8s %-6s %s${NC}\n" "N°" "Disque" "Taille" "Type" "Modèle"
  hr
  local i=1
  for D in "${DISKS[@]}"; do
    local TYPE="${DISK_TYPE[$D]:-?}"
    local HEALTH="${DISK_HEALTH[$D]:-?}"
    local HEALTH_COL="$GREEN"
    [ "$HEALTH" = "FAILED" ] && HEALTH_COL="$RED"
    [ "$HEALTH" = "?" ] && HEALTH_COL="$YELLOW"
    printf "  ${GREEN}[%d]${NC} %-12s %-8s %-6s %s ${HEALTH_COL}[SMART:%s]${NC}\n" \
      "$i" "$D" "${DISK_SIZE[$D]:-?}" "$TYPE" "${DISK_MODEL[$D]:0:20}" "$HEALTH"
    i=$(( i + 1 ))
  done
  echo ""
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | grep -v loop | head -25
  echo ""

  # Détection défauts intelligents
  local DEF_OS="${DISKS[0]:-/dev/sda}"
  local DEF_STORE="${DISKS[1]:-${DISKS[0]:-/dev/sda}}"
  local DEF_BASE; DEF_BASE=$(basename "$DEF_STORE")
  local DEF_MOUNT="/mnt/ia_${DEF_BASE}"
  local DEF_LABEL; DEF_LABEL="IA_$(echo "$DEF_BASE" | tr '[:lower:]' '[:upper:]')"

  read -rp "$(echo -e "${YELLOW}  [1/6] Disque OS            (Entrée = $DEF_OS)    : ${NC}")" TMP
  CFG[os_dev]="${TMP:-$DEF_OS}"

  read -rp "$(echo -e "${YELLOW}  [2/6] Disque stockage IA   (Entrée = $DEF_STORE) : ${NC}")" TMP
  CFG[hdd_dev]="${TMP:-$DEF_STORE}"
  [ -b "${CFG[hdd_dev]}" ] || warn "Disque ${CFG[hdd_dev]} introuvable."
  [ "${CFG[hdd_dev]}" = "${CFG[os_dev]}" ] && warn "Même disque pour OS et stockage IA."

  DEF_BASE=$(basename "${CFG[hdd_dev]}")
  DEF_MOUNT="/mnt/ia_${DEF_BASE}"
  DEF_LABEL="IA_$(echo "$DEF_BASE" | tr '[:lower:]' '[:upper:]')"

  read -rp "$(echo -e "${YELLOW}  [3/6] Point de montage     (Entrée = $DEF_MOUNT) : ${NC}")" TMP
  CFG[hdd_mount]="${TMP:-$DEF_MOUNT}"

  read -rp "$(echo -e "${YELLOW}  [3/6] Label disque         (Entrée = $DEF_LABEL) : ${NC}")" TMP
  CFG[hdd_label]="${TMP:-$DEF_LABEL}"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier modèles      (Entrée = ${CFG[hdd_mount]}/ollama_models) : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/ollama_models}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/ollama_models"
  CFG[ollama_dir]="$TMP"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier Open WebUI   (Entrée = ${CFG[hdd_mount]}/open-webui)    : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/open-webui}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/open-webui"
  CFG[webui_dir]="$TMP"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier backups      (Entrée = ${CFG[hdd_mount]}/backups)       : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/backups}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/backups"
  CFG[backup_dir]="$TMP"

  read -rp "$(echo -e "${YELLOW}  [4/6] Dossier Qdrant       (Entrée = ${CFG[hdd_mount]}/qdrant)        : ${NC}")" TMP
  TMP="${TMP:-${CFG[hdd_mount]}/qdrant}"
  _validate_data_path "$TMP" || TMP="${CFG[hdd_mount]}/qdrant"
  CFG[qdrant_dir]="$TMP"

  _ask_port "[5/6] Port Open WebUI" "8080" _WEBUI_PORT_TMP
  CFG[webui_port]="$_WEBUI_PORT_TMP"
  _ask_port "[5/6] Port Qdrant (API)" "${QDRANT_PORT_DEFAULT:-6333}" _QDRANT_PORT_TMP
  CFG[qdrant_port]="$_QDRANT_PORT_TMP"
  # Stocker l'image Docker dans la config (pour la retrouver lors des MAJ)
  CFG[docker_image]="${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}"

  # Mode réseau Docker — host est recommandé pour communiquer avec Ollama local
  echo ""
  echo -e "  ${DIM}Mode réseau Docker :${NC}"
  echo -e "    ${GREEN}[1]${NC}  --network=host  (recommandé — connexion directe à Ollama)  ← défaut"
  echo -e "    ${GREEN}[2]${NC}  -p PORT:8080    (bridge — si conflit de port)"
  read -rp "$(echo -e "${YELLOW}  [5b/6] Mode réseau         (Entrée = 1) : ${NC}")" NET_CHOICE
  case "${NET_CHOICE:-1}" in
    2)  CFG[docker_network]="bridge" ;;
    *)  CFG[docker_network]="host" ;;
  esac

  echo ""
  echo -e "${DIM}  [6/6] Sélection des modèles → après analyse matérielle${NC}"
}

# ================================================================
