#!/usr/bin/env python3
"""
Bridge minimal Ollama <-> OpenAI
- Ne stocke PAS la clé OpenAI en dur : lit OPENAI_API_KEY depuis l'env.
- /api/ollama   : POST { "prompt": "..." } -> stream text/plain from Ollama
- /api/openai   : POST { "user_prompt": "...", "local_reply": "...", "extra_instruction": "..." }
                  -> streams response from OpenAI (requires OPENAI_API_KEY)
- /health       : simple health check
- UI served at / (inline minimal HTML for convenience)
"""

from __future__ import annotations
import os
import json
import time
import traceback
import requests
import openai
from typing import Iterator, Optional
from flask import Flask, request, Response, render_template_string, jsonify

# -------------------------
# Configuration (env-driven)
# -------------------------
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "dolores")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "").strip()
# Optional: custom OpenAI base url for proxies/azure
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "").strip()

# Configure openai library if key present
if OPENAI_API_KEY:
    openai.api_key = OPENAI_API_KEY
    if OPENAI_BASE_URL:
        openai.api_base = OPENAI_BASE_URL

# Flask app
app = Flask(__name__)

# -------------------------
# Utilities
# -------------------------
def log(*args):
    print("[bridge]", *args, flush=True)

def safe_json_loads(b: bytes) -> Optional[dict]:
    try:
        return json.loads(b.decode("utf-8"))
    except Exception:
        return None

# -------------------------
# Ollama streaming wrapper
# -------------------------
def stream_ollama(prompt: str) -> Iterator[str]:
    """
    Call Ollama /api/generate with stream=True and yield text chunks.
    Each line from Ollama is expected to be a JSON line (the user's earlier format).
    We tolerate non-json lines.
    """
    url = f"{OLLAMA_HOST.rstrip('/')}/api/generate"
    payload = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": True}
    headers = {"Content-Type": "application/json"}
    try:
        with requests.post(url, json=payload, headers=headers, stream=True, timeout=30) as r:
            r.raise_for_status()
            for raw in r.iter_lines(decode_unicode=False):
                if not raw:
                    continue
                j = safe_json_loads(raw)
                if not j:
                    # fallback: yield raw text decoded
                    try:
                        yield raw.decode("utf-8", errors="ignore")
                    except Exception:
                        continue
                    continue
                # Ollama incremental format — adapt depending on your Ollama version
                # We yield any "response" field and also allow partial text.
                if "response" in j:
                    yield j["response"]
                elif "token" in j:
                    # some streams use 'token'
                    yield j["token"]
                elif "done" in j and j.get("done"):
                    break
    except requests.RequestException as e:
        log("Ollama request failed:", e)
        yield f"[ERROR] Ollama connection failed: {e}\n"

# -------------------------
# OpenAI streaming wrapper
# -------------------------
def stream_openai(prompt: str) -> Iterator[str]:
    """
    Stream from OpenAI using official python client.
    If OPENAI_API_KEY is not configured, yields nothing (route will return 503 earlier).
    Uses ChatCompletion streaming interface.
    """
    if not OPENAI_API_KEY:
        return
    try:
        # Note: the exact API may vary with openai package versions.
        # This uses the ChatCompletion streaming interface available in openai>=0.27 style.
        resp = openai.ChatCompletion.create(
            model=OPENAI_MODEL,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
            request_timeout=60,
        )
        for chunk in resp:
            # chunk is typically a dict containing 'choices'
            # We try to extract text progressively.
            try:
                choices = chunk.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {})
                # delta may contain 'content' or 'role'
                part = delta.get("content") or delta.get("text") or ""
                if part:
                    yield part
            except Exception:
                # fallback: send the chunk repr
                yield json.dumps(chunk, ensure_ascii=False) + "\n"
    except Exception as e:
        log("OpenAI streaming error:", e)
        yield f"[ERROR] OpenAI streaming error: {e}\n"

# -------------------------
# Routes
# -------------------------
@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "ollama_host": OLLAMA_HOST,
        "ollama_model": OLLAMA_MODEL,
        "openai_enabled": bool(OPENAI_API_KEY)
    })

@app.route("/api/ollama", methods=["POST"])
def api_ollama():
    data = request.get_json(silent=True) or {}
    prompt = data.get("prompt", "")
    if not prompt:
        return Response("Missing 'prompt' in JSON body", status=400)

    def generator():
        try:
            for chunk in stream_ollama(prompt):
                # stream as plain text; the frontend will append progressively
                yield chunk
        except Exception:
            yield "[ERROR] Internal error in Ollama stream\n"
            log(traceback.format_exc())

    return Response(generator(), mimetype="text/plain; charset=utf-8")

@app.route("/api/openai", methods=["POST"])
def api_openai():
    # If OpenAI isn't configured, return 503 and instruct the user.
    if not OPENAI_API_KEY:
        return Response("OpenAI API not configured on this server (OPENAI_API_KEY missing).", status=503)

    data = request.get_json(silent=True) or {}
    user_prompt = data.get("user_prompt", "")
    local_reply = data.get("local_reply", "")
    extra_instruction = data.get("extra_instruction", "")

    if not user_prompt:
        return Response("Missing 'user_prompt' in JSON body", status=400)

    # Build combined instruction for OpenAI
    full_instruction = (
        f"L’utilisateur avait posé la question suivante :\n\n{user_prompt}\n\n"
        f"Le modèle local (Ollama) a répondu ceci :\n\n{local_reply}\n\n"
        "Analyse cette réponse. Si elle te paraît incomplète ou ambiguë, "
        "dis clairement quelles précisions tu souhaiterais avant de répondre. "
        "Sinon, complète-la ou commente-la selon ton jugement, en gardant le format Markdown et LaTeX si utile."
    )
    if extra_instruction:
        full_instruction += f"\n\nInstruction supplémentaire : {extra_instruction}\n"

    def generator():
        try:
            for chunk in stream_openai(full_instruction):
                yield chunk
        except Exception:
            yield "[ERROR] Internal error in OpenAI stream\n"
            log(traceback.format_exc())

    return Response(generator(), mimetype="text/plain; charset=utf-8")

# Minimal UI for convenience (can be removed)
INDEX_HTML = """
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Bridge Ollama ↔ OpenAI</title></head>
<body style="background:#111;color:#eee;font-family:system-ui,monospace;padding:18px;">
  <h2>🧠 Bridge Ollama ↔ OpenAI</h2>
  <p>Use the /api/ollama and /api/openai endpoints. /health for status.</p>
  <pre style="white-space:pre-wrap;color:#9ad;">Ollama: {{ollama}}</pre>
  <p>OpenAI enabled: {{openai}}</p>
</body>
</html>
"""

@app.route("/", methods=["GET"])
def index():
    return render_template_string(INDEX_HTML, ollama=f"{OLLAMA_HOST} (model={OLLAMA_MODEL})", openai=bool(OPENAI_API_KEY))

# -------------------------
# Main
# -------------------------
if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Bridge Ollama <-> OpenAI (Flask)")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host")
    parser.add_argument("--port", default=8080, type=int, help="Bind port for the bridge UI")
    args = parser.parse_args()

    log(f"Starting bridge on http://{args.host}:{args.port}  (OLLAMA={OLLAMA_HOST}, model={OLLAMA_MODEL})")
    if OPENAI_API_KEY:
        log("OpenAI support: ENABLED")
    else:
        log("OpenAI support: DISABLED (no OPENAI_API_KEY)")

    # Run Flask (development server; for production use gunicorn/uvicorn)
    app.run(host=args.host, port=args.port, threaded=True)
