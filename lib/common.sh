#!/usr/bin/env bash
# ================================================================
#  lib/common.sh — Fondations partagées par tous les autres modules
#  Logging, couleurs, gestion des privilèges, chargement de la config.
#  Doit être sourcé en tout premier par le script principal.
# ================================================================

# NE PAS utiliser `set -e` ici : les erreurs sont gérées via trap ERR
# dans Momory-ia_local_v9.sh. `set -u` évite les variables non définies,
# `pipefail` propage l'échec d'un pipe.
set -uo pipefail
umask 027   # Nouveaux fichiers : rw-r----- (640), répertoires : rwxr-x--- (750)

# PATH sécurisé : uniquement des chemins absolus connus (pas de PATH hérité)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── Couleurs terminal ────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';    DIM='\033[2m';      NC='\033[0m'
RESET='\033[0m'

# ── Logging (messages utilisateur en français, noms de fonctions en anglais) ──
log()      { local msg; msg="[$(date +%H:%M:%S)] [OK]   $1"; echo -e "${GREEN}${msg}${NC}"; }
warn()     { local msg; msg="[$(date +%H:%M:%S)] [WARN] $1"; echo -e "${YELLOW}${msg}${NC}" >&2; }
err_msg()  { local msg; msg="[$(date +%H:%M:%S)] [ERR]  $1"; echo -e "${RED}${msg}${NC}" >&2; }
info()     { local msg; msg="[$(date +%H:%M:%S)] [INFO] $1"; echo -e "${CYAN}${msg}${NC}"; }
step()     { echo -e "\n${MAGENTA}[>>>]${NC}  ${BOLD}$1${NC}"; }
ok()       { echo -e "  ${GREEN}✓${NC} $1"; }
nok()      { echo -e "  ${RED}✗${NC} $1"; }
neutral()  { echo -e "  ${CYAN}→${NC} $1"; }
hr()       { echo -e "${DIM}  $(printf '─%.0s' {1..60})${NC}"; }

# Erreur fatale : affiche le message, pointe vers le log, quitte.
fatal_error() {
  err_msg "$1"
  echo -e "${RED}  Script arrêté. Consulte le log : ${LOG_FILE:-$IA_LOG_DIR}${NC}" >&2
  exit 1
}

# ── Chargement des réglages fixes ────────────────────────────────
# Charge uniquement config/defaults.conf (chemins, port, constantes).
# CFG (webui_dir, ollama_dir, backup_dir, etc.) est peuplé séparément
# par load_config/save_config dans lib/state.sh, qui sérialisent CFG
# avec HW et PLAN dans le même fichier ($IA_CONFIG_FILE) au format
# "CFG[clé]=valeur" sourcé directement — ne pas dupliquer cette logique
# ici avec un autre format, ça écraserait l'un ou l'autre.
declare -A CFG

load_settings() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [ -f "$repo_root/config/defaults.conf" ]; then
    # shellcheck source=config/defaults.conf
    source "$repo_root/config/defaults.conf"
  else
    fatal_error "Fichier de configuration introuvable : $repo_root/config/defaults.conf"
  fi

  # DASHBOARD_PORT peut être surchargé par l'environnement (ex: systemd
  # Environment=DASHBOARD_PORT=...) ; sinon on prend le défaut.
  DASHBOARD_PORT="${DASHBOARD_PORT:-$DASHBOARD_PORT_DEFAULT}"
  export DASHBOARD_PORT
}


# ── Gestion des droits root/sudo ────────────────────────────────
check_privileges() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERR]${NC} Ce script requiert les droits administrateur."
    echo ""
    echo -e "  Lance-le de l'une de ces façons :"
    echo -e "  ${CYAN}  sudo bash $0${NC}         ← recommandé"
    echo -e "  ${CYAN}  sudo bash $(realpath "$0")${NC}"
    echo ""
    echo -e "  ${DIM}Ton utilisateur doit être dans le groupe sudo.${NC}"
    echo -e "  ${DIM}Pour vérifier : groups \$(whoami)${NC}"
    exit 1
  fi

  # Récupérer l'utilisateur réel même sous sudo
  if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
  elif [ -n "${PKEXEC_UID:-}" ]; then
    REAL_USER=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
  else
    REAL_USER="$USER"
  fi
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
  # Fallback sûr sans eval (évite injection via nom utilisateur)
  [ -z "$REAL_HOME" ] && REAL_HOME="/home/$REAL_USER"
  # Garde-fou : on refuse de définir REAL_USER=root (ne pas chowner en root)
  if [ "$REAL_USER" = "root" ]; then
    warn "Impossible de déterminer l'utilisateur réel (REAL_USER=root)."
    warn "Lancez avec 'sudo bash $0' depuis un compte non-root."
    REAL_USER=""
    REAL_HOME=""
  fi
  export REAL_USER REAL_HOME
}

# ── Chemin canonique du script + lien symbolique ────────────────
# Le dashboard web a besoin de retrouver le script d'installation à un
# emplacement stable dans le home de l'utilisateur réel pour pouvoir le
# relancer depuis l'interface web.
ensure_script_symlink() {
  local script_path="$1"   # chemin réel du script principal (realpath "$0")
  echo "$script_path" > "$IA_INSTALLER_PATH_FILE" 2>/dev/null || true

  [ -z "${REAL_HOME:-}" ] && return
  local target="${REAL_HOME}/Momory-ia_local_v9.sh"
  [ "$script_path" = "$target" ] && return

  [ -L "$target" ] || [ -f "$target" ] && rm -f "$target" 2>/dev/null

  if ln -sf "$script_path" "$target" 2>/dev/null; then
    [ -n "${REAL_USER:-}" ] && chown "$REAL_USER" "$target" 2>/dev/null
    info "Lien symbolique créé : $target → $script_path"
  else
    warn "Impossible de créer le lien dans $REAL_HOME (permissions ?)"
  fi
}

