"""Surface projections on the fitted body. Each row is height, medial angle, lateral angle.
Angles run from anterior (0) around the lateral surface (90) to posterior (180).
Internal muscle groups use a surface projection for exercise highlighting.
"""

import numpy as np

# Separate bellies can share one EML role. Bounds follow insertions rather than latitude bands.
TRUNK = [
    (
        "upperPectorals",
        4,
        [(1.313, 53, 59), (1.34, 14, 64), (1.365, 2, 65), (1.391, 7, 55), (1.403, 30, 45)],
    ),
    (
        "pectorals",
        6,
        [
            (1.231, 15, 30),
            (1.239, 3, 41),
            (1.26, 1, 56),
            (1.29, 1, 64),
            (1.315, 2, 70),
            (1.34, 2, 52),
            (1.358, 3, 16),
        ],
    ),
    ("hipFlexors", 2, [(0.846, 45, 53), (0.89, 37, 60), (0.931, 47, 72), (0.965, 61, 73)]),
    (
        "obliques",
        3,
        [
            (0.885, 25, 37),
            (0.934, 22, 64),
            (0.99, 27, 86),
            (1.071, 29, 94),
            (1.142, 30, 85),
            (1.201, 37, 71),
            (1.236, 55, 67),
        ],
    ),
    (
        "lats",
        6,
        [
            (0.984, 145, 152),
            (1.037, 133, 161),
            (1.114, 117, 160),
            (1.18, 103, 158),
            (1.25, 92, 149),
            (1.305, 95, 125),
            (1.326, 101, 111),
        ],
    ),
    (
        "spinalErectors",
        4,
        [
            (0.914, 165, 172),
            (0.978, 152, 178),
            (1.066, 157, 179),
            (1.174, 161, 179),
            (1.264, 166, 179),
            (1.308, 173, 178),
        ],
    ),
    (
        "trapezius",
        4,
        [
            (1.14, 176, 179),
            (1.20, 165, 180),
            (1.267, 147, 180),
            (1.331, 132, 179),
            (1.362, 116, 178),
            (1.377, 127, 168),
        ],
    ),
    ("rhomboids", 2, [(1.24, 148, 158), (1.279, 143, 164), (1.316, 133, 158), (1.345, 131, 141)]),
    (
        "rotatorCuff",
        3,
        [(1.263, 119, 126), (1.29, 112, 144), (1.323, 107, 143), (1.35, 108, 132), (1.363, 116, 123)],
    ),
    (
        "upperTrapezius",
        4,
        [
            (1.344, 111, 120),
            (1.371, 97, 158),
            (1.397, 91, 180),
            (1.433, 108, 180),
            (1.472, 133, 179),
            (1.503, 159, 176),
        ],
    ),
    (
        "glutes",
        6,
        [
            (0.767, 139, 159),
            (0.79, 110, 173),
            (0.831, 99, 179),
            (0.882, 102, 179),
            (0.924, 116, 174),
            (0.954, 145, 166),
        ],
    ),
    (
        "hipAbductors",
        3,
        [(0.837, 89, 102), (0.875, 75, 116), (0.912, 73, 128), (0.948, 86, 128), (0.964, 101, 113)],
    ),
]
# Paired rectus columns converge inferiorly and follow the costal arch superiorly.
TRUNK += [
    ("abdominals", 2.5, [(0.881, 4, 8), (0.92, 2, 17), (0.977, 2, 24), (1.036, 2, 26), (1.046, 4, 23)]),
    ("abdominals", 3.4, [(1.045, 4, 20), (1.058, 2, 26), (1.093, 1.5, 29), (1.109, 3, 22)]),
    ("abdominals", 3.8, [(1.107, 4, 22), (1.12, 1.5, 29), (1.152, 2, 29), (1.169, 5, 20)]),
    ("abdominals", 3.4, [(1.165, 5, 19), (1.179, 2, 27), (1.213, 2, 25), (1.24, 7, 18)]),
]
for height, shift in [(1.153, 0), (1.181, 4), (1.208, 8), (1.234, 12)]:
    TRUNK.append(
        (
            "serratusAnterior",
            2.8,
            [
                (height, 48 + shift, 54 + shift),
                (height + 0.02, 53 + shift, 72 + shift),
                (height + 0.043, 65 + shift, 86 + shift),
                (height + 0.052, 79 + shift, 85 + shift),
            ],
        )
    )

