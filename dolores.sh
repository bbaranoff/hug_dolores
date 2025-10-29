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
# Ajoute ce réglage en haut avec les autres (ON par défaut = progression visible)
PULL_PROGRESS="${PULL_PROGRESS:-1}"

log()   { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[✖]\033[0m %s\n" "$*"; exit 1; }
trap 'log "⚠️  Une étape a échoué, poursuite du script..."' ERR

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
    $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
$SUDO systemctl restart docker || true

# === Étape 3 : Détection GPU ===
GPU_FLAG=()
VRAM_GB=0

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe."
  GPU_FLAG=(--gpus all)
  RAW_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || echo 0)
  VRAM_GB=$((RAW_VRAM / 1024))
  log "VRAM détectée : ${VRAM_GB} Go"
else
  log "⚠️  Aucun GPU NVIDIA détecté — passage en mode CPU uniquement."
fi

# === Étape 4 : Ajustement du modèle selon VRAM ===
if (( VRAM_GB <= 0 )); then
  CONTEXT=2048
  CACHE_TYPE="q4_0"
else
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
fi

# === Étape 5 : Calcul de l’overhead GPU (si GPU présent) ===
OVERHEAD=268435456  # 256 MiB par défaut

if (( VRAM_GB > 0 )); then
  VRAM_MB=$((VRAM_GB * 1024))
  OVERHEAD_PCT=5
  if pgrep -x Xorg >/dev/null 2>&1 || pgrep -x Xwayland >/dev/null 2>&1; then
    OVERHEAD_PCT=8
  fi
  MIN_OVERHEAD_MB=256
  MAX_OVERHEAD_MB=$(( VRAM_MB / 4 ))
  CALC_OVERHEAD_MB=$(( VRAM_MB * OVERHEAD_PCT / 100 ))
  (( CALC_OVERHEAD_MB < MIN_OVERHEAD_MB )) && CALC_OVERHEAD_MB=$MIN_OVERHEAD_MB
  (( CALC_OVERHEAD_MB > MAX_OVERHEAD_MB )) && CALC_OVERHEAD_MB=$MAX_OVERHEAD_MB
  OVERHEAD=$(( CALC_OVERHEAD_MB * 1024 * 1024 ))
  log "Overhead GPU calculé : ${CALC_OVERHEAD_MB} MiB (${OVERHEAD} bytes)"
else
  log "Mode CPU — aucun overhead GPU requis."
fi

# log "Préparation du conteneur $IMAGE..."
# $SUDO docker pull "$IMAGE" >/dev/null 2>&1 || log "Image locale utilisée."

# Par celui-ci :
log "Préparation du conteneur $IMAGE..."
if [ "$PULL_PROGRESS" -eq 1 ]; then
  # Progression visible (barres de téléchargement, couches, etc.)
  $SUDO docker pull "$IMAGE" || log "Image locale déjà présente ou pull non nécessaire."
else
  # Mode silencieux si besoin
  $SUDO docker pull -q "$IMAGE" || log "Image locale utilisée."
fi

# === Étape 7 : Lancement du conteneur ===
log "Contexte=$CONTEXT | Cache=$CACHE_TYPE | Overhead=$OVERHEAD bytes"
log "Démarrage du conteneur $IMAGE sur le port $PORT..."

$SUDO docker run -it --rm "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  -e OLLAMA_CONTEXT_LENGTH="$CONTEXT" \
  -e OLLAMA_KV_CACHE_TYPE="$CACHE_TYPE" \
  -e OLLAMA_NUM_PARALLEL=1 \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  -e OLLAMA_GPU_OVERHEAD="$OVERHEAD" \
  "$IMAGE" \
  bash -lc 'ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run dolores'
