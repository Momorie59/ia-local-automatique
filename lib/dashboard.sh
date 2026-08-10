#!/usr/bin/env bash
# Dashboard web — déploiement des fichiers web/ + service systemd
# (Module généré depuis install_ia_local_V8.sh ; le contenu Python/HTML/CSS/JS
#  a été extrait dans web/dashboard_server.py et web/static/*)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_dashboard_script() {
  mkdir -p "$(dirname "$DASHBOARD_SCRIPT")" /usr/local/share/ia-installer/web/static \
           /usr/local/share/ia-installer/web/downloads
  cp "$REPO_ROOT/web/dashboard_server.py" "$DASHBOARD_SCRIPT"
  cp -r "$REPO_ROOT/web/static/"* /usr/local/share/ia-installer/web/static/
  chmod 700 "$DASHBOARD_SCRIPT"   # Lecture root uniquement (contient la logique admin)

  # ── Rendre momory-cli téléchargeable directement depuis le dashboard ──
  if [ -d "$REPO_ROOT/momory-cli" ]; then
    python3 -c "
import shutil
shutil.make_archive('/usr/local/share/ia-installer/web/downloads/momory-cli', 'zip', '$REPO_ROOT', 'momory-cli')
" 2>/dev/null && ok "momory-cli prêt au téléchargement (http://<IP>:${DASHBOARD_PORT_DEFAULT}/download/momory-cli.zip)" \
      || warn "Impossible de préparer le zip momory-cli (source absente ou erreur)."
  fi

  # Mettre à jour le lien symbolique et le chemin sauvegardé
  ensure_script_symlink "$SCRIPT_PATH"
  ok "Dashboard Python installé : $DASHBOARD_SCRIPT"
}

# Créer et activer le service systemd du dashboard
install_dashboard_service() {
  local _PORT="${DASHBOARD_PORT:-7842}"
  # BIND toujours 0.0.0.0 : le dashboard doit être accessible depuis le LAN
  # même avant que la config soit chargée
  local _BIND="0.0.0.0"

  cat > /etc/systemd/system/ia-dashboard.service << SVCEOF
[Unit]
Description=Momory - IA Local — Dashboard système temps réel
After=network.target
# Pas de dépendance à ollama/docker : le dashboard démarre avant l'installation

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${DASHBOARD_SCRIPT}
Environment="DASHBOARD_PORT=${_PORT}"
Environment="DASHBOARD_BIND=${_BIND}"
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  svc_daemon_reload
  svc_enable  "$DASHBOARD_SERVICE"
  svc_restart "$DASHBOARD_SERVICE"
  sleep 2
}

# Récupérer l'IP LAN pour affichage
_dashboard_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+'     || hostname -I 2>/dev/null | awk '{print $1}'
}

