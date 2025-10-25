#!/bin/bash

echo "[*] Suppression des modèles Dolores et LoRA..."

# Répertoire LoRA
LOADED_LORA="$HOME/.ollama/models/dolores-v5"
if [ -d "$LOADED_LORA" ]; then
    rm -rf "$LOADED_LORA"
    echo "→ $LOADED_LORA supprimé"
fi

# Répertoire modèle fusionné
MERGED_MODEL="$HOME/dolores-v5-merged"
if [ -d "$MERGED_MODEL" ]; then
    rm -rf "$MERGED_MODEL"
    echo "→ $MERGED_MODEL supprimé"
fi

# Cache Transformers (optionnel)
TRANSFORMERS_CACHE="$HOME/.cache/huggingface/transformers"
if [ -d "$TRANSFORMERS_CACHE" ]; then
    echo "→ Cache Transformers conservé pour réutilisation"
fi

echo "[✓] Reset terminé. Vous pouvez recommencer l'installation depuis zéro."
