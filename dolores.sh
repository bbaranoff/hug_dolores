#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO="${SUDO:-sudo}"

log() { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }

# === Étape 0 — S'assurer que Docker tourne ===
ensure_docker() {
  if ! $SUDO docker info >/dev/null 2>&1; then
    log "Docker semble inactif — tentative de démarrage..."
    if command -v systemctl >/dev/null 2>&1; then
      $SUDO systemctl start docker 2>/dev/null || true
    fi
    # Si toujours pas dispo → dockerd manuel (cas WSL / container)
    if ! $SUDO docker info >/dev/null 2>&1; then
      log "Démarrage manuel de dockerd (mode fallback)…"
      nohup $SUDO dockerd >/var/log/dockerd.log 2>&1 &
      sleep 3
    fi
  fi

  if ! $SUDO docker info >/dev/null 2>&1; then
    echo "❌ Impossible de contacter le démon Docker. Vérifie les logs : /var/log/dockerd.log"
    exit 1
  fi
}

# === Étape 1 — Bootstrap apt + Docker ===
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y

  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https netcat-openbsd || true

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
fi

ensure_docker

# === Étape 2 — Détection GPU ===
GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté → support activé."
  GPU_FLAGS+=(--gpus all)
else
  log "Aucun GPU NVIDIA détecté (CPU)."
fi

# === Étape 3 — Gestion du TTY ===
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS="-it"
fi

# === Étape 4 — Préparation de l'image ===
log "Pull de $IMAGE si nécessaire..."
$SUDO docker pull "$IMAGE" || log "Image locale utilisée."

# === Étape 5 — Lancement du serveur Dolores ===
log "Lancement du conteneur Dolores (port $PORT)..."
CID="$($SUDO docker run -d --rm "${GPU_FLAGS[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  "$IMAGE" bash -lc 'ollama serve >/dev/null 2>&1 & exec sleep infinity')"

trap 'log "Arrêt du conteneur $CID..."; $SUDO docker stop "$CID" >/dev/null 2>&1 || true' EXIT

# === Étape 6 — Attente du service ===
for i in $(seq 1 40); do
  if curl -sS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    log "Port $PORT répond — connexion au modèle."
    break
  fi
  sleep 0.25
done

# === Étape 7 — Session interactive ===
log "Ouverture du prompt Dolores..."
exec $SUDO docker exec -it "$CID" bash -lc "exec ollama run $MODEL"