# Menu de gestion du dashboard
menu_dashboard() {
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  while true; do
    title "DASHBOARD WEB — STATS TEMPS RÉEL"

    local _PORT="${DASHBOARD_PORT:-7842}"
    local _LIP; _LIP=$(_dashboard_lan_ip)
    local _ACTIVE=0
    svc_active "$DASHBOARD_SERVICE" 2>/dev/null && _ACTIVE=1

    # ── Statut ──────────────────────────────────────────────────
    step "Statut du dashboard"
    if [ "$_ACTIVE" -eq 1 ]; then
      ok  "Dashboard : ${GREEN}actif${NC}"
      echo -e ""
      echo -e "  ${BOLD}Accès local  :${NC}  ${CYAN}http://127.0.0.1:${_PORT}${NC}"
      [ -n "$_LIP" ] &&       echo -e "  ${BOLD}Accès réseau :${NC}  ${CYAN}http://${_LIP}:${_PORT}${NC}"
      echo ""
      # Test rapide de connectivité
      if curl -sf --max-time 2 "http://127.0.0.1:${_PORT}/api/stats" &>/dev/null; then
        ok "API /api/stats répond correctement"
      else
        warn "Le service est actif mais ne répond pas encore (démarrage en cours ?)"
      fi
    else
      nok "Dashboard : ${RED}arrêté${NC}"
      echo ""
    fi

    # ── Menu ────────────────────────────────────────────────────
    echo -e "${BOLD}  ── Actions ────────────────────────────────────────────${NC}"
    if [ "$_ACTIVE" -eq 1 ]; then
      echo -e "  ${CYAN}[1]${NC}  Ouvrir dans le navigateur ${DIM}(si dispo)${NC}"
      echo -e "  ${CYAN}[2]${NC}  ${RED}Arrêter${NC} le dashboard"
      echo -e "  ${CYAN}[3]${NC}  ${YELLOW}Redémarrer${NC} le dashboard"
    else
      echo -e "  ${CYAN}[1]${NC}  ${GREEN}Démarrer${NC} le dashboard"
      echo -e "  ${CYAN}[2]${NC}  Installer / Réinstaller le dashboard"
    fi
    echo -e "  ${CYAN}[4]${NC}  Voir les logs du dashboard"
    echo -e "  ${CYAN}[5]${NC}  Changer le port ${DIM}(actuel: ${_PORT})${NC}"
    echo -e "  ${CYAN}[q]${NC}  Retour au menu principal"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Action : ${NC}")" _DCHOICE

    case "${_DCHOICE:-}" in

      1)
        if [ "$_ACTIVE" -eq 1 ]; then
          # Ouvrir dans le navigateur
          local _URL="http://127.0.0.1:${_PORT}"
          if command -v xdg-open &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            xdg-open "$_URL" &>/dev/null &
            ok "Navigateur ouvert → ${CYAN}${_URL}${NC}"
          else
            info "Ouvre manuellement : ${CYAN}${_URL}${NC}"
          fi
        else
          step "Démarrage du dashboard..."
          # Installer le script si absent
          if [ ! -f "$DASHBOARD_SCRIPT" ]; then
            install_dashboard_script
          fi
          # Créer le service si absent
          if [ ! -f "/etc/systemd/system/ia-dashboard.service" ]; then
            install_dashboard_service
          else
            svc_restart "$DASHBOARD_SERVICE"
          fi
          sleep 2
          if svc_active "$DASHBOARD_SERVICE" 2>/dev/null; then
            ok "Dashboard démarré → ${CYAN}http://127.0.0.1:${_PORT}${NC}"
            [ -n "$_LIP" ] && ok "Réseau LAN    → ${CYAN}http://${_LIP}:${_PORT}${NC}"
          else
            warn "Échec démarrage. Lance : journalctl -u ia-dashboard -n 30"
          fi
        fi
        sleep 2
        ;;

      2)
        if [ "$_ACTIVE" -eq 1 ]; then
          step "Arrêt du dashboard..."
          svc_stop "$DASHBOARD_SERVICE" && ok "Dashboard arrêté." || warn "Échec."
          sleep 1
        else
          step "Installation / Réinstallation du dashboard..."
          install_dashboard_script
          install_dashboard_service
          sleep 2
          svc_active "$DASHBOARD_SERVICE"             && ok "Dashboard installé et démarré → ${CYAN}http://127.0.0.1:${_PORT}${NC}"             || warn "Voir les logs : journalctl -u ia-dashboard -n 30"
        fi
        sleep 2
        ;;

      3)
        if [ "$_ACTIVE" -eq 1 ]; then
          step "Redémarrage du dashboard..."
          svc_restart "$DASHBOARD_SERVICE" && ok "Redémarré." || warn "Échec."
          sleep 2
        fi
        ;;

      4)
        echo ""
        journalctl -u "$DASHBOARD_SERVICE" -n 40 --no-pager 2>/dev/null           || warn "journalctl non disponible"
        echo ""
        read -rp "$(echo -e "${DIM}  Appuie sur Entrée pour continuer...${NC}")" _P
        ;;

      5)
        echo ""
        _ask_port "Nouveau port (actuel: ${_PORT})" "$_PORT" _NEWPORT
        DASHBOARD_PORT="$_NEWPORT"
        sed -i "s/DASHBOARD_PORT=[0-9]*/DASHBOARD_PORT=${_NEWPORT}/"           /etc/systemd/system/ia-dashboard.service 2>/dev/null || true
        svc_daemon_reload; svc_restart "$DASHBOARD_SERVICE"
        ok "Port changé → ${_NEWPORT}. Dashboard redémarré."
        sleep 2
        ;;

      q|Q) break ;;
      *) ;;
    esac
  done
}

# ── Trap de sortie global ─────────────────────────────────────────
_hud_exit_trap() {
  hud_stop
  tput cnorm 2>/dev/null || true    # Restaurer curseur visible
  printf "\033[r" 2>/dev/null || true  # Restaurer scroll region complète
  tput rmcup 2>/dev/null || true    # Restaurer l'écran si altscreen utilisé
}
trap '_hud_exit_trap' EXIT INT TERM PIPE HUP



