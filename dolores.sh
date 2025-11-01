#!/usr/bin/env bash
set -Eeo pipefail

# === Réglages rapides ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO_DEFAULT="${SUDO:-sudo}"
AUTO_GPU_LIMIT="${AUTO_GPU_LIMIT:-70}"
PULL_PROGRESS="${PULL_PROGRESS:-1}"

# Si root, pas besoin de sudo
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="$SUDO_DEFAULT"
fi

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

# === Étape 5 : Pull de l’image ===
log "Préparation du conteneur $IMAGE..."
if [ "$PULL_PROGRESS" -eq 1 ]; then
  $SUDO docker pull "$IMAGE" || log "Image locale déjà présente."
else
  $SUDO docker pull -q "$IMAGE" || log "Image locale utilisée."
fi

# === Étape 6 : Lancement d’Ollama en arrière-plan ===
log "Lancement du serveur Ollama (port $PORT)..."
$SUDO docker run -d --rm "${GPU_FLAG[@]}" \
  -p "$PORT:$PORT" \
  -v "$VOLUME":/root/.ollama \
  -e OLLAMA_HOST="0.0.0.0:$PORT" \
  -e OLLAMA_KV_CACHE_TYPE="$CACHE_TYPE" \
  -e OLLAMA_NUM_PARALLEL=1 \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  "$IMAGE" \
  bash -lc "ollama serve" >/dev/null

# === Étape 8 : Bridge Flask (optionnel) ===
read -rp "⚙️  Souhaitez-vous activer le bridge API Flask (Dolores ↔ OpenAI) ? [y/N] " ENABLE_API
if [[ "$ENABLE_API" =~ ^[YyOo] ]]; then
  log "Activation du bridge Flask (API)..."

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

  # === écriture du code Python ===
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
            try: j = json.loads(line.decode())
            except Exception: continue
            if "response" in j: yield j["response"]
            if j.get("done"): break

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


# === FRONTEND ===
INDEX_HTML = """
cat > /tmp/server.py <<'PYCODE'
#!/usr/bin/env python3
import os, json, requests
from flask import Flask, request, Response, render_template_string

# --- OpenAI SDK (optionnel) ---
try:
    from openai import OpenAI
except ImportError:
    OpenAI = None

# --- Config ---
OLLAMA_HOST  = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "").strip()
OPENAI_MODEL   = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "").strip()
OPENAI_ORG_ID   = os.getenv("OPENAI_ORG_ID", "").strip()

app = Flask(__name__)

# --- Page HTML (index) ---
INDEX_HTML = r"""
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Bridge Ollama <-> OpenAI</title>

<!-- Markdown -->
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>

<!-- MathJax pour le LaTeX -->
<script>
window.MathJax = {
  tex: {
    inlineMath: [['$', '$'], ['\\(', '\\)']],
    displayMath: [['$$', '$$'], ['\\[', '\\]']],
    processEscapes: true
  },
  options: { skipHtmlTags: ['script','noscript','style','textarea','pre','code'] },
  startup: { typeset: false }
};
</script>
<script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>

