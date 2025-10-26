#!/usr/bin/env bash
set -euo pipefail

# ====== Paramètres (surchargables) ======
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"          # image Docker à utiliser
MODEL="${MODEL:-dolores}"             # modèle Ollama à lancer
PORT="${PORT:-11434}"                 # port API
VOL="${VOL:-ollama}"                  # volume Docker pour le cache modèles
USE_GPU="${USE_GPU:-1}"               # 1 = --gpus all ; 0 = sans GPU
INSTALL_NVIDIA_TOOLKIT="${INSTALL_NVIDIA_TOOLKIT:-1}"  # 1 = tenter nvidia toolkit

# ====== Fonctions utilitaires ======
have() { command -v "$1" >/dev/null 2>&1; }
is_ubuntu_like() { [ -f /etc/debian_version ]; }
as_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

say() { printf "\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; }

# ====== Pré-checks ======
is_ubuntu_like || warn "Script testé surtout sur Ubuntu/Debian. On continue quand même."

if ! as_root; then
  if have sudo; then
    SUDO="sudo"
  else
    err "Exécute en root ou installe sudo."
  fi
else
  SUDO=""
fi

# ====== Installer Docker si absent ======
if ! have docker; then
  say "Installation de Docker…"
  $SUDO apt-get update -y
  $SUDO apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
  if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME || echo $(lsb_release -cs)) stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null || true
  fi
  $SUDO apt-get update -y || true
  # docker.io marche aussi, mais on préfère le paquet Docker officiel
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || $SUDO apt-get install -y docker.io
  # Démarrer Docker si systemd présent
  if have systemctl; then
    $SUDO systemctl enable --now docker || true
  else
    warn "systemd absent — tentative de démarrage du service docker."
    $SUDO service docker start || true
  fi
else
  say "Docker déjà présent."
fi

# ====== NVIDIA Toolkit (optionnel) ======
GPU_FLAG=()
if [ "$USE_GPU" = "1" ]; then
  if have nvidia-smi; then
    say "GPU NVIDIA détecté."
    GPU_FLAG=(--gpus all)
    if [ "$INSTALL_NVIDIA_TOOLKIT" = "1" ] && ! [ -x /usr/bin/nvidia-ctk ]; then
      warn "Tentative d’installation de NVIDIA Container Toolkit…"
      $SUDO apt-get update -y
      $SUDO apt-get install -y nvidia-container-toolkit || warn "Toolkit non installé (ok si déjà configuré)."
      if have nvidia-ctk; then
        $SUDO nvidia-ctk runtime configure --runtime=docker || true
        if have systemctl; then $SUDO systemctl restart docker || true; else $SUDO service docker restart || true; fi
      fi
    fi
  else
    warn "Pas de 'nvidia-smi' détecté — lancement SANS GPU."
  fi
else
  warn "USE_GPU=0 → lancement sans GPU."
fi

# ====== Pull optionnel de l’image ======
say "Vérification de l’image Docker : $IMAGE"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  say "Image absente localement, tentative de pull : $IMAGE"
  docker pull "$IMAGE" || warn "Impossible de pull $IMAGE (image locale seulement ?)"
fi

# ====== Lancement ======
say "Lancement de $IMAGE avec Ollama (API : :$PORT ; modèle : $MODEL)…"
exec docker run -it --rm \
  "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" bash -c "ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run '$MODEL'"
