"""Preview the V3 anatomy catalog or a locally authored fluent EML recipe."""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlencode

V3 = Path(__file__).resolve().parent
EXAMPLE = V3 / "Examples/squat-and-curl.json"


def mount_catalog(eml, root, authored):
    """Expose one selectable entry per authored ID, including edits to catalog recipes."""
    recipe_id = json.loads(authored.read_text(encoding="utf-8"))["id"]
    entry = root / "examples" / f"{recipe_id}.json"
    for directory in ("exercises", "examples"):
        folder = root / directory
        folder.mkdir()
        for path in (eml / directory).glob("*.json"):
            document = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(document, dict) and document.get("id") == recipe_id:
                entry = folder / path.name
                continue
            (folder / path.name).symlink_to(path)
    while entry.exists():
        entry = entry.with_name("v3-" + entry.name)
    shutil.copyfile(authored, entry)
    return recipe_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eml", type=Path, default=Path(os.environ.get("EML_ROOT", V3.parents[1] / "eml")))
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--recipe", type=Path, help="Local Python file defining recipe()")
    parser.add_argument("--export", type=Path, metavar="FILE.json",
                        help="Write the validated recipe as portable EML JSON and exit")
    args = parser.parse_args()
    if args.export and (not args.recipe or args.export.suffix.lower() != ".json"):
        parser.error("--export needs --recipe and a .json output path")
    if args.recipe and not args.recipe.is_file():
        parser.error(f"Recipe file does not exist: {args.recipe}")
    eml = args.eml.resolve()
    python = eml / ".venv/bin/python"
    if not python.is_file():
        parser.error(f"Prepare the EML Python environment at {python.parent.parent} first.")

    with tempfile.TemporaryDirectory(prefix="v3-exercise-viewer-") as folder:
        root = Path(folder)
        # EML finds registry data relative to its own source. Compile against the V3 bind profile.
        shutil.copytree(eml / "eml", root / "eml", ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("viewer", "interface.json", "schema", "library", "compat", "docs"):
            (root / name).symlink_to(eml / name)
        (root / "anatomy").symlink_to(V3.parent / "Revision/Sources/ExerciseDummy/Resources")
        authored = EXAMPLE
        if args.recipe:
            authored = root / "authored.json"
            # A chain may extend an existing exercise or import helpers from EML's examples.
            for directory in ("exercises", "examples"):
                (root / directory).symlink_to(eml / directory)
            (root / "export_recipe.py").symlink_to(V3 / "Authoring/export_recipe.py")
            result = subprocess.run([python, "-m", "export_recipe", args.recipe.resolve(), authored], cwd=root)
            if result.returncode:
                return result.returncode
            for directory in ("exercises", "examples"):
                (root / directory).unlink()
        if args.export:
            # Replace the destination only after the entire source has compiled and been written.
            with tempfile.TemporaryDirectory(dir=args.export.parent) as staging:
                staged = Path(staging) / "recipe.json"
                shutil.copyfile(authored, staged)
                staged.replace(args.export)
            print(args.export)
            return 0

        recipe_id = mount_catalog(eml, root, authored)
        query = "?" + urlencode({"id": recipe_id}) if args.recipe else ""
        print(f"Open http://127.0.0.1:{args.port}/{query}", flush=True)
        try:
            return subprocess.run([python, "-m", "viewer", "--port", str(args.port)], cwd=root).returncode
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
