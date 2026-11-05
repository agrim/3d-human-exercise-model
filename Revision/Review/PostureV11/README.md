# Exercise Studio and EML 1.1

This note records the EML 1.1 posture review. Its recordings and screenshots are retained in the local development archive. This source checkout keeps the written findings and test source; the observations and test results below are from that review.

The archived iPhone simulator playback showed the EML anatomy and equipment rendered by Metal from [EML v1.1.0](https://github.com/agrim/exercise-markup-language/tree/v1.1.0). The [persistent localhost viewer](http://127.0.0.1:8765/?id=deadlift) uses the same catalog.

| Exercise | What to inspect |
| --- | --- |
| Conventional and sumo deadlifts | The conventional bar clears the knees and reaches lockout. The sumo pickup keeps the shaft outside the legs. The measured minimum shaft margins against the atlas in the conventional, sumo and Romanian pulls were 29, 34 and 38 mm. |
| Side plank | The hold stacks the shoulder over its supporting elbow. The forearm points in front of the torso and rests within 6 mm of the floor. Orbit towards the supporting forearm to see the bend and floor contact together. |
| Shoulder press and lateral raise | In the seated rack, the forearms support the weights and the wrists stay close to straight. The peak angle between the forearm and middle metacarpal went from about 85° to 6°. In the lateral raise, the shafts remain within 4° of level. |
| Bird dog | Inspect a contralateral reach. The opposite hand supports the torso while the working hand leaves the floor and returns. |

The archived upper-body, loaded-pull and support comparisons used matched phases and camera angles to compare atlas poses. Six catalog sheets recorded four WebGL frames for every exercise in title-ID order.

## Review a personal exercise

Open **Exercises → Load EML**. Use **Open → Use example** for the v1.1 paused squat, or choose a personal file. **Preview** leaves the library and the remembered exercise selection untouched. If the document produces a measured posture finding, the player pauses on a sample. **Inspect → Movement checks** shows the joint or object, phase, time and measurement. Tap a finding to inspect it. **Save and play** and the manual builder’s **Export EML** require the v1.1 program to conform.

The typed wrist review measured 154.3° of roll against this rig’s 95° limit. Selecting that finding paused the model at the measured sample; the temporary preview was absent from My EML.

The manual builder reads the published pose/motion pairings. Planted macros carry their declared contact points into custom exercises. **Fixed points** can pin additional hand or foot landmarks to the starting pose or release them for a phase. The two viewers use the same solved motion but different lighting and framing.

## Verification

All 108 catalog programs compiled, loaded and rendered on an iPhone 18 Pro simulator. All 12 iOS tests passed; they include strict custom compilation, temporary preview, pin inheritance and release, catalog parity and camera gestures. All ten Mac package tests passed. The native transforms matched the reference compiler across 1,440 sampled frames of 108 catalog and three custom exercises; maximum observed body/prop deviation was under 0.001 mm.

The [EML conformance report](https://github.com/agrim/exercise-markup-language/blob/v1.1.0/docs/conformance.md) contains the sampled bounds, before/after geometric findings, floor measurements and repeatable commands. The checks use the reference atlas, contact surfaces and conservative body proxies. The simulator walkthrough does not measure physical iPhone performance or validate technique for an individual athlete.
