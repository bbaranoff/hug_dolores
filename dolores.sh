#!/usr/bin/env bash
set -Eeo pipefail

# === Réglages rapides ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO="${SUDO:-sudo}"
AUTO_GPU_LIMIT="${AUTO_GPU_LIMIT:-70}"
VOL="ollama"

# === Fonctions ===
log()   { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[✖]\033[0m %s\n" "$*"; exit 1; }
trap 'log "⚠️  Une étape a échoué, poursuite du script..."' ERR

# --- Helper : lecture VRAM robuste (renvoie des Go entiers) ---
get_gpu_mem_gb() {
  local raw

  # 1) Essai direct
  raw=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo $(( raw / 1024 ))
    return
  fi

  # 2) Essai avec unités (ex : “4096 MiB”)
  raw=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -n1 | tr -cd '0-9')
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo $(( raw / 1024 ))
    return
  fi

  # 3) Parse la table principale nvidia-smi
  raw=$(nvidia-smi 2>/dev/null | awk -F'/' '/MiB \//{gsub(/MiB/,"",$2); gsub(/[[:space:]]/,"",$2); print $2; exit}')
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo $(( raw / 1024 ))
    return
  fi

  # Fallback sûr
  echo 2
}

log "=== Initialisation de Dolores (image: $IMAGE, modèle: $MODEL) ==="

# === Étape 1 : Dépendances système ===
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y
  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https netcat-openbsd
else
  error "apt-get non trouvé — environnement non Debian/Ubuntu."
fi

# === Étape 2 : Docker ===
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
$SUDO systemctl restart docker || true

# === Étape 3 : GPU NVIDIA ===
if ! command -v nvidia-smi >/dev/null 2>&1; then
  error "Aucun pilote NVIDIA détecté sur l’hôte.
Installez les pilotes officiels : https://developer.nvidia.com/cuda-downloads"
fi

GPU_FLAGS=()
if nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe."

  RAW_POWER=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1)
  if [[ -z "$RAW_POWER" || "$RAW_POWER" == *"N/A"* || ! "$RAW_POWER" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log "⚠️  Puissance non lisible (${RAW_POWER:-vide}) → valeur par défaut 100 W."
    MAX_POWER=100
  else
    MAX_POWER=${RAW_POWER%.*}
  fi
  [[ "$AUTO_GPU_LIMIT" =~ ^[0-9]+$ ]] || AUTO_GPU_LIMIT=70
  LIMIT_POWER=$((MAX_POWER * AUTO_GPU_LIMIT / 100))
  log "Limite symbolique : ${LIMIT_POWER} W"
  GPU_FLAGS+=(--gpus all)
else
  error "❌ Échec de communication avec le GPU."
fi


# === Étape 6 : Image ===
log "Préparation du conteneur $IMAGE..."
$SUDO docker pull "$IMAGE" >/dev/null 2>&1 || log "Image locale utilisée."


log() { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }

log "=== Initialisation de Dolores (image: $IMAGE, modèle: $MODEL) ==="

# --- Détection VRAM totale ---
RAW_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || echo 0)
VRAM_MB=${RAW_VRAM:-0}
VRAM_GB=$((VRAM_MB / 1024))

if (( VRAM_GB == 0 )); then
  log "⚠️  GPU non détecté — passage en mode CPU."
  GPU_FLAG=()
else
  log "GPU NVIDIA détecté (${VRAM_GB} Go VRAM)"
  GPU_FLAG=(--gpus all)
fi

# --- Ajustement des paramètres ---
if (( VRAM_GB <= 4 )); then
  CONTEXT=2048
  CACHE_TYPE="q8_0"
elif (( VRAM_GB <= 8 )); then
  CONTEXT=4096
  CACHE_TYPE="q8_0"
else
  CONTEXT=8192
  CACHE_TYPE="f16"
fi

# --- Calcul dynamique de OLLAMA_GPU_OVERHEAD (en BYTES) ---

# VRAM totale en MiB
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)
: "${VRAM_MB:=0}"

# Pourcentage de base (5%). Si l'écran tourne sur le même GPU (Xorg/Xwayland), on met 8%.
OVERHEAD_PCT=5
if pgrep -x Xorg >/dev/null 2>&1 || pgrep -x Xwayland >/dev/null 2>&1; then
  OVERHEAD_PCT=8
fi

# Garde-fous : min 256 MiB, max = 25% de la VRAM
MIN_OVERHEAD_MB=256
MAX_FRACTION_DIV=4   # 1/4 de la VRAM

# Calcul en MB
CALC_OVERHEAD_MB=$(( VRAM_MB * OVERHEAD_PCT / 100 ))

# Clamping
# max autorisé
MAX_OVERHEAD_MB=$(( VRAM_MB / MAX_FRACTION_DIV ))
# applique bornes
if (( CALC_OVERHEAD_MB < MIN_OVERHEAD_MB )); then
  CALC_OVERHEAD_MB=$MIN_OVERHEAD_MB
fi
if (( CALC_OVERHEAD_MB > MAX_OVERHEAD_MB )); then
  CALC_OVERHEAD_MB=$MAX_OVERHEAD_MB
fi

# Conversion en BYTES pour OLLAMA_GPU_OVERHEAD
OVERHEAD=$(( CALC_OVERHEAD_MB * 1024 * 1024 ))

echo "[+] Overhead GPU calculé : ${CALC_OVERHEAD_MB} MiB (${OVERHEAD} bytes) (VRAM=${VRAM_MB} MiB, pct=${OVERHEAD_PCT}%)"


log "Contexte=$CONTEXT | Cache=$CACHE_TYPE | Overhead=$OVERHEAD bytes"

# --- Lancement du conteneur ---
log "Démarrage du conteneur $IMAGE sur le port $PORT..."

sudo docker run -it --rm --gpus all \
  -p "$PORT:$PORT" \
  -v ollama:/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  -e OLLAMA_CONTEXT_LENGTH="$CONTEXT" \
  -e OLLAMA_KV_CACHE_TYPE="$CACHE_TYPE"\
  -e OLLAMA_NUM_PARALLEL=1 \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  -e OLLAMA_GPU_OVERHEAD="$OVERHEAD" \
  "$IMAGE" \
  bash -lc 'ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run dolores'
