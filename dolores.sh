#!/usr/bin/env bash
set -Eeo pipefail

# === Réglages rapides ===
IMAGE="${IMAGE:-bastienbaranoff/dolores_v5}"
MODEL="${MODEL:-dolores}"
PORT="${PORT:-11434}"
VOLUME="${VOLUME:-ollama}"
SUDO_DEFAULT="${SUDO:-sudo}"
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

# === Étape 5 : Bridge Flask (optionnel) ===
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
  cat > /tmp/server.py <<'PYCODE'
  
#!/usr/bin/env python3
import os, json, requests
from flask import Flask, request, Response, render_template_string

app = Flask(__name__)

OLLAMA_HOST = "http://localhost:11434"
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")

# === Mémoire globale partagée (un seul fil de discussion) ===
CHAT_HISTORY = []


# === Streaming Ollama ===
def stream_ollama(prompt: str):
    global CHAT_HISTORY
    CHAT_HISTORY.append({"role": "user", "content": prompt})
    data = {"model": OLLAMA_MODEL, "messages": CHAT_HISTORY, "stream": True}
    url = f"{OLLAMA_HOST}/api/chat"
    full_reply = ""

    try:
        with requests.post(url, json=data, stream=True, timeout=120) as r:
            r.raise_for_status()
            for line in r.iter_lines(decode_unicode=True):
                if not line:
                    continue
                try:
                    j = json.loads(line)
                except Exception:
                    continue
                if "message" in j and "content" in j["message"]:
                    chunk = j["message"]["content"]
                    full_reply += chunk
                    yield chunk
                if j.get("done"):
                    break
    except Exception as e:
        yield f"[Erreur Ollama] {e}"

    CHAT_HISTORY.append({"role": "assistant", "content": full_reply})


# === Streaming OpenAI ===
def stream_openai(prompt: str):
    if not OPENAI_API_KEY:
        yield "[⚠️ Aucun jeton OpenAI configuré]"
        return
    try:
        import openai
        openai.api_key = OPENAI_API_KEY
        stream = openai.chat.completions.create(
            model=OPENAI_MODEL,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
        )
        for chunk in stream:
            delta = chunk.choices[0].delta
            if delta and delta.content:
                yield delta.content
    except Exception as e:
        yield f"[Erreur OpenAI] {e}"


# === Routes ===
@app.route("/")
def index():
    return render_template_string(INDEX_HTML)


@app.route("/api/ollama", methods=["POST"])
def api_ollama():
    prompt = request.json.get("prompt", "")
    if not prompt:
        return Response("[Erreur] Aucun prompt fourni.", mimetype="text/plain")
    return Response(stream_ollama(prompt), mimetype="text/plain")


@app.route("/api/openai", methods=["POST"])
def api_openai():
    user_prompt = request.json.get("user_prompt", "")
    local_reply = request.json.get("local_reply", "")
    extra_instruction = request.json.get("extra_instruction", "").strip()

    directive = "répond et synthétise" if extra_instruction.lower() == "gpt->dolores" else "corrige et questionne"

    full_instruction = (
        f"L’utilisateur a posé :\n{user_prompt}\n\n"
        f"Le modèle local (Dolores) a répondu :\n{local_reply}\n\n"
        f"Analyse cette réponse, {directive}."
    )

    return Response(stream_openai(full_instruction), mimetype="text/plain")


@app.route("/api/copy", methods=["POST"])
def api_copy():
    user_prompt = request.json.get("user_prompt", "")
    local_reply = request.json.get("local_reply", "")

    full_text = (
        f"L’utilisateur a posé :\n{user_prompt}\n\n"
        f"Le modèle local (Dolores) a répondu :\n{local_reply}"
    )

    return Response(full_text, mimetype="text/plain")


@app.route("/api/send_to_gpt", methods=["POST"])
def api_send_to_gpt():
    user_prompt = request.json.get("user_prompt", "")
    extra_instruction = request.json.get("extra_instruction", "").strip()

    full_instruction = (
        f"L’utilisateur a posé :\n{user_prompt}\n\n"
        f"Analyse et corrige, puis pose la question suivante."
    )

    return Response(stream_openai(full_instruction), mimetype="text/plain")


@app.route("/api/return_to_local", methods=["POST"])
def api_return_to_local():
    user_prompt = request.json.get("user_prompt", "")
    extra_instruction = request.json.get("extra_instruction", "").strip()

    full_instruction = (
        f"L’utilisateur a posé :\n{user_prompt}\n\n"
        f"Réponds en local."
    )

    return Response(stream_ollama(full_instruction), mimetype="text/plain")


@app.route("/api/copy_message", methods=["POST"])
def api_copy_message():
    user_prompt = request.json.get("user_prompt", "")
    full_text = (
        f"L’utilisateur a posé :\n{user_prompt}"
    )

    return Response(full_text, mimetype="text/plain")



