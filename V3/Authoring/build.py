"""Create an editable, skinned V3 Blender master from pinned art and the EML rig interface."""

import json
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Quaternion, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from base import relax_bind_weights, retarget
from export import MASTER_BODY, MASTER_RIG, export
from regions import sample


def blender(p):
    return (p[0], -p[2], p[1])


def make_surface(name, points, faces, weights, joints):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([blender(p) for p in points], [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    for i, j in enumerate(joints):
        g = obj.vertex_groups.new(name=j["name"])
        for vi in np.flatnonzero(weights[:, i] > 1e-5):
            g.add([int(vi)], weights[vi, i], "REPLACE")
    return obj


def cut_regions(points, triangles, skin, scores):
    # Intersect each triangle with the linear muscle-membership boundaries. Both
    # sides of an incision share positions and deform weights, including at junctions.
    out = list(points)
    out_weights = list(skin)
    faces, materials = [], []
    cache = {}
    labels = scores.argmax(1)
    for face in triangles:
        corners = np.asarray(face)
        owner = labels[corners]
        if min(owner) == max(owner):
            faces.append(face)
            materials.append(int(owner[0]))
            continue
        local = scores[corners]
        # A narrow third region can win inside the face without winning at a corner.
        possible = np.flatnonzero(local.max(axis=0) >= 0)
        # Any candidate dominated at every corner cannot win inside the triangle.
        possible = [
            i for i in possible if not any(np.all(local[:, j] > local[:, i]) for j in set(owner) if j != i)
        ]
        for label in possible:
            poly = list(np.eye(3))
            for other in possible:
                if other == label:
                    continue
                delta = local[:, label] - local[:, other]
                clipped = []
                for a, b in zip(poly, poly[1:] + poly[:1]):
                    da, db = a @ delta, b @ delta
                    if da >= 0:
                        clipped.append(a)
                    if (da > 0 and db < 0) or (da < 0 and db > 0):
                        clipped.append((da * b - db * a) / (da - db))
                poly = clipped
                if len(poly) < 3:
                    break
            if len(poly) < 3:
                continue
            ids = []
            for bary in poly:
                if bary.max() > 1 - 1e-7:
                    idx = int(corners[bary.argmax()])
                else:
                    key = tuple(
                        sorted((int(i), round(float(v), 7)) for i, v in zip(corners, bary) if v > 1e-7)
                    )
                    if key not in cache:
                        cache[key] = len(out)
                        out.append(bary @ points[corners])
                        out_weights.append(bary @ skin[corners])
                    idx = cache[key]
                ids.append(idx)
            for k in range(1, len(ids) - 1):
                f = (ids[0], ids[k], ids[k + 1])
                if len(set(f)) == 3:
                    faces.append(f)
                    materials.append(label)
    return out, faces, np.asarray(out_weights), materials


def refine_mobile_shoulders(obj, joints):
    """Limit weight gradients along connected edges of the final shoulder topology."""
    mesh = obj.data
    positions = np.array([(v.co.x, v.co.z, -v.co.y) for v in mesh.vertices])
    edges = np.array([tuple(e.vertices) for e in mesh.edges])
    ids = [
        i
        for i, j in enumerate(joints)
        if j["name"]
        in {"spine", "chest", "neck", "leftClavicle", "leftUpperArm", "rightClavicle", "rightUpperArm"}
    ]
    weights = np.zeros((len(positions), len(ids)))
    for v in mesh.vertices:
        for g in v.groups:
            if g.group in ids:
                weights[v.index, ids.index(g.group)] = g.weight
    movable = (weights.sum(1) > 0.98) & (positions[:, 1] > 1.14) & (np.abs(positions[:, 0]) > 0.05)
    a, b = edges[movable[edges].all(1)].T
    span = np.linalg.norm(positions[a] - positions[b], axis=1)
    # Eight units of weight per metre spreads a full change over about 12 cm.
    limit = 8.0 * span
    degree = np.maximum(1, np.bincount(np.r_[a, b], minlength=len(positions)))
    for _ in range(70):
        diff = weights[b] - weights[a]
        magnitude = np.abs(diff).sum(axis=1) * 0.5
        step = 0.9 * np.maximum(0, 1 - limit / np.maximum(1e-9, magnitude))[:, None] * diff
        delta = np.zeros_like(weights)
        np.add.at(delta, a, step)
        np.add.at(delta, b, -step)
        weights += delta / degree[:, None]
    for column, vg in enumerate(ids):
        group = obj.vertex_groups[vg]
        for i in np.flatnonzero(movable):
            group.add([int(i)], max(0, weights[i, column]), "REPLACE")


def skeleton(contract):
    rig = bpy.data.armatures.new("EML bind pivots")
    obj = bpy.data.objects.new(MASTER_RIG, rig)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    rig.display_type = "STICK"
    bpy.ops.object.mode_set(mode="EDIT")
    joints = contract["joints"]
    for i, j in enumerate(joints):
        b = rig.edit_bones.new(j["name"])
        b.head = blender(j["position"])
        children = [c for c in joints if c["parent"] == i]
        if children:
            # Longitudinal guides on the chest, pelvis and palm follow their central chain.
            child = next(
                (c for c in children if c["name"] in ("spine", "neck") or c["name"].endswith("Middle1")),
                children[0],
            )
            b.tail = blender(child["position"])
        else:
            parent = Vector(blender(joints[j["parent"]]["position"]))
            length = 0.145 if b.name == "head" else 0.047 if b.name.endswith("Toe") else 0.017
            b.tail = b.head + (b.head - parent).normalized() * length
        if j["parent"] >= 0:
            b.parent = rig.edit_bones[joints[j["parent"]]["name"]]
    bpy.ops.object.mode_set(mode="OBJECT")
    obj["eml_contract"] = json.dumps(contract, separators=(",", ":"))
    return obj


def build(inputs, eml_root, master, runtime):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    reference = json.loads((eml_root / "anatomy/model.json").read_text())
    contract = {k: reference[k] for k in ["joints", "landmarks", "handBindings", "groups"]}
    joints = contract["joints"]
    points, faces, weights, original = retarget(inputs, contract)
    # Fit heel and metatarsal contact pads to the EML floor; keep the instep and ankle.
    z = points[:, 2]
    drop = np.interp(
        z,
        [-0.06, -0.035, -0.016, 0.033, 0.073, 0.103, 0.15],
        [0.024, 0.022, 0.019, 0.018, 0.010, 0.006, 0.002],
    )
    points[:, 1] -= np.clip((0.102 - points[:, 1]) / 0.066, 0, 1) * drop
    weights = relax_bind_weights(points, faces, weights, joints, original)
    body = make_surface("Control cage", points, faces, weights, joints)
    sub = body.modifiers.new("Smooth anatomical cage", "SUBSURF")
    sub.levels = 1
    bpy.ops.object.modifier_apply(modifier=sub.name)
    mesh = body.data
    mesh.calc_loop_triangles()
    points = np.array([(v.co.x, v.co.z, -v.co.y) for v in mesh.vertices])
    normals = np.array([(v.normal.x, v.normal.z, -v.normal.y) for v in mesh.vertices])
    skin = np.zeros((len(points), len(joints)))
    for v in mesh.vertices:
        for g in v.groups:
            skin[v.index, g.group] = g.weight
    triangles = [tuple(t.vertices) for t in mesh.loop_triangles]
    scores, relief = sample(points, skin, joints, contract["groups"])
    points += normals * relief[:, None]
    points, faces, skin, materials = cut_regions(points, triangles, skin, scores)
    bpy.data.objects.remove(body, do_unlink=True)
    bpy.data.meshes.remove(mesh)
    obj = make_surface(MASTER_BODY, points, faces, skin, joints)
    for name in contract["groups"]:
        mat = bpy.data.materials.new(name)
        mat.diffuse_color = (0.48, 0.51, 0.53, 1) if name == "shell" else (0.30, 0.355, 0.39, 1)
        obj.data.materials.append(mat)
    obj.data.polygons.foreach_set("material_index", materials)
    obj.data.polygons.foreach_set("use_smooth", np.ones(len(faces), dtype=bool))
    # Lock material boundaries during simplification. Otherwise a cheap collapse can
    # move a muscle edge across several centimetres of almost planar skin.
    regions = np.full(len(points), -1)
    borders = set()
    for face, material in zip(faces, materials):
        for vi in face:
            if regions[vi] >= 0 and regions[vi] != material:
                borders.add(vi)
            regions[vi] = material
    interior = obj.vertex_groups.new(name="Mobile LOD interior")
    interior.add(sorted(set(range(len(points))) - borders), 1, "REPLACE")
    # Store a narrow fascial groove in the export's existing ambient visibility byte.
    fields, _ = sample(np.asarray(points), skin, joints, contract["groups"])
    fields[:, contract["groups"].index("shell")] = -1
    strongest = np.sort(fields, axis=1)[:, -2:]
    margin = np.minimum(np.abs(strongest[:, 1]), strongest[:, 1] - strongest[:, 0])
    visibility = 0.54 + 0.46 * np.clip(margin / 0.010, 0, 1)
    ao = obj.data.attributes.new("Fascial visibility", "FLOAT", "POINT")
    ao.data.foreach_set("value", visibility.astype(np.float32))
    lod = obj.modifiers.new("Mobile surface • collapse", "DECIMATE")
    lod.vertex_group = interior.name
    lod.vertex_group_factor = 1
    lod.ratio = 0.26
    lod.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=lod.name)
    obj.vertex_groups.remove(obj.vertex_groups["Mobile LOD interior"])
    refine_mobile_shoulders(obj, joints)
    rig = skeleton(contract)
    arm = obj.modifiers.new("Exercise skeleton", "ARMATURE")
    arm.object = rig
    obj.parent = rig
    rig.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    for area in bpy.context.screen.areas:
        if area.type == "VIEW_3D":
            space = area.spaces.active
            space.overlay.show_overlays = False
            space.shading.color_type = "MATERIAL"
            space.shading.show_cavity = True
            space.region_3d.view_rotation = Quaternion((1, 0, 0), np.pi / 2)
            space.region_3d.view_distance = 2.75
            space.region_3d.view_location = (0, 0, 0.86)
            space.region_3d.view_perspective = "ORTHO"
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(master.resolve()), compress=True)
    export(runtime)


if __name__ == "__main__":
    build(*[Path(arg) for arg in sys.argv[sys.argv.index("--") + 1 :]])