ARM = [
    (
        "anteriorDeltoids",
        4,
        [(1.267, 37, 47), (1.3, 3, 59), (1.35, -27, 63), (1.39, -25, 55), (1.425, 1, 53), (1.444, 28, 41)],
    ),
    (
        "lateralDeltoids",
        5,
        [
            (1.237, 79, 84),
            (1.27, 58, 100),
            (1.34, 53, 125),
            (1.41, 50, 131),
            (1.445, 65, 124),
            (1.454, 85, 104),
        ],
    ),
    (
        "posteriorDeltoids",
        4,
        [(1.268, 114, 119), (1.312, 109, 162), (1.369, 119, 199), (1.407, 128, 191), (1.437, 131, 151)],
    ),
    (
        "biceps",
        5.5,
        [
            (1.135, -31, -19),
            (1.163, -53, 14),
            (1.211, -72, 48),
            (1.255, -73, 48),
            (1.299, -66, 23),
            (1.348, -49, -13),
        ],
    ),
    ("brachialis", 3, [(1.125, 34, 45), (1.159, 13, 74), (1.202, 37, 94), (1.258, 43, 84), (1.28, 48, 57)]),
    (
        "triceps",
        4,
        [(1.141, 160, 178), (1.17, 117, 196), (1.221, 89, 205), (1.278, 82, 188), (1.323, 118, 169)],
    ),
    (
        "triceps",
        4,
        [(1.15, 190, 202), (1.208, 182, 265), (1.28, 164, 275), (1.352, 178, 254), (1.38, 207, 237)],
    ),
    ("forearms", 3, [(0.899, 36, 58), (0.955, 20, 74), (1.034, 10, 85), (1.09, 20, 103), (1.134, 55, 83)]),
    (
        "forearms",
        2.5,
        [(0.912, -55, -43), (0.978, -79, 13), (1.052, -106, 20), (1.10, -112, 3), (1.129, -96, -74)],
    ),
    (
        "forearms",
        2,
        [(0.918, 142, 160), (0.983, 116, 201), (1.055, 89, 242), (1.101, 98, 233), (1.13, 121, 166)],
    ),
]
LEG = [
    (
        "quadriceps",
        5,
        [
            (0.489, -8, 2),
            (0.536, -18, 23),
            (0.623, -20, 35),
            (0.718, -24, 42),
            (0.796, -18, 30),
            (0.858, 3, 18),
        ],
    ),
    (
        "quadriceps",
        5.5,
        [
            (0.476, 46, 57),
            (0.503, 20, 78),
            (0.589, 19, 97),
            (0.711, 32, 109),
            (0.793, 34, 99),
            (0.855, 58, 80),
        ],
    ),
    (
        "quadriceps",
        4.5,
        [(0.467, -52, -38), (0.489, -73, -17), (0.545, -63, -12), (0.633, -53, -17), (0.72, -45, -24)],
    ),
    (
        "adductors",
        4,
        [
            (0.506, 263, 272),
            (0.588, 238, 286),
            (0.686, 224, 312),
            (0.775, 227, 329),
            (0.84, 253, 318),
            (0.865, 278, 296),
        ],
    ),
    (
        "hamstrings",
        4.5,
        [
            (0.456, 126, 137),
            (0.498, 112, 154),
            (0.588, 105, 177),
            (0.706, 103, 182),
            (0.783, 117, 177),
            (0.825, 139, 164),
        ],
    ),
    (
        "hamstrings",
        4,
        [
            (0.449, 210, 222),
            (0.507, 182, 237),
            (0.603, 173, 245),
            (0.731, 171, 238),
            (0.811, 162, 211),
            (0.836, 178, 196),
        ],
    ),
    (
        "hipFlexors",
        2,
        [(0.73, -39, -28), (0.783, -31, -9), (0.83, -13, 15), (0.879, 15, 44), (0.913, 39, 54)],
    ),
    (
        "gastrocnemius",
        5,
        [(0.203, 182, 196), (0.247, 174, 219), (0.315, 165, 247), (0.381, 162, 246), (0.431, 184, 222)],
    ),
    (
        "gastrocnemius",
        4,
        [(0.234, 141, 153), (0.279, 117, 171), (0.349, 102, 169), (0.412, 121, 165), (0.437, 139, 151)],
    ),
    (
        "soleus",
        3,
        [(0.115, 157, 192), (0.187, 127, 212), (0.255, 99, 225), (0.318, 85, 151), (0.377, 90, 110)],
    ),
    (
        "tibialisAnterior",
        3,
        [(0.107, -10, 0), (0.174, -3, 27), (0.276, 4, 55), (0.377, 13, 72), (0.422, 25, 52)],
    ),
]
FOOT = [
    (
        "footStabilizers",
        1.1,
        [
            (-0.013, 29, 43),
            (0.018, -30, 86),
            (0.060, -62, 78),
            (0.107, -61, 73),
            (0.136, -33, 46),
            (0.15, -5, 12),
        ],
    )
]


