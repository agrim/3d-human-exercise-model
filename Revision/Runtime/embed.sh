#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -d .cache/Python.xcframework || ! -d .cache/wheels ]]; then
  echo "error: Run bash Revision/Runtime/bootstrap.sh before building." >&2
  exit 1
fi
/usr/bin/python3 stage.py
