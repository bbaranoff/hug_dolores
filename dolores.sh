#!/usr/bin/env bash
set -Eeo pipefail

# =============================
#  Réglages rapides (env vars)
# =============================
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"                # Port d'écoute Ollama dans le conteneur + host
VOLUME="${VOLUME:-ollama}"           # Volume persistant pour le cache de modèles
SUDO="${SUDO:-sudo}"                 # Peut être vide si root
PULL_PROGRESS="${PULL_PROGRESS:-1}"  # 1 = pull verbeux, 0 = silencieux
BRIDGE_PORT="${BRIDGE_PORT:-8080}"   # Port du bridge Flask
BRIDGE_HOST="${BRIDGE_HOST:-0.0.0.0}"

# =============================
#  Utilitaires
# =============================
log()   { printf "\033[1;36m[+]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[✖]\033[0m %s\n" "$*"; exit 1; }
trap 'warn "⚠️  Une étape a échoué, poursuite du script… (pipefail actif)"' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || error "Commande requise manquante: $1"; }

wait_http() {
  local url="$1" max="$2" i=0
  while (( i < max )); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# =============================
#  Étape 1 : Dépendances système
# =============================
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "Mise à jour du cache apt…"
  $SUDO apt-get update -y
  log "Installation des paquets requis…"
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    netcat-openbsd python3-venv
else
  warn "apt-get introuvable — je suppose que Docker et Python3 sont déjà installés."
fi

# =============================
#  Étape 2 : Docker
# =============================
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker…"
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
$SUDO systemctl restart docker || true

require_cmd docker

# =============================
#  Étape 3 : Détection GPU
# =============================
GPU_FLAG=()
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  log "GPU NVIDIA détecté — utilisation directe (--gpus all)."
  GPU_FLAG=(--gpus all)
else
  warn "Aucun GPU NVIDIA détecté — usage CPU uniquement."
fi

# =============================
#  Étape 4 : Pull image
# =============================
log "Préparation de l'image Docker: $IMAGE"
if [ "$PULL_PROGRESS" -eq 1 ]; then
  $SUDO docker pull "$IMAGE" || log "Image locale déjà présente."
else
  $SUDO docker pull -q "$IMAGE" || log "Image locale utilisée."
fi

# =============================
#  Étape 5 : Lancement Ollama
# =============================
# On lance en détaché un conteneur 'dolores_ollama' qui sert l'API
# NB: l'image doit contenir un 'ollama serve' en entrée, sinon on force la commande.
CONTAINER_NAME="dolores_ollama"

# Stop/cleanup précédent
if $SUDO docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  log "Arrêt de l'ancien conteneur $CONTAINER_NAME…"
  $SUDO docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

log "Démarrage d’Ollama ($CONTAINER_NAME) sur le port $PORT…"
$SUDO docker run -d --restart=unless-stopped \
  "${GPU_FLAG[@]}" \
  --name "$CONTAINER_NAME" \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  "$IMAGE" \
  bash -lc "ollama serve --host 0.0.0.0 --port $PORT"

# Attente API Ollama
log "Attente que l’API Ollama réponde…"
if ! wait_http "http://127.0.0.1:$PORT/api/tags" 45; then
  warn "L’API /api/tags ne répond pas encore, nouveau test /api/version…"
  wait_http "http://127.0.0.1:$PORT/api/version" 15 || error "Ollama ne répond pas. Vérifie les logs: docker logs $CONTAINER_NAME"
fi
log "✔️  Ollama API OK."

# Optionnel: s’assurer que le modèle existe (pull)
log "Vérification/installation du modèle: $MODEL"
docker exec "$CONTAINER_NAME" bash -lc "ollama pull '$MODEL' || true"

# =============================
#  Étape 6 : Bridge Flask (optionnel)
# =============================
read -rp "⚙️  Activer le bridge API Flask (Dolores ↔ OpenAI) ? [y/N] " ENABLE_API
if [[ "$ENABLE_API" =~ ^[YyOo] ]]; then
  log "Activation du bridge Flask (server.py)…"

  # OpenAI key (optionnelle)
  OPENAI_API_KEY_INPUT=""
  read -rp "🔐 Fournir un jeton OpenAI (OPENAI_API_KEY) pour /api/openai ? [y/N] " USE_TOKEN
  if [[ "$USE_TOKEN" =~ ^[YyOo] ]]; then
    read -rs -p "👉 Entrez votre OPENAI_API_KEY (commence par 'sk-'): " OPENAI_API_KEY_INPUT
    echo
    if [[ -z "$OPENAI_API_KEY_INPUT" || "$OPENAI_API_KEY_INPUT" != sk-* ]]; then
      warn "Jeton vide ou invalide ; /api/openai restera désactivé."
      OPENAI_API_KEY_INPUT=""
    else
      log "Jeton chargé (…${OPENAI_API_KEY_INPUT: -6})"
    fi
  else
    warn "Aucun jeton saisi ; si \$OPENAI_API_KEY existe déjà dans l’env, il sera utilisé."
  fi

  # venv
  BRIDGE_ENV="/tmp/.env_dolores"
  log "Création de l’environnement Python: $BRIDGE_ENV"
  python3 -m venv "$BRIDGE_ENV"
  # shellcheck disable=SC1091
  source "$BRIDGE_ENV/bin/activate"
  python3 -m pip install --upgrade pip >/dev/null
  python3 -m pip install --no-cache-dir flask requests openai >/dev/null

  # Générer server.py
  BRIDGE_FILE="/tmp/server.py"
  log "Écriture du bridge: $BRIDGE_FILE"
  cat > "$BRIDGE_FILE" <<'PYCODE'
#!/usr/bin/env python3
from __future__ import annotations
import os, json, traceback, requests, openai
from typing import Iterator, Optional
from flask import Flask, request, Response, render_template_string, jsonify

OLLAMA_HOST  = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "").strip()
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "").strip()

