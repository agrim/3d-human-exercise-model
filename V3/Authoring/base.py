"""Fit the authored MPFB surface and deform weights to EML's bind skeleton."""

import gzip
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
from fetch_base import FILES, TARGETS


def read_body(folder):
    vertices, faces = [], defaultdict(list)
    group = None
    with (folder / "base.obj").open() as obj:
        for line in obj:
            words = line.split()
            if not words:
                continue
            if words[0] == "v":
                vertices.append([float(v) for v in words[1:4]])
            elif words[0] == "g":
                group = words[1]
            elif words[0] == "f":
                faces[group].append([int(v.partition("/")[0]) - 1 for v in words[1:]])
    points = np.array(vertices)
    for name in sorted(f for f in FILES if f.endswith(".gz")):
        file = folder / Path(name).name
        with gzip.open(file) as target:
            delta = np.loadtxt(target)
        factor = TARGETS.get(
            name.removeprefix("targets/").removesuffix(".target.gz"),
            1 if file.name.startswith("universal") else 1 / 3,
        )
        points[delta[:, 0].astype(int)] += factor * delta[:, 1:]
    return points * 0.1, faces


def unit(v):
    return v / np.linalg.norm(v)


def basis(along, across):
    y = unit(along)
    x = unit(across - y * np.dot(y, across))
    return np.column_stack((x, y, np.cross(x, y)))


def retarget(folder, contract):
    points, groups = read_body(folder)
    source = json.loads((folder / "rig.game_engine.json").read_text())
    weights = json.loads((folder / "weights.game_engine.json").read_text())["weights"]
    joints = contract["joints"]
    positions = {j["name"]: np.array(j["position"]) for j in joints}
    names = list(positions)

    def joint(description):
        if description["strategy"] == "CUBE":
            indices = np.unique(groups[description["cube_name"]])
        else:
            indices = description["vertex_indices"]
        return points[indices].mean(axis=0)

    heads = {k: joint(b["head"]) for k, b in source.items()}
    tails = {k: joint(b["tail"]) for k, b in source.items()}
    # The torso's two middle source vertebrae straddle the EML spine/chest contract.
    extra = (positions["spine"] + positions["chest"]) * 0.5
    aim = {
        "pelvis": ("pelvis", positions["spine"], "pelvis"),
        "spine_01": ("spine", extra, "spine"),
        "spine_02": (extra, positions["chest"], "spine"),
        "spine_03": ("chest", positions["neck"], "chest"),
        "neck_01": ("neck", positions["head"], "neck"),
        "head": ("head", positions["head"] + [0, 0.165, -0.006], "head"),
    }
    for side, suffix in [("left", "_l"), ("right", "_r")]:
        for src, dst, end in [
            ("clavicle", "Clavicle", "UpperArm"),
            ("upperarm", "UpperArm", "Forearm"),
            ("lowerarm", "Forearm", "Hand"),
            ("hand", "Hand", "Middle1"),
            ("thigh", "Thigh", "Shin"),
            ("calf", "Shin", "Foot"),
            ("foot", "Foot", "Toe"),
            ("ball", "Toe", None),
        ]:
            tip = (
                positions[side + end]
                if end
                else positions[side + dst] + [0.006 if side == "left" else -0.006, -0.005, 0.064]
            )
            aim[src + suffix] = (side + dst, tip, side + dst)
        for src, dst in [
            ("thumb", "Thumb"),
            ("index", "Index"),
            ("middle", "Middle"),
            ("ring", "Ring"),
            ("pinky", "Little"),
        ]:
            digits = ["Base", "1", "2"] if src == "thumb" else ["1", "2", "3"]
            chain = [positions[side + dst + digit] for digit in digits]
            tip = chain[-1] + unit(chain[-1] - chain[-2]) * (0.022 if src == "thumb" else 0.017)
            for i, (digit, end) in enumerate(zip(digits, chain[1:] + [tip])):
                name = side + dst + digit
                aim[f"{src}_0{i + 1}{suffix}"] = (name, end, name)

    mapped = np.zeros_like(points)
    skin = np.zeros((len(points), len(names)))
    for src, (start, end, bind) in aim.items():
        start = positions[start] if isinstance(start, str) else start
        entries = np.array(weights[src])
        indices = entries[:, 0].astype(int)
        strength = entries[:, 1]
        across_src = across_dst = np.array([1.0, 0.0, 0.0])
        src_end = heads["neck_01"] if src == "spine_03" else tails[src]
        if src.startswith(("upperarm", "lowerarm", "clavicle")):
            across_src = across_dst = np.array([0.0, 0.0, 1.0])
        if src.startswith(("hand", "thumb", "index", "middle", "ring", "pinky")):
            side = "left" if src.endswith("_l") else "right"
            suffix = src[-2:]
            across_src = heads["index_01" + suffix] - heads["pinky_01" + suffix]
            across_dst = positions[side + "Index1"] - positions[side + "Little1"]
            if src.startswith("hand"):
                src_end = heads["middle_01" + suffix]
        local = (points[indices] - heads[src]) @ basis(src_end - heads[src], across_src)
        length_scale = np.linalg.norm(end - start) / np.linalg.norm(src_end - heads[src])
        # Scale length independently so EML contact spacing doesn't shrink limb girth.
        girth = 0.92
        if src.startswith(("foot", "ball")):
            girth = 0.82
        local *= [girth, length_scale, girth]
        fitted = start + local @ basis(end - start, across_dst).T
        if bind in ("pelvis", "spine", "chest"):
            # Keep the thoracic cage intact across segmented source vertebrae.
            # Their rest axes can diverge substantially in the sagittal plane.
            h = points[indices, 1]
            anchors = ["pelvis", "spine_01", "spine_03", "neck_01"]
            heights = [heads[k][1] for k in anchors]
            dest = np.array([positions[k] for k in ("pelvis", "spine", "chest", "neck")])
            fitted[:, 0] = points[indices, 0] * 0.96
            fitted[:, 1] = h + np.interp(h, heights, dest[:, 1] - heights)
            depth_offset = dest[:, 2] - [heads[k][2] for k in anchors]
            fitted[:, 2] = points[indices, 2] * 0.92 + np.interp(h, heights, depth_offset)
        mapped[indices] += fitted * strength[:, None]
        skin[indices, names.index(bind)] += strength
    visible = groups["body"] + groups["helper-l-eye"] + groups["helper-r-eye"]
    ids = np.unique(np.concatenate(visible))
    if np.min(skin[ids].sum(axis=1)) < 0.9:
        raise ValueError("Unweighted visible geometry")
    mapped = mapped[ids] / skin[ids].sum(axis=1)[:, None]
    skin = skin[ids] / skin[ids].sum(axis=1)[:, None]
    index = {v: i for i, v in enumerate(ids)}
    faces = [tuple(index[i] for i in f) for f in visible]
    return mapped, faces, skin, points[ids]