# ── Répertoires d'état et de logs + redirection des sorties ─────
# À appeler une fois, tôt dans Momory-ia_local_v9.sh, après load_settings.
init_state_and_logging() {
  mkdir -p "$IA_STATE_DIR" "$IA_LOG_DIR"
  chmod 700 "$IA_STATE_DIR" "$IA_LOG_DIR" 2>/dev/null || true

  local log_date; log_date=$(date +%Y%m%d_%H%M%S)
  LOG_FILE="$IA_LOG_DIR/install-${log_date}.log"
  touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

  # Redirection stdout+stderr vers le log ET la console
  exec > >(tee -a "$LOG_FILE") 2>&1
  ln -sf "$LOG_FILE" "$IA_LOG_DIR/install-latest.log"
  export LOG_FILE

  echo "================================================================"
  echo " INSTALLATEUR MOMORY - IA LOCAL"
  echo " Date    : $(date)"
  echo " User    : ${REAL_USER:-?} (home: ${REAL_HOME:-?})"
  echo " OS      : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -o)"
  echo " Kernel  : $(uname -r)"
  echo " Log     : $LOG_FILE"
  echo "================================================================"
  echo ""
}

# ── Prompt de confirmation oui/non ───────────────────────────────
# Fonctionne en terminal ET, en parallèle, depuis le dashboard web : la
# question est publiée dans $IA_PENDING_CONFIRM_FILE, et confirm() accepte
# la réponse depuis le premier des deux canaux qui répond (voir aussi
# $IA_CONFIRM_ANSWER_FILE, écrit par l'API /api/admin/confirm-answer).
confirm() {
  local question="$1"
  local qid="c$(date +%s%N)"
  _write_pending_confirm "$qid" "$question"

  local reply=""
  if [ -t 0 ]; then
    echo -e "${YELLOW}  >>> ${question} [oui/NON]  ${DIM}(ou valide depuis le dashboard)${NC}"
    while true; do
      if read -t 2 -r reply < /dev/tty 2>/dev/null; then
        break
      fi
      reply="$(_check_confirm_answer "$qid")"
      [ -n "$reply" ] && { echo -e "  ${DIM}→ Réponse reçue depuis le dashboard : ${reply}${NC}"; break; }
    done
  else
    # Pas de terminal interactif (ex: lancé depuis le dashboard en --web-install) :
    # on attend uniquement une réponse web, avec un délai de sécurité de 30 min
    # (défaut prudent = non, pour ne jamais présumer d'un "oui" silencieux).
    local waited=0 max_wait=1800
    while [ "$waited" -lt "$max_wait" ]; do
      reply="$(_check_confirm_answer "$qid")"
      [ -n "$reply" ] && break
      sleep 2; waited=$(( waited + 2 ))
      [ $(( waited % 60 )) -eq 0 ] && warn "En attente d'une validation dashboard : ${question}"
    done
    [ -z "$reply" ] && { warn "Délai dépassé, réponse par défaut : non."; reply="non"; }
  fi

  _clear_pending_confirm
  [[ "$reply" =~ ^[Oo][Uu][Ii]$ ]]
}

# Publie la question en attente dans le fichier lu par le dashboard.
_write_pending_confirm() {
  local qid="$1" question="$2"
  python3 -c "
import json
json.dump({'pending': True, 'qid': '${qid}', 'question': '''${question}'''}, open('$IA_PENDING_CONFIRM_FILE','w'))
" 2>/dev/null || true
  chmod 640 "$IA_PENDING_CONFIRM_FILE" 2>/dev/null || true
}

# Regarde si une réponse a été postée depuis le dashboard pour ce qid précis
# (le qid évite qu'une réponse à une ancienne question ne s'applique à la
# suivante). Retourne "oui"/"non" si trouvé, chaîne vide sinon.
_check_confirm_answer() {
  local qid="$1"
  [ -f "$IA_CONFIRM_ANSWER_FILE" ] || return 0
  python3 -c "
import json,sys
try:
    d=json.load(open('$IA_CONFIRM_ANSWER_FILE'))
    if d.get('qid')=='$qid': print(d.get('answer',''))
except Exception: pass
" 2>/dev/null
}

_clear_pending_confirm() {
  python3 -c "
import json
json.dump({'pending': False}, open('$IA_PENDING_CONFIRM_FILE','w'))
" 2>/dev/null || true
  rm -f "$IA_CONFIRM_ANSWER_FILE" 2>/dev/null || true
}

# ── Petits helpers d'affichage (titres, encadrés) ────────────────
title() {
  local len=${#1}
  local pad=$(( (56 - len) / 2 ))
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
  printf  "${BLUE}║${NC}%*s${BOLD}%s${NC}%*s${BLUE}║${NC}\n" "$pad" "" "$1" "$pad" ""
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
}

box_line() { printf "${CYAN}  │${NC}  %-20s : ${BOLD}%-32s${NC}${CYAN}│${NC}\n" "$1" "$2"; }
box_sep()  { echo -e "${CYAN}  ├──────────────────────────────────────────────────────┤${NC}"; }
box_top()  { echo -e "${CYAN}  ┌──────────────────────────────────────────────────────┐${NC}"; }
box_bot()  { echo -e "${CYAN}  └──────────────────────────────────────────────────────┘${NC}"; }