if OPENAI_API_KEY:
    openai.api_key = OPENAI_API_KEY
    if OPENAI_BASE_URL:
        openai.api_base = OPENAI_BASE_URL

app = Flask(__name__)

def safe_j(b: bytes) -> Optional[dict]:
    try:
        return json.loads(b.decode("utf-8"))
    except Exception:
        return None

def stream_ollama(prompt: str) -> Iterator[str]:
    url = f"{OLLAMA_HOST.rstrip('/')}/api/generate"
    payload = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": True}
    try:
        with requests.post(url, json=payload, stream=True, timeout=30) as r:
            r.raise_for_status()
            for raw in r.iter_lines(decode_unicode=False):
                if not raw: continue
                j = safe_j(raw)
                if j and "response" in j:
                    yield j["response"]
                elif j and "token" in j:
                    yield j["token"]
                else:
                    try: yield raw.decode("utf-8", errors="ignore")
                    except Exception: continue
    except Exception as e:
        yield f"[ERROR] Ollama connection failed: {e}\n"

def stream_openai(prompt: str) -> Iterator[str]:
    if not OPENAI_API_KEY:
        return
    try:
        resp = openai.ChatCompletion.create(
            model=OPENAI_MODEL,
            messages=[{"role":"user","content":prompt}],
            stream=True,
            request_timeout=60,
        )
        for chunk in resp:
            try:
                delta = chunk["choices"][0].get("delta", {})
                part = delta.get("content") or delta.get("text") or ""
                if part: yield part
            except Exception:
                yield json.dumps(chunk, ensure_ascii=False) + "\n"
    except Exception as e:
        yield f"[ERROR] OpenAI streaming error: {e}\n"

@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status":"ok",
        "ollama_host":OLLAMA_HOST,
        "ollama_model":OLLAMA_MODEL,
        "openai_enabled":bool(OPENAI_API_KEY),
    })

