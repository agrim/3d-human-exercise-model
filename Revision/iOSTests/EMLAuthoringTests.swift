import ExerciseDummy
import Foundation
import XCTest
import simd

@testable import HumanExerciseModels

final class EMLAuthoringTests: XCTestCase {
  private var root: URL { Bundle.main.bundleURL.appending(path: "EML") }
  private struct Clip: Decodable {
    struct Frame: Decodable {
      struct Item: Decodable { let sockets: [String: SIMD3<Float>] }
      let time: Float
      let rotations: [String: SIMD4<Float>]
      let landmarks: [String: SIMD3<Float>]
      let equipment: [String: Item]
    }
    let frames: [Frame]
  }

  @MainActor func testPortableDraftCompilesAndReplaysAuthoredTargets() async throws {
    let vocabulary = try EMLVocabulary.load(from: root)
    XCTAssertTrue(vocabulary.poses.contains("standing"))
    XCTAssertTrue(vocabulary.contactPoints.contains("leftHeel"))
    XCTAssertTrue(
      vocabulary.compatibleMotions["upper-lateral-raise-start"]?.contains("upper-lateral-elevation")
        == true)
    XCTAssertEqual(vocabulary.motionFamilies["bend-elbows"], "Basic movements")
    XCTAssertTrue(
      ["bothForearm", "leftForearm", "rightForearm"].allSatisfy(vocabulary.joints.contains))
    XCTAssertFalse(vocabulary.muscles.contains("bone"))

    var draft = EMLDraft()
    draft.title = "Curl and look"
    draft.mode = .loop
    draft.count = 3
    draft.primary = ["biceps"]
    draft.secondary = ["forearms"]
    draft.stanceWidth = "shoulder-width"
    draft.toeOut = 8
    draft.fixedPoints = ["leftHeel", "rightHeel"]
    draft.startJoints = [EMLJointEdit(joint: "neck", axis: "x", degrees: 5)]
    draft.phases = [
      EMLPhaseDraft(
        name: "Lift", seconds: 1,
        actions: [
          EMLActionDraft(motion: "bend-elbows", amount: 0.7, adjustable: true)
        ], joints: [EMLJointEdit(joint: "head", axis: "y", degrees: 30, adjustable: true)]),
      EMLPhaseDraft(name: "Pause", seconds: 0.5, holdsPrevious: true),
      EMLPhaseDraft(name: "Return", seconds: 1, adjustableDuration: true),
    ]
    draft.phases[2].fixedPoints = draft.fixedPoints
    draft.equipment = [
      EMLEquipmentDraft(kind: "kettlebell", hand: "leftHand"),
      EMLEquipmentDraft(kind: "flat-bench", hand: "", z: -1.2),
    ]
    let source = try draft.source(vocabulary: vocabulary)
    let persistent = try JSONEncoder().encode(draft)
    let reopened = try JSONDecoder().decode(EMLDraft.self, from: persistent)
    XCTAssertEqual(reopened, draft)
    XCTAssertEqual(try reopened.source(vocabulary: vocabulary), source)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    XCTAssertEqual(json["id"] as? String, "curl-and-look")
    XCTAssertEqual(json["eml"] as? String, "1.1")
    XCTAssertEqual(
      (json["contacts"] as? [[String: String]])?.map { $0["effector"] ?? "" },
      ["leftHeel", "rightHeel"])
    XCTAssertEqual(
      (json["phases"] as? [[String: Any]])?.last?["contacts"] as? [[String: String]],
      json["contacts"] as? [[String: String]])
    let parameters = try XCTUnwrap(json["parameters"] as? [String: [String: Double]])
    XCTAssertEqual(parameters.count, 3)
    let compiled = try await EMLCompiler.compile(Data(source.utf8), strict: true)
    let wire = try JSONDecoder().decode(Clip.self, from: compiled)
    let initial = try XCTUnwrap(wire.frames.first)
    let top = try XCTUnwrap(wire.frames.first { abs($0.time - 1) < 1e-6 })
    let pause = try XCTUnwrap(wire.frames.first { abs($0.time - 1.5) < 1e-6 })
    let final = try XCTUnwrap(wire.frames.last)
    let head = try XCTUnwrap(top.rotations["head"])
    XCTAssertGreaterThan(head.y, 0.25)
    XCTAssertEqual(try XCTUnwrap(pause.rotations["head"]), head)
    let forearm = try XCTUnwrap(top.rotations["leftForearm"])
    XCTAssertLessThan(forearm.x, -0.50)
    XCTAssertEqual(
      try XCTUnwrap(final.rotations["leftForearm"]), try XCTUnwrap(initial.rotations["leftForearm"])
    )
    for pose in [initial, top, pause, final] {
      let hand = try XCTUnwrap(pose.landmarks["leftGrip"])
      let handle = try XCTUnwrap(pose.equipment["item-1"]?.sockets["handle"])
      XCTAssertLessThan(simd_distance(hand, handle), 0.0001)
    }
    let player = try ExercisePlayer(emlRoot: root, compiledClip: compiled)
    XCTAssertEqual(player.primary, ["biceps"])
    XCTAssertEqual(player.demonstrationSeconds, 7.5, accuracy: 1e-6)
    XCTAssertEqual(player.inspectablePositions, ["lift", "pause", "return"])
    try player.inspectPosition("pause")
    XCTAssertNotNil(try player.snapshot(width: 160, height: 220).dataProvider)
    // An explicit release must not teleport the feet out of the prescribed wide stance.
    draft.phases[2].fixedPoints = []
    let released = Data(try draft.source(vocabulary: vocabulary).utf8)
    do {
      _ = try await EMLCompiler.compile(released, strict: true)
      XCTFail("The heel positions change discontinuously when their support is released.")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains("discontinuous-contact"), error.localizedDescription)
    }
  }

  @MainActor func testHoldUsesAuthoredStartAndRejectsMovingHold() async throws {
    var draft = EMLDraft()
    draft.title = "Stand and turn"
    draft.identifier = "personal-marker-hold"
    draft.mode = .hold
    draft.phases = [EMLPhaseDraft(name: "Hold", seconds: 1)]
    draft.startJoints = [EMLJointEdit(joint: "head", axis: "y", degrees: -25)]
    let held = try await EMLCompiler.compile(Data(try draft.source().utf8))
    let player = try ExercisePlayer(emlRoot: root, compiledClip: held)
    XCTAssertEqual(player.selectedExercise.id, draft.identifier)
    XCTAssertTrue(player.inspectablePositions.isEmpty)
    let library = RecipeLibrary()
    func rejects(_ document: EMLDraft, with code: String) async throws {
      let data = Data(try document.source().utf8)
      do {
        try await library.validateCustom(data)
        XCTFail("Expected EML conformance error " + code)
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(code), error.localizedDescription)
      }
    }
    draft.phases[0].actions = [EMLActionDraft(motion: "turn-head")]
    try await rejects(draft, with: "moving-hold")
    draft.mode = .loop
    try await rejects(draft, with: "open-loop")
    draft.phases.append(
      EMLPhaseDraft(name: "Return", actions: [EMLActionDraft(motion: "turn-head", amount: 0)]))
    try await library.validateCustom(Data(try draft.source().utf8))
    draft.mode = .once
    draft.phases[0].actions = [EMLActionDraft(motion: "not-in-vocabulary")]
    let invalid = try draft.source()
    do {
      _ = try await EMLCompiler.compile(Data(invalid.utf8))
      XCTFail("A new motion name cannot silently bypass the EML compiler.")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains("unknown-motion"), error.localizedDescription)
    }
  }

  @MainActor func testStepMusclesInheritReplaceAndClear() async throws {
    var draft = EMLDraft()
    draft.title = "Squat to press"
    draft.primary = ["quadriceps"]
    draft.secondary = ["glutes"]
    draft.phases = [
      .init(name: "Lower", actions: [.init(motion: "squat-upright")]),
      .init(
        name: "Press", actions: [.init(motion: "raise-arms-forward")],
        muscleOverride: .init(primary: ["anteriorDeltoids"], secondary: ["triceps"])),
      .init(name: "Pause", holdsPrevious: true, muscleOverride: .init()),
      .init(name: "Return"),
    ]
    let source = Data(try draft.source().utf8)
    let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
    let steps = try XCTUnwrap(doc["phases"] as? [[String: Any]])
    XCTAssertNil(steps[0]["muscles"])
    XCTAssertEqual(steps[2]["muscles"] as? [String: [String]], ["primary": [], "secondary": []])
    XCTAssertEqual(
      try JSONDecoder().decode(EMLDraft.self, from: JSONEncoder().encode(draft)), draft)
    // Simulate a builder draft saved before per-step roles were introduced.
    var old = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    var oldSteps = try XCTUnwrap(old["phases"] as? [[String: Any]])
    for i in oldSteps.indices { oldSteps[i].removeValue(forKey: "muscleOverride") }
    old["phases"] = oldSteps
    let reopened = try JSONDecoder().decode(
      EMLDraft.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertEqual(reopened.phases.map(\.id), draft.phases.map(\.id))
    XCTAssertTrue(reopened.phases.allSatisfy { $0.muscleOverride == nil })

    let clip = try await EMLCompiler.compile(source, strict: true)
    let player = try ExercisePlayer(emlRoot: root, compiledClip: clip)
    for (name, primary, secondary) in [
      ("lower", ["quadriceps"], ["glutes"]), ("press", ["anteriorDeltoids"], ["triceps"]),
      ("pause", [], []), ("return", ["quadriceps"], ["glutes"]),
    ] {
      try player.inspectPosition(name)
      XCTAssertEqual(player.primary, Set(primary), name)
      XCTAssertEqual(player.secondary, Set(secondary), name)
    }
    draft.phases[1].muscleOverride?.secondary.insert("anteriorDeltoids")
    do {
      try await RecipeLibrary().validateCustom(Data(try draft.source().utf8))
      XCTFail("A muscle cannot have both roles during a phase.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("muscle-role"), error.localizedDescription)
    }
  }
}
