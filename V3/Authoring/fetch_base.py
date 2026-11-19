"""Fetch only the pinned CC0 art inputs required to regenerate the V3 body."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen

REVISION = "9de0707fdc88438d7c53a1a2ac7937d9221e2431"
DATA = f"https://raw.githubusercontent.com/makehumancommunity/mpfb2/{REVISION}/src/mpfb/data/"
FILES = [
    "3dobjs/base.obj",
    "rigs/standard/rig.game_engine.json",
    "rigs/standard/weights.game_engine.json",
    *[f"targets/macrodetails/{name}-male-young.target.gz" for name in ("african", "asian", "caucasian")],
    "targets/macrodetails/universal-male-young-maxmuscle-averageweight.target.gz",
]

TARGETS = {
    "stomach/stomach-tone-incr": 0.85,
    "torso/torso-vshape-incr": 0.60,
    "torso/torso-muscle-pectoral-incr": 0.48,
    "torso/torso-muscle-dorsi-incr": 0.55,
    "buttocks/buttocks-volume-incr": 0.20,
}
for side in ("l", "r"):
    for part, area, amount in [
        ("upperarm", "arms", 0.55),
        ("upperarm-shoulder", "arms", 0.6),
        ("lowerarm", "arms", 0.36),
        ("upperleg", "legs", 0.56),
        ("lowerleg", "legs", 0.42),
    ]:
        TARGETS[f"{area}/{side}-{part}-muscle-incr"] = amount
FILES.extend(f"targets/{key}.target.gz" for key in TARGETS)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    destination = parser.parse_args().directory
    destination.mkdir(parents=True, exist_ok=True)

    def download(name):
        with urlopen(DATA + name, timeout=90) as response:
            (destination / Path(name).name).write_bytes(response.read())

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(download, FILES))
