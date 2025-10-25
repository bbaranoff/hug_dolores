#!/bin/bash
set -e

# -----------------------------
# Variables
# -----------------------------
HF_REPO="https://huggingface.co/bastienbaranoff/dolores-v5-lora"  # Ton repo HF
LORA_DIR="$HOME/.ollama/models/dolores-v5"
MERGED_DIR="$HOME/dolores-v5-merged"

# -----------------------------
# Reset des anciens modèles
# -----------------------------
echo "[*] Suppression des anciens modèles..."
rm -rf "$LORA_DIR"
rm -rf "$MERGED_DIR"

# -----------------------------
# Cloner le repo HF
# -----------------------------
echo "[*] Clonage du dépôt Hugging Face..."
git clone "$HF_REPO" /tmp/dolores-lora

# -----------------------------
# Récupérer LoRA
# -----------------------------
mkdir -p "$LORA_DIR"
cp /tmp/dolores-lora/adapter_model.safetensors "$LORA_DIR/"
cp /tmp/dolores-lora/adapter_config.json "$LORA_DIR/"
cp /tmp/dolores-lora/chat_template.jinja "$LORA_DIR/"

echo "[✓] LoRA installé dans $LORA_DIR"

# -----------------------------
# Fusionner avec le modèle de base
# -----------------------------
echo "[*] Fusion avec le modèle de base LLaMA 3.1..."
python3 <<EOF
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

base_model_name = "meta-llama/Llama-3.1-8B-Instruct"
lora_dir = "$LORA_DIR"
merged_model_dir = "$MERGED_DIR"

tokenizer = AutoTokenizer.from_pretrained(base_model_name)
model = AutoModelForCausalLM.from_pretrained(base_model_name, device_map="auto", dtype=torch.bfloat16)
model = PeftModel.from_pretrained(model, lora_dir)
model.eval()
model = model.merge_and_unload()
model.save_pretrained(merged_model_dir)
tokenizer.save_pretrained(merged_model_dir)
EOF

echo "[✓] Modèle fusionné prêt dans $MERGED_DIR"
echo "Vous pouvez maintenant lancer le chat interactif avec votre script Python."
