# Anatomy viewer review

This note records a simulator and browser review. Its recordings and screenshots are retained in the local development archive. This source checkout keeps the written findings, portable recipe and test source; the observations and test results below are from that review.

The current player lets you drag to orbit, pinch to zoom and tap **Reset view** to restore the exercise’s authored camera without changing the pose. Manual authoring is under **Exercises → Create custom EML**. **Save and play** keeps the editable steps on the device; **Export EML** produces a portable v1 JSON file through Files.

The [Standing Curl and Return recipe](standing-curl-and-return.json) is the unmodified file saved from the simulator's Files sheet. The standalone EML validator reported no issues. Opening those same bytes in the localhost viewer shows **Curl** at 1.00 s and **Return** at 2.00 s, with Biceps the sole primary group. The forearm rotates 90° between the endpoints.

The archived manual-builder walkthrough covered creating the steps, assigning Biceps, saving through Files, inspecting the anatomy, and loading the exported document back into the app. It combined the original authoring and Files recording with the corrected camera recording; the form titles at that review were **New EML** and **Edit EML**. Reopening **Edit steps** recovered the original movement choices.

A second archived walkthrough followed Suitcase Carry, **Swing Left**, resumed playback and a saved personal exercise. A separate recording covered **Open → Use example → Save and play** in the EML editor. The caption showed up to two names per role in authored order; Inspect listed them all.

The archived layout comparisons covered portrait, landscape, standing, Inspect and custom exercise views. These framing captures predate the camera reset button and the manual builder. The previous Bench Press capture was paused at 45%; the redesigned one was paused at the end of the authored Press phase.

On an iPhone 18 Pro simulator (iOS 27.0), XCTest measured the Metal view on a 402 × 874 pt display:

| Orientation | Previous viewer | Anatomy viewer |
| --- | --- | --- |
| Portrait | 402 × 442 pt (51% of screen area) | 402 × 644 pt (74%) |
| Landscape | 458 × 304 pt (40%) | 874 × 402 pt (100%, with controls in the corners) |

The scene stays framed over the complete movement. Anatomy and handheld equipment determine the fit; a stationary rack or a distant machine anchor can extend outside the view. On the Mac Metal test at the same pose and camera, the bench press body measured 190 → 230 px wide in a 402 × 625 portrait drawable and 144 → 183 px in a 674 × 345 landscape drawable.

At the largest accessibility text size on the 440 × 956 pt Pro Max simulator, the model still had 591 pt of height. The full title “Overhead Dumbbell Triceps Extension” was readable by scrolling the caption. The camera measures the head surface: at the Curl position its crown clears the top of a 402 × 616 test render by 10 px at normal zoom.

All 11 iOS test cases passed, including a targeted rerun of the Files handoff after allowing time for a fresh simulator’s document provider to launch. They compile and render all 108 catalog exercises, compare selected poses and equipment against the localhost viewer, and exercise one-shots, strict authoring validation, editable personal recipes and camera gestures. A separate cold launch restored the saved curl title and both steps. All nine Mac package tests passed; the native renderer comparison covered 1,436 sampled frames across the catalog and three custom exercises. The recordings show simulator behavior, not physical iPhone performance.

To check the current checkout, use the **HumanExerciseModels** scheme’s Test action for iOS, and `swift test --package-path Revision` for the Mac package. The compiler comparison requires the configured sibling EML checkout and its Python dependencies.
