#!/usr/bin/env bash
# Analyse complète du matériel
# (Module généré automatiquement depuis install_ia_local_V8.sh, lignes 4203-4541)

#  SECTION 1 : ANALYSE COMPLÈTE DU MATÉRIEL
# ================================================================

analyse_hardware() {
  title "ANALYSE COMPLÈTE DU MATÉRIEL"
  info "Analyse en cours, patiente quelques secondes...\n"

  declare -gA HW=()   # Hardware détecté
  declare -gA SYS=()  # État du système (ce qui est déjà installé)

  # ── CPU ─────────────────────────────────────────────────────────
  step "Processeur"
  HW[cpu_model]=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
  HW[cpu_cores]=$(nproc --all)
  HW[cpu_threads]=$(grep -c 'processor' /proc/cpuinfo)
  HW[cpu_arch]=$(uname -m)
  HW[cpu_vendor]=$(grep -m1 'vendor_id' /proc/cpuinfo | cut -d: -f2 | xargs)
  HW[cpu_avx]=$(grep -m1 'flags' /proc/cpuinfo | grep -c 'avx2' || echo "0")
  HW[cpu_freq_mhz]=$(grep -m1 'cpu MHz' /proc/cpuinfo | cut -d: -f2 | xargs | cut -d. -f1 || echo "?")

  ok "${HW[cpu_model]}"
  ok "${HW[cpu_cores]} cœurs physiques / ${HW[cpu_threads]} threads"
  [ "${HW[cpu_avx]}" = "1" ] && ok "AVX2 supporté (optimisations inférence CPU)" \
                               || warn "AVX2 non détecté — inférence CPU plus lente"

  # ── RAM ─────────────────────────────────────────────────────────
  step "Mémoire RAM"
  HW[ram_kb]=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  HW[ram_gb]=$(( HW[ram_kb] / 1024 / 1024 ))
  HW[ram_mb]=$(( HW[ram_kb] / 1024 ))
  HW[ram_free_gb]=$(( $(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
  HW[swap_gb]=$(( $(grep SwapTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))

  # Détail des barrettes si dmidecode disponible
  if command -v dmidecode &>/dev/null; then
    HW[ram_type]=$(dmidecode -t memory 2>/dev/null | grep -m1 'Type:' | grep -v 'Unknown' | awk '{print $2}' || echo "?")
    HW[ram_speed]=$(dmidecode -t memory 2>/dev/null | grep -m1 'Speed:' | awk '{print $2" "$3}' || echo "?")
    HW[ram_slots_used]=$(dmidecode -t memory 2>/dev/null | grep -c 'Size:.*MB\|Size:.*GB' || echo "?")
    ok "${HW[ram_gb]} Go ${HW[ram_type]} @ ${HW[ram_speed]} (${HW[ram_slots_used]} barrette(s))"
  else
    ok "${HW[ram_gb]} Go RAM disponible"
  fi

  [ "${HW[ram_gb]}" -lt 8 ]  && warn "RAM faible (<8 Go) — inférence limitée aux petits modèles"
  [ "${HW[ram_gb]}" -ge 16 ] && ok "RAM suffisante pour modèles 7-8B en CPU fallback"
  [ "${HW[ram_gb]}" -ge 32 ] && ok "RAM confortable — modèles 13B+ en CPU fallback possibles"

  # ── GPU ─────────────────────────────────────────────────────────
  step "Carte Graphique (GPU)"
  HW[gpu_brand]="none"
  HW[gpu_model]="Aucun GPU dédié"
  HW[gpu_vram_gb]=0
  HW[gpu_vram_source]="none"
  HW[gpu_driver_pkg]=""
  HW[gpu_driver_installed]="non"
  HW[gpu_docker_img]="ghcr.io/open-webui/open-webui:main"
  HW[gpu_docker_flags]=""
  HW[gpu_rocm_capable]=0
  HW[gpu_cuda_capable]=0

  local GPU_PCI=""
  GPU_PCI=$(lspci 2>/dev/null | grep -iE "VGA|3D controller|Display" || true)

  if echo "$GPU_PCI" | grep -qi "nvidia"; then
    HW[gpu_brand]="nvidia"
    HW[gpu_model]=$(echo "$GPU_PCI" | grep -i nvidia | head -1 | sed 's/.*: //' | sed 's/ (.*//')
    HW[gpu_cuda_capable]=1
    HW[gpu_docker_img]="ghcr.io/open-webui/open-webui:cuda"
    HW[gpu_docker_flags]="--gpus all"

    # Drivers déjà installés ?
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
      HW[gpu_driver_installed]="oui"
      local VRAM_MB
      VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
      HW[gpu_vram_gb]=$(( VRAM_MB / 1024 ))
      HW[gpu_vram_source]="nvidia-smi"
      HW[gpu_driver_current]=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "?")
      ok "Driver NVIDIA ${HW[gpu_driver_current]} déjà installé"
    else
      HW[gpu_driver_installed]="non"
      # VRAM depuis base de données
      _detect_vram_from_db "${HW[gpu_model]}"
      HW[gpu_vram_gb]=$VRAM_DB_RESULT
      HW[gpu_vram_source]="${VRAM_DB_SOURCE}"
    fi

    # Driver recommandé selon génération
    local M="${HW[gpu_model]}"
    if   echo "$M" | grep -qiE "RTX 50|B[0-9]{3}";                        then HW[gpu_driver_pkg]="nvidia-driver-570"
    elif echo "$M" | grep -qiE "RTX 40|Ada|L4[0-9]|H[0-9]{2}|A[0-9]{3}"; then HW[gpu_driver_pkg]="nvidia-driver-550"
    elif echo "$M" | grep -qiE "RTX 3[0-9]{3}|RTX 2[0-9]{3}|GTX 16[0-9]{2}"; then HW[gpu_driver_pkg]="nvidia-driver-545"
    elif echo "$M" | grep -qiE "GTX 10[0-9]{2}";                          then HW[gpu_driver_pkg]="nvidia-driver-535"
    elif echo "$M" | grep -qiE "GTX 9[0-9]{2}|GTX 7[0-9]{2}|GTX 8[0-9]{2}"; then HW[gpu_driver_pkg]="nvidia-driver-470"
    elif echo "$M" | grep -qiE "GTX [0-9]{3}[^0-9]|GT [0-9]{3}";         then HW[gpu_driver_pkg]="nvidia-driver-390"
    else HW[gpu_driver_pkg]="auto"; fi

    ok "${HW[gpu_model]}"
    ok "VRAM : ${HW[gpu_vram_gb]} Go (${HW[gpu_vram_source]})"
    ok "Driver recommandé : ${HW[gpu_driver_pkg]}"

  elif echo "$GPU_PCI" | grep -qiE "amd|radeon|advanced micro"; then
    HW[gpu_brand]="amd"
    HW[gpu_model]=$(echo "$GPU_PCI" | grep -iE "amd|radeon" | head -1 | sed 's/.*: //' | sed 's/ (.*//')

    if command -v rocm-smi &>/dev/null; then
      HW[gpu_driver_installed]="oui"
      local VRAM_AMD
      VRAM_AMD=$(rocm-smi --showmeminfo vram 2>/dev/null | grep "Total Memory" | awk '{print $NF}' | head -1 || echo "0")
      HW[gpu_vram_gb]=$(( VRAM_AMD / 1024 ))
      HW[gpu_vram_source]="rocm-smi"
    else
      _detect_vram_from_db "${HW[gpu_model]}"
      HW[gpu_vram_gb]=$VRAM_DB_RESULT
      HW[gpu_vram_source]="${VRAM_DB_SOURCE}"
    fi

    # ROCm compatible ?
    local M="${HW[gpu_model]}"
    if echo "$M" | grep -qiE "RX [5-9][0-9]{3}|RX 7[0-9]{3}|Vega|MI[0-9]|W[0-9]{4}"; then
      HW[gpu_rocm_capable]=1
      HW[gpu_docker_img]="ghcr.io/open-webui/open-webui:rocm"
      HW[gpu_docker_flags]="--device /dev/kfd --device /dev/dri --group-add video --group-add render"
    fi

    ok "${HW[gpu_model]}"
    ok "VRAM : ${HW[gpu_vram_gb]} Go (${HW[gpu_vram_source]})"
    [ "${HW[gpu_rocm_capable]}" = "1" ] && ok "ROCm compatible — accélération GPU disponible" \
                                         || warn "Carte ancienne — pas de ROCm, inférence CPU"

  elif echo "$GPU_PCI" | grep -qiE "intel.*arc"; then
    HW[gpu_brand]="intel"
    HW[gpu_model]=$(echo "$GPU_PCI" | grep -i "intel.*arc" | head -1 | sed 's/.*: //')
    _detect_vram_from_db "${HW[gpu_model]}"
    HW[gpu_vram_gb]=$VRAM_DB_RESULT
    ok "${HW[gpu_model]}"
    warn "Intel Arc : support IA partiel, inférence principalement CPU"
  else
    warn "Aucun GPU dédié détecté — inférence sur CPU uniquement"
  fi

  # ── STOCKAGE ────────────────────────────────────────────────────
  step "Stockage"
  declare -ga DISKS=()
  declare -gA DISK_SIZE DISK_MODEL DISK_TYPE DISK_HEALTH

  while IFS= read -r LINE; do
    local DNAME DSIZE DTYPE DMODEL
    DNAME=$(echo "$LINE" | awk '{print $1}')
    DSIZE=$(echo "$LINE" | awk '{print $2}')
    DTYPE=$(echo "$LINE" | awk '{print $3}')
    DMODEL=$(echo "$LINE" | awk '{$1=$2=$3=""; print $0}' | xargs)
    DISKS+=("/dev/$DNAME")
    DISK_SIZE["/dev/$DNAME"]="$DSIZE"
    DISK_MODEL["/dev/$DNAME"]="$DMODEL"
    DISK_TYPE["/dev/$DNAME"]="$DTYPE"

    # Santé SMART
    local SMART_STATUS="?"
    if command -v smartctl &>/dev/null; then
      SMART_STATUS=$(smartctl -H "/dev/$DNAME" 2>/dev/null | grep -oP 'PASSED|FAILED|OK' | head -1 || echo "?")
    fi
    DISK_HEALTH["/dev/$DNAME"]="$SMART_STATUS"

    # Détecter si SSD ou HDD
    local ROT
    ROT=$(cat "/sys/block/$DNAME/queue/rotational" 2>/dev/null || echo "?")
    [ "$ROT" = "0" ] && DTYPE="SSD" || [ "$ROT" = "1" ] && DTYPE="HDD"
    DISK_TYPE["/dev/$DNAME"]="$DTYPE"

    ok "/dev/$DNAME — $DSIZE ($DTYPE) — $DMODEL [SMART: $SMART_STATUS]"
  done < <(lsblk -dno NAME,SIZE,TYPE,MODEL | grep -v loop)

  # ── RÉSEAU ──────────────────────────────────────────────────────
  step "Réseau"
  HW[net_interfaces]=$(ip -o link show | grep -v "lo\|docker\|veth" | awk '{print $2}' | tr -d ':' | tr '\n' ' ' | sed 's/ *$//')
  HW[net_connected]="non"
  if ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    HW[net_connected]="oui"
    ok "Connexion Internet disponible"
  else
    warn "Pas de connexion Internet détectée"
    warn "Les téléchargements (drivers, modèles) seront impossibles"
  fi

  # ── SYSTÈME ─────────────────────────────────────────────────────
  step "Système d'exploitation"
  HW[os_name]=$(lsb_release -d 2>/dev/null | cut -f2 || echo "Inconnu")
  HW[os_version]=$(lsb_release -r 2>/dev/null | cut -f2 || echo "?")
  HW[os_codename]=$(lsb_release -c 2>/dev/null | cut -f2 || echo "?")
  HW[kernel]=$(uname -r)
  HW[arch]=$(uname -m)
  HW[uefi]=$([ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS")
  HW[secure_boot]=$(mokutil --sb-state 2>/dev/null | grep -oi 'enabled\|disabled' || echo "?")
  HW[user]="${SUDO_USER:-$USER}"
  HW[user_home]=$(eval echo "~${HW[user]}")

  ok "${HW[os_name]} (kernel ${HW[kernel]})"
  ok "Architecture : ${HW[arch]} | Boot : ${HW[uefi]} | Secure Boot : ${HW[secure_boot]}"

  # Secure Boot peut bloquer les drivers NVIDIA
  [ "${HW[secure_boot]}" = "enabled" ] && \
    warn "Secure Boot ACTIVÉ — peut bloquer les drivers NVIDIA/ROCm. Désactive-le dans le BIOS si problème."

  # ── CE QUI EST DÉJÀ INSTALLÉ ─────────────────────────────────
  step "Logiciels déjà installés"
  declare -gA SYS

  command -v docker &>/dev/null      && SYS[docker]="oui"        || SYS[docker]="non"
  command -v ollama &>/dev/null      && SYS[ollama]="oui"        || SYS[ollama]="non"
  command -v nvidia-smi &>/dev/null  && SYS[nvidia_driver]="oui" || SYS[nvidia_driver]="non"
  command -v rocm-smi &>/dev/null    && SYS[rocm]="oui"          || SYS[rocm]="non"
  dpkg -l 2>/dev/null | grep -q "nvidia-container-toolkit" \
                                     && SYS[nv_toolkit]="oui"    || SYS[nv_toolkit]="non"
  [ -f /swapfile ]                   && SYS[swapfile]="oui"      || SYS[swapfile]="non"

  SYS[ollama_version]=$(ollama --version 2>/dev/null | head -1 || echo "-")
  SYS[docker_version]=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo "-")

  [ "${SYS[docker]}" = "oui" ]       && ok "Docker ${SYS[docker_version]} installé"       || neutral "Docker        : non installé"
  [ "${SYS[ollama]}" = "oui" ]       && ok "Ollama ${SYS[ollama_version]} installé"       || neutral "Ollama        : non installé"
  [ "${SYS[nvidia_driver]}" = "oui" ] && ok "Driver NVIDIA installé"                       || neutral "Driver NVIDIA : non installé"
  [ "${SYS[rocm]}" = "oui" ]         && ok "ROCm installé"                                 || neutral "ROCm          : non installé"
  [ "${SYS[nv_toolkit]}" = "oui" ]   && ok "NVIDIA Container Toolkit installé"             || neutral "NV Toolkit    : non installé"
  [ "${SYS[swapfile]}" = "oui" ]     && ok "Swapfile existant"                              || neutral "Swapfile      : non configuré"
}

# ── Base de données VRAM ────────────────────────────────────────
_detect_vram_from_db() {
  local M="$1"
  VRAM_DB_RESULT=0
  VRAM_DB_SOURCE="db"

  # NVIDIA RTX 50xx
  echo "$M" | grep -qiE "RTX 5090"              && VRAM_DB_RESULT=32 && return
  echo "$M" | grep -qiE "RTX 5080"              && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 5070 Ti"           && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 5070 Super"        && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 5070[^TS ]|RTX 5070$" && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 5060 Ti"           && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 5060[^T ]|RTX 5060$" && VRAM_DB_RESULT=8 && return
  # NVIDIA RTX 40xx
  echo "$M" | grep -qiE "RTX 4090"              && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RTX 4080 Super"        && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4080[^S ]|RTX 4080$" && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4070 Ti Super"     && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4070 Ti[^S ]"      && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 4070 Super"        && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 4070[^TS ]|RTX 4070$" && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 4060 Ti 16"        && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RTX 4060 Ti[^1 ]|RTX 4060 Ti$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 4060[^T ]|RTX 4060$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 4050"              && VRAM_DB_RESULT=6  && return
  # NVIDIA RTX 30xx
  echo "$M" | grep -qiE "RTX 3090 Ti"           && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RTX 3090[^T ]|RTX 3090$" && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RTX 3080 Ti"           && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 3080 12"           && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 3080[^T1 ]|RTX 3080$" && VRAM_DB_RESULT=10 && return
  echo "$M" | grep -qiE "RTX 3070 Ti"           && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 3070[^T ]|RTX 3070$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 3060 Ti"           && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 3060[^T ]|RTX 3060$" && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RTX 3050"              && VRAM_DB_RESULT=8  && return
  # NVIDIA RTX 20xx
  echo "$M" | grep -qiE "RTX 2080 Ti"           && VRAM_DB_RESULT=11 && return
  echo "$M" | grep -qiE "RTX 2080 Super"        && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 2080[^TS ]|RTX 2080$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 2070 Super"        && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 2070[^S ]|RTX 2070$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "RTX 2060 Super"        && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX 2060[^S ]|RTX 2060$" && VRAM_DB_RESULT=6 && return
  # NVIDIA GTX 16xx
  echo "$M" | grep -qiE "GTX 1660 Ti"           && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 1660 Super"        && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 1660[^TS ]|GTX 1660$" && VRAM_DB_RESULT=6 && return
  echo "$M" | grep -qiE "GTX 1650 Super"        && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 1650[^S ]|GTX 1650$" && VRAM_DB_RESULT=4 && return
  # NVIDIA GTX 10xx
  echo "$M" | grep -qiE "GTX 1080 Ti"           && VRAM_DB_RESULT=11 && return
  echo "$M" | grep -qiE "GTX 1080[^T ]|GTX 1080$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "GTX 1070 Ti"           && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "GTX 1070[^T ]|GTX 1070$" && VRAM_DB_RESULT=8 && return
  echo "$M" | grep -qiE "GTX 1060 6"            && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 1060 3"            && VRAM_DB_RESULT=3  && return
  echo "$M" | grep -qiE "GTX 1060[^36 ]|GTX 1060$" && VRAM_DB_RESULT=6 && return
  echo "$M" | grep -qiE "GTX 1050 Ti"           && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 1050[^T ]|GTX 1050$" && VRAM_DB_RESULT=2 && return
  echo "$M" | grep -qiE "GTX 1030"              && VRAM_DB_RESULT=2  && return
  # NVIDIA GTX 9xx
  echo "$M" | grep -qiE "GTX 980 Ti"            && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "GTX 980[^T ]|GTX 980$" && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 970"               && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "GTX 960"               && VRAM_DB_RESULT=2  && return
  # AMD RX 7xxx
  echo "$M" | grep -qiE "RX 7900 XTX"           && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "RX 7900 GRE"           && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 7900 XT[^X ]|RX 7900 XT$" && VRAM_DB_RESULT=20 && return
  echo "$M" | grep -qiE "RX 7800 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 7700 XT"            && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RX 7600 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 7600[^X ]|RX 7600$" && VRAM_DB_RESULT=8 && return
  # AMD RX 6xxx
  echo "$M" | grep -qiE "RX 6950 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6900 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6800 XT"            && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6800[^X ]|RX 6800$" && VRAM_DB_RESULT=16 && return
  echo "$M" | grep -qiE "RX 6700 XT"            && VRAM_DB_RESULT=12 && return
  echo "$M" | grep -qiE "RX 6700[^X ]|RX 6700$" && VRAM_DB_RESULT=10 && return
  echo "$M" | grep -qiE "RX 6650 XT"            && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 6600 XT"            && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 6600[^X ]|RX 6600$" && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 6500 XT"            && VRAM_DB_RESULT=4  && return
  echo "$M" | grep -qiE "RX 6400"               && VRAM_DB_RESULT=4  && return
  # AMD RX 5xxx
  echo "$M" | grep -qiE "RX 5700 XT"            && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 5700[^X ]|RX 5700$" && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 5600 XT"            && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "RX 5500 XT 8"          && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RX 5500 XT[^8 ]"       && VRAM_DB_RESULT=4  && return
  # Professionnel
  echo "$M" | grep -qiE "A100.*80"              && VRAM_DB_RESULT=80 && return
  echo "$M" | grep -qiE "A100.*40"              && VRAM_DB_RESULT=40 && return
  echo "$M" | grep -qiE "H100.*80"              && VRAM_DB_RESULT=80 && return
  echo "$M" | grep -qiE "A40"                   && VRAM_DB_RESULT=48 && return
  echo "$M" | grep -qiE "A10[^0]|A10$"          && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "A30"                   && VRAM_DB_RESULT=24 && return
  echo "$M" | grep -qiE "A16"                   && VRAM_DB_RESULT=16 && return
  # Estimations par génération si non trouvé
  VRAM_DB_SOURCE="estimation"
  echo "$M" | grep -qiE "RTX [45][0-9]{3}"      && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "RTX [23][0-9]{3}"      && VRAM_DB_RESULT=8  && return
  echo "$M" | grep -qiE "GTX 1[0-9]{3}"         && VRAM_DB_RESULT=6  && return
  echo "$M" | grep -qiE "RX [5-7][0-9]{3}"      && VRAM_DB_RESULT=8  && return
  VRAM_DB_RESULT=4  # fallback minimal
}


# ══════════════════════════════════════════════════════════════════════
