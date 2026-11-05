import Metal
import XCTest
import simd

@testable import ExerciseDummy

final class ExerciseDummyTests: XCTestCase {
  func testCommandWireRoundTrip() throws {
    let commands: [ExerciseCommand] = [
      .selectExercise("push-up"), .setMirrored(true), .seek(0.5), .orient(yaw: 125, pitch: 20),
      .setTempo(1.5), .play, .pause, .setMuscles(primary: ["chest"], secondary: []),
      .setHighlighting(false), .useExerciseMuscles,
    ]
    for command in commands {
      XCTAssertEqual(
        command, try JSONDecoder().decode(ExerciseCommand.self, from: JSONEncoder().encode(command))
      )
    }
    XCTAssertEqual(
      .seek(0.75),
      try JSONDecoder().decode(
        ExerciseCommand.self, from: Data(#"{"op":"seek","phase":0.75}"#.utf8)))
  }

  func testEveryBundledTrackMatchesModelAndLoops() throws {
    let model = try Library.load("model.json", as: ModelData.self)
    let catalog = try Library.load("motions.json", as: MotionData.self)
    try Library.validate(model, catalog)
    for descriptor in catalog.exercises {
      let clip = try descriptor.loaded(model: model)
      let first = clip.pose(at: 0, joints: model.joints)
      let end = clip.pose(at: 1, joints: model.joints)
      for (a, b) in zip(first.positions, end.positions) {
        XCTAssertLessThan(simd_distance(a, b), 0.003, "\(clip.id) body loop")
      }
      for (a, b) in zip(first.props, end.props) {
        XCTAssertLessThan(simd_distance(a.origin, b.origin), 0.003, "\(clip.id) equipment loop")
      }
      let keys = (try XCTUnwrap(clip.frames.first), try XCTUnwrap(clip.frames.last))
      for (a, b) in zip(keys.0.rotations, keys.1.rotations) {
        XCTAssertGreaterThan(abs(simd_dot(a, b)), 0.9999, "\(clip.id) rotational loop")
      }
      for (a, b) in zip(keys.0.props, keys.1.props) {
        XCTAssertGreaterThan(
          abs(simd_dot(a.rotation, b.rotation)), 0.9999, "\(clip.id) equipment rotation")
        XCTAssertLessThan(
          simd_distance(a.scale ?? .one, b.scale ?? .one), 0.001, "\(clip.id) equipment scale")
      }
      if let track = descriptor.track {
        let bytes = try Data(contentsOf: Library.resource(track))
        XCTAssertThrowsError(try descriptor.decoded(bytes.dropLast(), model: model))
      }
    }
  }

  func testAlternatingSideWeightsCrossfadeAtHandoffAndLoop() {
    let focus = SideFocus(
      groups: ["quadriceps"],
      intervals: [
        .init(start: 0, end: 0.5, side: .left), .init(start: 0.5, end: 1, side: .right),
      ])
    XCTAssertEqual(focus.weights(at: 0.25), [1, 0])
    XCTAssertEqual(focus.weights(at: 0.75), [0, 1])
    XCTAssertLessThan(simd_distance(focus.weights(at: 0.5), [0.5, 0.5]), 0.001)
    XCTAssertEqual(focus.weights(at: 0), focus.weights(at: 1))
  }

  @MainActor func testUnilateralTintFollowsMirroredWorkingArm() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal GPU unavailable.")
    }
    let player = try ExercisePlayer(device: device, exerciseID: "concentration-curl")
    try player.send(.orient(yaw: 0, pitch: 10))
    try player.send(.seek(0.5))
    let size = 320
    func image() throws -> [UInt8] {
      let shot = try player.snapshot(width: size, height: size)
      return Array(try XCTUnwrap(shot.dataProvider?.data) as Data)
    }
    func additionalHighlightX(mirrored: Bool) throws -> Double {
      try player.send(.setMirrored(mirrored))
      try player.send(.useExerciseMuscles)
      let prescribed = try image()
      try player.send(
        .setMuscles(
          primary: player.selectedExercise.primary, secondary: player.selectedExercise.secondary))
      let bilateral = try image()
      var total = 0
      var count = 0
      for pixel in 0..<(size * size) {
        let red = pixel * 4 + 2
        // Only the additional warm pigment on the previously idle limb is measured.
        if Int(bilateral[red]) - Int(prescribed[red]) > 30 {
          total += pixel % size
          count += 1
        }
      }
      XCTAssertGreaterThan(count, 60)
      return Double(total) / Double(max(1, count))
    }
    // Anatomical left (+X) works in the source rep. The added opposite arm is on screen left.
    XCTAssertLessThan(try additionalHighlightX(mirrored: false), Double(size) * 0.47)
    XCTAssertGreaterThan(try additionalHighlightX(mirrored: true), Double(size) * 0.53)
    XCTAssertEqual(player.phase, 0.5)
  }

  @MainActor func testGPUCommandFlow() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal GPU unavailable.")
    }
    let player = try ExercisePlayer(device: device)
    let id = try XCTUnwrap(
      player.exercises.first { $0.id == "push-up" }?.id ?? player.exercises.first?.id)
    try player.send(.selectExercise(id))
    func pixels() throws -> Data {
      let image = try player.snapshot(width: 180, height: 200)
      return try XCTUnwrap(image.dataProvider?.data) as Data
    }
    let rest = try pixels()
    try player.send(.seek(0.5))
    let bottom = try pixels()
    XCTAssertNotEqual(rest, bottom)
    try player.send(.setHighlighting(false))
    XCTAssertNotEqual(try pixels(), bottom)
    try player.send(.setHighlighting(true))
    XCTAssertEqual(try pixels(), bottom)
    try player.send(
      .setMuscles(
        primary: player.selectedExercise.secondary,
        secondary: player.selectedExercise.primary))
    XCTAssertNotEqual(try pixels(), bottom)
    try player.send(.useExerciseMuscles)
    XCTAssertEqual(try pixels(), bottom)
    try player.send(.orient(yaw: 165, pitch: 25))
    XCTAssertNotEqual(try pixels(), bottom)
    XCTAssertThrowsError(try player.send(.setMuscles(primary: ["missing-group"], secondary: [])))
    XCTAssertThrowsError(try player.send(.selectExercise("not-in-catalog")))
    XCTAssertThrowsError(try player.send(.seek(.nan)))
    XCTAssertEqual(player.selectedExercise.id, id)
    try player.send(.setTempo(2))
    try player.send(.play)
    XCTAssertTrue(player.isPlaying)
    try player.send(.pause)
    XCTAssertFalse(player.isPlaying)
  }
}
