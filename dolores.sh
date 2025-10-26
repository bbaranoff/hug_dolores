#!/usr/bin/env bash
set -Eeuo pipefail

# === Réglages rapides (surchageables via env) ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"   # nom de l'image Docker
MODEL="${MODEL:-dolores}"                      # nom du modèle Ollama
PORT="${PORT:-11434}"                          # port hôte
VOLUME="${VOLUME:-ollama}"                     # volume pour /root/.ollama
SUDO="${SUDO:-sudo}"                           # préfixe sudo (mettre SUDO= pour le désactiver)

# === Détection GPU NVIDIA (optionnelle) ===
GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_FLAGS+=(--gpus all)
fi

# === TTY smart: -it si terminal interactif, sinon -t (compatible curl|bash) ===
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
    sleep 2                                       # petit délai de chauffe
    exec ollama run '"$MODEL"'
  '
