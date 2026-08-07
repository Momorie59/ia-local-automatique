#!/usr/bin/env bash
# Vérification et mise à jour
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 6295-6831)

#  FONCTION : VÉRIFICATION & MAJ (Ollama + Open WebUI + Modèles)
# ================================================================

menu_updates() {
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  title "VÉRIFICATION & MISE À JOUR"
  load_config   # déclare HW/CFG/PLAN/PLAN_DESC/PLAN_REBOOT avant de sourcer
  declare -gA HW=()

  # Vérification connexion réseau
  step "Vérification réseau"
  if ! ping -c1 -W3 8.8.8.8 &>/dev/null 2>&1; then
    warn "Pas de connexion Internet — impossible de vérifier les mises à jour."
    return 0
  fi
  ok "Connexion Internet disponible"

  # ── Résumé des versions actuelles ──────────────────────────
  echo ""
  step "Versions actuellement installées"

  local OLLAMA_LOCAL="" OLLAMA_REMOTE="" OLLAMA_STATUS=""
  local WEBUI_LOCAL=""  WEBUI_REMOTE=""  WEBUI_STATUS=""
  local SYS_UPDATES=0

  # Ollama version locale — normaliser pour éviter les faux positifs
  if command -v ollama &>/dev/null; then
    # Extraire X.Y.Z et supprimer tout suffixe/espace résiduel
    OLLAMA_LOCAL=$(ollama --version 2>/dev/null       | grep -oP '\d+\.\d+\.\d+' | head -1       | tr -d '[:space:]' || echo "?")
    # Supprimer suffixe pré-release éventuel (-rc1, -beta, etc.)
    OLLAMA_LOCAL="${OLLAMA_LOCAL%%-*}"
    OLLAMA_LOCAL="${OLLAMA_LOCAL:-?}"
    ok "Ollama installé : v$OLLAMA_LOCAL"
  else
    warn "Ollama : non installé"
    OLLAMA_LOCAL="non installé"
  fi

  # Open WebUI version locale (via Docker)
  # Méthode robuste : label de version en priorité, puis digest si absent (cas fréquent avec :main)
  local WEBUI_LOCAL_DIGEST=""
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    local WEBUI_RUNNING
    WEBUI_RUNNING=$(docker inspect --format='{{.State.Status}}' open-webui 2>/dev/null || echo "?")

    # Essai via label standard
    WEBUI_LOCAL=$(docker inspect open-webui 2>/dev/null \
      | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); \
        labels=d[0].get('Config',{}).get('Labels',{}); \
        v=labels.get('org.opencontainers.image.version', \
          labels.get('build_version','')); \
        print(v if v else '')\nexcept: print(chr(63))" 2>/dev/null || echo "")

    # Si label absent (cas fréquent avec :main), on utilise le digest court
    if [ -z "$WEBUI_LOCAL" ] || [ "$WEBUI_LOCAL" = "?" ]; then
      WEBUI_LOCAL=$(docker inspect open-webui 2>/dev/null \
        | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); \
          img=d[0].get('Image',''); \
          print(img[7:26] if img.startswith('sha256:') else img[:12])\nexcept: print(chr(63))" \
        2>/dev/null || echo "?")
      WEBUI_LOCAL_DIGEST="$WEBUI_LOCAL"
      ok "Open WebUI installé — digest local: ${WEBUI_LOCAL} (état: $WEBUI_RUNNING)"
    else
      ok "Open WebUI installé : v$WEBUI_LOCAL (état: $WEBUI_RUNNING)"
    fi
  else
    warn "Open WebUI : non installé"
    WEBUI_LOCAL="non installé"
  fi

  # Paquets système en attente
  SYS_UPDATES=$(pkg_count_upgradable)
  # Forcer entier propre (évite erreur bash "[: entier attendu")
  SYS_UPDATES=$(echo "$SYS_UPDATES" | tr -cd '0-9' | head -c 6)
  SYS_UPDATES=${SYS_UPDATES:-0}
  if [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null; then
    warn "Système : $SYS_UPDATES paquet(s) en attente de mise à jour"
  else
    ok "Système : à jour"
  fi

  # ── Récupération des dernières versions disponibles ─────────
  echo ""
  step "Vérification des nouvelles versions disponibles"
  info "Interrogation des API GitHub / Docker Hub..."

  # Ollama : dernière version GitHub — normaliser identiquement à la version locale
  OLLAMA_REMOTE=$(curl -sf --max-time 8     "https://api.github.com/repos/ollama/ollama/releases/latest"     | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
tag = data.get('tag_name','?').lstrip('v').strip()
# Supprimer suffixe pré-release pour comparaison cohérente
tag = re.sub(r'[-+].*$', '', tag)
print(tag)
" 2>/dev/null || echo "?")

  # Open WebUI — récupération de la version distante
  # Pour :main on compare le digest distant vs local
  local IMG_USED="${CFG[docker_image]:-ghcr.io/open-webui/open-webui:main}"
  WEBUI_REMOTE=$(curl -sf --max-time 8 \
    "https://api.github.com/repos/open-webui/open-webui/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','?').lstrip('v'))" \
    2>/dev/null || echo "?")

  # Si on utilise :main : comparer le digest local vs le digest de l'image
  # actuellement disponible sur le registre (docker pull --dry-run equivalent)
  if [ -n "$WEBUI_LOCAL_DIGEST" ] && [[ "$IMG_USED" == *":main" ]]; then
    local WEBUI_REMOTE_DIGEST="?"

    # Méthode 1 : docker manifest inspect (disponible si Docker ≥ 20)
    if docker manifest inspect "$IMG_USED" &>/dev/null 2>&1; then
      WEBUI_REMOTE_DIGEST=$(docker manifest inspect "$IMG_USED" 2>/dev/null         | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # schemaVersion 2 : le digest est dans config.digest
    dig = d.get('config',{}).get('digest','')
    if not dig:
        # fallback : premier layer ou manifests[0]
        dig = (d.get('manifests') or [{}])[0].get('digest','')
    print(dig[7:26] if dig.startswith('sha256:') else dig[:19])
except: print('?')
" 2>/dev/null || echo "?")
    fi

    # Méthode 2 : ghcr.io API publique avec token anonyme
    if [ "$WEBUI_REMOTE_DIGEST" = "?" ]; then
      local _GHCR_TOKEN
      _GHCR_TOKEN=$(curl -sf --max-time 8         "https://ghcr.io/token?scope=repository:open-webui/open-webui:pull&service=ghcr.io"         | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))"         2>/dev/null || echo "")

      if [ -n "$_GHCR_TOKEN" ]; then
        WEBUI_REMOTE_DIGEST=$(curl -sf --max-time 10           "https://ghcr.io/v2/open-webui/open-webui/manifests/main"           -H "Authorization: Bearer $_GHCR_TOKEN"           -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json"           -D - -o /dev/null 2>/dev/null           | grep -i 'docker-content-digest:'           | grep -oP 'sha256:[a-f0-9]+' | head -1           | cut -c1-26 || echo "?")
      fi
    fi

    # Comparaison
    if [ "$WEBUI_REMOTE_DIGEST" != "?" ] && [ -n "$WEBUI_REMOTE_DIGEST" ]; then
      if [ "$WEBUI_LOCAL_DIGEST" = "$WEBUI_REMOTE_DIGEST" ]; then
        WEBUI_STATUS="${GREEN}✓ à jour${NC} (image :main identique)"
        WEBUI_REMOTE="$WEBUI_LOCAL"   # forcer égalité → pas de MAJ proposée
      else
        WEBUI_STATUS="${YELLOW}⬆ nouvelle image :main disponible${NC}"
        WEBUI_REMOTE="(nouvelle image :main)"
      fi
    else
      # Digest distant non récupérable → comparer via version GitHub comme fallback
      # (déjà dans WEBUI_REMOTE depuis l'appel précédent)
      info "Digest distant non disponible — comparaison via version GitHub"
      # On laisse WEBUI_STATUS vide → sera calculé par le bloc suivant
    fi
  fi

  # ── Tableau comparatif ───────────────────────────────────────
  echo ""
  echo -e "${BOLD}  ┌─────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │  COMPOSANT         INSTALLÉ        DISPONIBLE    STATUT │${NC}"
  echo -e "${BOLD}  ├─────────────────────────────────────────────────────────┤${NC}"

  # Ollama
  if [ "$OLLAMA_REMOTE" != "?" ] && [ "$OLLAMA_LOCAL" != "?" ] && [ "$OLLAMA_LOCAL" != "non installé" ]; then
    # Comparaison sémantique segment par segment (évite "0.3.9" > "0.3.12" en strcmp)
    _ver_le() {
      # retourne 0 si $1 <= $2 (version A <= version B)
      local A="$1" B="$2"
      [ "$A" = "$B" ] && return 0
      local LOWER; LOWER=$(printf '%s
%s
' "$A" "$B"         | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
      [ "$LOWER" = "$A" ]
    }
    if [ "$OLLAMA_LOCAL" = "$OLLAMA_REMOTE" ]; then
      OLLAMA_STATUS="${GREEN}✓ à jour${NC}"
    elif _ver_le "$OLLAMA_REMOTE" "$OLLAMA_LOCAL"; then
      # Remote <= local : local est plus récent (dev/custom build)
      OLLAMA_STATUS="${GREEN}✓ à jour${NC} ${DIM}(local: v${OLLAMA_LOCAL})${NC}"
      OLLAMA_REMOTE="$OLLAMA_LOCAL"   # éviter faux positif dans HAS_UPDATE
    else
      OLLAMA_STATUS="${YELLOW}⬆ MAJ dispo${NC}"
    fi
  elif [ "$OLLAMA_LOCAL" = "non installé" ]; then
    OLLAMA_STATUS="${RED}✗ absent${NC}"
  else
    OLLAMA_STATUS="${DIM}? inconnu${NC}"
  fi

  printf "  │  %-18s %-15s %-13s " "Ollama" "v${OLLAMA_LOCAL}" "v${OLLAMA_REMOTE}"
  echo -e "${OLLAMA_STATUS}│"

  # Open WebUI (calcul du statut si pas encore fait par la logique digest)
  if [ -z "${WEBUI_STATUS:-}" ]; then
    if [ "$WEBUI_REMOTE" != "?" ] && [ "$WEBUI_LOCAL" != "?" ] && [ "$WEBUI_LOCAL" != "non installé" ]; then
      if [ "$WEBUI_LOCAL" = "$WEBUI_REMOTE" ]; then
        WEBUI_STATUS="${GREEN}✓ à jour${NC}"
      else
        WEBUI_STATUS="${YELLOW}⬆ MAJ dispo${NC}"
      fi
    elif [ "$WEBUI_LOCAL" = "non installé" ]; then
      WEBUI_STATUS="${RED}✗ absent${NC}"
    else
      WEBUI_STATUS="${DIM}? inconnu${NC}"
    fi
  fi

  printf "  │  %-18s %-15s %-13s " "Open WebUI" "v${WEBUI_LOCAL}" "v${WEBUI_REMOTE}"
  echo -e "${WEBUI_STATUS}│"

  # Système
  if [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null; then
    SYS_STATUS="${YELLOW}⬆ $SYS_UPDATES paquets${NC}"
  else
    SYS_STATUS="${GREEN}✓ à jour${NC}"
  fi
  printf "  │  %-18s %-15s %-13s " "Système ($PKG_MGR)" "-" "-"
  echo -e "${SYS_STATUS}│"

  echo -e "${BOLD}  └─────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # ── Proposer les mises à jour disponibles ───────────────────
  local HAS_UPDATE=0

  # Déclencher HAS_UPDATE uniquement si une MAJ est réellement disponible
  # (évite faux positifs si version locale = version remote après normalisation)
  { [ "$OLLAMA_LOCAL" != "$OLLAMA_REMOTE" ] && [ "$OLLAMA_REMOTE" != "?" ]     && [ "$OLLAMA_LOCAL" != "non installé" ]; } && HAS_UPDATE=1 || true
  { [ "$WEBUI_LOCAL"  != "$WEBUI_REMOTE"  ] && [ "$WEBUI_REMOTE"  != "?" ]     && [ "$WEBUI_LOCAL"  != "non installé" ]; } && HAS_UPDATE=1 || true
  [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null && HAS_UPDATE=1 || true

  if [ "$HAS_UPDATE" -eq 0 ]; then
    log "Tout est à jour — aucune mise à jour nécessaire."
    return 0
  fi

  echo -e "${BOLD}  Que veux-tu mettre à jour ?${NC}\n"

  local OPT=1
  declare -A UPDATE_MENU=()

  if [ "$OLLAMA_LOCAL" != "$OLLAMA_REMOTE" ] && [ "$OLLAMA_REMOTE" != "?" ]; then
    echo -e "  ${GREEN}[$OPT]${NC}  Ollama        v$OLLAMA_LOCAL → v$OLLAMA_REMOTE"
    UPDATE_MENU[$OPT]="OLLAMA"
    OPT=$(( OPT + 1 ))
  fi

  if [ "$WEBUI_LOCAL" != "$WEBUI_REMOTE" ] && [ "$WEBUI_REMOTE" != "?" ]; then
    echo -e "  ${GREEN}[$OPT]${NC}  Open WebUI    v$WEBUI_LOCAL → v$WEBUI_REMOTE"
    UPDATE_MENU[$OPT]="WEBUI"
    OPT=$(( OPT + 1 ))
  fi

  if [ "${SYS_UPDATES:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "  ${GREEN}[$OPT]${NC}  Système $PKG_MGR   ($SYS_UPDATES paquets)"
    UPDATE_MENU[$OPT]="APT"
    OPT=$(( OPT + 1 ))
  fi

  echo -e "  ${GREEN}[$OPT]${NC}  Tout mettre à jour"
  local OPT_ALL=$OPT
  OPT=$(( OPT + 1 ))
  echo -e "  ${GREEN}[$OPT]${NC}  Annuler"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix (plusieurs possibles, ex: 1 2) : ${NC}")" UPD_CHOICES

  # Traiter les choix
  for CHOICE_U in $UPD_CHOICES; do
    local TARGET="${UPDATE_MENU[$CHOICE_U]:-}"
    [ "$CHOICE_U" = "$OPT_ALL" ] && TARGET="ALL"

    case "$TARGET" in

      OLLAMA|ALL)
        step "Mise à jour Ollama v$OLLAMA_LOCAL → v$OLLAMA_REMOTE"
        svc_stop ollama
        _install_ollama_secure
        svc_daemon_reload
        svc_restart ollama
        sleep 2
        local OLLAMA_NEW
        OLLAMA_NEW=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
        if [ "$OLLAMA_NEW" = "$OLLAMA_REMOTE" ]; then
          ok "Ollama mis à jour : v$OLLAMA_NEW ✓"
        else
          warn "Ollama version après MAJ : v$OLLAMA_NEW (attendu v$OLLAMA_REMOTE)"
        fi
        ;&  # fallthrough si ALL

      WEBUI|ALL)
        [ "$TARGET" = "OLLAMA" ] && continue  # skip si uniquement OLLAMA dans la boucle
        step "Mise à jour Open WebUI v$WEBUI_LOCAL → v$WEBUI_REMOTE"

        # Récupérer les paramètres depuis la config sauvegardée
        local WEBUI_DATA_CURR="${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}"
        local WEBUI_PORT_CURR="${CFG[webui_port]:-8080}"
        local WEBUI_NET_CURR="${CFG[docker_network]:-host}"

        # Toujours utiliser :main sauf config explicite autre
        local IMG="${CFG[docker_image]:-ghcr.io/open-webui/open-webui:main}"

        info "Image cible  : $IMG"
        info "Data      : $WEBUI_DATA_CURR"
        info "Réseau       : $WEBUI_NET_CURR"

        # ── ÉTAPE 1 : Backup des données AVANT toute modification ──
        echo ""
        warn "Les conversations et paramètres seront préservés si le volume est correct."
        info "Backup automatique en cours..."
        _backup_webui_before_update "$WEBUI_DATA_CURR"

        # ── ÉTAPE 2 : Pull de la nouvelle image ─────────────────────
        info "Téléchargement de la nouvelle image..."
        local DOCKER_PULL_OUTPUT_FILE="/tmp/docker_pull_$$.log"
        docker pull "$IMG" > "$DOCKER_PULL_OUTPUT_FILE" 2>&1 &
        local DOCKER_PULL_PID=$!
        local SPINNER_CHARS="/-\|"
        local SPIN_IDX=0

        while kill -0 "$DOCKER_PULL_PID" 2>/dev/null; do
          local CURRENT_PCT_LINE=$(grep -oE "[0-9]+%[[:space:]]+.*" "$DOCKER_PULL_OUTPUT_FILE" | tail -1)
          if [ -n "$CURRENT_PCT_LINE" ]; then
            printf "\r  Pull image : %-60s" "$CURRENT_PCT_LINE"
          else
            SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER_CHARS} ))
            printf "\r  Pull image : %s En attente..." "${SPINNER_CHARS:$SPIN_IDX:1}"
          fi
          sleep 0.2
        done
        wait "$DOCKER_PULL_PID"
        local DOCKER_PULL_EXIT_CODE=$?

        # Clear the line
        printf "\r%s\r" "$(tput el)"
        cat "$DOCKER_PULL_OUTPUT_FILE" >> "$LOG_FILE" # Append full output to main log
        rm "$DOCKER_PULL_OUTPUT_FILE"

        if [ "$DOCKER_PULL_EXIT_CODE" -ne 0 ]; then
          error "Échec du pull de l'image Docker pour Open WebUI."
          return 1
        else
          ok "Image Open WebUI tirée avec succès."
        fi

        # ── ÉTAPE 3 : Relancer avec les bons paramètres ─────────────
        info "Lancement du container Open WebUI..."
        if _docker_run_webui "$IMG" "$WEBUI_DATA_CURR" "$WEBUI_PORT_CURR" "$WEBUI_NET_CURR"; then
          ok "Open WebUI mis à jour et redémarré ✓"
          # Supprimer anciennes images non utilisées
          docker image prune -f 2>/dev/null || true
          ok "Anciennes images supprimées (espace libéré)"
        else
          warn "Open WebUI non démarré après MAJ."
          echo ""
          warn "Restauration depuis le backup disponible :"
          [ -f "$IA_STATE_DIR/last_webui_backup" ] &&             warn "  Backup : $(cat "$IA_STATE_DIR/last_webui_backup")"
          warn "  Commande manuelle : docker logs open-webui"
        fi
        ;;

      APT|ALL)
        { [ "$TARGET" = "OLLAMA" ] || [ "$TARGET" = "WEBUI" ]; } && continue
        step "Mise à jour système ($SYS_UPDATES paquets)"
        pkg_update
        pkg_upgrade
        pkg_autoremove
        ok "Système mis à jour."

        # Vérifier si reboot nécessaire après MAJ noyau
        if [ -f /var/run/reboot-required ]; then
          warn "Un reboot est recommandé suite à la mise à jour du noyau."
          confirm "Redémarrer maintenant ?" && reboot_and_resume "MENU" "MAJ système"
        fi
        ;;
    esac
  done

  echo ""
  log "Mise(s) à jour terminée(s). Log : $LOG_FILE"
}

menu_status() {
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  load_config   # déclare HW/CFG/PLAN/PLAN_DESC/PLAN_REBOOT avant de sourcer

  while true; do
    title "ÉTAT DU SYSTÈME IA"

    # ── Statut des services ──────────────────────────────────────
    step "Services"
    local _OLL_OK=0 _WUI_OK=0 _DOC_OK=0
    svc_active ollama 2>/dev/null  && _OLL_OK=1
    docker ps &>/dev/null          && _DOC_OK=1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && _WUI_OK=1

    local _WEBUI_PORT="${CFG[webui_port]:-8080}"
    local _OLLAMA_HOST="${CFG[ollama_host]:-0.0.0.0}"

    if [ "$_OLL_OK" -eq 1 ]; then
      local _NM; _NM=$(curl -sf --max-time 2 "http://127.0.0.1:11434/api/tags" 2>/dev/null         | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); print(len(d.get('models',[])))\nexcept: print(chr(63))" 2>/dev/null || echo "?")
      ok  "Ollama    : ${GREEN}actif${NC}  →  ${CYAN}http://${_OLLAMA_HOST}:11434${NC}  ${DIM}(${_NM} modèles)${NC}"
    else
      nok "Ollama    : ${RED}arrêté${NC}"
    fi

    if [ "$_WUI_OK" -eq 1 ]; then
      ok  "Open WebUI: ${GREEN}actif${NC}  →  ${CYAN}http://localhost:${_WEBUI_PORT}${NC}"
    else
      nok "Open WebUI: ${RED}arrêté${NC}"
    fi

    if [ "$_DOC_OK" -eq 1 ]; then
      local _NC; _NC=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
      ok  "Docker    : ${GREEN}actif${NC}  ${DIM}(${_NC} container(s))${NC}"
    else
      nok "Docker    : ${RED}arrêté${NC}"
    fi

    echo ""

    # ── Info réseau Ollama ──────────────────────────────────────
    if [ "${_OLLAMA_HOST}" = "0.0.0.0" ]; then
      local _LIP; _LIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
      info "Ollama accessible sur le réseau LAN : ${CYAN}http://${_LIP:-<IP>}:11434${NC}"
    fi

    # ── GPU ──────────────────────────────────────────────────────
    step "GPU"
    case "${HW[gpu_brand]:-none}" in
      nvidia) nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total                 --format=csv,noheader 2>/dev/null                 | awk -F', ' '{printf "  %-30s  Temp: %s°C  Charge: %s%%  VRAM: %s/%s Mo
",$1,$2,$3,$4,$5}'                 || warn "nvidia-smi indisponible" ;;
      amd)    command -v rocm-smi &>/dev/null && rocm-smi --showuse --showtemp 2>/dev/null                 | grep -v "^$" | head -6 | sed 's/^/  /' || lspci | grep -i amd | sed 's/^/  /' ;;
      *)      echo "  CPU only — pas de GPU dédié détecté" ;;
    esac

    echo ""
    step "Modèles installés"
    command -v ollama &>/dev/null && ollama list 2>/dev/null || warn "Ollama non disponible"

    echo ""
    step "Disques"
    df -h 2>/dev/null | grep -vE "^(tmpfs|devtmpfs|udev|/dev/loop|Filesystem)"       | awk '{printf "  %-22s %6s  utilisé: %5s  libre: %5s  (%s)