@app.route("/api/ollama", methods=["POST"])
def api_ollama():
    data = request.get_json(silent=True) or {}
    prompt = data.get("prompt","")
    if not prompt:
        return Response("Missing 'prompt'", status=400)
    def gen():
        try:
            yield from stream_ollama(prompt)
        except Exception:
            yield "[ERROR] Internal error in Ollama stream\n"
    return Response(gen(), mimetype="text/plain; charset=utf-8")

@app.route("/api/openai", methods=["POST"])
def api_openai():
    if not OPENAI_API_KEY:
        return Response("OpenAI API not configured (OPENAI_API_KEY missing).", status=503)
    data = request.get_json(silent=True) or {}
    user_prompt = data.get("user_prompt","")
    local_reply = data.get("local_reply","")
    extra_instruction = data.get("extra_instruction","")
    if not user_prompt:
        return Response("Missing 'user_prompt'", status=400)
    full_instruction = (
        f"L’utilisateur avait posé la question suivante :\n\n{user_prompt}\n\n"
        f"Le modèle local (Ollama) a répondu ceci :\n\n{local_reply}\n\n"
        "Analyse cette réponse. Si elle te paraît incomplète ou ambiguë, "
        "dis clairement quelles précisions tu souhaiterais avant de répondre. "
        "Sinon, complète-la ou commente-la selon ton jugement, en gardant le format Markdown et LaTeX si utile."
    )
    if extra_instruction:
        full_instruction += f"\n\nInstruction supplémentaire : {extra_instruction}\n"
    def gen():
        try:
            yield from stream_openai(full_instruction)
        except Exception:
            yield "[ERROR] Internal error in OpenAI stream\n"
    return Response(gen(), mimetype="text/plain; charset=utf-8")

INDEX_HTML = """
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Bridge Ollama ↔ OpenAI</title></head>
<body style="background:#111;color:#eee;font-family:system-ui,monospace;padding:18px;">
  <h2>🧠 Bridge Ollama ↔ OpenAI</h2>
  <p>Endpoints : <code>/api/ollama</code>, <code>/api/openai</code>, <code>/health</code></p>
  <pre style="white-space:pre-wrap;color:#9ad;">Ollama: {{ollama}}</pre>
  <p>OpenAI enabled: {{openai}}</p>
</body>
</html>
"""

@app.route("/", methods=["GET"])
def index():
    return render_template_string(INDEX_HTML,
        ollama=f"{OLLAMA_HOST} (model={OLLAMA_MODEL})",
        openai=bool(OPENAI_API_KEY)
    )

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", default=8080, type=int)
    args = p.parse_args()
    print(f"[bridge] http://{args.host}:{args.port}  (OLLAMA={OLLAMA_HOST}, model={OLLAMA_MODEL})", flush=True)
    if OPENAI_API_KEY: print("[bridge] OpenAI: ENABLED", flush=True)
    else: print("[bridge] OpenAI: DISABLED", flush=True)
    app.run(host=args.host, port=args.port, threaded=True)
PYCODE
  chmod +x "$BRIDGE_FILE"

  # Exports pour le process Python
  export OLLAMA_HOST="http://127.0.0.1:$PORT"
  export OLLAMA_MODEL="$MODEL"
  if [[ -n "$OPENAI_API_KEY_INPUT" ]]; then export OPENAI_API_KEY="$OPENAI_API_KEY_INPUT"; fi

  # Lancer le bridge
  log "Démarrage du bridge Flask sur :$BRIDGE_PORT…"
  nohup python "$BRIDGE_FILE" --host "$BRIDGE_HOST" --port "$BRIDGE_PORT" \
    > /tmp/dolores_bridge.log 2>&1 &

  sleep 2
  echo ""
  echo "🌐 Vous pouvez maintenant ouvrir votre navigateur et accéder à l’interface :"
  echo "   👉 http://127.0.0.1:${BRIDGE_PORT} 😊"
  echo "   (Healthcheck : http://127.0.0.1:${BRIDGE_PORT}/health)"
  echo ""
else
  warn "Bridge Flask non activé. Vous pourrez le relancer plus tard."
fi

log "Installation terminée. Ollama écoute sur http://127.0.0.1:${PORT}"
