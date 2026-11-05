# Exercise Studio for iOS

Exercise Studio opens on the anatomy model. The caption names the exercise and the primary (red-orange) and secondary (amber) muscle groups. Gray tissue is unhighlighted. Drag to orbit, pinch to zoom, or tap **Pause** to hold a posture. The curved-arrow **Reset view** button restores the exercise’s camera angle and framing without changing its pose or playback.

- **Exercises** searches the 108 catalog exercises by name or muscle and lists personal exercises under **My EML**. **Create custom EML** opens the step builder. **Load EML** accepts an existing JSON file, pasted source or a working example.
- **Inspect** pauses the movement. Read its instructions, examine muscle groups, or choose an authored position such as **Press** or **Lower** to see that pose. The list follows the recipe’s own phases, including for custom exercises; it does not repeat entries for every rep. Static holds have no unnecessary position selector.

The app compiles [Exercise Markup Language](https://github.com/agrim/exercise-markup-language) recipes on the device and renders their anatomy and equipment with Metal. The built-in catalog and new manual drafts use EML 1.1. Existing 1.0 documents use their original definitions and equipment. A personal recipe is separate from the built-in catalog even when the IDs match.

**Load EML → Preview** lets you examine an unsaved recipe. If the compiler detects a movement problem, the model pauses at a measured pose. **Inspect → Movement checks** shows the phase, time and measurement; selecting a finding takes you to that sample. **Save and play** and **Export EML** require a conforming v1.1 exercise. [See the posture and apparatus review](Revision/Review/PostureV11/README.md).

## Build an exercise by hand

Open **Exercises → Create custom EML**, name the exercise and choose a starting pose. **Add step** opens a phase: give it a name and duration, then pick one or more movements. The searchable list comes directly from EML’s libraries (101 coordinated movements in v1). For finer control, set an angle on an individual joint or on both sides. The setup also supports stance, equipment, muscle roles and repetition settings.

For a simple curl, use **Standing**, add **Bend** with **Bend Elbows**, then add **Return** with no movements or joint overrides. Each step describes its endpoint relative to the starting pose, so the empty second step brings the arms back down. **Hold previous position** keeps the preceding endpoint instead. You can insert, reorder and delete steps. Each step inherits the exercise’s primary and secondary muscles unless you choose different roles for that step.

When EML publishes verified movements for the chosen starting pose, the picker groups them at the top. Grounded macros such as **Squat Down** plant the feet by default. **Starting pose → Fixed points** can pin a hand or foot to its starting position for a personal exercise. An individual step can inherit, replace or release those contacts. Abruptly releasing a contact that would make the body jump fails validation.

**Export EML** checks the recipe with EML’s reference compiler and opens Files with a portable JSON document. It leaves the draft open and does not save to the library. **Save and play** checks the recipe, adds it to **My EML** and starts the anatomy model. Later, open **Inspect → Edit steps** to continue working on a builder-created exercise. **Inspect → Export EML** shares any saved personal recipe. The editable form stays on the device; the exported file contains EML only and can also be loaded in the browser viewer.

[Try an exercise built and exported on the simulator: Standing Curl and Return](Revision/Review/AnatomyViewer/standing-curl-and-return.json). Load it in Exercise Studio or in the [localhost anatomy viewer](http://127.0.0.1:8765/). In Exercise Studio, select **Inspect → Curl** to hold the peak contraction while you rotate or magnify the anatomy.

[Read the manual builder, camera controls and viewport verification](Revision/Review/AnatomyViewer/README.md).

## Build and run

Use Xcode on macOS with an iOS 17 or newer simulator or device. Check out the wrapper and EML in sibling folders, then prepare the embedded Python runtime before opening the Xcode project. The following commands assume you are in the wrapper root.

```sh
git clone --branch v1.1.0 https://github.com/agrim/exercise-markup-language.git ../eml
bash Revision/Runtime/bootstrap.sh
open HumanExerciseModels.xcodeproj
```

If you already have the EML checkout, use it directly. To build against another location, pass `EML_ROOT=/absolute/path/to/eml` as an Xcode build setting. Build the **HumanExerciseModels** scheme. Each build stages the current EML source and runtime assets into the app. Rebuild after changing EML in the checkout. Installed apps play from their own bundle, including when the Mac or viewer is offline. Only the build machine needs to fetch the compiler dependencies.

## Compare with the browser

The [localhost anatomy viewer](http://127.0.0.1:8765/?id=suitcase-carry) reads the same EML checkout. Its login service follows the Simple Trainer review setup and restarts if the process exits. See [service setup](Revision/Tools/viewer-service/README.md) and the [written simulator and browser comparison](Revision/Review/EML/README.md).

## Repository layout

- [Revision/Preview](Revision/Preview) contains the iOS catalog, EML editor and playback UI.
- [Revision/Runtime](Revision/Runtime) embeds the EML compiler for iOS. [ExerciseDummy](Revision/Sources/ExerciseDummy) interprets the compiled frames and renders the anatomy, equipment and muscle colors.
- [The EML repository](https://github.com/agrim/exercise-markup-language/tree/v1.1.0) owns the language, authoring guide, catalog, Blender master, runtime anatomy and asset credits. This repository contains the iOS wrapper, renderer and regression fixtures. Model authoring belongs to EML.
