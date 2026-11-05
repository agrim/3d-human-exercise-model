# EML Studio comparison

This note records the EML Studio comparison. Its recordings and screenshots are retained in the local development archive. This source checkout keeps the written findings, JSON fixtures and repeatable test instructions; the observations and test results below are from that review.

The archived side-by-side comparison used an iPhone 18 Pro simulator on iOS 27.0 and the local EML v1.0.0 viewer. Both captures used the exercise’s authored camera and the same 12 Hz reference samples, interpolated during playback. The edit aligned the start of each repetition to approximately one video frame.

| Exercise | Recorded simulator flow | Recorded browser flow | Observed movement |
| --- | --- | --- | --- |
| Suitcase Carry | Searched, selected and played; captured Swing Left | Played and captured Swing Left | The dumbbell stayed at the anatomical left side as the feet alternated. One cycle lasted 2.18 seconds. |
| Studio Custom Goblet | Imported through Files, saved and played; captured the pause | Imported and played; captured the pause | The bell stayed at the chest. The knees and hips flexed, the head turned left during the pause, and the body returned to standing. One rep lasted 4.40 seconds. |

The [custom input](studio-custom-goblet.json) adapts the EML authoring example under a new ID outside the catalog. Import this file into either viewer to reproduce the comparison. Exercise Studio saved it in **My EML** and reopened it after termination. These recordings predate the named-position viewer. The recorded iOS slider covered all five prescribed repetitions; the browser scrubbed one cycle. Metal uses a stronger floor shadow and lighter weights than WebGL. The red and amber muscle assignments agree.

The hosted simulator suite covers five cases. One compiled, loaded and rendered every one of the 108 bundled exercises through Metal. Another compared ten start and phase-boundary samples of the two recorded exercises against [data from the localhost viewer](../../iOSTests/viewer-reference.json), including the root, selected joint rotations, equipment and muscle roles. The remaining tests check a newly authored one-shot whose angle changes under the same ID, duplicate keys, invalid schema, unreachable contacts and recovery. The Mac Swift suite also compared 1,429 sampled frames across the 108 plus two custom exercises. Native joint positions and equipment centers or connection endpoints differed from the compiler by less than 0.001 mm on those samples.

Use the **HumanExerciseModels** scheme’s Test action to rerun the simulator checks. With the viewer running, regenerate its expected values with `python3 Revision/Tools/viewer_reference.py` from the wrapper root. Visual inspection covered the two recordings. The full catalog check rendered one pose per exercise, and the unsigned device build was compile-only.
