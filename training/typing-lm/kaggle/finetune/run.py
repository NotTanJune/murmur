# Murmur plan 004: Hinglish fine-tune of distilgpt2 on Kaggle's GPU T4 x2.
import os, shutil, subprocess, sys
found = None
for root, _, files in os.walk("/kaggle/input"):
    if "added-tokens.txt" in files:
        found = root
        break
assert found, "the murmur-hinglish-inputs dataset is not attached"
work = "/tmp/in"
shutil.copytree(found, work, dirs_exist_ok=True)
print("inputs:", sorted(os.listdir(work)), flush=True)
subprocess.run([sys.executable, "-m", "pip", "install", "-q", "transformers==4.53.2"], check=True)
subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv"])
sample = next(n for n in ("hinglish-sample.txt.gz", "hinglish-sample.txt") if os.path.exists(os.path.join(work, n)))
out = "/kaggle/working/ft"
cmd = [sys.executable, "finetune.py", "--eval-sentences", "eval-sentences.tsv", "--out", out,
       "--data", "/tmp/data", "--hinglish", sample, "--hinglish-share", "0.15",
       "--added-tokens", "added-tokens.txt", "--eval-batch", "128"]
with open("/kaggle/working/ft.log", "w") as log:
    process = subprocess.Popen(cmd, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        print(line, end="", flush=True)
        log.write(line)
        log.flush()
    sys.exit(process.wait())
