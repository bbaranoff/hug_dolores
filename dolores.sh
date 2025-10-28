#!/usr/bin/env bash
set -Eeo pipefail

# === Réglages rapides (surchageables via env) ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"   # image Docker
MODEL="dolores"                      # modèle unique (non modifié)
PORT="${PORT:-11434}"                          # port d'écoute
VOLUME="${VOLUME:-ollama}"                     # volume persistant
SUDO="${SUDO:-sudo}"                           # préfixe sudo (vide si root)
AUTO_GPU_LIMIT="${AUTO_GPU_LIMIT:-70}"         # % de puissance max (indicatif)
VOL="ollama"

# === Utilitaires ===
log()   { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[✖]\033[0m %s\n" "$*"; exit 1; }
trap 'log "⚠️  Une étape a échoué, poursuite du script..."' ERR

log "=== Initialisation de Dolores (image: $IMAGE, modèle: $MODEL) ==="

# === Étape 1 : Dépendances de base ===
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

# === Étape 2 : Docker ===
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
$SUDO service docker stop || true
sleep 2
$SUDO service docker start || true
sleep 2
# === Étape 3 : Vérification GPU + limites indicatives ===
if ! command -v nvidia-smi >/dev/null 2>&1; then
  error "Aucun pilote NVIDIA détecté sur l’hôte.
Installez d’abord les pilotes NVIDIA officiels : https://developer.nvidia.com/cuda-downloads"
fi

GPU_FLAGS=()
if nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe."

  # Puissance (souvent N/A sur laptops) → valeur symbolique
  RAW_POWER=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1)
  if [[ -z "$RAW_POWER" || "$RAW_POWER" == *"N/A"* || ! "$RAW_POWER" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log "⚠️  Puissance non lisible sur GPU mobile (${RAW_POWER:-vide}) — valeur par défaut 100 W."
    MAX_POWER=100
  else
    MAX_POWER=${RAW_POWER%.*}
  fi
  [[ "$AUTO_GPU_LIMIT" =~ ^[0-9]+$ ]] || AUTO_GPU_LIMIT=70
  LIMIT_POWER=$((MAX_POWER * AUTO_GPU_LIMIT / 100))
fi

# === Étape 4 : Détection VRAM → OLLAMA_MAX_VRAM_GB ===
RAW_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)
if [[ -z "$RAW_MEM" || ! "$RAW_MEM" =~ ^[0-9]+$ ]]; then
  log "⚠️  VRAM illisible (${RAW_MEM:-vide}) — OLLAMA_MAX_VRAM_GB=2 par sécurité."
  GPU_MEM_GB=2
else
  GPU_MEM_GB=$((RAW_MEM / 1024))
fi

# === Étape 5 : Gestion du TTY ===
TTY_FLAGS="-t"
if [ -t 0 ] && [ -t 1 ]; then TTY_FLAGS="-it"; fi

# === Étape 6 : Image ===
log "Préparation du conteneur $IMAGE..."
$SUDO docker pull "$IMAGE" >/dev/null 2>&1 || log "Image locale utilisée."

# === Étape 7 : Lancement (modèle inchangé) ===
log "Lancement du modèle $MODEL sur le port $PORT..."
$SUDO docker run $TTY_FLAGS --rm \
  "${GPU_FLAGS[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOL":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  -e OLLAMA_MAX_VRAM_GB="$GPU_MEM_GB" \
  -e MODEL="$MODEL" \
  "$IMAGE" bash -c 'ollama serve >/dev/null 2>&1 & sleep 3; ollama run "$MODEL"'
