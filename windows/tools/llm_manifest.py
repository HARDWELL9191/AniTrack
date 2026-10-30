"""Records the AI writer's model packages for the app: for each Snapdragon variant, Qualcomm's
download URL, size and SHA-256 (the app checks its download against them), after running the
app's own unpack-and-check code (examples/llm_check) on the real package.

Usage: python llm_manifest.py <out llm-models.json> <llm_check exe> <scratch dir>
"""
import hashlib
import json
import os
import subprocess
import sys
import urllib.request

MODEL = "Qwen3 4B Instruct"
RELEASE = "v0.65.0"  # Qualcomm AI Hub release (QAIRT 2.50); AniReco ships Genie 2.51
BASE = "https://qaihub-public-assets.s3.us-west-2.amazonaws.com/qai-hub-models/models/qwen3_4b_instruct_2507/releases"
VARIANTS = {
    "x_elite": "qualcomm_snapdragon_x_elite",
    "x2_elite": "qualcomm_snapdragon_x2_elite",
}


def fetch(url, path):
    h = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(url, timeout=120) as r, open(path, "wb") as f:
        while chunk := r.read(8 << 20):
            f.write(chunk)
            h.update(chunk)
            size += len(chunk)
    return size, h.hexdigest()


def main(out, check_exe, scratch):
    os.makedirs(scratch, exist_ok=True)
    variants = {}
    for key, soc in VARIANTS.items():
        url = f"{BASE}/{RELEASE}/qwen3_4b_instruct_2507-genie-w4a16-{soc}.zip"
        path = os.path.join(scratch, f"{key}.zip")
        size, sha = fetch(url, path)
        check = subprocess.run([check_exe, path, os.path.join(scratch, key)], capture_output=True, text=True, timeout=1800)
        os.remove(path)
        if check.returncode != 0:
            sys.exit(f"::error::{key} package failed the app's check: {check.stdout} {check.stderr}")
        print(f"::notice::{key}: {size / 1e9:.2f} GB, sha256 {sha[:16]}..., check: {check.stdout.strip()}")
        variants[key] = {"url": url, "size": size, "sha256": sha}
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"model": MODEL, "release": RELEASE, "variants": variants}, f, indent=2)


if __name__ == "__main__":
    main(*sys.argv[1:4])
