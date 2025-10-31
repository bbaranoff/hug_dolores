#!/usr/bin/env python3
import os
import json
import requests
import openai
from flask import Flask, request, Response, render_template_string

# === CONFIGURATION ===
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
openai.api_key = os.getenv("OPENAI_API_KEY", "sk-....")

app = Flask(__name__)

# === STREAMING ===
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

def stream_openai(prompt):
    stream = openai.chat.completions.create(
        model=OPENAI_MODEL,
        messages=[{"role": "user", "content": prompt}],
        stream=True
    )
    for chunk in stream:
        delta = chunk.choices[0].delta
        if delta and delta.content:
            yield delta.content

# === ROUTES ===
@app.route("/")
def index():
    return render_template_string(INDEX_HTML)

@app.route("/api/ollama", methods=["POST"])
def api_ollama():
    prompt = request.json.get("prompt", "")
    return Response(stream_ollama(prompt), mimetype="text/plain")

@app.route("/api/openai", methods=["POST"])
def api_openai():
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

# === FRONTEND ===
INDEX_HTML = """
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Bridge Ollama ↔ OpenAI</title>

<!-- Markdown -->
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>

<!-- MathJax pour le LaTeX -->
<script>
window.MathJax = {
  tex: {
    inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
    displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
    processEscapes: true
  },
  options: { skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code'] },
  startup: { typeset: false }
};
</script>
<script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>

<style>
  body { font-family: system-ui, monospace; background:#111; color:#eee; margin:0; padding:20px; }
  #chat { background:#181818; padding:10px; border-radius:6px; min-height:300px; overflow-y:auto; }
  .user { color:#6cf; margin-bottom:8px; }
  .ollama { color:#8f8; margin-bottom:8px; }
  .gpt { color:#fc8; margin-bottom:8px; }
  textarea { width:100%; background:#222; color:#eee; border:none; padding:10px; border-radius:6px; }
  #prompt { height:60px; margin-top:10px; }
  #extra  { height:40px; font-size:0.9em; opacity:0.8; margin-top:5px; }
  #extra:focus { opacity:1; }
  button { margin:5px; padding:8px 15px; background:#333; color:#eee;
           border:1px solid #555; cursor:pointer; border-radius:4px; }
  button:hover { background:#444; }
  #status { color:#888; margin-top:5px; font-style:italic; }
  .message { padding:6px; border-bottom:1px solid #333; }
</style>
</head>
<body>
<h2>🧠 Bridge Ollama ↔ OpenAI</h2>

<div id="chat"></div>

<textarea id="prompt" placeholder="Écris ton message ici... (Markdown et LaTeX acceptés)"></textarea>
<textarea id="extra" placeholder="(Optionnel) Instruction supplémentaire pour l'IA — ex. : 'Traduis en anglais'"></textarea><br/>

<button onclick="btnOllama()">Réponse Ollama</button>
<button onclick="btnSubmitGPT()">Soumettre à GPT</button>
<button onclick="btnReturnLocal()">Renvoyer au local</button>
<button onclick="copyChat()">Copier la discussion complète</button>
<span id="copyok" style="margin-left:8px;color:#8f8;"></span>
<div id="status"></div>

<script>
let lastUserPrompt = "";
let lastLocalText = "";
let lastGptText   = "";

// ===== Markdown + LaTeX =====
async function renderMarkdown(container, text) {
  container.innerHTML = marked.parse(text);
  if (window.MathJax && window.MathJax.typesetPromise) {
    await MathJax.typesetClear([container]);
    await MathJax.typesetPromise([container]);
  }
}

// ===== Ajout de message =====
function addLine(roleClass, rawText, prefix="") {
  const chat = document.getElementById("chat");
  const div = document.createElement("div");
  div.classList.add("message", roleClass);
  chat.appendChild(div);
  renderMarkdown(div, (prefix ? prefix + " " : "") + rawText);
  chat.scrollTop = chat.scrollHeight;
  return div;
}

// ===== Fabrique de payload =====
function getPayload(basePrompt, includeInstruction=true) {
  const extra = document.getElementById("extra").value.trim();
  if (includeInstruction && extra) {
    return { prompt: basePrompt + "\\n\\n[Instruction: " + extra + "]" };
  }
  return { prompt: basePrompt };
}

// ===== Streaming =====
async function streamTo(url, payload, roleClass, statusLabel) {
  const status = document.getElementById("status");
  const chat = document.getElementById("chat");
  const resp = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(payload)
  });

  if (!resp.ok) throw new Error("Erreur HTTP : " + resp.status);

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

  await new Promise(r => setTimeout(r, 1000));
  status.textContent = "✅ " + statusLabel + " terminé";
  return collected.trim();
}

// ===== Actions principales =====
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

// ===== Copier toute la discussion =====
async function copyChat() {
  const chatElem = document.getElementById("chat");
  const text = chatElem ? chatElem.innerText.trim() : "";
  const badge = document.getElementById("copyok");
  if (!text) {
    badge.textContent = "Rien à copier";
    setTimeout(() => badge.textContent = "", 1200);
    return;
  }
  try {
    await navigator.clipboard.writeText(text);
    badge.textContent = "📋 Discussion copiée";
    setTimeout(() => badge.textContent = "", 1500);
  } catch (e) {
    badge.textContent = "⚠️ Échec de copie";
    setTimeout(() => badge.textContent = "", 1500);
  }
}
</script>
</body>
</html>
"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
