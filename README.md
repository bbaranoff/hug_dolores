Interested, star her ! When sufficient stars then may i will make her open source.

# Dolores v5 LoRA

Ce dépôt contient le **script et le template** pour utiliser **Dolores v5 LoRA** avec LLaMA 3.1-Instruct. Le LoRA permet de spécialiser le modèle sur tes données d’instructions tout en gardant la base de LLaMA.

> ⚠️ Le modèle de base LLaMA 3.1 n’est **pas inclus** pour des raisons de licence. Vous devez le télécharger séparément via Hugging Face.

---

## 📦 Contenu du dépôt

* `run_dolores_template.py` : Script Python pour lancer le chat interactif avec template Jinja.
* `chat_template.jinja` : Template Jinja pour formater les prompts.
* `adapter_config.json` : Configuration du LoRA.
* `adapter_model.safetensors` : Poids LoRA (si le repo est privé).
* `README.md` : Ce fichier.

---

## 🔧 Prérequis

* Python ≥ 3.12
* GPU recommandé (RTX 4090 ou équivalent)
* Librairies Python :

```bash
pip install torch transformers peft jinja2
```

* Git LFS si tu récupères le LoRA via Hugging Face :

```bash
git lfs install
```

---

## ⚡ Installation depuis Hugging Face

1. Cloner le dépôt :

```bash
git clone https://huggingface.co/<votre-username>/dolores-v5-lora
cd dolores-v5-lora
```

2. Installer les fichiers LoRA (adapter_model.safetensors + adapter_config.json) :

```bash
mkdir -p ~/.ollama/models/dolores-v5/
cp adapter_model.safetensors ~/.ollama/models/dolores-v5/
cp adapter_config.json ~/.ollama/models/dolores-v5/
cp chat_template.jinja ~/.ollama/models/dolores-v5/
```

---

## 🔹 Fusionner le LoRA avec le modèle de base

```bash
python merge_dolores.py
```

* Le modèle fusionné sera sauvegardé dans :

```
/home/nirvana/dolores-v5-merged/
```

* Le dossier contient : `pytorch_model.bin`, `tokenizer.json`, `config.json` → prêt pour l’inférence.

---

## 🗨️ Lancer le chat interactif

```bash
python run_dolores_template.py
```

Exemple :

```
Dolores v5 LoRA prête avec template ! Tapez 'quit' pour sortir.

Vous: Bonjour Dolores
Dolores: Bonjour ! Comment puis-je vous aider aujourd'hui ?
```

* Tape `quit` ou `exit` pour fermer le chat.

---

## ⚙️ Options et conseils

* **Dtype** : `bfloat16` recommandé pour RTX 4090.
* **Tokens générés** : `max_new_tokens=200` recommandé pour éviter de saturer la VRAM.
* **GPU faible / CPU** : utiliser `load_in_8bit=True` dans `merge_dolores.py` pour économiser de la mémoire.

