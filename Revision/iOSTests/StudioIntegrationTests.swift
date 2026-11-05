import ExerciseDummy
import Foundation
import XCTest
import simd

@testable import HumanExerciseModels

final class StudioIntegrationTests: XCTestCase {
  private struct Roles: Decodable, Equatable { let primary, secondary: [String] }
  private struct Prop: Decodable {
    let position: SIMD3<Float>
    let rotation: SIMD4<Float>
  }
  private struct Sample: Decodable {
    let time: Double
    let phase: String
    let root: SIMD3<Float>
    let muscles: Roles
    let rotations: [String: SIMD4<Float>]
    let equipment: [String: Prop]
  }
  private struct Reference: Decodable {
    let id: String
    let duration: Double
    let samples: [Sample]
    let customSource: String?
  }
  private struct Wire: Decodable {
    let duration: Double
    let frames: [Sample]
  }

  private var emlRoot: URL { Bundle.main.bundleURL.appendingPathComponent("EML") }

  @MainActor func testInvalidCustomWristShowsTheMeasuredPoseAndBlocksStrictExport() async throws {
    let source = Data(
      """
      {"eml":"1.1","id":"wrist-review","title":"Wrist review","start":{"pose":"standing"},
       "phases":[{"id":"raise","seconds":1,"actions":[],"detail":{"joints":{"leftHand":{"z":155}}}}],
       "repeat":{"mode":"once","count":1},"muscles":{"primary":["forearms"],"secondary":[]}}
      """.utf8)
    let wire = try await EMLCompiler.compile(source)
    let player = try ExercisePlayer(emlRoot: emlRoot, compiledClip: wire)
    let issue = try XCTUnwrap(player.movementIssues.first { $0.subject == "leftHand" })
    XCTAssertEqual(issue.phase, "raise")
    XCTAssertGreaterThan(issue.seconds, 0)
    try player.inspectIssue(issue)
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(player.phase * player.demonstrationSeconds, issue.seconds, accuracy: 0.001)
    do {
      _ = try await EMLCompiler.compile(source, strict: true)
      XCTFail("Strict exports must reject an impossible bend inside the custom phase")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("wrist"), error.localizedDescription)
    }
    let storage = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storage) }
    let library = RecipeLibrary(personalDirectory: storage)
    let text = String(decoding: source, as: UTF8.self)
    try await library.previewCustom(text)
    XCTAssertEqual(library.displayHeader?.id, "wrist-review")
    XCTAssertFalse(try XCTUnwrap(library.player).isPlaying)
    XCTAssertNil(library.selected)
    do {
      try await library.playCustom(text)
      XCTFail("An invalid preview cannot become a saved v1.1 exercise")
    } catch {
      XCTAssertTrue(library.saved.isEmpty)
      XCTAssertEqual(library.previewSource, text)
    }
  }

  @MainActor func testSavedBuilderStepsReopenOnlyForTheirMatchingPortableSource() async throws {
    let suite = UUID().uuidString
    let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
    let storage = URL.temporaryDirectory.appending(path: suite)
    defer {
      prefs.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: storage)
    }
    func library() -> RecipeLibrary {
      RecipeLibrary(personalDirectory: storage, preferences: prefs)
    }
    let studio = library()
    await studio.open()
    var draft = EMLDraft()
    draft.title = "Standing head turn"
    draft.phases = [
      .init(name: "Turn", actions: [.init(motion: "turn-head")]), .init(name: "Return"),
    ]
    let original = Data(try draft.source().utf8)
    let selectedBefore = studio.selected?.id
    try await studio.validateCustom(original)
    XCTAssertEqual(studio.selected?.id, selectedBefore)
    XCTAssertTrue(studio.saved.isEmpty, "Export must leave the user's current library untouched.")
    try await studio.playAuthored(draft)
    let reopened = library()
    await reopened.open()
    let entry = try XCTUnwrap(reopened.selected)
    XCTAssertEqual(try Data(contentsOf: entry.url), original)
    var steps = try XCTUnwrap(reopened.authoredDrafts[entry.id])
    XCTAssertEqual(steps.phases, draft.phases)
    XCTAssertEqual(steps.identifier, entry.header.id)
    steps.title = "Renamed head turn"
    steps.phases.append(.init(name: "Rest", seconds: 0.5, holdsPrevious: true))
    try await reopened.playAuthored(steps)
    XCTAssertEqual(reopened.selected?.id, entry.id)
    XCTAssertEqual(reopened.saved.count, 1)
    XCTAssertEqual(reopened.player?.inspectablePositions, ["turn", "return", "rest"])
    // A valid externally edited recipe need not be representable by the native form.
    var raw = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try steps.source().utf8)) as? [String: Any])
    raw["instructions"] = "Changed outside the builder."
    let bytes = try JSONSerialization.data(withJSONObject: raw)
    try await reopened.playCustom(String(decoding: bytes, as: UTF8.self))
    let check = library()
    await check.open()
    XCTAssertEqual(check.selected?.id, entry.id)
    XCTAssertNil(
      check.authoredDrafts[entry.id], "Do not offer stale editable steps after an external edit.")
  }
  private func fixture() throws -> [Reference] {
    let file = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "viewer-reference", withExtension: "json"))
    return try JSONDecoder().decode([Reference].self, from: Data(contentsOf: file))
  }

  @MainActor func testEveryCatalogExerciseCompilesAndRendersOnIOS() async throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: emlRoot.appendingPathComponent("exercises"), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertGreaterThanOrEqual(files.count, 108)
    var player: ExercisePlayer?
    for file in files {
      let id = file.deletingPathExtension().lastPathComponent
      do {
        let data = try await EMLCompiler.compile(Data(contentsOf: file))
        try autoreleasepool {
          if let active = player {
            try active.load(compiledClip: data)
          } else {
            player = try ExercisePlayer(emlRoot: emlRoot, compiledClip: data)
          }
          let active = try XCTUnwrap(player)
          XCTAssertEqual(active.selectedExercise.id, id)
          try active.send(.seek(0.4))
          // Snapshot goes through the same Metal command encoder as the live MTKView.
          let image = try active.snapshot(width: 128, height: 160)
          XCTAssertEqual(image.width, 128)
          XCTAssertEqual(image.height, 160)
        }
      } catch {
        XCTFail("Catalog exercise \(id) failed on iOS: \(error)")
        throw error
      }
    }
    print("Hosted simulator compiled and Metal-rendered all \(files.count) bundled EML exercises.")
  }

  @MainActor func testCatalogAndCustomMatchLocalhostViewer() async throws {
    for ref in try fixture() {
      let source: Data
      if let custom = ref.customSource {
        source = Data(custom.utf8)
      } else {
        source = try Data(contentsOf: emlRoot.appendingPathComponent("exercises/\(ref.id).json"))
      }
      let data = try await EMLCompiler.compile(source)
      let wire = try JSONDecoder().decode(Wire.self, from: data)
      XCTAssertEqual(wire.duration, ref.duration, accuracy: 0.00001)
      let player = try ExercisePlayer(emlRoot: emlRoot, compiledClip: data)
      XCTAssertEqual(player.selectedExercise.id, ref.id)
      var stills = Set<Data>()
      for expected in ref.samples {
        let actual = try XCTUnwrap(wire.frames.first { abs($0.time - expected.time) < 0.000001 })
        XCTAssertEqual(actual.phase, expected.phase)
        XCTAssertEqual(actual.muscles, expected.muscles)
        XCTAssertLessThan(simd_distance(actual.root, expected.root), 0.0001)
        for (joint, rotation) in expected.rotations {
          let q = try XCTUnwrap(actual.rotations[joint])
          // q and -q represent the same orientation.
          XCTAssertGreaterThan(
            abs(simd_dot(q, rotation)), 0.99999, "\(ref.id): \(joint) at \(expected.time)")
        }
        for (id, prop) in expected.equipment {
          let other = try XCTUnwrap(actual.equipment[id])
          XCTAssertLessThan(simd_distance(prop.position, other.position), 0.0001)
          XCTAssertGreaterThan(abs(simd_dot(prop.rotation, other.rotation)), 0.99999)
        }
        try player.send(.seek(Float(expected.time) / player.demonstrationSeconds))
        let image = try player.snapshot(width: 200, height: 260)
        stills.insert(try XCTUnwrap(image.dataProvider?.data) as Data)
      }
      XCTAssertGreaterThan(stills.count, 1, "\(ref.id) should move on the native surface.")
    }
  }

  @MainActor func testEditingMyOwnOneShotChangesItsPoseWithoutChangingID() async throws {
    let app = RecipeLibrary()
    let previous = UserDefaults.standard.string(forKey: "eml.selected")
    defer { UserDefaults.standard.set(previous, forKey: "eml.selected") }
    await app.open()
    let id = "studio-author-" + UUID().uuidString.lowercased()
    let url = URL.applicationSupportDirectory.appending(path: "My EML/" + id + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    func source(_ turn: Int) -> String {
      """
      {"eml":"1.0","id":"\(id)","title":"Turn to the marker","start":{"pose":"standing"},
       "parameters":{"angle":{"default":\(turn),"min":-45,"max":45}},
       "phases":[{"id":"look","seconds":1.4,"actions":[],"detail":{"joints":{"head":{"y":{"param":"angle"}}}}}],
       "muscles":{"primary":[],"secondary":[]},"repeat":{"mode":"once","count":1}}
      """
    }
    func finalHead(_ degrees: Int) async throws -> SIMD4<Float> {
      let text = source(degrees)
      try await app.playCustom(text)
      let player = try XCTUnwrap(app.player)
      XCTAssertFalse(player.loopsPreview, "One-shot EML should keep its ending by default.")
      XCTAssertEqual(player.selectedExercise.id, id)
      XCTAssertEqual(app.saved.filter { $0.header.id == id }.count, 1)
      let saved = try Data(contentsOf: url)
      XCTAssertEqual(saved, Data(text.utf8))
      let wire = try JSONDecoder().decode(Wire.self, from: try await EMLCompiler.compile(saved))
      return try XCTUnwrap(wire.frames.last?.rotations["head"])
    }
    let left = try await finalHead(35)
    let right = try await finalHead(-30)
    XCTAssertLessThan(
      simd_dot(left, right), 0.90, "Editing the angle should change head orientation.")
  }

  @MainActor func testUnreachableContactIsVisibleAndClearsOnNextRecipe() async throws {
    let source = Data(
      """
      {"eml":"1.0","id":"unreachable-reach","title":"Unreachable reach","start":{"pose":"standing"},
       "contacts":[{"effector":"rightPalm","target":{"point":[4,1,0]}}],
       "phases":[{"id":"reach","seconds":1,"actions":[]}],"repeat":{"mode":"once","count":1},
       "muscles":{"primary":["anteriorDeltoids"],"secondary":[]}}
      """.utf8)
    let solved = try await EMLCompiler.compile(source)
    let player = try ExercisePlayer(emlRoot: emlRoot, compiledClip: solved)
    let warning = try XCTUnwrap(player.contactWarning)
    XCTAssertTrue(warning.contains("rightPalm"), warning)
    XCTAssertTrue(warning.contains("unreachable-contact"), warning)
    let catalog = try Data(
      contentsOf: emlRoot.appendingPathComponent("exercises/suitcase-carry.json"))
    try player.load(compiledClip: try await EMLCompiler.compile(catalog))
    XCTAssertNil(player.contactWarning)
  }

  @MainActor func testInvalidImportsKeepCurrentExercise() async throws {
    let app = RecipeLibrary()
    let previous = UserDefaults.standard.string(forKey: "eml.selected")
    defer { UserDefaults.standard.set(previous, forKey: "eml.selected") }
    await app.open()
    let player = try XCTUnwrap(app.player, app.problem ?? "No player")
    try player.send(.pause)
    try player.send(.seek(0.25))
    let id = player.selectedExercise.id
    let pose = try XCTUnwrap(player.snapshot(width: 160, height: 220).dataProvider?.data) as Data
    let custom = try XCTUnwrap(try fixture().compactMap(\.customSource).first)
    let duplicate = custom.replacingOccurrences(
      of: #""eml": "1.0","#, with: #""eml": "1.0", "eml": "1.0","#)
    XCTAssertNotEqual(duplicate, custom)
    var invalid = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(custom.utf8)) as? [String: Any])
    invalid["unknownSocket"] = 17
    let unknown = String(
      decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
    for (text, expectedCode) in [(duplicate, "duplicate-key"), (unknown, "schema")] {
      do {
        try await app.playCustom(text)
        XCTFail("Invalid custom EML was accepted.")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expectedCode), error.localizedDescription)
      }
      XCTAssertEqual(player.selectedExercise.id, id)
      XCTAssertEqual(player.phase, 0.25)
      let shown = try XCTUnwrap(player.snapshot(width: 160, height: 220).dataProvider?.data) as Data
      XCTAssertEqual(shown.count, pose.count)
      let delta = zip(pose, shown).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
      let mean = Double(delta) / Double(pose.count)
      print("Paused snapshot mean absolute 8-bit channel difference after \(expectedCode): \(mean)")
      // The simulator's Metal multisample resolve can differ at subpixel edges of the same pose.
      XCTAssertLessThan(mean, 0.1, "A rejected recipe visibly changed the paused render")
    }
  }
}
