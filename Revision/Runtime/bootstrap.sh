#!/bin/bash
# Fetch the exact BeeWare runtime and pure Python schema-validation wheels before opening Xcode.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .cache/wheels
if [[ ! -f .cache/Python.xcframework/.eml-b18 ]]; then
  expected=d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d
  if ! echo "$expected  .cache/Python.tar.gz" | shasum -a256 -c - >/dev/null 2>&1; then
    curl --fail --location --retry 3 https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz -o .cache/Python.tar.gz
  fi
  echo "$expected  .cache/Python.tar.gz" | shasum -a256 -c -
  tar -xzf .cache/Python.tar.gz -C .cache
  touch .cache/Python.xcframework/.eml-b18
fi
/usr/bin/python3 - <<'PY'
import hashlib, json, subprocess
from pathlib import Path
for wheel in json.loads(Path("wheels.json").read_text()):
    path = Path(".cache/wheels") / wheel["name"]
    def verified():
        return path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == wheel["sha256"]
    if not verified():
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--silent", "--show-error",
                        wheel["url"], "-o", str(path)], check=True)
    if not verified():
        raise SystemExit(f"Checksum mismatch: {path}")
PY
