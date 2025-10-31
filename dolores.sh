#!/usr/bin/env bash
set -Eeo pipefail

# === Réglages rapides ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO="${SUDO:-sudo}"
AUTO_GPU_LIMIT="${AUTO_GPU_LIMIT:-70}"
PULL_PROGRESS="${PULL_PROGRESS:-1}"

log()   { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[✖]\033[0m %s\n" "$*"; exit 1; }
trap 'log "⚠️  Une étape a échoué, poursuite du script..."' ERR

log "=== Initialisation de Dolores (image: $IMAGE, modèle: $MODEL) ==="

# === Étape 1 : Dépendances système ===
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt..."
  $SUDO apt-get update -y
  log "Installation des paquets requis..."
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    netcat-openbsd python3-venv
else
  error "apt-get non trouvé — environnement non Debian/Ubuntu."
fi

# === Étape 2 : Docker ===
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
$SUDO systemctl restart docker || true

# === Étape 3 : Détection GPU ===
GPU_FLAG=()
VRAM_GB=0

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe."
  GPU_FLAG=(--gpus all)
  RAW_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 || echo 0)
  VRAM_GB=$((RAW_VRAM / 1024))
  log "VRAM détectée : ${VRAM_GB} Go"
else
  log "⚠️  Aucun GPU NVIDIA détecté — passage en mode CPU uniquement."
fi

# === Étape 4 : Ajustement du modèle selon VRAM ===
if (( VRAM_GB <= 0 )); then
  CONTEXT=2048; CACHE_TYPE="q4_0"
elif (( VRAM_GB <= 4 )); then
  CONTEXT=2048; CACHE_TYPE="q8_0"
elif (( VRAM_GB <= 8 )); then
  CONTEXT=4096; CACHE_TYPE="q8_0"
else
  CONTEXT=8192; CACHE_TYPE="f16"
fi

# === Étape 5 : Overhead GPU ===
OVERHEAD=268435456
if (( VRAM_GB > 0 )); then
  VRAM_MB=$((VRAM_GB * 1024))
  OVERHEAD_PCT=5
  if pgrep -x Xorg >/dev/null 2>&1 || pgrep -x Xwayland >/dev/null 2>&1; then
    OVERHEAD_PCT=8
  fi
  MIN_OVERHEAD_MB=256
  MAX_OVERHEAD_MB=$((VRAM_MB / 4))
  CALC_OVERHEAD_MB=$(( VRAM_MB * OVERHEAD_PCT / 100 ))
  (( CALC_OVERHEAD_MB < MIN_OVERHEAD_MB )) && CALC_OVERHEAD_MB=$MIN_OVERHEAD_MB
  (( CALC_OVERHEAD_MB > MAX_OVERHEAD_MB )) && CALC_OVERHEAD_MB=$MAX_OVERHEAD_MB
  OVERHEAD=$(( CALC_OVERHEAD_MB * 1024 * 1024 ))
  log "Overhead GPU calculé : ${CALC_OVERHEAD_MB} MiB (${OVERHEAD} bytes)"
else
  log "Mode CPU — aucun overhead GPU requis."
fi

# === Étape 6 : Pull de l’image ===
log "Préparation du conteneur $IMAGE..."
if [ "$PULL_PROGRESS" -eq 1 ]; then
  $SUDO docker pull "$IMAGE" || log "Image locale déjà présente."
else
  $SUDO docker pull -q "$IMAGE" || log "Image locale utilisée."
fi

# === Étape 7 : Bridge Flask (optionnel) ===
read -rp "⚙️  Souhaitez-vous activer le bridge API Flask (Dolores ↔ OpenAI) ? [y/N] " ENABLE_API
if [[ "$ENABLE_API" =~ ^[YyOo] ]]; then
  log "Activation du bridge Flask (API)..."
  export ENABLE_FLASK_BRIDGE=1

  read -rp "🔐 Fournir un jeton OpenAI (OPENAI_API_KEY) pour /api/openai ? [y/N] " USE_TOKEN
  if [[ "$USE_TOKEN" =~ ^[YyOo] ]]; then
    read -rs -p "👉 Entrez votre OPENAI_API_KEY (commence par 'sk-') : " OPENAI_API_KEY_INPUT
    echo
    if [[ "$OPENAI_API_KEY_INPUT" == sk-* ]]; then
      export OPENAI_API_KEY="$OPENAI_API_KEY_INPUT"
      echo "🔑 Jeton chargé (…${OPENAI_API_KEY_INPUT: -6})"
    else
      echo "⚠️ Jeton invalide — /api/openai désactivé."
      unset OPENAI_API_KEY
    fi
  fi

  log "Installation du bridge Flask…"
  python3 -m venv /tmp/.env_dolores
  source /tmp/.env_dolores/bin/activate
  pip install --no-cache-dir flask requests openai > /dev/null

  cat > /tmp/server.py <<'PYCODE'
#!/usr/bin/env python3
import os, json, requests
from flask import Flask, request, Response

try:
    from openai import OpenAI
except ImportError:
    OpenAI = None

OLLAMA_HOST  = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "").strip()
OPENAI_MODEL   = os.getenv("OPENAI_MODEL", "gpt-4o-mini")

