#!/usr/bin/env bash
# Panneau HUD — stats système temps réel
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 1027-1706)

#  PANNEAU HUD — STATS SYSTÈME EN TEMPS RÉEL (coin haut-droit)
# ================================================================
#  Dessiné via codes ANSI de positionnement — zéro dépendance.
#  Tourne dans un sous-process background, rafraîchi toutes les 2s.
#  Compatible tous terminaux ≥ 80 colonnes.
# ================================================================

HUD_PID=""       # PID du sous-process HUD (vide = HUD arrêté)
HUD_WIDTH=34     # Largeur du panneau en colonnes
HUD_ROWS=18      # Hauteur réservée en haut pour le panneau

# Variables delta CPU/réseau partagées via fichier tmp (sous-process)
_HUD_STAT_FILE="/tmp/ia_installer_hud_$$.stat"

# ── Dessiner UNE ligne de contenu dans le panneau ───────────────
# _hud_line ROW LABEL VALUE [COULEUR_VALEUR]
_hud_line() {
  local ROW="$1" LABEL="$2" VAL="$3" VCOL="${4:-$CYAN}"
  local TCOLS; TCOLS=$(_term_cols)
  local COL=$(( TCOLS - HUD_WIDTH ))
  [ "$COL" -lt 1 ] && return
  local MAX=$(( HUD_WIDTH - 14 ))
  [ "${#VAL}" -gt "$MAX" ] && VAL="${VAL:0:$(( MAX - 1 ))}…"
  printf "\033[s\033[%d;%dH\033[K${BLUE}│${NC}${DIM} %-9s ${NC}${VCOL}%-*s${NC}${BLUE}│${NC}\033[u" \
    "$ROW" "$COL" "$LABEL" "$MAX" "$VAL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Dessiner UNE ligne de séparateur ────────────────────────────
_hud_sep() {
  local ROW="$1"
  local TCOLS; TCOLS=$(_term_cols)
  local COL=$(( TCOLS - HUD_WIDTH ))
  [ "$COL" -lt 1 ] && return
  local INNER=$(( HUD_WIDTH - 2 ))
  printf "\033[s\033[%d;%dH\033[K${BLUE}├$(printf '─%.0s' $(seq 1 $INNER))┤${NC}\033[u" "$ROW" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Dessiner le cadre complet ────────────────────────────────────
_hud_frame() {
  local TCOLS; TCOLS=$(_term_cols)
  local COL=$(( TCOLS - HUD_WIDTH ))
  [ "$COL" -lt 1 ] && return
  local INNER=$(( HUD_WIDTH - 2 ))
  local W=$HUD_WIDTH

  # Top border
  printf "\033[s\033[1;%dH\033[K${BLUE}┌$(printf '─%.0s' $(seq 1 $INNER))┐${NC}\033[u" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  # Titre
  local T="  📊 STATS SYSTÈME  "
  local TLEN=${#T}
  local PAD=$(( (INNER - TLEN) / 2 ))
  local RPAD=$(( INNER - TLEN - PAD ))
  printf "\033[s\033[2;%dH\033[K${BLUE}│${NC}${BOLD}$(printf '%*s' $PAD '')${CYAN}%s${NC}$(printf '%*s' $RPAD '')${BLUE}│${NC}\033[u" \
    "$COL" "$T" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  # Séparateur sous titre
  printf "\033[s\033[3;%dH\033[K${BLUE}├$(printf '─%.0s' $(seq 1 $INNER))┤${NC}\033[u" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  # Bottom border (ligne HUD_ROWS)
  printf "\033[s\033[%d;%dH\033[K${BLUE}└$(printf '─%.0s' $(seq 1 $INNER))┘${NC}\033[u" \
    "$HUD_ROWS" "$COL" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Lecture et affichage de toutes les stats ─────────────────────
_hud_update() {
  # ── CPU (delta depuis dernière lecture) ─────────────────────
  local CPU_IDLE CPU_TOTAL CPU_PCT=0
  local CPU_LINE; CPU_LINE=$(grep -E '^cpu ' /proc/stat 2>/dev/null | head -1)
  local _u _n _s _id _io _ir _si _st
  read -r _ _u _n _s _id _io _ir _si _st _ <<< "$CPU_LINE"
  CPU_TOTAL=$(( _u+_n+_s+_id+_io+_ir+_si+${_st:-0} ))
  CPU_IDLE=$_id

  if [ -f "$_HUD_STAT_FILE" ]; then
    local PT PI; read -r PT PI < "$_HUD_STAT_FILE" 2>/dev/null || { PT=0; PI=0; }
    local DT=$(( CPU_TOTAL - PT )); local DI=$(( CPU_IDLE - PI ))
    [ "$DT" -gt 0 ] && CPU_PCT=$(( (DT - DI) * 100 / DT ))
  fi
  echo "$CPU_TOTAL $CPU_IDLE" > "$_HUD_STAT_FILE"

  local CPU_COL="$GREEN"
  [ "$CPU_PCT" -ge 60 ] && CPU_COL="$YELLOW"
  [ "$CPU_PCT" -ge 85 ] && CPU_COL="$RED"

  # Fréquence
  local CPU_FREQ="?"
  CPU_FREQ=$(awk '{printf "%.1f GHz", $1/1000000}' \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) || \
  CPU_FREQ=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | \
    awk '{printf "%.0f MHz", $4}') || CPU_FREQ="?"

  # Température CPU
  local CPU_TEMP="N/A"
  for _F in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$_F" ] || continue
    local _T; _T=$(cat "$_F" 2>/dev/null) || continue
    [ "$_T" -gt 1000 ] 2>/dev/null && {
      CPU_TEMP="$(( _T / 1000 ))°C"; break; }
  done

  local TEMP_COL="$GREEN"
  local _TN; _TN=$(echo "$CPU_TEMP" | grep -oP '^\d+' || echo 0)
  [ "${_TN:-0}" -ge 70 ] && TEMP_COL="$YELLOW"
  [ "${_TN:-0}" -ge 85 ] && TEMP_COL="$RED"

  # ── RAM ────────────────────────────────────────────────────
  local MEM_TOTAL MEM_AVAIL MEM_USED MEM_PCT
  MEM_TOTAL=$(grep MemTotal     /proc/meminfo | awk '{print $2}')
  MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  MEM_USED=$(( (MEM_TOTAL - MEM_AVAIL) / 1024 ))
  local MEM_TOT_MB=$(( MEM_TOTAL / 1024 ))
  MEM_PCT=$(( MEM_USED * 100 / (MEM_TOT_MB > 0 ? MEM_TOT_MB : 1) ))
  local RAM_COL="$GREEN"
  [ "$MEM_PCT" -ge 70 ] && RAM_COL="$YELLOW"
  [ "$MEM_PCT" -ge 90 ] && RAM_COL="$RED"

  # Swap
  local SWAP_TOT SWAP_FREE SWAP_USED SWAP_MB
  SWAP_TOT=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  SWAP_FREE=$(grep SwapFree  /proc/meminfo | awk '{print $2}')
  SWAP_USED=$(( (SWAP_TOT - SWAP_FREE) / 1024 ))
  SWAP_MB=$(( SWAP_TOT / 1024 ))

  # ── GPU ────────────────────────────────────────────────────
  local GPU_UTIL="N/A" GPU_TEMP="N/A" GPU_MEM="N/A" GPU_COL="$DIM"
  if command -v nvidia-smi &>/dev/null; then
    local _GLINE
    _GLINE=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total \
      --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$_GLINE" ]; then
      local _GU _GT _GMU _GMT
      IFS=', ' read -r _GU _GT _GMU _GMT <<< "$_GLINE"
      GPU_UTIL="${_GU}%"
      GPU_TEMP="${_GT}°C"
      GPU_MEM="${_GMU}/${_GMT} Mo"
      GPU_COL="$GREEN"
      [ "${_GU:-0}" -ge 70 ] && GPU_COL="$YELLOW"
      [ "${_GU:-0}" -ge 90 ] && GPU_COL="$RED"
    fi
  elif command -v rocm-smi &>/dev/null; then
    GPU_UTIL="$(rocm-smi --showuse 2>/dev/null | grep -oP '\d+(?=%)' | head -1 || echo '?')%"
    GPU_COL="$CYAN"; GPU_MEM="ROCm"
  fi

  # ── Disques ───────────────────────────────────────────────
  local DISK_IA_STAT="N/A" DISK_IA_PCT=0 DISK_IA_COL="$GREEN"
  local DISK_ROOT_STAT="N/A"
  local _MOUNT="${CFG[hdd_mount]:-}"

  if [ -n "$_MOUNT" ] && mountpoint -q "$_MOUNT" 2>/dev/null; then
    local _DF; _DF=$(df -BG "$_MOUNT" 2>/dev/null | awk 'NR==2{print $3, $4, $5}')
    local _DU _DF2 _DPCT
    read -r _DU _DF2 _DPCT <<< "$_DF"
    DISK_IA_STAT="${_DU} us / ${_DF2} libre"
    DISK_IA_PCT=${_DPCT//%/}
    [ "${DISK_IA_PCT:-0}" -ge 80 ] && DISK_IA_COL="$YELLOW"
    [ "${DISK_IA_PCT:-0}" -ge 95 ] && DISK_IA_COL="$RED"
  fi

  local _RDF; _RDF=$(df -BG / 2>/dev/null | awk 'NR==2{print $3, $4}')
  local _RU _RF; read -r _RU _RF <<< "$_RDF"
  DISK_ROOT_STAT="${_RU} us / ${_RF} libre"

  # ── Réseau ────────────────────────────────────────────────
  local NET_RX="N/A" NET_TX="N/A"
  local _NETDEV; _NETDEV=$(ip route 2>/dev/null | awk '/^default/{print $5;exit}')
  if [ -n "$_NETDEV" ]; then
    local _RX _TX
    _RX=$(cat "/sys/class/net/${_NETDEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    _TX=$(cat "/sys/class/net/${_NETDEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
    local _NETF="/tmp/ia_hud_net_$$.stat"
    if [ -f "$_NETF" ]; then
      local _PRX _PTX; read -r _PRX _PTX < "$_NETF" 2>/dev/null || { _PRX=0; _PTX=0; }
      local DRX=$(( (_RX - _PRX) / 1024 / 2 ))   # /2 car rafraîchi toutes les 2s
      local DTX=$(( (_TX - _PTX) / 1024 / 2 ))
      [ "$DRX" -gt 1024 ] && NET_RX="↓$(( DRX/1024 ))M/s" || NET_RX="↓${DRX}K/s"
      [ "$DTX" -gt 1024 ] && NET_TX="↑$(( DTX/1024 ))M/s" || NET_TX="↑${DTX}K/s"
    else
      NET_RX="↓---" NET_TX="↑---"
    fi
    echo "$_RX $_TX" > "$_NETF"
  fi

  # ── Services (URLs avec ports) ────────────────────────────
  local WEBUI_PORT="${CFG[webui_port]:-8080}"
  local OLLAMA_PORT="11434"
  local WEBUI_URL="http://localhost:${WEBUI_PORT}"
  local OLLAMA_URL="http://localhost:${OLLAMA_PORT}"

  local WEBUI_STATUS WEBUI_COL OLLAMA_STATUS OLLAMA_COL

  # Vérifier Open WebUI
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    WEBUI_STATUS="✓ :${WEBUI_PORT} actif"
    WEBUI_COL="$GREEN"
  else
    WEBUI_STATUS="✗ :${WEBUI_PORT} arrêté"
    WEBUI_COL="$RED"
  fi

  # Vérifier API Ollama
  if curl -sf --max-time 1 "${OLLAMA_URL}/api/tags" &>/dev/null; then
    # Compter les modèles chargés
    local _NM
    _NM=$(curl -sf --max-time 2 "${OLLAMA_URL}/api/tags" 2>/dev/null \
      | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(len(d.get('models',[])))
except: print('?')" \
      2>/dev/null || echo "?")
    OLLAMA_STATUS="✓ :${OLLAMA_PORT} (${_NM} mod.)"
    OLLAMA_COL="$GREEN"
  else
    OLLAMA_STATUS="✗ :${OLLAMA_PORT} N/A"
    OLLAMA_COL="$RED"
  fi

  # ── Horloge & uptime ─────────────────────────────────────
  local NOW; NOW=$(date +"%H:%M:%S")
  local UPTIME_STR
  UPTIME_STR=$(awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if(d>0) printf "%dd %dh%dm",d,h,m; else printf "%dh %dm",h,m}' /proc/uptime 2>/dev/null)

  # ── Dessiner le panneau complet ───────────────────────────
  _hud_frame

  local R=4
  _hud_line $R "CPU"    "${CPU_PCT}%  ${CPU_FREQ}"       "$CPU_COL";  R=$(( R+1 ))
  _hud_line $R "Temp."  "$CPU_TEMP"                       "$TEMP_COL"; R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "RAM"    "${MEM_USED}/${MEM_TOT_MB} MB ${MEM_PCT}%" "$RAM_COL"; R=$(( R+1 ))
  _hud_line $R "Swap"   "${SWAP_USED}/${SWAP_MB} MB"     "$DIM";      R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "GPU"    "$GPU_UTIL  $GPU_TEMP"            "$GPU_COL";  R=$(( R+1 ))
  _hud_line $R "VRAM"   "$GPU_MEM"                        "$GPU_COL";  R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "WebUI"  "$WEBUI_STATUS"                   "$WEBUI_COL";  R=$(( R+1 ))
  _hud_line $R "Ollama" "$OLLAMA_STATUS"                  "$OLLAMA_COL"; R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "Disque" "$DISK_IA_STAT"                   "$DISK_IA_COL"; R=$(( R+1 ))
  _hud_line $R "Root"   "$DISK_ROOT_STAT"                 "$GREEN";    R=$(( R+1 ))
  _hud_sep  $R;                                                         R=$(( R+1 ))
  _hud_line $R "Réseau" "${NET_RX}  ${NET_TX}"            "$CYAN";     R=$(( R+1 ))
  _hud_line $R "Uptime" "${UPTIME_STR}  ${NOW}"           "$DIM"
}

# ── Détection du VRAI terminal — robuste sous sudo, SSH, pipe ────
#
# Problème : sous "sudo ./script.sh", /dev/tty pointe sur le pseudo-
# terminal de sudo et non celui de l'utilisateur. stty, dd, et les
# séquences ANSI échouent ou ne fonctionnent pas correctement.
#
# Solution : détecter le vrai TTY en cascade et le stocker dans
# _REAL_TTY — variable utilisée partout à la place de /dev/tty.
# ─────────────────────────────────────────────────────────────────
_REAL_TTY=""

_detect_real_tty() {
  local _TTY=""

  # 1. sudo positionne $SUDO_TTY avec le tty de l'utilisateur appelant
  if [ -n "${SUDO_TTY:-}" ] && [ -w "$SUDO_TTY" ]; then
    _TTY="$SUDO_TTY"

  # 2. /proc/PID/fd/0 du shell parent (fonctionne en bash sous sudo)
  elif [ -r "/proc/${PPID}/fd/0" ]; then
    local _P; _P=$(readlink -f "/proc/${PPID}/fd/0" 2>/dev/null)
    [ -w "${_P:-}" ] && _TTY="$_P"

  # 3. $(tty) du process courant (valide si stdin n'est pas redirigé)
  elif _T=$(tty 2>/dev/null) && [ -w "$_T" ] && [[ "$_T" != "not a tty" ]]; then
    _TTY="$_T"

  # 4. /dev/tty — fallback POSIX standard
  elif [ -w "/dev/tty" ]; then
    _TTY="/dev/tty"
  fi

  _REAL_TTY="${_TTY:-}"
  export _REAL_TTY
}

# Appeler immédiatement à la définition
_detect_real_tty

# Vrai si un terminal interactif est disponible
_term_is_interactive() {
  [ -n "$_REAL_TTY" ] && [ -w "$_REAL_TTY" ] && return 0
  [ -t 1 ] && return 0
  return 1
}

# Nombre de colonnes du terminal
_term_cols() {
  local C
  if [ -n "$_REAL_TTY" ]; then
    C=$(stty size < "$_REAL_TTY" 2>/dev/null | awk '{print $2}')
    [ "${C:-0}" -gt 0 ] && echo "$C" && return
    C=$(tput cols 2>/dev/null)
    [ "${C:-0}" -gt 0 ] && echo "$C" && return
  fi
  [ -n "${COLUMNS:-}" ] && echo "$COLUMNS" && return
  echo 80
}

# Nombre de lignes du terminal
_term_rows() {
  local R
  if [ -n "$_REAL_TTY" ]; then
    R=$(stty size < "$_REAL_TTY" 2>/dev/null | awk '{print $1}')
    [ "${R:-0}" -gt 0 ] && echo "$R" && return
    R=$(tput lines 2>/dev/null)
    [ "${R:-0}" -gt 0 ] && echo "$R" && return
  fi
  [ -n "${LINES:-}" ] && echo "$LINES" && return
  echo 24
}

# Écrire une séquence ANSI sur le vrai terminal
_tty_write() { printf "%s" "$*" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true; }

# Lire depuis le vrai terminal (non-bloquant grâce au stty préalable)
_tty_read1() { dd bs=1 count=1 < "${_REAL_TTY:-/dev/tty}" 2>/dev/null; }

# ── Démarrer le HUD en arrière-plan ─────────────────────────────
hud_start() {
  # Le HUD ANSI nécessite un terminal qui supporte le positionnement
  _term_is_interactive || return 0
  local TCOLS; TCOLS=$(_term_cols)
  [ "$TCOLS" -lt 90 ] && return 0  # Terminal trop étroit pour le panneau

  # Réserver les lignes du haut : le texte scrollera en dessous
  local TROWS; TROWS=$(_term_rows)
  { tput csr $((HUD_ROWS + 1)) $(( TROWS - 1 )) 2>/dev/null     || printf "\033[%d;%dr" $((HUD_ROWS + 1)) $(( TROWS - 1 )); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
  { tput cup $((HUD_ROWS + 1)) 0 2>/dev/null     || printf "\033[%d;0H" $((HUD_ROWS + 1)); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true

  (
    sleep 1
    while true; do
      _hud_update 2>/dev/null || true
      sleep 2
    done
  ) &
  HUD_PID=$!
  export HUD_PID
}

# ── Arrêter le HUD et restaurer le terminal ──────────────────────
hud_stop() {
  [ -z "${HUD_PID:-}" ] && return 0
  kill "$HUD_PID" 2>/dev/null || true
  wait "$HUD_PID" 2>/dev/null || true
  HUD_PID=""
  rm -f "$_HUD_STAT_FILE" "/tmp/ia_hud_net_$$.stat" 2>/dev/null || true

  _term_is_interactive || return 0
  local TROWS; TROWS=$(_term_rows)
  local TCOLS; TCOLS=$(_term_cols)
  # Restaurer scroll region complète
  { tput csr 0 $(( TROWS - 1 )) 2>/dev/null     || printf "\033[0;%dr" $(( TROWS - 1 )); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
  # Effacer le panneau colonne par colonne
  local COL=$(( TCOLS - HUD_WIDTH ))
  local R
  for R in $(seq 1 $(( HUD_ROWS + 1 ))); do
    printf "\033[s\033[%d;%dH\033[K%*s\033[u" "$R" "$COL" "$(( HUD_WIDTH + 1 ))" "" > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
  done
  { tput cup $(( HUD_ROWS + 2 )) 0 2>/dev/null     || printf "\033[%d;0H" $(( HUD_ROWS + 2 )); } > "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
}

# ── Vue stats : contenu commun (texte pur, sans ANSI position) ──
_stats_draw_content() {
  local TCOLS="${1:-80}"

  # ── Header ──────────────────────────────────────────────────
  local TITLE="  ✦  STATS SYSTÈME EN TEMPS RÉEL  ✦  "
  printf "${BOLD}${CYAN}%-*s${NC}\n" "$TCOLS" "$TITLE"
  printf "${BLUE}"; printf '─%.0s' $(seq 1 "$TCOLS"); printf "${NC}\n"
  echo ""

  # ── CPU ────────────────────────────────────────────────────
  local CPU_LINE; CPU_LINE=$(grep -E '^cpu ' /proc/stat 2>/dev/null | head -1)
  local _u _n _s _id _io _ir _si _st
  read -r _ _u _n _s _id _io _ir _si _st _ <<< "$CPU_LINE"
  local CPU_TOTAL=$(( _u+_n+_s+_id+_io+_ir+_si+${_st:-0} ))
  local CPU_IDLE=$_id
  local CPU_PCT=0
  if [ -f "$_HUD_STAT_FILE" ]; then
    local PT PI; read -r PT PI < "$_HUD_STAT_FILE" 2>/dev/null || { PT=0; PI=0; }
    local DT=$(( CPU_TOTAL - PT )); local DI=$(( CPU_IDLE - PI ))
    [ "$DT" -gt 0 ] && CPU_PCT=$(( (DT - DI) * 100 / DT ))
  fi
  echo "$CPU_TOTAL $CPU_IDLE" > "$_HUD_STAT_FILE"

  local CPU_FREQ
  CPU_FREQ=$(awk '{printf "%.2f GHz", $1/1000000}' \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) || \
  CPU_FREQ=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{printf "%.0f MHz",$4}') || \
  CPU_FREQ="?"
  local CPU_TEMP="N/A"
  for _F in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$_F" ] && { local _T; _T=$(cat "$_F" 2>/dev/null)
      [ "${_T:-0}" -gt 1000 ] && { CPU_TEMP="$(( _T/1000 ))°C"; break; }; }
  done

  local CPU_COL="$GREEN"
  [ "$CPU_PCT" -ge 60 ] && CPU_COL="$YELLOW"
  [ "$CPU_PCT" -ge 85 ] && CPU_COL="$RED"
  local CFILL=$(( CPU_PCT * 40 / 100 )); local CEMPTY=$(( 40 - CFILL ))
  local CBAR="${CPU_COL}"; for i in $(seq 1 $CFILL); do CBAR+="█"; done
  CBAR+="${DIM}"; for i in $(seq 1 $CEMPTY); do CBAR+="░"; done; CBAR+="${NC}"
  printf "  ${BOLD}CPU${NC}    [%b] ${CPU_COL}%3d%%${NC}   Fréq: %s   Temp: %s\n" \
    "$CBAR" "$CPU_PCT" "${CPU_FREQ:-?}" "$CPU_TEMP"

  # CPU par cœur
  local CORES_DISPLAY=""
  while IFS= read -r CORE_LINE; do
    local _CID _CU _CN _CS _CID2 _CIO _CIR _CSI
    read -r _CID _CU _CN _CS _CID2 _CIO _CIR _CSI _ <<< "$CORE_LINE"
    local CT=$(( _CU+_CN+_CS+_CID2+_CIO+_CIR+_CSI ))
    local CP=0; [ "$CT" -gt 0 ] && CP=$(( (_CU+_CN+_CS) * 100 / CT ))
    local CC="$GREEN"; [ "$CP" -ge 60 ] && CC="$YELLOW"; [ "$CP" -ge 85 ] && CC="$RED"
    CORES_DISPLAY+="  ${DIM}${_CID#cpu}${NC}:${CC}${CP}%${NC}"
  done < <(grep -E '^cpu[0-9]+' /proc/stat 2>/dev/null | head -16)
  echo -e "  ${DIM}Cœurs :${NC}$CORES_DISPLAY"
  echo ""

  # ── RAM & SWAP ──────────────────────────────────────────────
  local MEM_TOTAL MEM_AVAIL MEM_USED MEM_TOT_MB MEM_PCT
  MEM_TOTAL=$(grep MemTotal     /proc/meminfo | awk '{print $2}')
  MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  MEM_USED=$(( (MEM_TOTAL - MEM_AVAIL) / 1024 ))
  MEM_TOT_MB=$(( MEM_TOTAL / 1024 ))
  MEM_PCT=$(( MEM_USED * 100 / (MEM_TOT_MB > 0 ? MEM_TOT_MB : 1) ))
  local SWAP_TOT SWAP_FREE SWAP_USED SWAP_MB SWAP_PCT=0
  SWAP_TOT=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  SWAP_FREE=$(grep SwapFree  /proc/meminfo | awk '{print $2}')
  SWAP_USED=$(( (SWAP_TOT - SWAP_FREE) / 1024 ))
  SWAP_MB=$(( SWAP_TOT / 1024 ))
  [ "$SWAP_MB" -gt 0 ] && SWAP_PCT=$(( SWAP_USED * 100 / SWAP_MB ))

  local RAM_COL="$GREEN"
  [ "$MEM_PCT" -ge 70 ] && RAM_COL="$YELLOW"; [ "$MEM_PCT" -ge 90 ] && RAM_COL="$RED"
  local RFILL=$(( MEM_PCT * 40 / 100 )); local REMPTY=$(( 40 - RFILL ))
  local RBAR="${RAM_COL}"; for i in $(seq 1 $RFILL); do RBAR+="█"; done
  RBAR+="${DIM}"; for i in $(seq 1 $REMPTY); do RBAR+="░"; done; RBAR+="${NC}"
  printf "  ${BOLD}RAM${NC}    [%b] ${RAM_COL}%3d%%${NC}   %d/%d Mo\n" "$RBAR" "$MEM_PCT" "$MEM_USED" "$MEM_TOT_MB"

  local SFILL=$(( SWAP_PCT * 40 / 100 )); local SEMPTY=$(( 40 - SFILL ))
  local SBAR="${DIM}"; for i in $(seq 1 $SFILL); do SBAR+="█"; done
  SBAR+="${DIM}"; for i in $(seq 1 $SEMPTY); do SBAR+="░"; done; SBAR+="${NC}"
  printf "  ${BOLD}Swap${NC}   [%b] ${DIM}%3d%%${NC}   %d/%d Mo\n" "$SBAR" "$SWAP_PCT" "$SWAP_USED" "$SWAP_MB"
  echo ""

  # ── GPU ────────────────────────────────────────────────────
  printf "  ${BOLD}GPU${NC}\n"
  if command -v nvidia-smi &>/dev/null; then
    local _GLINE
    _GLINE=$(nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw \
      --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$_GLINE" ]; then
      local _GN _GU _GT _GMU _GMT _GPW
      IFS=', ' read -r _GN _GU _GT _GMU _GMT _GPW <<< "$_GLINE"
      local GC="$GREEN"
      [ "${_GU:-0}" -ge 70 ] && GC="$YELLOW"; [ "${_GU:-0}" -ge 90 ] && GC="$RED"
      local GFILL=$(( ${_GU:-0} * 40 / 100 )); local GEMPTY=$(( 40 - GFILL ))
      local GBAR="${GC}"; for i in $(seq 1 $GFILL); do GBAR+="█"; done
      GBAR+="${DIM}"; for i in $(seq 1 $GEMPTY); do GBAR+="░"; done; GBAR+="${NC}"
      printf "  ${DIM}%-30s${NC}\n" "${_GN:-NVIDIA}"
      printf "  Utilisation  [%b] ${GC}%3d%%${NC}\n" "$GBAR" "${_GU:-0}"
      printf "  VRAM         ${MAGENTA}%s / %s Mo${NC}   Temp: %s°C   Puissance: %s W\n" \
        "${_GMU:-?}" "${_GMT:-?}" "${_GT:-?}" "${_GPW:-?}"
    else
      echo "  ${DIM}GPU NVIDIA détecté mais nvidia-smi ne répond pas.${NC}"
    fi
  elif command -v rocm-smi &>/dev/null; then
    echo "  ${CYAN}AMD GPU (ROCm)${NC}"
    rocm-smi --showuse --showtemp 2>/dev/null | grep -v '^$' | head -5 | sed 's/^/  /'
  else
    echo "  ${DIM}Aucun GPU dédié détecté (CPU-only mode)${NC}"
  fi
  echo ""

  # ── SERVICES ───────────────────────────────────────────────
  local WEBUI_PORT="${CFG[webui_port]:-8080}"
  local OLLAMA_HOST="${CFG[ollama_host]:-0.0.0.0}"
  local WEBUI_URL="http://localhost:${WEBUI_PORT}"
  local OLLAMA_URL="http://${OLLAMA_HOST}:11434"
  [ "$OLLAMA_HOST" = "0.0.0.0" ] && OLLAMA_URL="http://localhost:11434"

  printf "  ${BOLD}SERVICES${NC}\n"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    printf "  ${GREEN}✓${NC}  Open WebUI    ${GREEN}actif${NC}  →  ${CYAN}%s${NC}\n" "$WEBUI_URL"
  else
    printf "  ${RED}✗${NC}  Open WebUI    ${RED}arrêté${NC}  →  ${DIM}%s${NC}\n" "$WEBUI_URL"
  fi
  if curl -sf --max-time 1 "http://127.0.0.1:11434/api/tags" &>/dev/null; then
    local _NM
    _NM=$(curl -sf --max-time 2 "http://127.0.0.1:11434/api/tags" 2>/dev/null \
      | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); print(len(d.get('models',[])))\nexcept: print(chr(63))" 2>/dev/null || echo "?")
    printf "  ${GREEN}✓${NC}  Ollama API    ${GREEN}actif${NC}   →  ${CYAN}%s${NC}  ${DIM}(%s modèles)${NC}\n" \
      "$OLLAMA_URL" "$_NM"
    # Afficher aussi l'URL LAN si écoute externe
    if [ "${CFG[ollama_host]:-}" = "0.0.0.0" ]; then
      local _LIP; _LIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' \
        || hostname -I 2>/dev/null | awk '{print $1}')
      printf "  ${DIM}   ↳ réseau LAN  →  ${CYAN}http://%s:11434${NC}\n" "${_LIP:-<IP>}"
    fi
  else
    printf "  ${RED}✗${NC}  Ollama API    ${RED}N/A${NC}     →  ${DIM}%s${NC}\n" "$OLLAMA_URL"
  fi
  if docker info &>/dev/null 2>&1; then
    local _NC; _NC=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    printf "  ${GREEN}✓${NC}  Docker        ${GREEN}actif${NC}   →  ${DIM}%s container(s)${NC}\n" "$_NC"
  else
    printf "  ${RED}✗${NC}  Docker        ${RED}arrêté${NC}\n"
  fi
  echo ""

  # ── DISQUES ────────────────────────────────────────────────
  printf "  ${BOLD}DISQUES${NC}\n"
  df -h 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|udev|/dev/loop|Filesystem)' | while IFS= read -r _DL; do
    local _FS _SZ _US _AV _PC _MT
    read -r _FS _SZ _US _AV _PC _MT <<< "$_DL"
    local _P=${_PC//%/}
    local _DC="$GREEN"
    [ "${_P:-0}" -ge 80 ] && _DC="$YELLOW"; [ "${_P:-0}" -ge 95 ] && _DC="$RED"
    local _DFILL=$(( ${_P:-0} * 20 / 100 )); local _DEMPTY=$(( 20 - _DFILL ))
    local _DBAR="${_DC}"; for i in $(seq 1 $_DFILL); do _DBAR+="█"; done
    _DBAR+="${DIM}"; for i in $(seq 1 $_DEMPTY); do _DBAR+="░"; done; _DBAR+="${NC}"
    printf "  [%b] ${_DC}%4s${NC}  %-20s  %s us / %s lib  %s\n" \
      "$_DBAR" "$_PC" "${_FS:0:20}" "$_US" "$_AV" "$_MT"
  done
  echo ""

  # ── RÉSEAU ────────────────────────────────────────────────
  local _NETDEV; _NETDEV=$(ip route 2>/dev/null | awk '/^default/{print $5;exit}')
  if [ -n "$_NETDEV" ]; then
    local _IP; _IP=$(ip -4 addr show "$_NETDEV" 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)
    printf "  ${BOLD}RÉSEAU${NC}  ${DIM}%s${NC}  IP: ${CYAN}%s${NC}\n" "$_NETDEV" "${_IP:-?}"
    local _NETF="/tmp/ia_hud_net_$$.stat"
    local _RX _TX
    _RX=$(cat "/sys/class/net/${_NETDEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    _TX=$(cat "/sys/class/net/${_NETDEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
    if [ -f "$_NETF" ]; then
      local _PRX _PTX; read -r _PRX _PTX < "$_NETF" 2>/dev/null || { _PRX=0; _PTX=0; }
      local DRX=$(( (_RX - _PRX) / 1024 / 2 )) DTX=$(( (_TX - _PTX) / 1024 / 2 ))
      local RXS TXS
      [ "$DRX" -gt 1024 ] && RXS="$(( DRX/1024 )) Mo/s" || RXS="${DRX} Ko/s"
      [ "$DTX" -gt 1024 ] && TXS="$(( DTX/1024 )) Mo/s" || TXS="${DTX} Ko/s"
      printf "  ↓ Réception : ${CYAN}%-12s${NC}   ↑ Émission : ${DIM}%-12s${NC}\n" "$RXS" "$TXS"
    fi
    echo "$_RX $_TX" > "$_NETF"
  fi
  echo ""

  # ── Footer ──────────────────────────────────────────────────
  local _UPTIME
  _UPTIME=$(awk '{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if(d>0) printf "%d jour(s) %dh%02dm",d,h,m; else printf "%dh %02dm",h,m}' /proc/uptime 2>/dev/null)
  printf "${BLUE}"; printf '─%.0s' $(seq 1 "$TCOLS"); printf "${NC}\n"
  printf "  Uptime : ${DIM}%s${NC}   Heure : ${BOLD}%s${NC}" \
    "$_UPTIME" "$(date +"%H:%M:%S")"
}

# ── Vue plein écran des stats (menu_stats_live) ──────────────────
# Fonctionne en mode interactif (ANSI, rafraîchissement en place)
# ET en mode non-interactif (SSH sans TTY, pipe, nohup) — sortie texte simple.
menu_stats_live() {
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  load_config   # déclare HW/CFG/PLAN/PLAN_DESC/PLAN_REBOOT avant de sourcer

  local TCOLS; TCOLS=$(_term_cols)
  local TROWS; TROWS=$(_term_rows)

  if _term_is_interactive; then
    # ────────────────────────────────────────────────────────
    # MODE INTERACTIF : plein écran avec rafraîchissement ANSI
    # ────────────────────────────────────────────────────────

    # Flag de sortie partagé entre la boucle et le trap
    local _STATS_EXIT=0   # 0=continuer  1=retour menu  2=quitter script

    # Restauration propre du terminal (appelée par trap ET sortie normale)
    local _STTY_SAVE=""
    _STTY_SAVE=$(stty -g < "${_REAL_TTY:-/dev/tty}" 2>/dev/null) || true

    _stats_restore_term() {
      _tty_write "\033[?25h"          # Rendre le curseur visible
      _tty_write "\033[r"             # Restaurer scroll region
      _tty_write "\033[999;1H"        # Curseur en bas
      if [ -n "$_STTY_SAVE" ]; then
        stty "$_STTY_SAVE" < "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
      else
        stty sane < "${_REAL_TTY:-/dev/tty}" 2>/dev/null || true
      fi
    }

    # Ctrl+C : sortir proprement de la boucle → retour menu
    trap '_STATS_EXIT=1' INT

    # Masquer curseur + vider écran
    _tty_write "\033[?25l"
    clear

    local _REFRESH=3    # secondes entre deux rafraîchissements auto
    local _ELAPSED=0

    while [ "$_STATS_EXIT" -eq 0 ]; do

      # Redessiner depuis le haut sans effacer (évite le flash)
      _tty_write "\033[1;1H"
      TCOLS=$(_term_cols)
      _stats_draw_content "$TCOLS" 2>/dev/null

      # Barre de commandes
      printf "\n"
      printf "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
      printf "  ${BOLD}[Entrée]${NC} Menu   ${BOLD}[r]${NC} Rafraîchir   ${BOLD}[q]${NC} Quitter   ${DIM}↻ %ds${NC}   \n" \
        $(( _REFRESH - _ELAPSED ))

      # ── Lecture d'une touche avec timeout 1s ──────────────────
      # read -t fonctionne nativement en bash sans manipulation stty
      # Retourne 1 si timeout (aucune touche), 0 si touche lue
      local KEY=""
      if [ -n "$_REAL_TTY" ]; then
        IFS= read -r -s -n1 -t1 KEY < "$_REAL_TTY" 2>/dev/null || true
      else
        IFS= read -r -s -n1 -t1 KEY 2>/dev/null || true
      fi

      # Incrémenter compteur de temps écoulé
      _ELAPSED=$(( _ELAPSED + 1 ))
      [ "$_ELAPSED" -ge "$_REFRESH" ] && _ELAPSED=0

      # Traiter la touche
      case "$KEY" in
        q|Q)
          _STATS_EXIT=2
          ;;
        $'\n'|$'\r')
          # Entrée → retour menu
          _STATS_EXIT=1
          ;;
        r|R)
          # Rafraîchir immédiatement
          _ELAPSED=0
          ;;
        # Toute autre touche ou timeout → reboucler
      esac

    done

    # ── Nettoyage ─────────────────────────────────────────────
    trap - INT
    _stats_restore_term
    rm -f "$_HUD_STAT_FILE" "/tmp/ia_hud_net_$$.stat" 2>/dev/null || true
    clear

    # Action selon la raison de sortie
    if [ "$_STATS_EXIT" -eq 2 ]; then
      echo -e "${CYAN}Au revoir !${NC}"
      exit 0
    fi
    # _STATS_EXIT=1 → return 0 → retour au menu (ci-dessous)

  else
    # ────────────────────────────────────────────────────────
    # MODE NON-INTERACTIF : sortie texte une seule fois
    # Parfait pour SSH sans TTY, pipe, cron, nohup
    # ────────────────────────────────────────────────────────
    warn "Terminal non-interactif détecté — affichage texte unique (pas de rafraîchissement)"
    echo ""
    _stats_draw_content "$TCOLS" 2>/dev/null
    echo ""
    info "Pour le mode rafraîchissement, lance le script dans un terminal interactif."
    rm -f "$_HUD_STAT_FILE" "/tmp/ia_hud_net_$$.stat" 2>/dev/null || true
  fi
}


# ════════════════════════════════════════════════════════════════════