def sample(points, weights, joints, groups):
    x, y, z = points.T
    x = np.abs(x)
    index = {j["name"]: i for i, j in enumerate(joints)}
    field = np.full((len(points), len(groups)), -0.5)
    field[:, groups.index("shell")] = 0
    relief = np.zeros(len(points))

    def mass(*names):
        return weights[:, [index[side + n] for n in names for side in ("left", "right")]].sum(1)

    arm = mass("UpperArm", "Forearm", "Hand")
    leg = mass("Thigh", "Shin")
    foot = mass("Foot", "Toe")
    trunk = np.clip(1 - arm - leg - foot - weights[:, index["head"]], 0, 1)
    # At the iliac crest the gluteal muscle crosses from pelvis to femur.
    pelvis = np.maximum(trunk, leg * np.clip((y - 0.765) / 0.055, 0, 1))
    torso_z = np.interp(
        y,
        [0.78, 0.88, 1, 1.10, 1.22, 1.34, 1.41, 1.48],
        [0.002, 0.013, 0.04, 0.023, 0.014, 0.003, -0.003, -0.018],
    )

    def angle(a, b):
        return np.degrees(np.arctan2(a, b))

    trunk_theta = angle(x * 0.7, z - torso_z)

    def limb_theta(names):
        centers = np.array([joints[index["left" + n]]["position"] for n in names])
        cx = np.interp(y, centers[:, 1], centers[:, 0])
        cz = np.interp(y, centers[:, 1], centers[:, 2])
        return angle(x - cx, z - cz)

    arm_theta = limb_theta(["Hand", "Forearm", "UpperArm"])
    leg_theta = limb_theta(["Foot", "Shin", "Thigh"])
    foot_theta = angle(x - (0.073 + 0.32 * np.clip(z, 0, 0.14)), y - 0.015)
    for patches, level, theta, ownership in [
        (TRUNK, y, trunk_theta, trunk),
        (ARM, y, arm_theta, arm),
        (LEG, y, leg_theta, leg),
        (FOOT, z, foot_theta, foot),
    ]:
        for group, mm, rows in patches:
            h, low, high = np.array(rows).T
            mask = pelvis if patches is TRUNK and group in ("glutes", "hipAbductors") else ownership
            middle = np.interp(level, h, (low + high) / 2)
            width = np.interp(level, h, (high - low) / 2)
            offset = np.abs((theta - middle + 180) % 360 - 180)
            ends = np.minimum(level - h[0], h[-1] - level)
            cap = min(0.012, (h[-1] - h[0]) * 0.2)
            t = np.clip(ends / cap, 0, 1)
            rounded_width = width * np.sqrt(t * (2 - t))
            radius = 0.115 if patches is TRUNK else 0.065 if patches is LEG else 0.045
            edge = np.minimum((rounded_width - offset) * np.pi / 180 * radius, ends)
            edge = np.minimum(edge, (mask - 0.18) * 0.075)
            idx = groups.index(group)
            field[:, idx] = np.maximum(field[:, idx], edge)
            arc = np.minimum(1, offset / np.maximum(rounded_width, 0.001))
            fullness = np.sqrt(1 - arc**2) * np.sqrt(t) * mask
            relief = np.maximum(relief, mm * 0.0015 * fullness**1.5)
    return field, relief