app = Flask(__name__)

def get_openai_client():
    if not OPENAI_API_KEY or OpenAI is None:
        return None
    return OpenAI(api_key=OPENAI_API_KEY)

def stream_openai(prompt):
    client = get_openai_client()
    if not client: return
    stream = client.chat.completions.create(
        model=OPENAI_MODEL,
        messages=[{"role": "user", "content": prompt}],
        stream=True,
    )
    for chunk in stream:
        delta = chunk.choices[0].delta
        if delta and delta.content:
            yield delta.content

def stream_ollama(prompt):
    url = f"{OLLAMA_HOST}/api/generate"
    data = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": True}
    with requests.post(url, json=data, stream=True) as r:
        for line in r.iter_lines():
            if not line: continue
            try:
                j = json.loads(line.decode())
            except Exception:
                continue
            if "response" in j:
                yield j["response"]
            if j.get("done"):
                break

@app.route("/api/ollama", methods=["POST"])
def api_ollama():
    prompt = request.json.get("prompt", "")
    return Response(stream_ollama(prompt), mimetype="text/plain")

@app.route("/api/openai", methods=["POST"])
def api_openai():
    if not OPENAI_API_KEY or OpenAI is None:
        return Response("OpenAI API non configurée.", status=503)
    user_prompt = request.json.get("user_prompt", "")
    local_reply = request.json.get("local_reply", "")
    extra = request.json.get("extra_instruction", "")
    full = f"Question : {user_prompt}\nRéponse locale : {local_reply}\n{extra}"
    return Response(stream_openai(full), mimetype="text/plain")

@app.route("/")
def index():
    return "<h3>Bridge actif sur /api/ollama et /api/openai</h3>"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
PYCODE

  nohup /tmp/.env_dolores/bin/python /tmp/server.py >/tmp/bridge.log 2>&1 &
  echo ""
  echo "🌐 Vous pouvez maintenant ouvrir votre navigateur et accéder à l’interface :"
  echo "   👉 http://127.0.0.1:8080 😊"
  echo ""
else
  log "Bridge Flask désactivé par l’utilisateur."
  export ENABLE_FLASK_BRIDGE=0
fi

# === Étape 8 : Lancement du conteneur ===
log "Contexte=$CONTEXT | Cache=$CACHE_TYPE | Overhead=$OVERHEAD bytes"
log "Démarrage du conteneur $IMAGE sur le port $PORT..."

$SUDO docker run -it "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  -e OLLAMA_KV_CACHE_TYPE="$CACHE_TYPE" \
  -e OLLAMA_NUM_PARALLEL=1 \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  -e OLLAMA_GPU_OVERHEAD="$OVERHEAD" \
  "$IMAGE" \
bash -lc 'ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run dolores'
