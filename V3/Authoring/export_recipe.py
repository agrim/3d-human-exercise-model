"""Run inside the selected EML environment and V3 anatomy overlay."""

import runpy
import sys
from pathlib import Path


def export(source, output):
    from eml import Error, Program

    try:
        from eml import Recipe
    except ImportError:
        raise SystemExit("Fluent authoring needs an EML checkout with eml.Recipe. "
                         "Use codex/eml-fluent-recipe or a revision that includes it.") from None

    # The overlay owns the active EML package. Local recipe helpers may live beside the source.
    sys.path.insert(1, str(source.parent))
    factory = runpy.run_path(str(source)).get("recipe")
    if not callable(factory):
        raise SystemExit(f"{source} must define a recipe() function returning eml.Recipe.")
    try:
        authored = factory()
        if not isinstance(authored, Recipe):
            raise SystemExit(f"{source}: recipe() must return an eml.Recipe.")
        Program(authored).compile(fps=24, strict=True)
        output.write_text(authored.to_json() + "\n", encoding="utf-8")
    except Error as error:
        raise SystemExit(str(error)) from None


if __name__ == "__main__":
    export(Path(sys.argv[1]), Path(sys.argv[2]))
