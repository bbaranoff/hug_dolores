#!/usr/bin/env bash
set -Eefo pipefail
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO="${SUDO:-sudo}"
AUTO_GPU_LIMIT="${AUTO_GPU_LIMIT:-70}"
VOL="ollama"

log(){ printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
error(){ printf "\033[1;31m[✖]\033[0m %s\n" "$*"; exit 1; }
trap 'log "⚠️  Une étape a échoué, poursuite du script..."' ERR

log "=== Initialisation de Dolores (image: $IMAGE, modèle: $MODEL) ==="

# --- Dépendances de base ---
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y
  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https netcat-openbsd
else
  error "apt-get non trouvé — environnement non Debian/Ubuntu. Arrêt."
fi

# --- Docker ---
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

# --- Vérification GPU sur l’hôte ---
# --- Vérification GPU sur l’hôte ---
if ! command -v nvidia-smi >/dev/null 2>&1; then
  error "Aucun pilote NVIDIA détecté sur l’hôte.
Installez d’abord les pilotes NVIDIA officiels, puis relancez le script.
Référence : https://developer.nvidia.com/cuda-downloads"
fi

# --- GPU : limitation adaptative sécurisée ---
GPU_FLAGS=()
if nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe."

  # Récupère la puissance max, en filtrant les valeurs non numériques
  RAW_POWER=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1)
  if [[ "$RAW_POWER" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    MAX_POWER=${RAW_POWER%.*}
  else
    log "⚠️  Valeur de puissance non numérique (${RAW_POWER}), utilisation par défaut 100W."
    MAX_POWER=100
  fi

  # Ratio de limitation configurable
  AUTO_GPU_LIMIT=${AUTO_GPU_LIMIT:-70}
  if ! [[ "$AUTO_GPU_LIMIT" =~ ^[0-9]+$ ]]; then AUTO_GPU_LIMIT=70; fi
  LIMIT_POWER=$((MAX_POWER * AUTO_GPU_LIMIT / 100))

  log "Limitation logicielle estimée : ${LIMIT_POWER}W (sur ${MAX_POWER}W max, ${AUTO_GPU_LIMIT}% du total)"
  GPU_FLAGS+=(--gpus all)
else
  error "❌ Échec de la communication avec le GPU.
Vérifiez vos pilotes NVIDIA et relancez."
fi


# --- GPU : limitation adaptative ---
GPU_FLAGS=()
if nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe."
  MAX_POWER=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1)
  MAX_POWER=${MAX_POWER:-100}
  LIMIT_POWER=$((MAX_POWER * AUTO_GPU_LIMIT / 100))
  log "Limitation logicielle estimée : ${LIMIT_POWER}W (non forcée)"
  GPU_FLAGS+=(--gpus all)
else
  error "❌ Échec de la communication avec le GPU.
Vérifiez vos pilotes NVIDIA et relancez."
fi

# --- TTY ---
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then TTY_FLAGS="-it"; fi

# --- Image ---
log "Préparation du conteneur $IMAGE..."
$SUDO docker pull "$IMAGE" >/dev/null 2>&1 || log "Image locale utilisée."

# --- Lancement ---
log "Lancement du modèle $MODEL sur le port $PORT..."
$SUDO docker run $TTY_FLAGS --rm \
  "${GPU_FLAGS[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" bash -c "ollama serve >/dev/null 2>&1 & sleep 3; exec ollama run $MODEL" || \
  log "⚠️  Le conteneur n’a pas pu démarrer. Vérifie 'sudo docker ps -a'."

log "✅ Dolores est opérationnelle sur le port $PORT."