",$1,$2,$3,$4,$5}'

    echo ""
    step "RAM & Swap"
    free -h 2>/dev/null | awk '
      /^Mem:/  {printf "  RAM   : %s total  %s utilisé  %s libre
", $2,$3,$4}
      /^Swap:/ {printf "  Swap  : %s total  %s utilisé  %s libre
", $2,$3,$4}'

    # ══════════════════════════════════════════════════════════════
    # Sous-menu de contrôle des services
    # ══════════════════════════════════════════════════════════════
    echo ""
    echo -e "${BOLD}  ── Contrôle des services ──────────────────────────────${NC}"
    echo -e "  ${CYAN}[1]${NC}  Ollama     — ${GREEN}Démarrer${NC}"
    echo -e "  ${CYAN}[2]${NC}  Ollama     — ${RED}Arrêter${NC}"
    echo -e "  ${CYAN}[3]${NC}  Ollama     — ${YELLOW}Redémarrer${NC}"
    echo -e "  ${CYAN}[4]${NC}  Open WebUI — ${GREEN}Démarrer${NC}"
    echo -e "  ${CYAN}[5]${NC}  Open WebUI — ${RED}Arrêter${NC}"
    echo -e "  ${CYAN}[6]${NC}  Open WebUI — ${YELLOW}Redémarrer${NC}"
    echo -e "  ${CYAN}[7]${NC}  Docker     — ${YELLOW}Redémarrer${NC}"
    echo -e "  ${CYAN}[8]${NC}  Tout       — ${GREEN}Démarrer${NC}  ${DIM}(Docker → Ollama → WebUI)${NC}"
    echo -e "  ${CYAN}[9]${NC}  Tout       — ${RED}Arrêter${NC}   ${DIM}(WebUI → Ollama → Docker)${NC}"
    echo -e "  ${CYAN}[r]${NC}  Rafraîchir l'affichage"
    echo -e "  ${CYAN}[q]${NC}  Retour au menu principal"
    echo ""
    read -rp "$(echo -e "${YELLOW}  >>> Action : ${NC}")" _SVC_CHOICE

    case "${_SVC_CHOICE:-r}" in

      1)  # Démarrer Ollama
          step "Démarrage Ollama..."
          svc_start ollama && ok "Ollama démarré." || warn "Échec démarrage Ollama."
          sleep 2 ;;

      2)  # Arrêter Ollama
          step "Arrêt Ollama..."
          svc_stop ollama && ok "Ollama arrêté." || warn "Échec arrêt Ollama."
          sleep 1 ;;

      3)  # Redémarrer Ollama
          step "Redémarrage Ollama..."
          svc_restart ollama && ok "Ollama redémarré." || warn "Échec redémarrage Ollama."
          sleep 2 ;;

      4)  # Démarrer Open WebUI
          step "Démarrage Open WebUI..."
          if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
            docker start open-webui && ok "Open WebUI démarré." || warn "Échec démarrage WebUI."
            # Recréer le service systemd si absent
            if [ "$HAS_SYSTEMD" -eq 1 ] && [ ! -f /etc/systemd/system/open-webui.service ]; then
              step "Création du service systemd open-webui..."
              _install_webui_service "${CFG[webui_port]:-8080}" "${CFG[webui_dir]}"                 "${HW[gpu_docker_img]:-ghcr.io/open-webui/open-webui:main}"                 "${CFG[docker_network]:-host}"
            fi
          else
            warn "Container open-webui inexistant — utilise [Option 7] Réparer WebUI."
          fi
          sleep 2 ;;

      5)  # Arrêter Open WebUI
          step "Arrêt Open WebUI..."
          docker stop open-webui 2>/dev/null && ok "Open WebUI arrêté." || warn "Échec arrêt WebUI."
          sleep 1 ;;

      6)  # Redémarrer Open WebUI
          step "Redémarrage Open WebUI..."
          docker restart open-webui 2>/dev/null && ok "Open WebUI redémarré." || warn "Échec redémarrage WebUI."
          sleep 2 ;;

      7)  # Redémarrer Docker
          step "Redémarrage Docker..."
          warn "Ceci arrêtera TOUS les containers en cours."
          confirm "Confirmer le redémarrage Docker ?" && {
            svc_restart docker && ok "Docker redémarré." || warn "Échec redémarrage Docker."
          } || info "Annulé."
          sleep 3 ;;

      8)  # Tout démarrer
          step "Démarrage de tous les services..."
          svc_start docker  2>/dev/null || true; sleep 2
          svc_start ollama  2>/dev/null || true; sleep 2
          docker start open-webui 2>/dev/null || true; sleep 1
          ok "Séquence de démarrage terminée." ;;

      9)  # Tout arrêter
          step "Arrêt de tous les services..."
          confirm "Arrêter WebUI, Ollama et Docker ?" && {
            docker stop open-webui 2>/dev/null || true; sleep 1
            svc_stop ollama 2>/dev/null || true; sleep 1
            warn "Docker non arrêté (peut affecter d'autres containers)."
          } || info "Annulé." ;;

      q|Q) break ;;
      r|R|*) ;;  # Rafraîchir → reboucler
    esac
  done
}

# ================================================================
