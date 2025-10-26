#!/usr/bin/env bash
set -Eeuo pipefail

# === Réglages rapides (surchageables via env) ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO="${SUDO:-sudo}"

log() { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }

# --- apt bootstrap (déjà présent dans ta version précédente) ---
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y

  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    netcat-openbsd || true

  # Docker depuis dépôt officiel si absent
  if ! command -v docker >/dev/null 2>&1; then
    log "Installation de Docker (dépôt officiel)..."
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

  # start docker if possible
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  fi
else
  log "apt-get non trouvé — on saute le bootstrap apt."
fi

# === GPU detection ===
GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté → support activé."
  GPU_FLAGS+=(--gpus all)
else
  log "Aucun GPU NVIDIA détecté (CPU)."
fi

# === TTY handling ===
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS="-it"
fi

# === Pull image if possible ===
log "Préparation: pull $IMAGE (si nécessaire)..."
$SUDO docker pull "$IMAGE" || log "Pull échoué ou image locale utilisée."

# === Run container (launch server in container) ===
log "Lancement du conteneur (expose :$PORT) — je vais attendre que le port réponde..."
$SUDO docker run --rm "${GPU_FLAGS[@]}" $TTY_FLAGS \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  "$IMAGE" bash -lc "ollama serve >/dev/null 2>&1 & exec sleep 9999" &

# Récupère PID du dernier background (le docker run détaché ici)
DOCKER_BG_PID=$!

# Boucle côté hôte pour détecter le port (curl local)
for i in $(seq 1 40); do
  if curl -sS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    log "Port $PORT répond — on lance le client Ollama localement dans le conteneur."
    break
  fi
  sleep 0.25
done

# Si le port n'est jamais disponible, on prévient mais on tente quand même d'ouvrir le prompt
if ! curl -sS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  log "Attention : le port $PORT n'a pas répondu dans le délai. Je vais quand même essayer d'ouvrir le prompt."
fi

# Trouve l'ID du conteneur (le plus récent avec cette image)
CID="$($SUDO docker ps -q --filter "ancestor=$IMAGE" | head -n1)"
if [ -z "$CID" ]; then
  log "Erreur : impossible de trouver le conteneur lancé (CID vide). Affiche les conteneurs actuels :"
  $SUDO docker ps --no-trunc
  exit 1
fi

# Exec dans le conteneur pour lancer ollama run (interactive)
log "Exécution interactive : docker exec -it $CID ollama run $MODEL"
exec $SUDO docker exec -it "$CID" bash -lc "exec ollama run $MODEL"