<style>
  body { font-family: system-ui, monospace; background:#111; color:#eee; margin:0; padding:20px; }
  #chat { background:#181818; padding:10px; border-radius:8px; min-height:320px; overflow-y:auto; }
  .message { padding:6px 4px; border-bottom:1px solid #2a2a2a; }
  .user  { color:#6cc2ff; }
  .ollama{ color:#91f2a7; }
  .gpt   { color:#ffc78a; }
  textarea { width:100%; background:#202020; color:#eee; border:1px solid #333; padding:10px; border-radius:6px; }
  #prompt { height:70px; margin-top:10px; }
  #extra  { height:44px; font-size:0.9em; opacity:0.85; margin-top:6px; }
  #extra:focus { opacity:1; }
  button { margin:6px 6px 0 0; padding:9px 16px; background:#2b2b2b; color:#eee;
           border:1px solid #4a4a4a; cursor:pointer; border-radius:6px; }
  button:hover { background:#3a3a3a; }
  #status { color:#aaa; margin-top:8px; font-style:italic; }
</style>
</head>
<body>
<h2>🧠 Bridge Ollama ↔ OpenAI</h2>
<div id="chat"></div>

<textarea id="prompt" placeholder="Écris ton message… (Markdown & LaTeX ok)"></textarea>
<textarea id="extra"  placeholder="(Optionnel) Instruction supplémentaire — ex. 'Traduis en anglais'"></textarea><br/>

<button onclick="btnOllama()">Réponse Ollama</button>
<button onclick="btnSubmitGPT()">Soumettre à GPT</button>
<button onclick="btnReturnLocal()">Renvoyer au local</button>
<button onclick="copyChat()">Copier la discussion</button>
<span id="copyok" style="margin-left:8px;color:#8f8;"></span>
<div id="status"></div>

<script>
let lastUserPrompt = "";
let lastLocalText  = "";
let lastGptText    = "";

// Render Markdown + LaTeX
async function renderMarkdown(container, text) {
  container.innerHTML = marked.parse(text);
  if (window.MathJax && window.MathJax.typesetPromise) {
    await MathJax.typesetClear([container]);
    await MathJax.typesetPromise([container]);
  }
}

// Append message
function addLine(roleClass, rawText, prefix="") {
  const chat = document.getElementById("chat");
  const div = document.createElement("div");
  div.classList.add("message", roleClass);
  chat.appendChild(div);
  renderMarkdown(div, (prefix ? prefix + " " : "") + rawText);
  chat.scrollTop = chat.scrollHeight;
  return div;
}

// Build payload (inject extra instruction into prompt)
function getPayload(basePrompt, includeInstruction=true) {
  const extra = document.getElementById("extra").value.trim();
  if (includeInstruction && extra) {
    return { prompt: basePrompt + "\\n\\n[Instruction: " + extra + "]" };
  }
  return { prompt: basePrompt };
}

// Generic stream fetch
async function streamTo(url, payload, roleClass, statusLabel) {
  const status = document.getElementById("status");
  const chat   = document.getElementById("chat");
  const resp = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(payload)
  });
  if (!resp.ok) throw new Error("HTTP " + resp.status);

  const reader  = resp.body.getReader();
  const decoder = new TextDecoder("utf-8");
  const liveDiv = document.createElement("div");
  liveDiv.classList.add("message", roleClass);
  chat.appendChild(liveDiv);

  status.textContent = "⏳ " + statusLabel + "…";
  let collected = "";

  while (true) {
    const {value, done} = await reader.read();
    if (done) break;
    const chunk = decoder.decode(value);
    collected += chunk;
    await renderMarkdown(liveDiv, collected);
    chat.scrollTop = chat.scrollHeight;
  }

  status.textContent = "✅ " + statusLabel + " terminé";
  return collected.trim();
}

// Buttons
async function btnOllama() {
  const promptEl = document.getElementById("prompt");
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  lastUserPrompt = prompt;
  addLine("user", prompt, "🧍");
  promptEl.value = "";
  const payload = getPayload(prompt, true);
  const out = await streamTo("/api/ollama", payload, "ollama", "Ollama");
  lastLocalText = out || lastLocalText;
}

async function btnSubmitGPT() {
  if (!lastUserPrompt && !lastLocalText) return;
  const extra = document.getElementById("extra").value.trim();
  const out = await streamTo("/api/openai", {
    user_prompt: lastUserPrompt,
    local_reply: lastLocalText,
    extra_instruction: extra
  }, "gpt", "GPT");
  lastGptText = out || lastGptText;
}

async function btnReturnLocal() {
  const toSend = lastGptText || document.getElementById("prompt").value.trim();
  if (!toSend) return;
  const payload = getPayload(toSend, true);
  const out = await streamTo("/api/ollama", payload, "ollama", "Ollama");
  lastLocalText = out || lastLocalText;
}

async function copyChat() {
  const chatElem = document.getElementById("chat");
  const text = chatElem ? chatElem.innerText.trim() : "";
  const badge = document.getElementById("copyok");
  if (!text) { badge.textContent = "Rien à copier"; setTimeout(()=>badge.textContent="",1200); return; }
  try {
    await navigator.clipboard.writeText(text);
    badge.textContent = "📋 Copié";
    setTimeout(()=>badge.textContent="",1500);
  } catch(e) {
    badge.textContent = "⚠️ Échec";
    setTimeout(()=>badge.textContent="",1500);
  }
}
</script>
</body>
</html>
"""

def get_openai_client():
    if not OPENAI_API_KEY or OpenAI is None:
        return None
    kwargs = {"api_key": OPENAI_API_KEY}
    if OPENAI_BASE_URL: kwargs["base_url"] = OPENAI_BASE_URL
    if OPENAI_ORG_ID:   kwargs["organization"] = OPENAI_ORG_ID
    return OpenAI(**kwargs)

def stream_openai(prompt):
    client = get_openai_client()
    if not client:
        return
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
            try: j = json.loads(line.decode())
            except Exception: continue
            if "response" in j: yield j["response"]
            if j.get("done"): break

# --- Routes ---
@app.route("/")
def index():
    return render_template_string(INDEX_HTML)

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
    full = (
        f"L’utilisateur avait posé :\n\n{user_prompt}\n\n"
        f"Réponse locale (Ollama) :\n\n{local_reply}\n\n"
        "Analyse et complète la réponse."
    )
    if extra:
        full += f"\n\nInstruction supplémentaire : {extra}"
    return Response(stream_openai(full), mimetype="text/plain")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
PYCODE



  nohup python /tmp/server.py >/tmp/bridge.log 2>&1 &
  echo ""
  echo "🌐 Vous pouvez maintenant ouvrir votre navigateur :"
  echo "   👉 http://127.0.0.1:8080 😊"
  echo ""
else
  log "Bridge Flask désactivé par l’utilisateur."
fi

# === Étape finale : Interaction CLI ===
log "✅ Tout est prêt. Ollama écoute sur le port $PORT."
echo "Tapez : curl http://127.0.0.1:$PORT/api/tags"
