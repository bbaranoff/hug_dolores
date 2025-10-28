#!/usr/bin/env bash
set -Eeo pipefail  # robuste sans casser sur variable vide

# === Réglages rapides (surchageables via env) ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"   # image Docker à lancer
MODEL="${MODEL:-dolores}"                      # modèle Ollama
PORT="${PORT:-11434}"                          # port hôte
VOLUME="${VOLUME:-ollama}"                     # volume persistant
SUDO="${SUDO:-sudo}"                           # préfixe sudo (vide = root)
AUTO_GPU_LIMIT="${AUTO_GPU_LIMIT:-70}"         # % limite puissance GPU
VOL="ollama"

# === Fonctions utilitaires ===
log() { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
trap 'log "⚠️  Une étape a échoué, poursuite du script..."' ERR

log "=== Initialisation de Dolores (image: $IMAGE, modèle: $MODEL) ==="

# === Étape 1 : Installation dépendances ===
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y

  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https netcat-openbsd

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

  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl restart docker || true
    $SUDO systemctl enable docker >/dev/null 2>&1 || true
  fi
else
  log "apt-get non trouvé — environnement non Debian/Ubuntu."
fi

# === Étape 2 : GPU NVIDIA (auto-limit + fallback CPU) ===
GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté → configuration du runtime Docker..."
  if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | $SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends nvidia-container-toolkit
    $SUDO nvidia-ctk runtime configure --runtime=docker
    $SUDO systemctl restart docker || true
  fi

  # Lecture des limites GPU avec valeurs de secours
  MAX_POWER=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1)
  MAX_POWER=${MAX_POWER:-100}
  if ! [[ "$MAX_POWER" =~ ^[0-9]+$ ]]; then MAX_POWER=100; fi
  LIMIT_POWER=$((MAX_POWER * AUTO_GPU_LIMIT / 100))

  log "Limitation GPU → ${LIMIT_POWER}W (sur ${MAX_POWER}W max, ${AUTO_GPU_LIMIT}% du total)"
  $SUDO nvidia-smi -pl "$LIMIT_POWER" >/dev/null 2>&1 || log "⚠️  Limite GPU non appliquée (droits restreints)."

  # Ajuste mémoire
  GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 || echo 8192)
  if [ "$GPU_MEM" -lt 8192 ]; then
    log "VRAM < 8 Go → exécution allégée."
    export DOL_MAX_VRAM_GB=$((GPU_MEM / 1024))
  else
    export DOL_MAX_VRAM_GB=14
  fi

  GPU_FLAGS+=(--gpus all)
else
  log "Aucun GPU NVIDIA détecté — exécution CPU uniquement."
fi

# === Étape 3 : TTY (pour compatibilité curl|bash) ===
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS="-it"
fi

# === Étape 4 : Téléchargement image Docker ===
log "Préparation du conteneur $IMAGE..."
$SUDO docker pull "$IMAGE" >/dev/null 2>&1 || log "Image locale utilisée."

# === Étape 5 : Lancement Dolores ===
log "Lancement du modèle $MODEL sur le port $PORT..."
$SUDO docker run $TTY_FLAGS --rm \
  "${GPU_FLAGS[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" bash -c "ollama serve >/dev/null 2>&1 & sleep 3; exec ollama run $MODEL" || \
  log "⚠️  Le conteneur n’a pas pu démarrer. Vérifie 'sudo docker ps -a'."

log "✅ Dolores est opérationnelle sur le port $PORT."
