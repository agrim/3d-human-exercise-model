#!/usr/bin/env bash
# Prepare portable EML work; native compilation remains a macOS/Xcode workflow.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ is required"'
if [[ -z "${EML_ROOT:-}" ]]; then
  for candidate in "$root/../eml" "$root/../exercise-markup-language"; do
    if [[ -f "$candidate/eml/program.py" ]]; then EML_ROOT="$candidate"; break; fi
  done
fi
if [[ -z "${EML_ROOT:-}" || ! -f "$EML_ROOT/requirements.txt" || ! -f "$EML_ROOT/eml/program.py" ]]; then
  echo "Select agrim/exercise-markup-language too, and set EML_ROOT to its checkout path." >&2
  exit 1
fi
EML_ROOT="$(cd "$EML_ROOT" && pwd)"
python3 -m venv "$EML_ROOT/.venv"
"$EML_ROOT/.venv/bin/python" -m pip install --disable-pip-version-check -r "$EML_ROOT/requirements.txt"
printf 'Portable EML Python: %s/.venv/bin/python\n' "$EML_ROOT"
echo "Do not run the Apple runtime bootstrap or claim native rendering checks on Linux."
