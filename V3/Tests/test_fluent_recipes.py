"""Exercise the local authoring CLI with the selected EML checkout and the V3 rig."""

import filecmp
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from V3.preview import EXAMPLE, V3, mount_catalog

EML = Path(os.environ.get("EML_ROOT", V3.parents[1] / "eml")).resolve()


def export(source, destination):
    return subprocess.run(
        [sys.executable, V3 / "preview.py", "--eml", EML, "--recipe", source, "--export", destination],
        capture_output=True, text=True,
    )


class FluentRecipes(unittest.TestCase):
    def test_opengym_and_native_assets_match_the_blender_export(self):
        runtime = V3.parent / "Revision/Sources/ExerciseDummy/Resources"
        for name in ("model.json", "vertices.bin", "indices.bin", "ATTRIBUTION.md"):
            with self.subTest(name=name):
                self.assertTrue(filecmp.cmp(EML / "anatomy" / name, runtime / name, shallow=False),
                                f"EML's distributed {name} differs from the V3 export")

    def test_native_example_matches_the_authored_chain(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "recipe.json"
            result = export(EXAMPLE.with_name("squat_and_curl.py"), output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_bytes(), EXAMPLE.read_bytes())

    def test_upstream_equipment_chain_replaces_a_catalog_id_in_preview(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "recipe.json"
            result = export(EML / "examples/fluent_incline_push_up.py", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(output.read_text())
            original = EML / "exercises/incline-push-up.json"
            self.assertEqual(document, json.loads(original.read_text()))
            document["title"] = "My incline push-up"
            output.write_text(json.dumps(document))
            self.assertEqual(mount_catalog(EML, root, output), "incline-push-up")
            matching = [path for path in root.glob("*/*.json")
                        if json.loads(path.read_text()).get("id") == "incline-push-up"]
            self.assertEqual(matching, [root / "exercises/incline-push-up.json"])
            self.assertEqual(json.loads(matching[0].read_text()), document)
            self.assertNotEqual(json.loads(original.read_text())["title"], document["title"])

    def test_failed_chain_preserves_previous_export(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "invalid.py"
            source.write_text('from eml import Recipe\n'
                              'def recipe():\n'
                              '    return Recipe("invalid", "Invalid").move("missing-movement", 1)\n')
            output = root / "recipe.json"
            output.write_bytes(EXAMPLE.read_bytes())
            result = export(source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing-movement", result.stderr)
            self.assertEqual(output.read_bytes(), EXAMPLE.read_bytes())

    def test_chain_can_extend_a_version_one_recipe_from_the_checkout(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "extend.py"
            source.write_text('from eml import Recipe, load\n'
                              'def recipe():\n'
                              '    return Recipe.from_document(load("examples/paused-goblet-look-left.json")).repeat(2)\n')
            output = root / "variant.json"
            result = export(source, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            original = json.loads((EML / "examples/paused-goblet-look-left.json").read_text())
            original["repeat"] = {"mode": "loop", "count": 2}
            self.assertEqual(json.loads(output.read_text()), original)
