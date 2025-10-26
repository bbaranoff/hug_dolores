#!/usr/bin/env bash
set -Eeuo pipefail

# === Réglages rapides (surchageables via env) ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"   # nom de l'image Docker
MODEL="${MODEL:-dolores}"                      # nom du modèle Ollama
PORT="${PORT:-11434}"                          # port hôte
VOLUME="${VOLUME:-ollama}"                     # volume pour /root/.ollama
SUDO="${SUDO:-sudo}"                           # préfixe sudo (mettre SUDO= pour le désactiver)

# === Bootstrap apt: installe les paquets nécessaires si absents ===
ensure_apt_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends "$pkg"
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  # curl pour récupérer des scripts, docker.io pour exécuter le conteneur
  command -v curl   >/dev/null 2>&1 || ensure_apt_pkg curl
  command -v docker >/dev/null 2>&1 || ensure_apt_pkg docker.io

  # Démarrer le service Docker si systemd est dispo (ignore les erreurs hors-systemd)
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  fi
fi

# === Détection GPU NVIDIA (optionnelle) ===
GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_FLAGS+=(--gpus all)
fi

# === TTY smart: -it si terminal interactif, sinon -t (fixe l’erreur via curl|bash) ===
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS="-it"
fi

# === Run: lance le serveur en arrière-plan, puis entre direct au prompt du modèle ===
exec $SUDO docker run --rm "${GPU_FLAGS[@]}" $TTY_FLAGS \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  "$IMAGE" bash -lc '
    ollama serve >/dev/null 2>&1 &               # pas de logs
    for i in {1..20}; do sleep 0.2; nc -z 127.0.0.1 '"$PORT"' && break || true; done
    exec ollama run '"$MODEL"'
  '