def relax_bind_weights(points, faces, weights, joints, original):
    """Regularize steep weight gradients left where the A-pose folds into EML rest."""
    from mathutils.kdtree import KDTree

    # Area-weight the kernel; the denser groin and underarm loops should not bias it.
    area = np.zeros(len(points))
    for f in faces:
        tri = points[list(f[:3])]
        area[list(f)] += np.linalg.norm(np.cross(tri[1] - tri[0], tri[2] - tri[0]))
    result = weights.copy()
    index = {j["name"]: i for i, j in enumerate(joints)}
    side_x = np.abs(points[:, 0])
    for side in ("left", "right"):
        sign = 1 if side == "left" else -1
        for center, radii, sigma, bones in [
            (
                (0.065, 0.849, 0.005),
                (0.155, 0.186, 0.157),
                0.036,
                ["pelvis", "spine", "leftThigh", "rightThigh"],
            ),
            (
                (0.15, 1.36, 0.005),
                (0.119, 0.123, 0.125),
                0.031,
                ["chest", "neck", side + "Clavicle", side + "UpperArm"],
            ),
            ((0.213, 1.125, 0), (0.085, 0.103, 0.087), 0.022, [side + "UpperArm", side + "Forearm"]),
            ((0.075, 0.452, 0), (0.092, 0.117, 0.105), 0.021, [side + "Thigh", side + "Shin"]),
        ]:
            axis = np.array(center) * [sign, 1, 1]
            # Shared pelvic vertices see the same smooth field from both sides.
            offset = (points - axis) / radii
            if "pelvis" in bones:
                offset[:, 0] = (side_x - center[0]) / radii[0]
            dist = np.linalg.norm(offset, axis=1)
            mass = weights[:, [index[n] for n in bones]].sum(1)
            ids = np.flatnonzero((dist < 1.65) & (mass > 0.80))
            tree = KDTree(len(ids))
            for i in ids:
                tree.insert(points[i], int(i))
            tree.balance()
            for i in ids[(dist[ids] < 1.04) & (points[ids, 0] * sign >= 0)]:
                neighbors = tree.find_range(points[i], sigma * 2.8)
                indices = np.array([n[1] for n in neighbors])
                distance = np.array([n[2] for n in neighbors])
                if side + "UpperArm" in bones and "chest" in bones:
                    # In the lowered bind pose, medial upper arm skin almost touches the
                    # rib cage. Keep those surfaces distinct using their A-pose separation.
                    distance = np.linalg.norm(original[indices] - original[i], axis=1)
                kernel = np.exp(-0.5 * (distance / sigma) ** 2) * area[indices]
                if kernel.sum() > 0:
                    blend = np.clip((1.04 - dist[i]) / 0.32, 0, 1) * mass[i]
                    result[i] = weights[i] * (1 - blend) + blend * (
                        kernel @ weights[indices] / kernel.sum()
                    )
    return result
