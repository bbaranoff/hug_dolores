#!/usr/bin/env bash
set -Eeuo pipefail

# === Réglages rapides (surchageables via env) ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"   # image Docker à lancer
MODEL="${MODEL:-dolores}"                      # modèle Ollama
PORT="${PORT:-11434}"                          # port hôte
VOLUME="${VOLUME:-ollama}"                     # volume persistant
SUDO="${SUDO:-sudo}"                           # préfixe sudo (vide = root)
VOL="ollama"

# === Fonctions utilitaires ===
log() { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }

# === Étape 1 : Installer les dépendances système ===
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y

  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    netcat-openbsd

  # === Docker ===
  if ! command -v docker >/dev/null 2>&1; then
    log "Installation de Docker (depuis dépôt officiel)..."
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

  # === Démarrage du service docker si besoin ===
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  fi
else
  log "apt-get non trouvé — tu n’es probablement pas sur Ubuntu/Debian."
fi

# === Étape 2 : Détection GPU NVIDIA (optionnelle) ===
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
$SUDO  apt-get install -y nvidia-container-toolkit
$SUDO nvidia-ctk runtime configure --runtime=docker
$SUDO systemctl restart docker
GPU_FLAGS=()
if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté → activation du support CUDA."
  GPU_FLAGS+=(--gpus all)
else
  log "Aucun GPU NVIDIA détecté (exécution CPU uniquement)."
fi

# === Étape 3 : Gestion du TTY (curl|bash compatible) ===
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then
  TTY_FLAGS="-it"
fi

# === Étape 4 : Téléchargement de l’image si absente ===
log "Préparation du conteneur $IMAGE..."
$SUDO docker pull "$IMAGE" || log "Image locale utilisée."

# === Étape 5 : Lancement silencieux du serveur et entrée directe au prompt ===
log "Démarrage du modèle $MODEL sur le port $PORT..."
# Serve silencieux + prompt
echo "[+] Lancement $IMAGE (modèle=$MODEL, port=$PORT)…"
exec sudo docker run -it --rm \
  "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" bash -c "ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run $MODEL"
