"""Pass recipe data to the same EML v1 evaluator used by the reference viewer."""
import json
import math

from eml import Program
from eml.data import Error, _unique

FPS = 12
MAX_SAMPLES = 3600


def reject_constant(token):
    raise Error("non-finite", "", token)


def compile_bytes(source, strict=False):
    if len(source) > 512_000:
        raise Error("source-budget", "", "Choose a recipe smaller than 512 KB")
    try:
        recipe = json.loads(source.decode("utf-8"), object_pairs_hook=_unique, parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise Error("invalid-json", "", str(exc)) from exc
    program = Program(recipe)
    repeated_travel = any(program.repeat.get("travel", []))
    cycles = program.repeat["count"] if repeated_travel else 1
    samples = math.ceil(program.duration * FPS) + len(program.doc["phases"]) + 1
    if samples * cycles > MAX_SAMPLES:
        raise Error("preview-budget", "/repeat", "Shorten the preview to 3,600 sampled poses")
    # Raw previews retain diagnostics for inspection. Authored saves and exports must conform.
    clip = program.compile(FPS, strict=strict)
    if cycles > 1:
        clip["travelCycles"] = [list(program.frames(FPS, cycle)) for cycle in range(1, cycles)]
    return json.dumps(clip, allow_nan=False, separators=(",", ":")).encode("utf-8")
