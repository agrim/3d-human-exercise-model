# Simple Trainer exercise dummy

The native exercise player demonstrates all **108 built-in Simple Trainer exercises** on an anatomical model. Pass the app's catalog ID to select an exercise. The player applies the movement, equipment, camera and muscle roles together.

This source checkout contains the player, exercise tracks and regression fixtures. Review media and earlier model-authoring work are retained in the local development archive.

## In Simple Trainer

Add `Revision` as a local Swift package in Xcode and link its **ExerciseDummy** library to the iPhone target. Retain one player for the workout screen. The package supports iOS 17 and newer. All execution and rendering are local.

```swift
import ExerciseDummy
import SwiftUI

@MainActor
func makeDemo(catalogID: String) throws -> ExercisePlayer {
    let player = try ExercisePlayer(exerciseID: catalogID)
    try player.send(.play)
    return player
}

// In the host view, with a retained player:
// ExerciseDummyView(player: player)
```

```swift
try player.send(.selectExercise("concentration-curl"))
try player.send(.orient(yaw: 35, pitch: 12))
try player.send(.setTempo(0.75))
try player.send(.pause)
try player.send(.seek(0.5))
try player.send(.setMirrored(true))         // Demonstrate the opposite side.
```

The catalog is available through `player.exercises`. A lookup such as `player.exercise(id: catalogID)` returns nil for custom exercises without a demonstration. Selecting an unknown ID throws. The host can present its own fallback for those entries. `player.attribution` exposes the bundled credits.

Commands also have a flat Codable representation. For example, the JSON below selects and starts a deadlift. Decode it as `[ExerciseCommand]` and send the commands in order.

```json
[{"op":"selectExercise","id":"deadlift"},{"op":"play"}]
```

**Red-orange** identifies primary targets, **amber** identifies secondary targets, and **gray** identifies unhighlighted tissue. These are the app's authored training roles. A gray muscle can still participate in the movement. Selected unilateral clips restrict the relevant colors to the working side. The host may override the roles with `.setMuscles(primary:secondary:)` and restore them with `.useExerciseMuscles`.

## Model and motion

The anatomy model combines BodyParts3D and Z-Anatomy into 28 controllable muscle groups on a 51-joint skeleton. Metal draws the body in a single indexed draw with a separate shadow pass. The player loads each exercise's animation track on demand. Each exercise supplies its prescribed camera, equipment dimensions, world-space equipment motion, root translation and local joint rotations. Static holds preserve their held posture. The compact package has no runtime dependency on Blender or a third-party engine. [Model comparisons and adaptation notes](Revision/Authoring/SOURCES.md) · [Attribution and licenses](Revision/ATTRIBUTION.md)

The catalog snapshot comes from Simple Trainer commit `a33c437c45c092d6895891c5088763d108627cb7`. It joins the eight original exercises in `WorkoutCatalog.swift` with the 100 defaults in `ExerciseCatalog+Defaults.swift`. The historical catalog compiler rejected missing or duplicate IDs and unmapped muscle roles.

## Preview and test

Open **HumanExerciseModels.xcodeproj** and run the **HumanExerciseModels** scheme on an iPhone. The preview includes exercise search, camera controls, playback, a phase slider, muscle highlighting and credits. The independently maintained Simple Trainer app can integrate the package through the interface above.

On a fresh checkout, install Git LFS and run `git lfs pull --include="Revision/Sources/ExerciseDummy/Resources/**"` to fetch the two mesh buffers. The exercise metadata and tracks are included in the source checkout. Previewing, testing and rendering these fixtures do not require Blender or a review reel.

Current model authoring, the editable Blender master and rebuild instructions are maintained in the [EML anatomy repository](https://github.com/agrim/exercise-markup-language/tree/main/anatomy). The wrapper's earlier authoring scripts and Blender copies are local archives, not rebuild dependencies of this checkout.

Run the package checks and batch renderer from the repository root:

```sh
swift test --package-path Revision -c release
swift run --package-path Revision -c release RenderBatch /tmp/exercise-poses 4
```

The render command writes generated frames to `/tmp/exercise-poses`. Retain the [geometry attribution and license](Revision/Sources/ExerciseDummy/Resources/ATTRIBUTION.md) with distributed model copies.