# ── Barre de progression ─────────────────────────────────────────

# ── Validation d'un numéro de port saisi par l'utilisateur ───────────────────
# Vérifie : numérique, entre 1024 et 65535, pas déjà utilisé par le système

# ── Validation d'un chemin de montage / répertoire donné par l'utilisateur ───
# Bloque les chemins dangereux : /, /boot, /etc, /usr, /var, /sys, etc.

# ── Wrapper sécurisé pour rm -rf ─────────────────────────────────────────────
# Refuse de supprimer /, /boot, /etc et autres chemins système critiques.
# Toujours utiliser _safe_rm à la place de rm -rf dans ce script.
_safe_rm() {
  local TARGET="$1"
  local REAL_TARGET
  REAL_TARGET=$(realpath -m "$TARGET" 2>/dev/null || echo "$TARGET")

  # Refuse si vide
  if [ -z "$REAL_TARGET" ] || [ "$REAL_TARGET" = "/" ]; then
    warn "_safe_rm : cible vide ou racine refusée ('$TARGET')"
    return 1
  fi

  # Refuse les chemins système
  for _SAFE_D in / /boot /etc /usr /var /sys /proc /dev /run /root /bin /sbin /lib /lib64 /home; do
    if [ "$REAL_TARGET" = "$_SAFE_D" ]; then
      warn "_safe_rm : chemin système protégé refusé ('$TARGET')"
      return 1
    fi
  done

  # Refuse les chemins trop courts (moins de 8 caractères pour éviter /tmp/x)
  if [ ${#REAL_TARGET} -lt 8 ] && [ -d "$REAL_TARGET" ]; then
    warn "_safe_rm : chemin suspect trop court refusé ('$TARGET')"
    return 1
  fi

  rm -rf "$TARGET"
}

_validate_data_path() {
  local PATH_VAL="$1"
  local DANGEROUS="/|/boot|/etc|/usr|/var|/sys|/proc|/dev|/run|/tmp|/root|/bin|/sbin|/lib"

  # Chemin non vide
  if [ -z "$PATH_VAL" ]; then
    warn "Chemin vide non autorisé."
    return 1
  fi

  # Chemin absolu obligatoire
  if [[ "$PATH_VAL" != /* ]]; then
    warn "Chemin relatif non autorisé : '$PATH_VAL' (doit commencer par /)"
    return 1
  fi

  # Blocage des répertoires système critiques
  local _CLEAN; _CLEAN=$(realpath -m "$PATH_VAL" 2>/dev/null || echo "$PATH_VAL")
  for _D in / /boot /etc /usr /var /sys /proc /dev /run /tmp /root /bin /sbin /lib /lib64; do
    if [ "$_CLEAN" = "$_D" ] || [[ "$_CLEAN" == "$_D/"* && ${#_CLEAN} -le $(( ${#_D} + 3 )) ]]; then
      warn "Chemin système protégé non autorisé : '$PATH_VAL'"
      return 1
    fi
  done

  # Refus des path traversal
  if echo "$PATH_VAL" | grep -q '\.\.'; then
    warn "Chemin avec '..' non autorisé : '$PATH_VAL'"
    return 1
  fi

  return 0
}

_validate_port() {
  local PORT_VAL="$1"
  local RESERVED_PORTS="22 25 53 80 443 3306 5432 6379 8443 27017"

  # Vérification numérique
  if ! [[ "$PORT_VAL" =~ ^[0-9]+$ ]]; then
    warn "Port invalide : '$PORT_VAL' n'est pas un nombre."
    return 1
  fi

  # Plage autorisée
  if [ "$PORT_VAL" -lt 1024 ] || [ "$PORT_VAL" -gt 65535 ]; then
    warn "Port hors plage : $PORT_VAL (autorisé : 1024–65535)"
    return 1
  fi

  # Ports réservés / sensibles
  for _RP in $RESERVED_PORTS; do
    if [ "$PORT_VAL" -eq "$_RP" ]; then
      warn "Port $PORT_VAL réservé — choisissez un autre port."
      return 1
    fi
  done

  # Vérifier si le port est déjà utilisé
  if ss -tlnp 2>/dev/null | grep -q ":$PORT_VAL "; then
    warn "Port $PORT_VAL déjà utilisé par un autre processus."
    if ! confirm "Utiliser quand même le port $PORT_VAL ?"; then
      return 1
    fi
  fi

  return 0
}

# Demande un port avec validation et retry
_ask_port() {
  local PROMPT="$1"
  local DEFAULT="$2"
  local RESULT_VAR="$3"
  local ATTEMPTS=0

  while [ $ATTEMPTS -lt 3 ]; do
    read -rp "$(echo -e "${YELLOW}  >>> $PROMPT [${DEFAULT}] : ${NC}")" _PORT_INPUT
    _PORT_INPUT="${_PORT_INPUT:-$DEFAULT}"
    if _validate_port "$_PORT_INPUT"; then
      printf -v "$RESULT_VAR" '%s' "$_PORT_INPUT"
      return 0
    fi
    ATTEMPTS=$(( ATTEMPTS + 1 ))
    [ $ATTEMPTS -lt 3 ] && warn "Réessayez ($ATTEMPTS/3)..."
  done
  warn "Port invalide après 3 tentatives — valeur par défaut utilisée : $DEFAULT"
  printf -v "$RESULT_VAR" '%s' "$DEFAULT"
  return 0
}

PROGRESS_TOTAL=0
PROGRESS_CURRENT=0
PROGRESS_LABEL=""
# Progression fine à l'intérieur de l'étape en cours (téléchargement modèle/image) ;
# vide/0 quand aucun téléchargement n'est en cours — le frontend masque alors la ligne.
PROGRESS_SUBSTEP_LABEL=""
PROGRESS_SUBSTEP_PCT=0

progress_init() {
  PROGRESS_TOTAL="${1:-10}"
  PROGRESS_CURRENT=0
  PROGRESS_LABEL="${2:-Installation}"
  progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
}

progress_step() {
  PROGRESS_CURRENT=$(( PROGRESS_CURRENT + 1 ))
  PROGRESS_LABEL="${1:-$PROGRESS_LABEL}"
  local PCT=$(( PROGRESS_CURRENT * 100 / PROGRESS_TOTAL ))
  progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
  local FILLED=$(( PCT * 40 / 100 ))
  local EMPTY=$(( 40 - FILLED ))
  local BAR=""
  BAR+="${GREEN}"
  for ((i=0; i<FILLED; i++)); do BAR+="█"; done
  BAR+="${DIM}"
      for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
      BAR+="${NC}"
  printf "\r  [%b] %3d%%  %s%-40s" "$BAR" "$PCT" "" "$PROGRESS_LABEL"
  [ "$PROGRESS_CURRENT" -ge "$PROGRESS_TOTAL" ] && echo ""
}

progress_write_json() {
  # Écrit l'état de progression dans un fichier JSON lu par le dashboard
  # Appelé automatiquement par progress_init et progress_step
  local STEP_NAME="${1:-$CURRENT_STEP}"
  local STEP_DESC="${2:-${PLAN_DESC[$CURRENT_STEP]:-}}"
  local PCT=0
  [ "${PROGRESS_TOTAL:-0}" -gt 0 ] && PCT=$(( PROGRESS_CURRENT * 100 / PROGRESS_TOTAL ))
  python3 -c "
import json,time
d={
  'active': True,
  'step_name': '${STEP_NAME}',
  'step_desc': '${STEP_DESC}',
  'step_current': ${PROGRESS_CURRENT:-0},
  'step_total': ${PROGRESS_TOTAL:-0},
  'pct': ${PCT},
  'label': '${PROGRESS_LABEL:-Installation en cours}',
  'substep_label': '${PROGRESS_SUBSTEP_LABEL:-}',
  'substep_pct': ${PROGRESS_SUBSTEP_PCT:-0},
  'ts': time.time(),
  'plan': [$(printf '"%s",' ${PLAN[@]+"${PLAN[@]}"} | sed 's/,$//')]
}
print(json.dumps(d))
" > "$IA_PROGRESS_FILE" 2>/dev/null || true
  chmod 640 "$IA_PROGRESS_FILE" 2>/dev/null || true   # root:rw, group:r
}

progress_clear_json() {
  # Supprime le fichier de progression — la bannière disparaît du dashboard
  rm -f "$IA_PROGRESS_FILE"
}

progress_apt() {
  # Exécute apt avec parsing de la progression
  local CMD=("$@")
  local PKG_COUNT=0 PKG_DONE=0
  DEBIAN_FRONTEND=noninteractive "${CMD[@]}" 2>&1 | while IFS= read -r LINE; do
    echo "$LINE" >> "$LOG_FILE"   # toujours logger
    if echo "$LINE" | grep -q "^Get:"; then
      PKG_COUNT=$(( PKG_COUNT + 1 ))
    elif echo "$LINE" | grep -q "^Unpacking\|^Setting up"; then
      PKG_DONE=$(( PKG_DONE + 1 ))
      [ "$PKG_COUNT" -gt 0 ] && {
        local PCT=$(( PKG_DONE * 100 / (PKG_COUNT > 0 ? PKG_COUNT : 1) ))
        printf "\r  ${GREEN}[apt]${NC} %d%%  %s" "$PCT" "$(echo "$LINE" | cut -c1-50)"
      }
    fi
  done
  echo ""
}

progress_ollama_pull() {
  # Validation stricte du nom de modèle avant exécution
  local MODEL="$1"
  # Format autorisé : alphanum + : / . - _ uniquement (ex: llama3.2:3b, deepseek-r1:7b)
  if ! echo "$MODEL" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{1,99}$'; then
    warn "Nom de modèle invalide ou trop long : '$MODEL'"
    warn "Caractères autorisés : lettres, chiffres, :  /  .  -  _"
    return 1
  fi
  ollama pull "$MODEL" 2>&1 | while IFS= read -r LINE; do
    echo "$LINE" >> "$LOG_FILE"
    if echo "$LINE" | grep -qE "[0-9]+%"; then
      local PCT
      PCT=$(echo "$LINE" | grep -oE "[0-9]+%" | tail -1 | tr -d '%')
      PROGRESS_SUBSTEP_LABEL="Téléchargement $MODEL"
      PROGRESS_SUBSTEP_PCT="$PCT"
      progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
      local FILLED=$(( PCT * 30 / 100 ))
      local EMPTY=$(( 30 - FILLED ))
      local BAR="${GREEN}"
      for ((i=0; i<FILLED; i++)); do BAR+="█"; done
      BAR+="${DIM}"
      for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
      BAR+="${NC}"
      printf "\r  Pull %-25s [%b] %3d%%" "$MODEL" "$BAR" "$PCT"
    fi
  done
  # $? après un pipeline reflète la DERNIÈRE commande (le while, qui réussit
  # quasi toujours), pas "ollama pull" lui-même — sans PIPESTATUS[0], un
  # pull qui échoue (mauvais nom, réseau, disque plein) était rapporté comme
  # un succès à chaque fois, en installation comme dans le menu "Ajouter".
  local PULL_STATUS=${PIPESTATUS[0]}
  PROGRESS_SUBSTEP_LABEL=""; PROGRESS_SUBSTEP_PCT=0
  progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
  echo ""
  return "$PULL_STATUS"
}

progress_docker_pull() {
  # Suit un `docker pull` couche par couche et estime un pourcentage global
  # (nb de couches terminées / nb de couches vues) — approximatif mais
  # suffisant pour montrer que ça avance plutôt qu'un dashboard figé.
  local IMAGE="$1"
  local -A SEEN_LAYERS=() DONE_LAYERS=()
  docker pull "$IMAGE" 2>&1 | while IFS= read -r LINE; do
    echo "$LINE" >> "$LOG_FILE"
    local LID
    LID=$(echo "$LINE" | grep -oE '^[a-f0-9]{12}' || true)
    [ -z "$LID" ] && continue
    SEEN_LAYERS["$LID"]=1
    if echo "$LINE" | grep -qE 'Pull complete|Already exists'; then
      DONE_LAYERS["$LID"]=1
    fi
    local TOTAL=${#SEEN_LAYERS[@]} DONE=${#DONE_LAYERS[@]}
    local PCT=0
    [ "$TOTAL" -gt 0 ] && PCT=$(( DONE * 100 / TOTAL ))
    PROGRESS_SUBSTEP_LABEL="Téléchargement image $IMAGE ($DONE/$TOTAL couches)"
    PROGRESS_SUBSTEP_PCT="$PCT"
    progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
  done
  PROGRESS_SUBSTEP_LABEL=""; PROGRESS_SUBSTEP_PCT=0
  progress_write_json "${CURRENT_STEP:-}" "${PLAN_DESC[${CURRENT_STEP:-}]:-}"
}

# New helper function for generic background command with spinner
run_with_spinner() {
  local CMD_TO_RUN="$1"
  local MSG="$2"
  local PID
  local SPINNER_CHARS="/-\|"
  local SPIN_IDX=0
  local EXIT_CODE=0
  local TMP_OUTPUT_FILE="/tmp/spinner_output_$$.log"

  info "$MSG"
  # Run command in background
  eval "$CMD_TO_RUN" > "$TMP_OUTPUT_FILE" 2>&1 &
  PID=$!

  while kill -0 "$PID" 2>/dev/null; do
    SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER_CHARS} ))
    printf "\r  %s %s" "${SPINNER_CHARS:$SPIN_IDX:1}" "$MSG"
    sleep 0.1
  done

  wait "$PID"
  EXIT_CODE=$?

  printf "\r%-80s\r" "" # Clear the line (portable, sans tput)
  cat "$TMP_OUTPUT_FILE" >> "$LOG_FILE" # Append full output to log file
  rm "$TMP_OUTPUT_FILE"

  if [ "$EXIT_CODE" -ne 0 ]; then
    nok "$MSG (Échec avec code $EXIT_CODE)"
    return 1
  else
    ok "$MSG (Terminé)"
    return 0
  fi
}
# ── Trap ERR : gestion des erreurs par étape ────────────────────
CURRENT_STEP="INIT"
LAST_ERROR_LINE=0
LAST_ERROR_CMD=""

trap '_trap_error "$LINENO" "$BASH_COMMAND"' ERR

_trap_error() {
  local LINE="$1"
  local CMD="$2"
  LAST_ERROR_LINE="$LINE"
  LAST_ERROR_CMD="$CMD"

  # ── Ignorer les erreurs non critiques pendant la phase INIT ──────
  # Pendant INIT, beaucoup de commandes peuvent échouer sans gravité
  # (détection matériel, vérifications optionnelles, etc.)
  # On n'écrit PAS dans le state pour ne pas bloquer les prochains lancements.
  if [ "$CURRENT_STEP" = "INIT" ]; then
    # Juste logger discrètement, sans interrompre ni sauvegarder l'état
    echo "[$(date +%H:%M:%S)] [TRAP/INIT] ligne $LINE : $CMD" >> "$IA_STATE_DIR/errors.log" 2>/dev/null || true
    return 0
  fi

  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ❌  ERREUR DÉTECTÉE                                      ║${NC}"
  echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
  printf  "${RED}║${NC}  Étape   : %-45s${RED}║${NC}\n" "$CURRENT_STEP"
  printf  "${RED}║${NC}  Ligne   : %-45s${RED}║${NC}\n" "$LINE"
  printf  "${RED}║${NC}  Commande: %-45s${RED}║${NC}\n" "${CMD:0:45}"
  printf  "${RED}║${NC}  Log     : %-45s${RED}║${NC}\n" "$LOG_FILE"
  echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Sauvegarder l'erreur dans le state (seulement pour les vraies étapes)
  echo "ERROR:${CURRENT_STEP}:${LINE}:${CMD}" >> "$IA_STATE_DIR/errors.log"
  save_state "ERROR:$CURRENT_STEP"

  echo -e "${BOLD}Que faire ?${NC}"
  echo -e "  ${GREEN}[1]${NC} Réessayer cette étape"
  echo -e "  ${GREEN}[2]${NC} Ignorer et continuer"
  echo -e "  ${GREEN}[3]${NC} Abandonner (état sauvegardé pour reprise)"
  echo -e "  ${GREEN}[4]${NC} Ouvrir un shell de débogage"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix [1-4] : ${NC}")" ERR_CHOICE

  case "${ERR_CHOICE:-3}" in
    1)
      info "Reprise de l'étape $CURRENT_STEP..."
      save_state "EXEC:${PLAN_STEP_IDX:-0}"
      return 0
      ;;
    2)
      warn "Étape $CURRENT_STEP ignorée — continuation..."
      return 0
      ;;
    4)
      warn "Shell de débogage — tape 'exit' pour continuer."
      bash || true
      return 0
      ;;
    3|*)
      err_msg "Installation suspendue à l'étape $CURRENT_STEP."
      info "Pour reprendre : sudo bash $SCRIPT_PATH"
      exit 1
      ;;
  esac
}

# ================================================================
