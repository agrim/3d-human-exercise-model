"""Export the edited Blender master to the compact, indexed EML/Metal mesh format."""

import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

import bpy

MASTER_BODY = "V3 • Anatomy"
MASTER_RIG = "V3 • EML skeleton"


def eml(v):
    return (v.x, v.z, -v.y)


def fiber_coordinate(name, p):
    # Isolines follow the fascicle direction. Coordinates stay in bind space.
    x, y, z = abs(p[0]), p[1], p[2]
    if name in ("pectorals", "upperPectorals"):
        return y - 0.42 * x + 1.3 * x * x
    if name in ("serratusAnterior", "obliques", "hipFlexors"):
        return 0.66 * x - 0.53 * y + 0.48 * z
    if name in ("upperTrapezius", "trapezius", "rhomboids", "rotatorCuff", "lats"):
        return 0.83 * x - 0.44 * y + 0.3 * z
    if name in ("glutes", "hipAbductors"):
        return y - 0.69 * x - 0.22 * z
    if name == "abdominals":
        return x + 0.018 * (y - 1.12) ** 2
    if name == "footStabilizers":
        return x - 0.32 * z
    return (
        x + 0.57 * z + (0.15 * y if name in ("biceps", "triceps", "forearms", "brachialis") else -0.075 * y)
    )


def export(directory):
    rig = bpy.data.objects[MASTER_RIG]
    source = bpy.data.objects[MASTER_BODY]
    model = json.loads(rig["eml_contract"])
    names = [j["name"] for j in model["joints"]]
    group_names = model["groups"]
    for j in model["joints"]:
        bone = rig.data.bones[j["name"]]
        parent = names[j["parent"]] if j["parent"] >= 0 else None
        if (bone.parent.name if bone.parent else None) != parent:
            raise ValueError(f"Bone parent differs from EML: {bone.name}")
        if max(abs(a - b) for a, b in zip(eml(bone.head_local), j["position"])) > 0.00001:
            raise ValueError(f"Rest pivot differs from EML: {bone.name}")

    # Evaluate the editable surface in bind pose. Artist poses never enter the runtime mesh.
    rest = rig.data.pose_position
    rig.data.pose_position = "REST"
    bpy.context.view_layer.update()
    evaluated = source.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    try:
        relative = rig.matrix_world.inverted() @ evaluated.matrix_world
        if not relative.is_identity:
            mesh.transform(relative)
            if relative.is_negative:
                mesh.flip_normals()
        mesh.calc_loop_triangles()
        vertex_data = bytearray()
        batches = defaultdict(list)
        shared = {}
        group_ids = {g.index: names.index(g.name) for g in source.vertex_groups if g.name in names}
        material_ids = [group_names.index(m.name) for m in mesh.materials]
        covered_joints = set()
        visibility = mesh.attributes.get("Fascial visibility")
        for tri in mesh.loop_triangles:
            if tri.area <= 1e-14:
                continue
            group = material_ids[tri.material_index]
            batch = batches[group]
            for vi in tri.vertices:
                key = (vi, group)
                if key not in shared:
                    v = mesh.vertices[vi]
                    influences = sorted(
                        [
                            (g.weight, group_ids[g.group])
                            for g in v.groups
                            if g.group in group_ids and g.weight > 0
                        ],
                        reverse=True,
                    )[:4]
                    if not influences:
                        raise ValueError(f"Unweighted vertex {vi}")
                    total = sum(w for w, _ in influences)
                    raw = [w * 255 / total for w, _ in influences]
                    weights = [int(w) for w in raw]
                    for slot in sorted(range(len(raw)), key=lambda i: raw[i] - weights[i], reverse=True)[
                        : 255 - sum(weights)
                    ]:
                        weights[slot] += 1
                    ids = [i for _, i in influences]
                    covered_joints.update(i for i, w in zip(ids, weights) if w)
                    encoded = dict(zip(ids, weights))
                    pos = eml(v.co)
                    ao = visibility.data[vi].value if visibility else 1
                    tag = 1 + round(max(0, min(1, ao)) * 254)
                    if group_names[group] not in {"neutral", "bone", "shell", "tendon"}:
                        coordinate = round((fiber_coordinate(group_names[group], pos) + 2) * 16384)
                        tag |= (3 << 8) | (max(0, min(65535, coordinate)) << 16)
                    for side_id, side in enumerate(("left", "right"), 1):
                        forearm = encoded.get(names.index(side + "Forearm"), 0)
                        hand = encoded.get(names.index(side + "Hand"), 0)
                        if forearm and hand:
                            tag = (tag & 255) | side_id << 8 | forearm << 16 | hand << 24
                            break
                    ids += [0] * (4 - len(ids))
                    weights += [0] * (4 - len(weights))
                    shared[key] = len(shared)
                    vertex_data.extend(
                        struct.pack("<6f8B2I", *pos, *eml(v.normal), *ids, *weights, group, tag)
                    )
                batch.append(shared[key])
        active = set(group_names) - {"neutral", "bone", "tendon", "shell"}
        missing = active - {group_names[i] for i in batches}
        if missing or len(covered_joints) != len(names):
            raise ValueError(
                f"Missing surface groups {missing} or weights {set(range(len(names))) - covered_joints}"
            )
        parts, indices = [], bytearray()
        for group, items in sorted(batches.items()):
            parts.append(
                {
                    "name": group_names[group],
                    "group": group_names[group],
                    "firstIndex": len(indices) // 4,
                    "indexCount": len(items),
                }
            )
            indices.extend(struct.pack(f"<{len(items)}I", *items))
        model.update(
            version=1,
            modelID="simple-trainer-v3",
            parts=parts,
            vertexCount=len(shared),
            indexCount=len(indices) // 4,
            wristPivots=["leftHand", "rightHand"],
        )
        directory.mkdir(exist_ok=True, parents=True)
        (directory / "vertices.bin").write_bytes(vertex_data)
        (directory / "indices.bin").write_bytes(indices)
        (directory / "model.json").write_text(json.dumps(model, indent=2) + "\n")
        print(
            f"V3: {len(shared):,} vertices, {len(indices) // 12:,} triangles, "
            f"{len(vertex_data) + len(indices):,} buffer bytes; {len(active)} muscle roles."
        )
    finally:
        evaluated.to_mesh_clear()
        rig.data.pose_position = rest


if __name__ == "__main__":
    export(Path(sys.argv[sys.argv.index("--") + 1]))