# === FRONTEND HTML ===
INDEX_HTML = """
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<!-- KaTeX + Marked -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
<script src="https://cdn.jsdelivr.net/npm/marked@4.3.0/marked.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>

<style>
  /* ===================== Thèmes ===================== */
  :root {
    /* Clair (par défaut) */
    --bg:#f6f8fa; --panel:#ffffff; --text:#0b1220; --muted:#57606a;
    --user:#175fe8; --ollama:#0a7f3f; --gpt:#8a5a00;
    --border:#d0d7de; --shadow: #00000014;
  }
  :root[data-theme="dark"]{
    --bg:#0d1117; --panel:#161b22; --text:#e6edf3; --muted:#8b949e;
    --user:#4da3ff; --ollama:#7ee787; --gpt:#f0c674;
    --border:#30363d; --shadow:#0005;
  }

  /* ===================== Layout général ===================== */
  html,body{
    margin:0; height:100%;
    background:var(--bg); color:var(--text);
    font:16px/1.6 system-ui,monospace;
  }
  #page{
    width:90%;              /* => marges latérales = 5% */
    margin:0 5%;
    display:flex; flex-direction:column; align-items:center;
    min-height:100%;
  }
  header{
    width:100%;
    max-width:1100px;
    display:flex; align-items:center; justify-content:space-between;
    padding:24px 0 8px;
  }
  h2{
    margin:0;
    color:var(--user);
    font-weight:650;
  }
  #themeToggle{
    background:transparent; border:1px solid var(--border);
    padding:8px 12px; border-radius:8px; cursor:pointer;
    color:var(--text);
  }

  /* ===================== Zone de chat ===================== */
  #chat{
    width:100%; max-width:1100px;
    flex:1;
    background:var(--panel);
    border:1px solid var(--border);
    border-radius:14px;
    padding:28px;
    overflow-y:auto;
    box-shadow:0 10px 30px var(--shadow), inset 0 0 1px var(--border);
    scroll-behavior:smooth;
    margin-bottom:20px;
  }
  .message{
    margin:20px 0;              /* plus large */
    max-width:78%;
    padding:14px 18px;
    border-radius:14px;
    line-height:1.55;
    word-wrap:break-word;
    box-shadow:0 2px 4px var(--shadow);
  }
  .user{
    align-self:flex-end;
    background:color-mix(in oklab, var(--user) 12%, var(--panel));
    color:var(--user);
    border-top-right-radius:4px;
    margin-left:auto;
  }
  .ollama{
    background:color-mix(in oklab, var(--ollama) 12%, var(--panel));
    border-top-left-radius:4px;
    color:var(--ollama);
  }
  .gpt{
    background:color-mix(in oklab, var(--gpt) 12%, var(--panel));
    border-top-left-radius:4px;
    color:var(--gpt);
  }

  /* ===================== Entrées ===================== */
  textarea{
    width:100%; max-width:1100px;
    border:none; border-radius:10px;
    background:color-mix(in oklab, var(--panel) 92%, var(--bg));
    color:var(--text);
    padding:14px 16px; margin-top:14px;
    font-family:inherit;
    font-size:1em;
    resize:none;
    box-shadow:0 0 0 1px var(--border);
  }
  textarea:focus{ outline:none; box-shadow:0 0 0 2px color-mix(in oklab, var(--user) 35%, var(--border)); }
  #extra{ opacity:0.9; height:45px; }

  /* ===================== Boutons ===================== */
  #toolbar{
    display:flex; flex-wrap:wrap; justify-content:center; gap:10px;
    width:100%; max-width:1100px; margin-top:10px;
  }
  button{
    background:color-mix(in oklab, var(--panel) 80%, var(--bg));
    color:var(--text);
    border:1px solid var(--border);
    border-radius:8px;
    padding:10px 18px;
    cursor:pointer;
    font-family:inherit; font-size:0.95em;
    transition:transform .12s ease, background .12s ease;
  }
  button:hover{ transform:translateY(-1px); }
  #status{
    width:100%; max-width:1100px; color:var(--muted);
    font-style:italic; font-size:0.92em;
    text-align:left; margin:10px 0 24px;
  }
  #copyok{ margin-left:6px; color:var(--ollama); font-size:0.9em; }
  ::selection{ background:color-mix(in oklab, var(--user) 25%, transparent); }
</style>
</head>
<body>
<div id="page">
  <div id="chat"></div>

  <textarea id="prompt" placeholder="💬 Écris ton message ici..."></textarea>
  <textarea id="extra" placeholder="(Optionnel) Instruction supplémentaire..."></textarea>

  <div id="toolbar">
    <button onclick="btnOllama()">Réponse Ollama</button>
    <button onclick="btnSubmitGPT()">Soumettre à GPT</button>
    <button onclick="btnReturnLocal()">Renvoyer au local</button>
    <button onclick="copyChat()">Copier la discussion</button>
    <span id="copyok"></span>
  </div>

  <div id="status"></div>
</div>

<script>
let lastUserPrompt = "";
let lastLocalText = "";
let lastGptText   = "";

/* ===== Thème clair/sombre (clair par défaut) ===== */
(function initTheme(){
  const saved = localStorage.getItem("dolores_theme");
  const prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  const theme = saved || "light";  // clair par défaut
  document.documentElement.setAttribute("data-theme", theme === "dark" ? "dark" : "light");
  document.getElementById("themeToggle").textContent = theme === "dark" ? "☀️ Mode clair" : "🌙 Mode sombre";
})();
function toggleTheme(){
  const current = document.documentElement.getAttribute("data-theme") || "light";
  const next = current === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("dolores_theme", next);
  document.getElementById("themeToggle").textContent = next === "dark" ? "☀️ Mode clair" : "🌙 Mode sombre";
}

/* ===== Markdown + KaTeX ===== */
async function renderMarkdown(container, text) {
  if (!window.marked) return;
  marked.setOptions({ breaks: true, mangle: false, headerIds: false });
  container.innerHTML = marked.parse(text || "");
  if (typeof renderMathInElement === "function") {
    renderMathInElement(container, {
      delimiters: [
        { left: "$$", right: "$$", display: true },
        { left: "$", right: "$", display: false },
        { left: "\\(", right: "\\)", display: false },
        { left: "\\[", right: "\\]", display: true }
      ],
      throwOnError: false,
      strict: "ignore"
    });
  }
}

/* ===== Ajout de message ===== */
function addLine(roleClass, rawText, prefix="") {
  const chat = document.getElementById("chat");
  const div = document.createElement("div");
  div.classList.add("message", roleClass);
  renderMarkdown(div, (prefix ? prefix + " " : "") + rawText);
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
  return div;
}

/* ===== Streaming ===== */
async function streamTo(url, payload, roleClass, statusLabel) {
  const status = document.getElementById("status");
  const chat = document.getElementById("chat");
  const resp = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(payload)
  });
  if (!resp.ok) { status.textContent = "⚠️ Erreur HTTP " + resp.status; return ""; }
  const reader = resp.body.getReader();
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

/* ===== Actions (inchangées) ===== */
async function btnOllama(){
  const promptEl = document.getElementById("prompt");
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  lastUserPrompt = prompt;
  addLine("user", prompt, "🧍");
  promptEl.value = "";
  const out = await streamTo("/api/ollama", { prompt }, "ollama", "Ollama");
  lastLocalText = out;
}

async function btnSubmitGPT(){
  if (!lastUserPrompt && !lastLocalText) return;
  const extra = document.getElementById("extra").value.trim();
  const out = await streamTo("/api/openai", {
    user_prompt: lastUserPrompt,
    local_reply: lastLocalText,
    extra_instruction: extra
  }, "gpt", "GPT");
  lastGptText = out;
}

async function btnReturnLocal(){
  const toSend = lastGptText || document.getElementById("prompt").value.trim();
  if (!toSend) return;
  const out = await streamTo("/api/ollama", { prompt: toSend }, "ollama", "Ollama");
  lastLocalText = out;
}

async function copyChat(){
  const chatElem = document.getElementById("chat");
  const text = chatElem ? chatElem.innerText.trim() : "";
  const badge = document.getElementById("copyok");
  if (!text) { badge.textContent = "Rien à copier"; setTimeout(()=>badge.textContent="", 1200); return; }
  try {
    await navigator.clipboard.writeText(text);
    badge.textContent = "📋 Copié";
    setTimeout(()=>badge.textContent="", 1500);
  } catch {
    badge.textContent = "⚠️ Échec";
    setTimeout(()=>badge.textContent="", 1500);
  }
}
</script>
</body>
</html>
"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)

PYCODE

  pkill -f server.py || true
  python /tmp/server.py >/tmp/bridge.log 2>&1 &
else
  log "Bridge Flask désactivé par l’utilisateur."
fi

echo ""
echo "🌐 Vous pouvez maintenant ouvrir votre navigateur :"
echo "   👉 http://127.0.0.1:8080 😊"
echo ""
echo "✅ Tout est prêt."

# === Étape 6 : Lancement Ollama ===
log "Lancement du serveur Ollama (port $PORT)..."
$SUDO docker run -it "${GPU_FLAG[@]}" \
  --net host \
  -v "$VOLUME":/root/.ollama \
  -e OLLAMA_KV_CACHE_TYPE="$CACHE_TYPE" \
  -e OLLAMA_NUM_PARALLEL=1 \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  "$IMAGE" \
  bash -lc 'ollama serve >/dev/null 2>&1 & sleep 2; exec ollama run dolores'
