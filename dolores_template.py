import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
from peft import PeftModel
from jinja2 import Template

# -----------------------------
# Chemins
# -----------------------------
base_model_name = "meta-llama/Llama-3.1-8B-Instruct"
lora_dir = "/home/nirvana/.ollama/models/dolores-v5/"
template_file = "/home/nirvana/.ollama/models/dolores-v5/chat_template.jinja"

# -----------------------------
# Charger le tokenizer et le modèle
# -----------------------------
tokenizer = AutoTokenizer.from_pretrained(base_model_name)
model = AutoModelForCausalLM.from_pretrained(
    base_model_name,
    device_map="auto",
    load_in_8bit=True  # très efficace pour économiser de la VRAM
)

# Appliquer LoRA
model = PeftModel.from_pretrained(model, lora_dir)
model.eval()

# -----------------------------
# Charger le template Jinja
# -----------------------------
with open(template_file, "r", encoding="utf-8") as f:
    template_content = f.read()
jinja_template = Template(template_content)

# -----------------------------
# Boucle interactive
# -----------------------------
print("Dolores v5 LoRA prête avec template ! Tapez 'quit' pour sortir.")

while True:
    user_input = input("\nVous: ")
    if user_input.lower() in ["quit", "exit"]:
        break

    messages = [{"role": "user", "content": user_input}]
    prompt = jinja_template.render(messages=messages)

    # Générer le prompt via Jinja
    #prompt = jinja_template.render(user_input=user_input)

    # Tokenization
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)

    # Génération
    with torch.no_grad():
        output_ids = model.generate(**inputs, max_new_tokens=200)
    response = tokenizer.decode(output_ids[0], skip_special_tokens=True)

    print(f"Dolores: {response}")
