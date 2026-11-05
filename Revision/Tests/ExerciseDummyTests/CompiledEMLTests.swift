import Foundation
import XCTest
import simd

@testable import ExerciseDummy

#if os(macOS)
  import Foundation
  import Metal
  import XCTest
  import simd

  @testable import ExerciseDummy

  /// Compare native forward kinematics against independently calculated world positions from the
  /// real compiler. Exercise IDs, weights, frames and geometry come from the configured sibling repo.
  final class CompiledEMLTests: XCTestCase {
    struct Reference: Decodable {
      struct Frame: Decodable {
        let time: Double
        let positions: [String: SIMD3<Float>]
        let partCenters: [SIMD3<Float>]
        let connectionEnds: [[SIMD3<Float>]]
      }
      let frames: [Frame]
    }

    @MainActor func testCatalogAndCustomClipsAgainstEML() throws {
      let env = ProcessInfo.processInfo.environment
      let here = URL(fileURLWithPath: #filePath)
      let defaultRoot = (0..<5).reduce(here) { url, _ in url.deletingLastPathComponent() }
        .appendingPathComponent("eml")
      let root = env["EML_ROOT"].map { URL(fileURLWithPath: $0) } ?? defaultRoot
      let python =
        env["EML_PYTHON"].map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent(".venv/bin/python")
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      let standingCurl = here.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(
          "Review/AnatomyViewer/standing-curl-and-return.json")
      let compile = Process()
      compile.currentDirectoryURL = root
      compile.executableURL = python
      compile.arguments = [
        "-c",
        #"""
        import sys, json
        from pathlib import Path
        from eml import Program, load
        from eml.data import registry
        from eml.native import part_pose
        kit = registry()[2]
        out = Path(sys.argv[1])
        def write(doc):
            program = Program(doc)
            clip = program.compile(3, strict=False)
            if any(program.repeat.get("travel", [])):
                clip["travelCycles"] = [
                    [program.sample(f["time"], cycle) for f in clip["frames"]]
                    for cycle in range(1, program.repeat["count"])]
            for f in clip["frames"]:
                f["partCenters"] = [part_pose(f["equipment"][i["id"]], part)[0]
                    for i in clip["equipment"] for part in kit[i["kind"]]["visual"]]
                f["connectionEnds"] = [[f["equipment"][edge[side]["item"]]["sockets"][edge[side]["socket"]]
                    for side in ("from", "to")] for edge in clip["connections"]]
            (out / (doc["id"]+".json")).write_text(json.dumps(clip))
        for file in sorted(Path("exercises").glob("*.json")):
            write(load(file))
        write(load(Path("examples/traveling-reach.json")))
        doc = load(Path("examples/paused-goblet-look-left.json"))
        doc["id"] = "user-defined-one-shot"
        doc["repeat"] = {"mode":"once","count":1}
        doc["phases"] = doc["phases"][:2]
        doc["phases"][1]["muscles"] = {"primary":["obliques"],"secondary":[]}
        write(doc)
        crown = load(Path(sys.argv[2]))
        crown["id"] = "standing-crown-regression"
        write(crown)
        """#, dir.path, standingCurl.path,
      ]
      try compile.run()
      compile.waitUntilExit()
      XCTAssertEqual(compile.terminationStatus, 0)
      let model = try JSONDecoder().decode(
        ModelData.self, from: Data(contentsOf: root.appendingPathComponent("anatomy/model.json")))
      let kit = try JSONDecoder().decode(
        [String: EMLProp].self,
        from: Data(contentsOf: root.appendingPathComponent("library/equipment.json")))
      let files = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      let catalog = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("exercises"), includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "json" }
      XCTAssertGreaterThanOrEqual(catalog.count, 108)
      XCTAssertEqual(files.count, catalog.count + 3)
      var maximumError: Float = 0
      var equipmentError: Float = 0
      var sampleCount = 0
      for file in files {
        try autoreleasepool {
          let bytes = try Data(contentsOf: file)
          let reference = try JSONDecoder().decode(Reference.self, from: bytes)
          let compiled = try JSONDecoder().decode(CompiledEML.self, from: bytes)
          let clip = try compiled.makeClip(model: model, kit: kit)
          let positions = clip.inspectionPositions()
          if compiled.repeatPolicy.mode == .hold {
            XCTAssertTrue(positions.isEmpty, "\(clip.id) is a stationary hold")
          } else {
            var seen = Set<String>()
            let names = reference.frames.indices.compactMap { i -> String? in
              let name = compiled.frames[i].phase
              return seen.insert(name).inserted ? name : nil
            }
            XCTAssertEqual(positions.map(\.name), names, clip.id)
            for position in positions {
              XCTAssertEqual(clip.annotation(at: position.progress)?.phase, position.name, clip.id)
            }
          }
          for frame in reference.frames {
            let pose = clip.pose(at: Float(frame.time) / clip.duration, joints: model.joints)
            for (name, position) in zip(model.joints.map(\.name), pose.positions) {
              let p = try XCTUnwrap(frame.positions[name])
              maximumError = max(maximumError, simd_distance(p, position))
            }
            XCTAssertEqual(pose.props.count, frame.partCenters.count + frame.connectionEnds.count)
            for (world, target) in zip(pose.props, frame.partCenters) {
              equipmentError = max(equipmentError, simd_distance(world.origin, target))
            }
            for (world, ends) in zip(
              pose.props.dropFirst(frame.partCenters.count), frame.connectionEnds)
            {
              for (side, target) in zip([Float(-0.5), 0.5], ends) {
                let w = world * SIMD4(side, 0, 0, 1)
                equipmentError = max(equipmentError, simd_distance([w.x, w.y, w.z], target))
              }
            }
            sampleCount += 1
          }
          if clip.id == "traveling-reach" {
            let initial = clip.pose(at: 0, joints: model.joints).positions[0]
            let end = clip.pose(at: 1, joints: model.joints).positions[0]
            XCTAssertEqual(end.z - initial.z, 1.0, accuracy: 0.0001)
          }
          if clip.id == "standing-crown-regression", let device = MTLCreateSystemDefaultDevice() {
            let player = try ExercisePlayer(emlRoot: root, compiledClip: bytes, device: device)
            try player.inspectPosition("curl")
            let image = try player.snapshot(width: 402, height: 616)
            let rgba = Array(try XCTUnwrap(image.dataProvider?.data) as Data)
            let top = try XCTUnwrap(
              stride(from: 0, to: rgba.count, by: 4).first { rgba[$0 + 2] > 100 })
            let clearance = top / 4 / image.width
            XCTAssertGreaterThan(clearance, 5, "The neutral crown must clear the fitted view")
            XCTAssertLessThan(
              clearance, 32, "Keep the standing figure close to the size of its viewport")
            print("Standing curl crown clears portrait viewport by \(clearance) pixels.")
          }
          if clip.id == "bench-press", let device = MTLCreateSystemDefaultDevice() {
            let player = try ExercisePlayer(emlRoot: root, compiledClip: bytes, device: device)
            try player.send(.setMuscles(primary: player.muscleGroups, secondary: []))
            try player.send(.seek(0.45))
            // This oblique view used to fit diagonal corners outside both the lifter and bar.
            for (w, h, minSpan) in [(402, 625, 210), (674, 345, 165)] {
              let shot = try player.snapshot(width: w, height: h)
              let bytes = Array(try XCTUnwrap(shot.dataProvider?.data) as Data)
              let xs = stride(from: 0, to: bytes.count, by: 4).lazy.filter { i in
                Int(bytes[i + 2]) > 100 && Int(bytes[i + 2]) > Int(bytes[i]) + 38
              }.map { $0 / 4 % w }
              let left = try XCTUnwrap(xs.min())
              let right = try XCTUnwrap(xs.max())
              XCTAssertGreaterThan(right - left, minSpan)
              XCTAssertGreaterThan(left, 0)
              XCTAssertLessThan(right, w - 1)
            }
          }
          if clip.id == "user-defined-one-shot", let device = MTLCreateSystemDefaultDevice() {
            let player = try ExercisePlayer(emlRoot: root, compiledClip: bytes, device: device)
            try player.send(.seek(0))
            let initial =
              try XCTUnwrap(player.snapshot(width: 240, height: 320).dataProvider?.data) as Data
            try player.send(.seek(1))
            let final =
              try XCTUnwrap(player.snapshot(width: 240, height: 320).dataProvider?.data) as Data
            XCTAssertNotEqual(initial, final)
            XCTAssertEqual(player.phaseName, "pause-and-look")
            XCTAssertEqual(player.primary, ["obliques"])
            try player.send(.play)
            try player.inspectPosition("descend")
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.phaseName, "descend")
            XCTAssertEqual(player.phase, Float(1.7) / player.demonstrationSeconds, accuracy: 1e-6)
            XCTAssertThrowsError(try player.inspectPosition("missing"))
            XCTAssertEqual(player.phaseName, "descend")
            try player.inspectPosition("pause-and-look")
            XCTAssertThrowsError(try player.load(compiledClip: Data("{}".utf8)))
            XCTAssertEqual(player.selectedExercise.id, clip.id)
            XCTAssertEqual(player.phase, 1)
            print("Native Metal rendered a custom one-shot and its per-phase muscle overrides.")
          }
        }
      }
      XCTAssertLessThan(
        maximumError, 0.0001, "Native FK disagrees with the reference world-space joints.")
      XCTAssertLessThan(
        equipmentError, 0.0001, "Equipment center or cable socket disagrees with EML.")
      print(
        "Reference EML parity: \(catalog.count) catalog + 3 custom, \(sampleCount) frames × \(model.joints.count) joints, max \(maximumError * 1000) mm body and \(equipmentError * 1000) mm equipment."
      )
    }
  }
#endif

final class EMLTimingTests: XCTestCase {
  func testPhaseBoundaryAndRepeatClock() throws {
    let model = ModelData(
      version: 1, vertexCount: 0, indexCount: 0,
      joints: [.init(name: "pelvis", parent: -1, position: .zero)], groups: ["quadriceps"], wristPivots: nil)
    func frame(_ seconds: Double, phase: String, x: Int, primary: [String]) -> [String: Any] {
      [
        "time": seconds, "phase": phase, "root": [x, 0, 0], "rotations": ["pelvis": [0, 0, 0, 1]],
        "equipment": [:], "muscles": ["primary": primary, "secondary": []],
      ]
    }
    let frames = [
      frame(0, phase: "raise", x: 0, primary: ["quadriceps"]),
      frame(0.5, phase: "raise", x: 1, primary: ["quadriceps"]),
      frame(1, phase: "lower", x: 0, primary: []),
    ]
    let wire: [String: Any] = [
      "eml": "1.0", "id": "new-id", "title": "Example", "duration": 1, "joints": ["pelvis"],
      "equipment": [], "connections": [], "camera": [15, 6],
      "muscles": ["primary": [], "secondary": []],
      "repeat": ["mode": "loop", "count": 2], "frames": frames,
    ]
    let bytes = try JSONSerialization.data(withJSONObject: wire)
    let clip = try JSONDecoder().decode(CompiledEML.self, from: bytes).makeClip(
      model: model, kit: [:])
    XCTAssertEqual(clip.annotation(at: 0.25)?.phase, "raise")
    XCTAssertEqual(clip.annotation(at: 0.251)?.roles.primary, [])
    XCTAssertEqual(clip.pose(at: 0.75, joints: model.joints).positions.first, [1, 0, 0])
    XCTAssertEqual(clip.pose(at: 1, joints: model.joints).positions.first, .zero)
    let positions = clip.inspectionPositions()
    XCTAssertEqual(positions.map(\.name), ["raise", "lower"])
    XCTAssertEqual(positions.first?.progress, 0.25)
    let last = try XCTUnwrap(positions.last)
    XCTAssertEqual(clip.annotation(at: last.progress)?.phase, "lower")
    XCTAssertLessThan(last.progress, 0.5, "The last pose must not wrap into the next rep.")
    var arc = clip
    arc.frames[2].annotation = arc.frames[0].annotation
    XCTAssertEqual(arc.inspectionPositions().map(\.progress), [0.25], "Inspect the top of the arc.")
  }
}
