# Historical anatomy reconstruction notes

Current anatomy authoring, the Blender master and rebuild instructions are maintained in [EML](https://github.com/agrim/exercise-markup-language/tree/v1.1.0/anatomy). This wrapper retains the legacy regression buffers and their [attribution](../../Sources/ExerciseDummy/Resources/ATTRIBUTION.md). The notes below describe the earlier reconstruction; its scripts and working models remain local archives.

## Earlier reconstruction

The artist-facing mesh is built from the original BodyParts3D 4.0 and Z-Anatomy atlases. The generator reads the publisher's element IDs, selects musculoskeletal structures, registers the second atlas against eight corresponding bones and emits indexed geometry in meters. The neutral hand and foot surfaces come from the same scanned body as its skeleton.

The archived reconstruction ran from the model repository root with Python 3.14, Blender and its configured Blender launcher. The commands below document that pipeline and require its locally archived scripts; they are not build steps for this source checkout. The upstream archives and extracted Blender file used a scratch directory outside the repository.

```sh
python3.14 -m venv /tmp/exercise-atlas-env
/tmp/exercise-atlas-env/bin/pip install -r Revision/Authoring/anatomy/requirements.txt
/tmp/exercise-atlas-env/bin/python Revision/Authoring/anatomy/prepare_sources.py /tmp/exercise-atlas-input
/tmp/exercise-atlas-env/bin/python Revision/Authoring/anatomy/build.py /tmp/exercise-atlas-input /tmp/exercise-atlas-output
/tmp/exercise-atlas-env/bin/python Revision/Authoring/anatomy/audit.py /tmp/exercise-atlas-output
```

The upstream preparation verified SHA-256 digests and loaded Blender with embedded scripts disabled. The three generated files were `model.json`, `vertices.bin` and `indices.bin`. Their human-readable attribution is retained with the regression resources. [Source credits and license](../../Sources/ExerciseDummy/Resources/ATTRIBUTION.md)

## Anatomy and visibility

BodyParts3D provides the skeleton and most superficial muscles. Z-Anatomy supplies five bilateral muscles, including the lats and rectus abdominis. The eight-bone registration has coordinate extrema RMS differences of approximately 3 mm mediolaterally, 4 mm anteroposteriorly, and 10 mm vertically. This is an educational model adapted from two anatomical references.

The anterior aponeuroses are recessed within the measured rectus footprint so the six-pack and lateral obliques remain independently visible. On the pectoralis major, the small clavicular insertion retains its named mesh and its anterior overlap is mapped to the upper pectoral group. A continuous inset surface fills the spaces between torso structures. Distal tendons terminate within the hand and foot surfaces. The head, wrist and ankle borders taper into the exposed tissue. The anatomy metadata retains the source IDs for every section, including the projected region and the inset surface.

The ray audit counts the first visible muscle group at each pixel in six views of the resting model. Camera angle and movement can occlude tissue. For example, much of the rhomboid lies deep to the trapezius. The binary contains the actual underlying muscle geometry for inspection. The model's 28 control groups combine several named structures where Simple Trainer uses one label.

## Native buffers

The model faces +Z, +Y points up and +X points to anatomical left. Every bind rotation is the identity. The root uses parent index -1. Joint positions and contact landmarks in the metadata are world-space meters. Grip poses are local joint quaternions in XYZW order.

Each little-endian 40-byte vertex contains float32 position and normal, four uint8 joint indices, four uint8 joint weights summing to 255, one uint32 muscle group and one uint32 containing baked ambient accessibility in its low byte. Values 1–255 represent increasing visibility within 32 mm of the vertex. Zero indicates an unbaked surface. All three vertices of a triangle share a group ID. The index buffer contains little-endian uint32 triangles. The renderer can therefore update a group palette and a joint matrix palette without rebuilding the mesh.
