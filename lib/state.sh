#!/usr/bin/env bash
# Gestion d'état — reprise après reboot/erreur
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 3955-4202)

#  GESTION D'ÉTAT (reprise après reboot / erreur)
# ================================================================

IA_STATE_FILE="$IA_STATE_DIR/state"
IA_PROGRESS_FILE="$IA_STATE_DIR/progress.json"   # Lu par le dashboard en temps réel
IA_CONFIG_FILE="$IA_STATE_DIR/config.env"

save_state()  { echo "$1" > "$IA_STATE_FILE"; }
load_state()  { [ -f "$IA_STATE_FILE" ] && cat "$IA_STATE_FILE" || echo "START"; }

PLAN_STEP_IDX=0  # index courant dans le plan (pour le trap)

# Sérialisation robuste des tableaux associatifs en fichier sourceable
save_config() {
  {
    echo "# Config sauvegardée $(date)"
    # HW : tableau associatif matériel
    for K in "${!HW[@]}"; do
      printf 'HW[%s]=%q\n' "$K" "${HW[$K]}"
    done
    # CFG : tableau associatif configuration
    for K in "${!CFG[@]}"; do
      printf 'CFG[%s]=%q\n' "$K" "${CFG[$K]}"
    done
    # PLAN : tableau indexé des étapes
    echo "PLAN=($(printf '"%s" ' "${PLAN[@]}"))"
    # PLAN_DESC et PLAN_REBOOT
    for K in "${!PLAN_DESC[@]}"; do
      printf 'PLAN_DESC[%s]=%q\n' "$K" "${PLAN_DESC[$K]}"
    done
    for K in "${!PLAN_REBOOT[@]}"; do
      printf 'PLAN_REBOOT[%s]=%q\n' "$K" "${PLAN_REBOOT[$K]}"
    done
  } > "$IA_CONFIG_FILE"
}

load_config() {
  # Initialiser les tableaux avant de sourcer
  declare -gA HW=() CFG=() PLAN_DESC=() PLAN_REBOOT=()
  declare -ga PLAN=()
  [ -f "$IA_CONFIG_FILE" ] && source "$IA_CONFIG_FILE" || true
}

# Enregistrement d'un reboot avec reprise
reboot_and_resume() {
  local NEXT="$1"
  local REASON="${2:-Reboot requis}"

  save_state "RESUME:$NEXT"
  save_config

  cat > /etc/systemd/system/ia-installer-resume.service << EOF
[Unit]
Description=Reprise Installateur Momory - IA Local
After=network-online.target multi-user.target
Wants=network-online.target
ConditionPathExists=$IA_STATE_FILE

[Service]
Type=oneshot
ExecStart=/bin/bash "$SCRIPT_PATH"
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ia-installer-resume.service

  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  🔄  REBOOT PROGRAMMÉ                                    ║${NC}"
  echo -e "${YELLOW}║  Raison  : $REASON$(printf '%*s' $((44 - ${#REASON})) '')║${NC}"
  echo -e "${YELLOW}║  Reprise : Phase $NEXT$(printf '%*s' $((43 - ${#NEXT})) '')║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  sleep 4
  reboot
}

cleanup_resume() {
  systemctl disable ia-installer-resume.service 2>/dev/null || true
  rm -f /etc/systemd/system/ia-installer-resume.service
  systemctl daemon-reload
  rm -f "$IA_STATE_FILE"
}

# ── Fonction centrale : lancement Open WebUI ─────────────────────
# Respecte EXACTEMENT la commande de référence de l'utilisateur :
# docker run -d --network=host -v /mnt/.../open-webui:/app/backend/data
#   -e OLLAMA_BASE_URL=http://127.0.0.1:11434
#   --name open-webui --restart always ghcr.io/open-webui/open-webui:main
_docker_run_webui() {
  local IMG="${1:-${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}}"
  # Validation format image Docker : doit correspondre à registry/image:tag
  if ! echo "$IMG" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._/:-]{5,150}$'; then
    warn "Format d'image Docker invalide : '$IMG' — utilisation de l'image par défaut."
    IMG="ghcr.io/open-webui/open-webui:main"
  fi
  local DATA_DIR="${2:-${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}}"
  local PORT="${3:-${CFG[webui_port]:-8080}}"
  local NET_MODE="${4:-${CFG[docker_network]:-host}}"
  local OLLAMA_URL="http://127.0.0.1:11434"

  # Arrêter et supprimer l'ancien container si existant
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    info "Arrêt du container open-webui existant..."
    docker stop open-webui 2>/dev/null || true
    docker rm   open-webui 2>/dev/null || true
  fi

  # Vérifier que le dossier data existe
  mkdir -p "$DATA_DIR"
  chown -R "$REAL_USER:$REAL_USER" "$DATA_DIR" 2>/dev/null || true

  info "Image     : $IMG"
  info "Data      : $DATA_DIR"
  info "Réseau    : $NET_MODE"
  info "Ollama URL: $OLLAMA_URL"

      # Construire la commande selon le mode réseau
      if [ "$NET_MODE" = "host" ]; then
        # Mode host : PAS de -p (incompatible avec --network=host sous Docker)
        docker run -d \
          --network=host \
          -v "${DATA_DIR}:/app/backend/data" \
          -e OLLAMA_BASE_URL="$OLLAMA_URL" \
          -e PORT="${PORT}" \
          --name open-webui \
          --restart unless-stopped \
          "$IMG"
      else
    # Mode bridge : port mapping + add-host pour atteindre Ollama sur l'hôte
    docker run -d \
      -p "${PORT}:8080" \
      --add-host=host.docker.internal:host-gateway \
      -v "${DATA_DIR}:/app/backend/data" \
      -e OLLAMA_BASE_URL="$OLLAMA_URL" \
      --name open-webui \
      --restart unless-stopped \
      "$IMG"
  fi

  local EXIT_CODE=$?
  if [ "$EXIT_CODE" -ne 0 ]; then
    warn "docker run a retourné le code $EXIT_CODE"
    warn "Vérifie : docker logs open-webui"
    return 1
  fi

  # Attendre que le container démarre
  local WAIT=0
  while [ "$WAIT" -lt 15 ]; do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && break
    sleep 1; WAIT=$(( WAIT + 1 ))
  done

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    if [ "$NET_MODE" = "host" ]; then
      log "Open WebUI actif → http://localhost:8080"
    else
      log "Open WebUI actif → http://localhost:$PORT"
    fi
    return 0
  else
    warn "Open WebUI ne semble pas démarré."
    warn "Diagnostic : docker logs open-webui"
    docker logs --tail 20 open-webui 2>/dev/null || true
    return 1
  fi
}


