"""Run EML's browser viewer on localhost with the V3 human and the chosen EML checkout."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--eml", type=Path, default=Path(os.environ.get("EML_ROOT", REPO.parent / "eml")))
parser.add_argument("--port", type=int, default=8766)
args = parser.parse_args()
eml = args.eml.resolve()
python = eml / ".venv/bin/python"
if not python.is_file():
    parser.error(f"Prepare the EML Python environment at {python.parent.parent} first.")
with tempfile.TemporaryDirectory(prefix="v3-exercise-viewer-") as folder:
    root = Path(folder)
    # The compiler resolves data relative to its own source path. Give it a private
    # module copy, so both its registry and the HTTP viewer read the V3 bind profile.
    shutil.copytree(eml / "eml", root / "eml", ignore=shutil.ignore_patterns("__pycache__"))
    for name in (
        "viewer",
        "interface.json",
        "schema",
        "library",
        "exercises",
        "examples",
        "compat",
        "docs",
    ):
        (root / name).symlink_to(eml / name)
    (root / "anatomy").symlink_to(REPO / "Revision/Sources/ExerciseDummy/Resources")
    try:
        subprocess.run([str(python), "-m", "viewer", "--port", str(args.port)], cwd=root, check=True)
    except KeyboardInterrupt:
        pass
