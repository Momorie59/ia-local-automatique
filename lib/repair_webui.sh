#!/usr/bin/env bash
# Réparation rapide Open WebUI
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 7231-7744)

#  RÉPARATION RAPIDE OPEN WEBUI (après MAJ ratée)
# ================================================================

menu_repair_webui() {
  # Empêche les erreurs bénignes de ce menu de déclencher (plus tard,
  # dans un AUTRE menu) le trap ERR interactif qui peut quitter le programme.
  CURRENT_STEP="INIT"
  title "🔧 RÉPARATION OPEN WEBUI"

  echo -e "${YELLOW}  Cet outil recrée le container Open WebUI avec les bons paramètres.${NC}"
  echo -e "${YELLOW}  Tes conversations et paramètres sont dans le dossier de données.${NC}"
  echo ""

  # ── Détecter l'état actuel ──────────────────────────────────
  step "Diagnostic"
  load_config   # déclare HW/CFG/PLAN/PLAN_DESC/PLAN_REBOOT avant de sourcer

  DATA_DIR="${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}"
  PORT="${CFG[webui_port]:-8080}"
  IMG="${CFG[docker_image]:-ghcr.io/open-webui/open-webui:main}"
  NET="${CFG[docker_network]:-host}"

  # Container actuel
  CUR_STATE; CUR_STATE=$(docker inspect --format="{{.State.Status}}" open-webui 2>/dev/null || echo "absent")
  CUR_IMG;   CUR_IMG=$(docker inspect  --format="{{.Config.Image}}"  open-webui 2>/dev/null || echo "?")
  CUR_VOL;   CUR_VOL=$(docker inspect  --format="{{range .Mounts}}{{.Source}}{{end}}" open-webui 2>/dev/null || echo "?")
  CUR_NET;   CUR_NET=$(docker inspect  --format="{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" open-webui 2>/dev/null | tr ' ' '
' | grep OLLAMA || echo "?")
  CUR_ENV;   CUR_ENV=$(docker inspect  --format='{{range .Config.Env}}{{println .}}{{end}}' open-webui 2>/dev/null | grep "OLLAMA_BASE_URL" || echo "?")

  echo -e "  ${BOLD}Container actuel :${NC}"
  printf "    %-20s %s
" "État :"     "$CUR_STATE"
  printf "    %-20s %s
" "Image :"    "$CUR_IMG"
  printf "    %-20s %s
" "Volume :"   "$CUR_VOL"
  printf "    %-20s %s
" "Réseau :"   "$CUR_NET"
  printf "    %-20s %s
" "OLLAMA URL:" "$CUR_ENV"
  echo ""

  # ── Afficher/corriger les paramètres cibles ─────────────────
  step "Paramètres cibles (ta commande de référence)"
  echo ""
  echo -e "  ${BOLD}Dossier données :${NC} $DATA_DIR"

  # Vérifier si le dossier existe et contient des données
  if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    ok "Données trouvées dans $DATA_DIR"
    DATA_SIZE; DATA_SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
    info "Taille : $DATA_SIZE"
    # Lister les fichiers importants
    [ -f "$DATA_DIR/webui.db" ]       && ok "webui.db présent (conversations ✓)"
    [ -d "$DATA_DIR/uploads" ]         && ok "uploads/ présent"
    [ -f "$DATA_DIR/config.json" ]     && ok "config.json présent"
  else
    warn "Dossier $DATA_DIR vide ou absent !"
    echo ""
    echo -e "  ${RED}Possible causes :${NC}"
    echo -e "   - Le dossier a été créé avec un chemin différent"
    echo -e "   - Le disque /mnt/ia_toshiba n'est pas monté"
    echo ""
    # Chercher des données dans des emplacements alternatifs
    step "Recherche de données dans des emplacements alternatifs..."
    FOUND_DATA=""
    for SEARCH_PATH in       /mnt/ia_toshiba/open-webui       /mnt/ia_sdb/open-webui       /mnt/ia_storage/open-webui       /root/.open-webui       /var/lib/open-webui; do
      if [ -d "$SEARCH_PATH" ] && [ -f "$SEARCH_PATH/webui.db" ]; then
        ok "Données trouvées dans : $SEARCH_PATH"
        FOUND_DATA="$SEARCH_PATH"
      fi
    done
    # Chercher aussi dans les volumes Docker nommés
    docker volume ls 2>/dev/null | grep -i webui | while read -r _ VOL; do
      warn "Volume Docker trouvé : $VOL"
    done

    if [ -n "$FOUND_DATA" ]; then
      warn "Données trouvées dans $FOUND_DATA mais attendues dans $DATA_DIR"
      confirm "Utiliser $FOUND_DATA comme source ?" && DATA_DIR="$FOUND_DATA"
    fi
  fi

  # Vérifier que le disque est monté
  if [[ "$DATA_DIR" == /mnt/* ]]; then
    MOUNT_POINT; MOUNT_POINT=$(echo "$DATA_DIR" | cut -d/ -f1-3)
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
      warn "Le point de montage $MOUNT_POINT n'est PAS monté !"
      warn "Monte le disque d'abord : mount /dev/sdb $MOUNT_POINT"
      confirm "Tenter de monter automatiquement via fstab ?" &&         mount "$MOUNT_POINT" 2>/dev/null && ok "Monté." || warn "Échec montage."
    fi
  fi

  echo ""
  echo -e "  ${BOLD}Image Docker :${NC} $IMG"
  echo -e "  ${BOLD}Réseau      :${NC} $NET (--network=host recommandé)"
  echo -e "  ${BOLD}Ollama URL  :${NC} OLLAMA_BASE_URL=http://127.0.0.1:11434"
  echo ""

  # Permettre de modifier les paramètres
  read -rp "$(echo -e "${YELLOW}  >>> Dossier données [Entrée=$DATA_DIR] : ${NC}")" TMP
  [ -n "$TMP" ] && DATA_DIR="$TMP"

  read -rp "$(echo -e "${YELLOW}  >>> Image Docker    [Entrée=$IMG] : ${NC}")" TMP
  [ -n "$TMP" ] && IMG="$TMP"

  echo ""
  echo -e "  ${BOLD}La commande qui sera exécutée :${NC}"
  echo -e "  ${CYAN}docker run -d --network=host \${NC}"
  echo -e "  ${CYAN}  -p ${PORT}:8080 \${NC}"
  echo -e "  ${CYAN}  -v ${DATA_DIR}:/app/backend/data \${NC}"
  echo -e "  ${CYAN}  -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \${NC}"
  echo -e "  ${CYAN}  --name open-webui --restart always \${NC}"
  echo -e "  ${CYAN}  $IMG${NC}"
  echo ""

  confirm "Appliquer cette configuration ?" || { info "Annulé."; return 0; }

  # ── Vérifier qu'Ollama tourne ───────────────────────────────
  step "Vérification Ollama"
  if svc_active ollama 2>/dev/null || systemctl is-active --quiet ollama 2>/dev/null; then
    ok "Ollama actif"
    # Tester l'API
    if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags &>/dev/null; then
      ok "API Ollama répond sur :11434"
      MODEL_COUNT=$(curl -sf --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null \
        | python3 -c "import sys,json\ntry: d=json.load(sys.stdin); print(len(d.get('models',[])))\nexcept: print(chr(63))" 2>/dev/null || echo "?")
      ok "$MODEL_COUNT modèle(s) disponible(s) via Ollama"
    else
      warn "Ollama tourne mais l'API ne répond pas encore — attente..."
      sleep 5
    fi
  else
    warn "Ollama est arrêté — démarrage..."
    systemctl start ollama 2>/dev/null || svc_start ollama
    sleep 5
    curl -sf --max-time 3 http://127.0.0.1:11434/api/tags &>/dev/null       && ok "Ollama prêt" || warn "Ollama ne répond pas sur :11434"
  fi

  # ── Appliquer la réparation ─────────────────────────────────
  step "Recréation du container Open WebUI"
  _docker_run_webui "$IMG" "$DATA_DIR" "$PORT" "host"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$"; then
    echo ""
    echo -e "${GREEN}${BOLD}  ✓ Open WebUI réparé !${NC}"
    echo ""
    echo -e "  Accès   : ${CYAN}http://localhost:8080${NC}"
    echo -e "  Données : $DATA_DIR"
    echo ""

    # Sauvegarder la config corrigée
    CFG[webui_dir]="$DATA_DIR"
    CFG[docker_image]="$IMG"
    CFG[docker_network]="host"
    save_config
    ok "Configuration mise à jour."
  fi
}

# ── Menu principal ─────────────────────────────────────────────
# Nettoyer un éventuel état ERROR:INIT résiduel avant d'afficher le menu
# (l'erreur INIT n'est jamais bloquante, c'est de l'initialisation)
if [ -f "$IA_STATE_FILE" ]; then
  _STALE=$(cat "$IA_STATE_FILE" 2>/dev/null || echo "")
  if [[ "$_STALE" == "ERROR:INIT" ]]; then
    rm -f "$IA_STATE_FILE"
  fi
fi
unset _STALE



# ── Vérification de mise à jour du script installateur ───────────────────────
# Compare le hash local avec la version sur GitHub pour détecter les updates
_check_script_update() {
  local SCRIPT_PATH="${BASH_SOURCE[0]}"
  local GITHUB_RAW="${SCRIPT_UPDATE_URL:-}"   # Peut être défini dans config.env

  [ -z "$GITHUB_RAW" ] && return 0   # Pas d'URL configurée → skip silencieux

  local LOCAL_SHA; LOCAL_SHA=$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo "")
  local REMOTE_SHA
  REMOTE_SHA=$(curl -sf --max-time 10 "$GITHUB_RAW"     | sha256sum | cut -d' ' -f1 2>/dev/null || echo "")

  [ -z "$REMOTE_SHA" ] && return 0   # Pas de connexion → skip silencieux
  [ "$LOCAL_SHA" = "$REMOTE_SHA" ] && return 0   # Identique → rien à faire

  echo ""
  echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}║  🔄  MISE À JOUR DU SCRIPT DISPONIBLE                    ║${NC}"
  echo -e "  ${CYAN}║                                                          ║${NC}"
  echo -e "  ${CYAN}║  Une nouvelle version du script est disponible.          ║${NC}"
  echo -e "  ${CYAN}║  SHA256 local  : ${LOCAL_SHA:0:32}…  ║${NC}"
  echo -e "  ${CYAN}║  SHA256 distant: ${REMOTE_SHA:0:32}…  ║${NC}"
  echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if confirm "Télécharger et remplacer le script par la nouvelle version ?"; then
    local TMP_SCRIPT; TMP_SCRIPT=$(mktemp /tmp/ia-update-$$.sh)
    if curl -fsSL --max-time 60 "$GITHUB_RAW" -o "$TMP_SCRIPT"; then
      # Vérification intégrité du script téléchargé
      local DL_SHA; DL_SHA=$(sha256sum "$TMP_SCRIPT" | cut -d' ' -f1)
      if [ "$DL_SHA" = "$REMOTE_SHA" ]; then
        chmod 755 "$TMP_SCRIPT"
        cp "$TMP_SCRIPT" "$SCRIPT_PATH"
        ok "Script mis à jour. Redémarrez le script pour appliquer les changements."
        rm -f "$TMP_SCRIPT"
        exit 0
      else
        warn "SHA256 du fichier téléchargé ne correspond pas — mise à jour annulée."
        rm -f "$TMP_SCRIPT"
      fi
    else
      warn "Téléchargement échoué."
      rm -f "$TMP_SCRIPT"
    fi
  fi
}

# ── Lancement anticipé du dashboard au démarrage du script ───────────────────
# Démarre le dashboard en arrière-plan immédiatement pour que l'utilisateur
# puisse suivre l'installation via l'interface web dès le début.
_start_dashboard_early() {
  [ "$HAS_SYSTEMD" -ne 1 ] && return 0   # Pas systemd — pas de service
  local _PORT="${DASHBOARD_PORT:-7842}"
  local _LIP
  _LIP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')

  # Installer le script Python dashboard si absent
  if [ ! -f "$DASHBOARD_SCRIPT" ]; then
    install_dashboard_script 2>/dev/null || true
  fi

  # Créer le service systemd si absent
  if [ ! -f "/etc/systemd/system/${DASHBOARD_SERVICE}.service" ]; then
    install_dashboard_service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi

  # Démarrer/redémarrer si pas actif
  if ! svc_active "$DASHBOARD_SERVICE" 2>/dev/null; then
    systemctl start "$DASHBOARD_SERVICE" 2>/dev/null || true
    sleep 2
  fi

  # Affichage d'accueil
  clear
  # Vérifier silencieusement si une mise à jour du script est disponible
  _check_script_update &>/dev/null &
  local _URL_LOCAL="http://127.0.0.1:${_PORT}"
  local _URL_LAN=""
  [ -n "$_LIP" ] && [ "$_LIP" != "127.0.0.1" ] && _URL_LAN="http://${_LIP}:${_PORT}"

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   🤖  MOMORY - IA LOCAL — Installateur v5.0                         ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   Vous pouvez suivre et piloter l'installation de deux façons :      ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${GREEN}🌐  Via l'interface web${CYAN}  (recommandé)                            ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  printf  "   ${CYAN}║${NC}      ${BOLD}%-68s${CYAN}║${NC}
" "$_URL_LOCAL"
  if [ -n "$_URL_LAN" ]; then
  printf  "   ${CYAN}║${NC}      ${BOLD}%-68s${CYAN}║${NC}
" "$_URL_LAN  ← réseau local"
  fi
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║      Ouvrez cette adresse dans votre navigateur.                    ║${NC}"
  echo -e "${CYAN}║      La progression s'affichera en temps réel sur le dashboard.     ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${YELLOW}⌨️   Via ce terminal${CYAN}  (mode classique)                             ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║      Continuez ici pour une installation guidée en ligne de         ║${NC}"
  echo -e "${CYAN}║      commande. Les deux modes sont synchronisés en temps réel.      ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${YELLOW}🔐  Accès Administration (onglet ⚙️ du dashboard web)${CYAN}             ║${NC}"
  echo -e "${CYAN}║                                                                      ║${NC}"
  local _ADM_USER="admin" _ADM_IS_DEFAULT=1
  if [ -f "$IA_CREDS_FILE" ]; then
    _ADM_USER=$(python3 -c "import json; d=json.load(open('$IA_CREDS_FILE')); print(d.get('user','admin'))" 2>/dev/null || echo "admin")
    _ADM_IS_DEFAULT=$(python3 -c "import json,hashlib; d=json.load(open('$IA_CREDS_FILE')); print(1 if d.get('hash')==hashlib.sha256(b'ia-local-admin').hexdigest() else 0)" 2>/dev/null || echo "1")
  fi
  printf  "   ${CYAN}║${NC}      Login    : ${BOLD}%-53s${CYAN}║${NC}
" "$_ADM_USER"
  if [ "$_ADM_IS_DEFAULT" = "1" ]; then
  printf  "   ${CYAN}║${NC}      Password : ${YELLOW}%-53s${CYAN}║${NC}
" "ia-local-admin  ← À CHANGER !"
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}║   ${RED}⚠  Mot de passe par défaut — changez-le dans Administration !${CYAN}   ║${NC}"
  else
  printf  "   ${CYAN}║${NC}      Password : ${GREEN}%-53s${CYAN}║${NC}
" "(mot de passe personnalisé ✓)"
  fi
  echo -e "${CYAN}║                                                                      ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Tentative d'ouvrir automatiquement le navigateur (si desktop)
  if command -v xdg-open &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$_URL_LOCAL" &>/dev/null & disown
    echo -e "  ${GREEN}✓${NC}  Navigateur ouvert automatiquement"
  else
    echo -e "  ${YELLOW}→${NC}  Copiez l'URL ci-dessus dans votre navigateur pour accéder au dashboard"
  fi

  echo ""
  read -rp "$(echo -e "${YELLOW}  Appuyez sur Entrée pour continuer dans le terminal...${NC}")" _WPAUSE
}



# ── Mode --dry-run ────────────────────────────────────────────────────────────
# Simule l'installation sans rien modifier : analyse le matériel, construit
# le plan, affiche ce qui serait fait, mais n'exécute aucune commande système.
DRY_RUN=0
_dry_run_check() {
  [ "$DRY_RUN" -eq 1 ]
}

run_dry_run() {
  DRY_RUN=1
  title "MODE DRY-RUN — Simulation de l'installation"
  echo -e "  ${YELLOW}Aucune modification ne sera apportée au système.${NC}"
  echo -e "  ${DIM}Ce mode analyse le matériel et affiche le plan d'installation.${NC}"
  echo ""

  # Analyse complète (lecture seule — pas d'effets de bord)
  analyse_hardware

  # Poser les questions de config sans appliquer
  configure_infra

  # Construire le plan
  build_install_plan

  echo ""
  title "📋 PLAN D'INSTALLATION (simulation)"
  echo -e "  ${BOLD}${#PLAN[@]} étapes seraient exécutées :${NC}"
  echo ""
  local IDX=1
  for STEP in "${PLAN[@]}"; do
    local DESC="${PLAN_DESC[$STEP]:-}"
    local REBOOT="${PLAN_REBOOT[$STEP]:-non}"
    local REBOOT_TAG=""
    [ "$REBOOT" = "oui" ] && REBOOT_TAG=" ${YELLOW}[REBOOT]${NC}"
    printf "  ${GREEN}%2d.${NC}  ${BOLD}%-20s${NC}  ${DIM}%s${NC}%b
"       "$IDX" "$STEP" "$DESC" "$REBOOT_TAG"
    IDX=$(( IDX + 1 ))
  done
  echo ""
  echo -e "  ${CYAN}→ Aucune modification effectuée. Relancez sans --dry-run pour installer.${NC}"
  echo ""
  DRY_RUN=0
}

# ── Sauvegarde automatique avant mise à jour majeure ─────────────────────────
# Crée une archive compressée des données critiques avant toute opération
# destructive : MAJ WebUI, MAJ Ollama, réinstallation.
_auto_backup_before_update() {
  local REASON="${1:-update}"
  local BACKUP_BASE="${CFG[backup_dir]:-/mnt/ia_toshiba/backups}"
  local STAMP; STAMP=$(date +%Y%m%d_%H%M%S)
  local BACKUP_DIR="$BACKUP_BASE/auto_${REASON}_${STAMP}"

  info "Sauvegarde automatique avant $REASON..."
  mkdir -p "$BACKUP_DIR" 2>/dev/null || { warn "Impossible de créer le répertoire de backup."; return 0; }

  local SAVED=0

  # Données WebUI (conversations, paramètres, utilisateurs)
  local WEBUI_DATA="${CFG[webui_dir]:-/mnt/ia_toshiba/open-webui}"
  if [ -d "$WEBUI_DATA" ] && [ "$(ls -A "$WEBUI_DATA" 2>/dev/null)" ]; then
    cp -r "$WEBUI_DATA" "$BACKUP_DIR/webui-data" 2>/dev/null && SAVED=$(( SAVED + 1 )) || true
  fi

  # Modèles Ollama (seulement les métadonnées + blobs manifest — pas les poids)
  local OLLAMA_DATA="${CFG[ollama_dir]:-/mnt/ia_toshiba/ollama}"
  if [ -d "$OLLAMA_DATA/manifests" ]; then
    mkdir -p "$BACKUP_DIR/ollama-manifests"
    cp -r "$OLLAMA_DATA/manifests" "$BACKUP_DIR/ollama-manifests/" 2>/dev/null && SAVED=$(( SAVED + 1 )) || true
  fi

  # Configuration de l'installateur
  [ -f "$IA_CONFIG_FILE" ] && cp "$IA_CONFIG_FILE" "$BACKUP_DIR/" 2>/dev/null && SAVED=$(( SAVED + 1 )) || true
  # Copier les credentials avec permissions strictes (contient hash SHA256)
  if [ -f "$IA_CREDS_FILE" ]; then
    cp "$IA_CREDS_FILE" "$BACKUP_DIR/admin-credentials" 2>/dev/null &&       chmod 600 "$BACKUP_DIR/admin-credentials" 2>/dev/null &&       SAVED=$(( SAVED + 1 )) || true
  fi

  chmod -R 600 "$BACKUP_DIR" 2>/dev/null || true  # Backup lisible root uniquement

  if [ $SAVED -gt 0 ]; then
    local SIZE; SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "?")
    ok "Backup créé : $BACKUP_DIR ($SIZE)"
    echo "$BACKUP_DIR" > "$IA_STATE_DIR/last_auto_backup"
  else
    rmdir "$BACKUP_DIR" 2>/dev/null || true
    info "Rien à sauvegarder."
  fi

  # Garder seulement les 5 derniers backups automatiques
  ls -dt "$BACKUP_BASE"/auto_* 2>/dev/null | tail -n +6 | xargs rm -rf 2>/dev/null || true
}

# ── Gestion des arguments de ligne de commande ───────────────────────────────
for _ARG in "$@"; do
  case "$_ARG" in
    --dry-run|-n)
      detect_os 2>/dev/null || true
      run_dry_run; exit 0 ;;
    --version|-v)
      echo "Momory - IA Local Installer v5.0 — Auteur: Momorie"; exit 0 ;;
    --check-update)
      SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-}"
      _check_script_update; exit 0 ;;
    --web-install)
      # Lancement non-interactif depuis l'interface web
      # Le script s'exécute sans menu : analyse + backend auto + plan + install
      detect_os 2>/dev/null || true
      analyse_hardware 2>/dev/null || true
      CFG[backend]="${CFG[backend]:-ollama}"
      HW[backend]="${HW[backend]:-ollama}"
      run_full_install "ANALYSE"
      exit 0 ;;

    --help|-h)
      echo "Usage: sudo bash $0 [OPTIONS]"
      echo "Options:"
      echo "  --dry-run, -n       Simuler l'installation sans rien modifier"
      echo "  --version, -v       Afficher la version"
      echo "  --check-update      Vérifier si une MAJ du script est disponible"
      echo "  --help, -h          Afficher cette aide"
      exit 0 ;;
  esac
done

_start_dashboard_early

while true; do
  title "INSTALLATEUR MOMORY - IA LOCAL v5.0"

  # Afficher un indicateur si un état d'erreur est présent
  _MENU_STATE=$(cat "$IA_STATE_FILE" 2>/dev/null || echo "")
  if [[ "$_MENU_STATE" == ERROR:* ]]; then
    echo -e "  ${RED}⚠  État d'erreur détecté : ${BOLD}${_MENU_STATE}${NC}"
    echo -e "  ${DIM}  Utilise [0] pour effacer si tout fonctionne correctement.${NC}"
    echo ""
  fi

  echo -e "  ${GREEN}[1]${NC}  Installation complète"
  echo -e "  ${GREEN}[2]${NC}  Gérer les modèles IA"
  echo -e "  ${GREEN}[3]${NC}  Vérifier & appliquer les mises à jour"
  echo -e "  ${GREEN}[4]${NC}  Réinstaller un composant"
  echo -e "  ${GREEN}[5]${NC}  État du système"
  echo -e "  ${GREEN}[6]${NC}  Nettoyage complet (clean install)"
  echo -e "  ${RED}[7]${NC}  ${BOLD}Réparer Open WebUI${NC}  ${DIM}← si conversations perdues ou modèles inaccessibles${NC}"
  echo -e "  ${GREEN}[8]${NC}  Voir les logs"
  echo -e "  ${CYAN}[s]${NC}  ${BOLD}Stats système en temps réel${NC}  ${DIM}← CPU · RAM · GPU · Services · Réseau${NC}"
  echo -e "  ${CYAN}[d]${NC}  ${BOLD}Dashboard web${NC}  ${DIM}← Stats temps réel sur http://localhost:${DASHBOARD_PORT:-7842}${NC}"
  echo -e "  ${YELLOW}[0]${NC}  ${BOLD}Effacer l'état d'erreur${NC}  ${DIM}← si tout fonctionne mais une erreur est affichée${NC}"
  echo -e "  ${GREEN}[9]${NC}  Quitter"
  echo ""
  read -rp "$(echo -e "${YELLOW}  >>> Choix [0-9/s/d] : ${NC}")" CHOICE
  case "$CHOICE" in
    1) run_full_install "ANALYSE" ;;
    2) menu_models        ;;
    3) menu_updates       ;;
    4) menu_reinstall     ;;
    5) menu_status        ;;
    6) clean_install      ;;
    7) menu_repair_webui  ;;
    s|S) menu_stats_live  ;;
    d|D) menu_dashboard   ;;
    8)
      echo -e "\n${BOLD}Logs disponibles :${NC}"
      ls -lht "$IA_LOG_DIR"/*.log 2>/dev/null | head -10 || warn "Aucun log trouvé."
      echo ""
      read -rp "$(echo -e "${YELLOW}  >>> Voir le log (Entrée = dernier, ou nom fichier) : ${NC}")" LOG_CHOICE
      LOG_TO_VIEW="${LOG_CHOICE:-$LOG_LATEST}"
      [ -f "$LOG_TO_VIEW" ] && less "$LOG_TO_VIEW" || warn "Fichier introuvable."
      ;;
    0)
      title "🧹 NETTOYAGE DE L'ÉTAT D'ERREUR"
      _CUR=$(cat "$IA_STATE_FILE" 2>/dev/null || echo "(aucun état)")
      echo -e "  ${BOLD}État actuel :${NC} $_CUR"
      echo ""
      if [ "$_CUR" = "(aucun état)" ] || [ -z "$_CUR" ]; then
        ok "Aucun état d'erreur à effacer."
      else
        echo -e "  ${YELLOW}Vérification rapide des services...${NC}"
        _CL_DOCKER=$(command -v docker &>/dev/null && docker ps &>/dev/null && echo "oui" || echo "non")
        _CL_OLLAMA=$(command -v ollama &>/dev/null && systemctl is-active --quiet ollama 2>/dev/null && echo "oui" || echo "non")
        _CL_WEBUI=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^open-webui$" && echo "oui" || echo "non")
        [ "$_CL_DOCKER" = "oui" ] && ok "Docker    : actif" || warn "Docker    : inactif"
        [ "$_CL_OLLAMA" = "oui" ] && ok "Ollama    : actif" || warn "Ollama    : inactif"
        [ "$_CL_WEBUI"  = "oui" ] && ok "Open WebUI : actif" || warn "Open WebUI : inactif"
        echo ""
        confirm "Effacer l'état d'erreur ($_CUR) ?" && {
          rm -f "$IA_STATE_FILE" "$IA_STATE_DIR/errors.log"
          ok "État effacé. Le script démarrera normalement au prochain lancement."
        } || info "Annulé."
      fi
      echo ""
      read -rp "$(echo -e "${DIM}  Appuie sur Entrée pour continuer...${NC}")" _PAUSE
      ;;
    9) hud_stop 2>/dev/null || true; clear; echo -e "${CYAN}Au revoir !${NC}\n"; exit 0 ;;
    *) warn "Choix invalide." ;;
  esac
done