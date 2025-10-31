#!/usr/bin/env bash
set -Eeo pipefail
# === Étape 6.5 : Préparation du bridge Flask ===
log "Préparation du bridge Flask (server.py)..."

# ⬇️ écrire le code Python dans un fichier temporaire
cat > /tmp/server.py <<'PYCODE'
#!/usr/bin/env python3
import os, json, requests
from flask import Flask, request, Response, render_template_string

# OpenAI SDK (v1)
try:
    from openai import OpenAI
except ImportError:
    OpenAI = None

OLLAMA_HOST  = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "").strip()
OPENAI_MODEL   = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "")
OPENAI_ORG_ID   = os.getenv("OPENAI_ORG_ID", "")

app = Flask(__name__)

def get_openai_client():
    if not OPENAI_API_KEY or OpenAI is None:
        return None
    kwargs = {"api_key": OPENAI_API_KEY}
    if OPENAI_BASE_URL:
        kwargs["base_url"] = OPENAI_BASE_URL
    if OPENAI_ORG_ID:
        kwargs["organization"] = OPENAI_ORG_ID
    return OpenAI(**kwargs)

def stream_openai(prompt):
    client = get_openai_client()
    if not client:
        yield from ()
        return
    stream = client.chat.completions.create(
        model=OPENAI_MODEL,
        messages=[{"role": "user", "content": prompt}],
        stream=True,
        timeout=60
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
            if not line:
                continue
            try:
                j = json.loads(line.decode("utf-8"))
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
        return Response("OpenAI API non configurée (clé absente ou SDK manquant).", status=503)
    user_prompt = request.json.get("user_prompt", "")
    local_reply = request.json.get("local_reply", "")
    extra_instruction = request.json.get("extra_instruction", "")
    full_instruction = (
        f"L’utilisateur avait posé la question suivante :\n\n{user_prompt}\n\n"
        f"Le modèle local (Ollama) a répondu ceci :\n\n{local_reply}\n\n"
        "Analyse cette réponse, puis complète ou améliore-la.\n"
    )
    if extra_instruction:
        full_instruction += f"\nInstruction supplémentaire : {extra_instruction}\n"
    return Response(stream_openai(full_instruction), mimetype="text/plain")

@app.route("/")
def index():
    return "<h2>✅ Bridge actif sur /api/ollama et /api/openai</h2>"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
PYCODE

# Crée l’environnement et installe les libs
python3 -m venv /tmp/.env_dolores
source /tmp/.env_dolores/bin/activate
pip install --no-cache-dir flask requests openai > /dev/null
nohup /tmp/.env_dolores/bin/python /tmp/server.py >/tmp/bridge.log 2>&1 &
echo "🌐 Bridge Flask actif → http://127.0.0.1:8080 😊"

"""


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
