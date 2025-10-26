#!/usr/bin/env bash
set -eo pipefail

IMAGE="bastienbaranoff/dolores_v5"
MODEL="dolores"
PORT="11434"
VOL="ollama"

have(){ command -v "$1" >/dev/null 2>&1; }

# Installe Docker si absent (Ubuntu/Debian)
if ! have docker; then
  echo "[+] Installation Docker…"
  sudo apt-get update -y
  sudo apt-get install -y docker.io
fi

# GPU auto
GPU_FLAG=()
if have nvidia-smi; then
  echo "[+] GPU NVIDIA détecté → --gpus all"
  GPU_FLAG=(--gpus all)
else
  echo "[!] Pas de GPU détecté → CPU"
fi

# Pull si nécessaire
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[+] Pull $IMAGE…"
  docker pull "$IMAGE"
fi

# Serve silencieux + prompt
echo "[+] Lancement $IMAGE (modèle=$MODEL, port=$PORT)…"
exec docker run -it --rm \
  "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" bash -c "ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run $MODEL"
