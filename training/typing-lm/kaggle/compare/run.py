import glob, os, subprocess, sys, shutil
import torch, transformers
print("torch", torch.__version__, "transformers", transformers.__version__, "cpus", os.cpu_count(), flush=True)
inp = "/kaggle/input"
def find(name):
    hits = sorted(glob.glob(f"{inp}/**/{name}", recursive=True))
    print(name, "->", hits, flush=True)
    return hits
evaldir = os.path.dirname(find("cases.json")[0])
work = "/kaggle/working/eval"; shutil.copytree(evaldir, work, dirs_exist_ok=True)
script = os.path.join(work, "evaluate.py")
models = []
from huggingface_hub import snapshot_download
stock = snapshot_download("distilbert/distilgpt2", revision="2290a62682d06624634c1f46a6ad5be0f47f38aa",
                          allow_patterns=["config.json", "model.safetensors", "tokenizer.json", "vocab.json", "merges.txt", "tokenizer_config.json", "generation_config.json"])
models.append(("stock", stock))
for cfg in find("config.json"):
    folder = os.path.dirname(cfg)
    label = os.path.basename(folder)
    if label in ("quarter", "half", "full"):
        models.append(("hinglish-" + label, folder))
threads = str(os.cpu_count() or 4)
for label, folder in models:
    print(f"===== {label} ({folder})", flush=True)
    subprocess.run([sys.executable, script, "--model", folder, "--name", label, "--eval-dir", work,
                    "--context", "32", "--second", "0", "--threads", threads], check=False)
print("DONE", flush=True)
