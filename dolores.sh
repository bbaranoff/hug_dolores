#!/usr/bin/env bash
set -euo pipefail

# === [ COULEURS ] ===
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }

# === [ PARAMÈTRES PAR DÉFAUT ] ===
IMAGE="bastienbaranoff/dolores_v5"
MODEL="dolores"
PORT="${PORT:-11434}"
VOL="${VOL:-ollama}"

# === [ DÉTECTION GPU NVIDIA ] ===
GPU_FLAG=()
if command -v nvidia-smi >/dev/null 2>&1; then
  green "[+] GPU NVIDIA détecté → utilisation de --gpus all"
  GPU_FLAG=(--gpus all)
else
  yellow "[!] Aucun GPU NVIDIA détecté → exécution CPU"
fi

# === [ GESTION DU TTY ] ===
if [ -t 1 ]; then
  TTY_FLAG="-t"
else
  TTY_FLAG=""
fi

# === [ RÉSUMÉ ] ===
green "[+] Lancement du modèle : $MODEL"
green "    Image  : $IMAGE"
green "    Port   : $PORT"
green "    Volume : $VOL"

# === [ EXÉCUTION DOCKER ] ===
exec docker run -i $TTY_FLAG --rm \
  "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" bash -c '
    ollama serve >/dev/null 2>&1 &
    sleep 2
    exec ollama run "$MODEL"
  '
