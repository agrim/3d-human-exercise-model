"""Refresh the hosted iOS tests' reference samples from the running EML anatomy viewer."""

import json
from pathlib import Path
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:8765"
REVISION = Path(__file__).resolve().parents[1]
JOINTS = ["head", "leftHand", "rightHand", "leftThigh", "rightThigh", "leftFoot", "rightFoot"]


def reference(path, source=None):
    request = Request(BASE + path, data=source, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=30) as response:
        clip = json.load(response)
    frames = clip["frames"]
    # Every compliant sample grid includes these phase endpoints.
    keys = [frames[0]] + [
        frame for i, frame in enumerate(frames)
        if i + 1 == len(frames) or frames[i + 1]["phase"] != frame["phase"]
    ]
    result = {"id": clip["id"], "duration": clip["duration"], "samples": []}
    for frame in keys:
        if frame["diagnostics"]:
            raise ValueError(f"Viewer reported a contact error in {clip['id']} at {frame['time']}")
        result["samples"].append({
            "time": frame["time"], "phase": frame["phase"], "root": frame["root"],
            "muscles": frame["muscles"],
            "rotations": {key: frame["rotations"][key] for key in JOINTS},
            "equipment": {
                key: {"position": pose["position"], "rotation": pose["rotation"]}
                for key, pose in frame["equipment"].items()
            },
        })
    if source is not None:
        result["customSource"] = source.decode()
    return result


def main():
    custom = (REVISION / "Review/EML/studio-custom-goblet.json").read_bytes()
    fixtures = [
        reference("/api/clip?entry=exercises%2Fsuitcase-carry.json"),
        reference("/api/preview", custom),
    ]
    (REVISION / "iOSTests/viewer-reference.json").write_text(
        json.dumps(fixtures, separators=(",", ":"), ensure_ascii=False) + "\n"
    )


if __name__ == "__main__":
    main()
