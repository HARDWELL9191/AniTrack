"""CI check of the on-device AI with the real model: runs the app's engine (embed_check example)
on a few synopses and checks the vectors are sound and that similar shows land closer together
than different ones. Prints which backend ran (the CI machine has no NPU, so it reports why).

Usage: python ai_check.py <embed_check.exe> <resources dir> <scratch dir>
"""
import json
import math
import os
import subprocess
import sys

TEXTS = [
    # 0 and 1: reincarnated in a fantasy world; 2: high school volleyball; 3: space detective noir.
    "Mushoku Tensei: Jobless Reincarnation. Drama, Fantasy. Isekai, Reincarnation, Magic. "
    "A 34-year-old shut-in dies and is reborn in a world of magic, determined to live his new life without regrets.",
    "Re:ZERO -Starting Life in Another World-. Drama, Fantasy, Psychological. Isekai, Time Manipulation. "
    "Subaru Natsuki is suddenly summoned to another world and discovers he returns from death to fix his mistakes.",
    "Haikyu!!. Comedy, Drama, Sports. Volleyball, School, Team Sports. "
    "A short boy joins his high school volleyball club and teams up with a genius setter to reach nationals.",
    "Cowboy Bebop. Action, Drama, Sci-Fi. Space, Bounty Hunters, Noir. "
    "In 2071 a crew of bounty hunters drifts through the solar system chasing criminals and their own pasts.",
]


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def main(exe, res, scratch):
    os.makedirs(scratch, exist_ok=True)
    texts_path = os.path.join(scratch, "texts.json")
    with open(texts_path, "w", encoding="utf-8") as f:
        json.dump(TEXTS, f)
    run = subprocess.run([exe, res, scratch, texts_path], capture_output=True, text=True, timeout=600)
    print(run.stderr.strip())
    if run.returncode != 0:
        sys.exit(f"embed_check failed ({run.returncode})")
    out = json.loads(run.stdout)
    print("backend:", out["backend"], "|", out["detail"])
    vecs = [out["out"][str(i)]["full"] for i in range(len(TEXTS))]
    for i, v in enumerate(vecs):
        norm = math.sqrt(sum(x * x for x in v))
        if len(v) != 384 or abs(norm - 1) > 1e-3 or any(math.isnan(x) for x in v):
            sys.exit(f"vector {i}: bad shape or norm (len {len(v)}, norm {norm})")
    sims = {(i, j): cos(vecs[i], vecs[j]) for i in range(len(vecs)) for j in range(i + 1, len(vecs))}
    for (i, j), s in sims.items():
        print(f"similarity {i}-{j}: {s:.3f}")
    if not (sims[(0, 1)] > sims[(0, 2)] and sims[(0, 1)] > sims[(0, 3)] and sims[(0, 1)] > sims[(1, 2)]):
        sys.exit("the two isekai shows should be the closest pair")
    print("AI check passed")


if __name__ == "__main__":
    main(*sys.argv[1:4])