# ── Service systemd pour Open WebUI ──────────────────────────────────────
# Garantit l'ordre de démarrage : Docker → Ollama (prêt) → WebUI
# Remplace le simple "--restart always" qui ne connaît pas Ollama
_install_webui_service() {
  local PORT="${1:-${CFG[webui_port]:-8080}}"
  local DATA_DIR="${2:-${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}}"
  local IMG="${3:-${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}}"
  local NET_MODE="${4:-${CFG[docker_network]:-host}}"
  local OLLAMA_URL="http://127.0.0.1:11434"

  [ "$HAS_SYSTEMD" -ne 1 ] && return 0  # Pas systemd → le --restart gère

  cat > /etc/systemd/system/open-webui.service << WUEOF
[Unit]
Description=Open WebUI — Interface IA locale
Documentation=https://github.com/open-webui/open-webui
# Attendre que Docker ET Ollama soient actifs
After=docker.service ollama.service network-online.target
Requires=docker.service
Wants=ollama.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Attendre qu'Ollama soit réellement prêt (API qui répond) avant de lancer WebUI
# Timeout 120s pour les machines lentes qui chargent un modèle au démarrage
ExecStartPre=/bin/bash -c '  echo "[open-webui] Attente Ollama...";   i=0;   while [ \$i -lt 60 ]; do     curl -sf --max-time 2 http://127.0.0.1:11434/api/tags > /dev/null 2>&1 && break;     sleep 2; i=\$((i+1));   done;   if [ \$i -ge 60 ]; then     echo "[open-webui] WARN: Ollama non prêt après 120s, démarrage WebUI quand même";   else     echo "[open-webui] Ollama prêt après \$((i*2))s";   fi'

# Démarrer le container (le créer s'il n'existe pas, sinon le démarrer)
ExecStart=/bin/bash -c '  if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^open-webui\$"; then     docker start open-webui;   else     echo "[open-webui] Container absent — création impossible au boot, voir install";     exit 1;   fi'

ExecStop=/usr/bin/docker stop open-webui

# Redémarrer si Docker redémarre ou si Ollama redémarre
ExecStartPost=/bin/bash -c '  sleep 5;   if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^open-webui\$"; then     echo "[open-webui] Container démarré avec succès";   else     echo "[open-webui] WARN: Container non présent dans docker ps après démarrage";   fi'

Restart=on-failure
RestartSec=10
TimeoutStartSec=150

[Install]
WantedBy=multi-user.target
WUEOF

  svc_daemon_reload
  systemctl enable open-webui.service
  ok "Service systemd open-webui.service créé et activé au boot"
  ok "Ordre garanti : Docker → Ollama (API prête) → Open WebUI"
}

# ── Sauvegarde données WebUI avant MAJ ───────────────────────────
_backup_webui_before_update() {
  local DATA_DIR="${1:-${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}}"
  local BACKUP_DIR="${CFG[backup_dir]:-$(dirname "$DATA_DIR")/backups}"
  local STAMP; STAMP=$(date +%Y%m%d_%H%M%S)
  local BACKUP_PATH="$BACKUP_DIR/webui_pre_update_$STAMP"

  mkdir -p "$BACKUP_DIR"
  if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    info "Sauvegarde des données WebUI avant MAJ..."
    cp -r "$DATA_DIR" "$BACKUP_PATH" &&       ok "Backup créé : $BACKUP_PATH ($(du -sh "$BACKUP_PATH" | cut -f1))" ||       warn "Backup échoué — MAJ continue quand même."
    echo "$BACKUP_PATH" > "$IA_STATE_DIR/last_webui_backup"
  else
    info "Dossier WebUI vide ou inexistant — pas de backup nécessaire."
  fi
}



# ================================================================
