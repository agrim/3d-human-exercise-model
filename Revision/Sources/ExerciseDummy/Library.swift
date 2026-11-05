import Foundation
import simd

public enum ExerciseDummyError: Error, LocalizedError, Sendable {
  case invalidAsset(String)
  case invalidCommand(String)
  case rendering(String)

  public var errorDescription: String? {
    switch self {
    case .invalidAsset(let detail), .invalidCommand(let detail), .rendering(let detail):
      return detail
    }
  }
}

/// Identifiers are stable across the rendering and exercise-authoring APIs.
public struct ExerciseDefinition: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let seconds: Float
  public let primary: [String]
  public let secondary: [String]
  public let cameraYaw, cameraPitch: Float
}

struct Joint: Decodable, Equatable {
  let name: String
  let parent: Int
  let position: SIMD3<Float>
}

struct ModelData: Decodable {
  let version, vertexCount, indexCount: Int
  let joints: [Joint]
  let groups: [String]
  let wristPivots: [String]?
}

enum PropKind: String, Decodable { case dumbbell, barbell, kettlebell, bench, box, rod, ball }
struct Equipment: Decodable, Hashable {
  let kind: PropKind
  let length, radius: Float
  let size: SIMD3<Float>?
  let height: Float?
  let material: String?
}
struct PropPose: Decodable {
  let position: SIMD3<Float>
  let rotation: SIMD4<Float>
  let scale: SIMD3<Float>?
}
struct Keyframe: Decodable {
  let phase: Float
  let root: SIMD3<Float>
  let rotations: [SIMD4<Float>]
  let props: [PropPose]
  var annotation: FrameAnnotation? = nil
}
struct SideFocus: Decodable {
  enum Side: String, Decodable { case left, right }
  struct Interval: Decodable {
    let start, end: Float
    let side: Side
  }
  let groups: [String]
  let intervals: [Interval]

  // Feather a handoff between the two sides over 4% of the loop.
  func weights(at phase: Float) -> SIMD2<Float> {
    func wrapped(_ p: Float) -> Float { p - floor(p) }
    func at(_ p: Float) -> SIMD2<Float> {
      let t = wrapped(p)
      guard let hit = intervals.first(where: { $0.start <= t && t < $0.end }) else { return .one }
      return hit.side == .left ? [1, 0] : [0, 1]
    }
    for interval in intervals {
      for edge in [interval.start, interval.end] {
        let delta = wrapped(phase - edge + 0.5) - 0.5
        if abs(delta) < 0.02 {
          let t = (delta + 0.02) / 0.04
          return simd_mix(
            at(edge - 0.00001), at(edge + 0.00001), SIMD2(repeating: t * t * (3 - 2 * t)))
        }
      }
    }
    return at(phase)
  }
}
struct Clip: Decodable {
  let id, title: String
  let seconds: Float
  let primary, secondary: [String]
  let camera: [Float]
  let cameraTarget: SIMD3<Float>?
  let cameraDistance: Float?
  let sideFocus: SideFocus?
  var frames: [Keyframe]
  let equipment: [Equipment]
  let track: String?
  var cycles = 1
  var travelFrames: [[Keyframe]] = []
  var emlPartOffsets: [simd_float4x4]?
  var emlFramingPaths: [AABB]?
  var emlSceneBounds: AABB?
  var movementIssues: [MovementIssue] = []
  var duration: Float { seconds * Float(cycles) }

  init(
    eml wire: CompiledEML, equipment: [Equipment], frames: [Keyframe],
    travelFrames: [[Keyframe]], partOffsets: [simd_float4x4], framing: [AABB], scene: AABB
  ) {
    id = wire.id
    title = wire.title
    seconds = wire.duration
    primary = wire.muscles.primary
    secondary = wire.muscles.secondary
    camera = wire.camera
    cameraTarget = nil
    cameraDistance = nil
    sideFocus = wire.sideFocus
    self.frames = frames
    self.equipment = equipment
    track = nil
    cycles = wire.repeatPolicy.count
    self.travelFrames = travelFrames
    emlPartOffsets = partOffsets
    emlFramingPaths = framing
    emlSceneBounds = scene
  }

  enum CodingKeys: String, CodingKey {
    case id, title, seconds, primary, secondary, camera, cameraTarget, cameraDistance, frames,
      equipment, track, sideFocus
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    seconds = try c.decode(Float.self, forKey: .seconds)
    primary = try c.decode([String].self, forKey: .primary)
    secondary = try c.decode([String].self, forKey: .secondary)
    camera = try c.decode([Float].self, forKey: .camera)
    cameraTarget = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .cameraTarget)
    cameraDistance = try c.decodeIfPresent(Float.self, forKey: .cameraDistance)
    equipment = try c.decode([Equipment].self, forKey: .equipment)
    frames = try c.decodeIfPresent([Keyframe].self, forKey: .frames) ?? []
    track = try c.decodeIfPresent(String.self, forKey: .track)
    sideFocus = try c.decodeIfPresent(SideFocus.self, forKey: .sideFocus)
  }

  var definition: ExerciseDefinition {
    .init(
      id: id, title: title, seconds: seconds, primary: primary, secondary: secondary,
      cameraYaw: camera[0], cameraPitch: camera[1])
  }
}
struct MotionData: Decodable {
  let version: Int
  let joints: [String]
  let exercises: [Clip]
}

enum Library {
  static func resource(_ name: String) throws -> URL {
    guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
      throw ExerciseDummyError.invalidAsset("Invalid resource name.")
    }
    // EXM1 is a desktop authoring fixture. The iOS app ships the EML checkout's data.
    #if os(macOS)
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)
      let path = root.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: path.path) { return path }
    #endif
    throw ExerciseDummyError.invalidAsset(
      "Missing legacy fixture \(name). Initialize with an EML root.")
  }
  static func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: resource(name)))
  }
  static let structural: Set<String> = ["bone", "tendon", "shell", "neutral"]

  private static func require(_ pass: Bool, _ detail: String) throws {
    if !pass { throw ExerciseDummyError.invalidAsset(detail) }
  }

  static func validateModel(_ model: ModelData) throws {
    try require(model.version == 1, "Unsupported exercise anatomy.")
    try require(
      (1...256).contains(model.joints.count) && !model.groups.isEmpty,
      "Empty or unsupported skeleton or palette.")
    try require(
      Set(model.groups).count == model.groups.count
        && Set(model.joints.map(\.name)).count == model.joints.count,
      "Duplicate skeleton or group ID.")
    for (i, j) in model.joints.enumerated() {
      try require(
        i == 0 ? j.parent == -1 : (0..<i).contains(j.parent),
        "Joints must be in parent-first order with one root.")
      try require(j.position.isFiniteVector, "Invalid joint center.")
    }
  }

  static func validate(_ model: ModelData, _ motion: MotionData) throws {
    try validateModel(model)
    try require(motion.version == 1, "Unsupported exercise asset version.")
    try require(
      motion.joints == model.joints.map(\.name),
      "Exercise tracks and skeleton use different joints.")
    try require(
      !motion.exercises.isEmpty && Set(motion.exercises.map(\.id)).count == motion.exercises.count,
      "Missing or duplicate exercise ID.")
    let groups = Set(model.groups).subtracting(structural)
    for c in motion.exercises {
      let primary = Set(c.primary)
      let secondary = Set(c.secondary)
      try require(
        c.seconds.isFinite && c.seconds > 0 && !c.id.isEmpty
          && (c.emlFramingPaths != nil || !primary.isEmpty)
          && primary.isSubset(of: groups) && secondary.isSubset(of: groups)
          && primary.isDisjoint(with: secondary),
        "Invalid exercise duration or muscle roles for \(c.id).")
      try require(
        c.camera.count == 2 && c.camera.allSatisfy(\.isFinite)
          && c.cameraTarget?.isFiniteVector != false
          && c.cameraDistance.map { $0.isFinite && $0 > 0 } != false,
        "Invalid camera for \(c.id).")
      try require(
        c.equipment.allSatisfy {
          $0.length.isFinite && $0.length > 0 && $0.radius.isFinite && $0.radius > 0
            && $0.size.map { $0.isFiniteVector && $0.min() > 0 } != false
            && $0.height.map { $0.isFinite && $0 > 0 } != false
        }, "Invalid equipment for \(c.id).")
      if let focus = c.sideFocus {
        try require(
          !focus.intervals.isEmpty && Set(focus.groups).isSubset(of: primary.union(secondary)),
          "Invalid side-specific muscle group.")
        var previousEnd: Float = 0
        for interval in focus.intervals {
          try require(
            interval.start >= previousEnd && interval.end <= 1 && interval.end > interval.start,
            "Invalid side interval.")
          previousEnd = interval.end
        }
      }
      if c.track != nil && c.frames.isEmpty { continue }
      try validateFrames(c, model: model)
    }
  }
  static func validateFrames(_ c: Clip, model: ModelData) throws {
    func require(_ pass: Bool, _ message: String) throws {
      if !pass { throw ExerciseDummyError.invalidAsset(message) }
    }
    try require(
      c.frames.count >= 2 && c.frames.first?.phase == 0 && c.frames.last?.phase == 1,
      "Incomplete loop in \(c.id).")
    var previous: Float = -1
    for f in c.frames {
      try require(
        f.phase > previous && f.phase.isFinite && f.root.isFiniteVector
          && f.rotations.count == model.joints.count && f.rotations.allSatisfy(\.isUnitRotation)
          && f.props.count == c.equipment.count
          && f.props.allSatisfy {
            $0.position.isFiniteVector && $0.rotation.isUnitRotation
              && $0.scale?.isFiniteVector != false
          }, "Invalid animation frame in \(c.id).")
      previous = f.phase
    }
  }
}
extension SIMD3 where Scalar == Float {
  var isFiniteVector: Bool { x.isFinite && y.isFinite && z.isFinite }
}
extension SIMD4 where Scalar == Float {
  var isUnitRotation: Bool { abs(simd_length_squared(self) - 1) < 0.01 }
}
extension simd_float4x4 {
  static func translated(_ p: SIMD3<Float>) -> Self {
    var t = matrix_identity_float4x4
    t.columns.3 = SIMD4(p, 1)
    return t
  }
  var origin: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}

struct Pose {
  let skin: [simd_float4x4]
  let positions: [SIMD3<Float>]
  let props: [simd_float4x4]
  func reflectingX() -> Pose {
    let reflection = simd_float4x4(diagonal: [-1, 1, 1, 1])
    return Pose(
      skin: skin.map { reflection * $0 }, positions: positions.map { [-$0.x, $0.y, $0.z] },
      props: props.map { reflection * $0 })
  }
}
extension Clip {
  /// Normalized progress covers the demonstration, including its last endpoint.
  func sampleLocation(_ progress: Float) -> (frames: [Keyframe], phase: Float) {
    let t = min(1, max(0, progress)) * Float(cycles)
    let cycle = min(Int(t), cycles - 1)
    let frames = cycle == 0 || travelFrames.isEmpty ? self.frames : travelFrames[cycle - 1]
    return (frames, t - Float(cycle))
  }

  func annotation(at progress: Float) -> FrameAnnotation? {
    let (frames, phase) = sampleLocation(progress)
    guard frames.first?.annotation != nil else { return nil }
    // A boundary belongs to the completed phase. Between samples the next endpoint owns the interval.
    var low = 0
    var high = frames.count - 1
    while low < high {
      let mid = (low + high) / 2
      if frames[mid].phase < phase { low = mid + 1 } else { high = mid }
    }
    return frames[low].annotation
  }

  func pose(at phase: Float, joints: [Joint]) -> Pose {
    let location = sampleLocation(phase)
    let frames = location.frames
    let phase = location.phase
    var lo = 0
    var hi = frames.count - 1
    while hi - lo > 1 {
      let mid = (lo + hi) / 2
      if frames[mid].phase <= phase { lo = mid } else { hi = mid }
    }
    let a = frames[lo]
    let b = frames[hi]
    let fraction = min(1, max(0, (phase - a.phase) / (b.phase - a.phase)))
    func rotation(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> simd_float4x4 {
      simd_float4x4(simd_slerp(simd_quatf(vector: a), simd_quatf(vector: b), fraction).normalized)
    }
    let offset = simd_mix(a.root, b.root, SIMD3(repeating: fraction))
    var world = [simd_float4x4]()
    var skin = [simd_float4x4]()
    world.reserveCapacity(joints.count)
    skin.reserveCapacity(joints.count)
    for (i, j) in joints.enumerated() {
      let local = rotation(a.rotations[i], b.rotations[i])
      let transform: simd_float4x4
      if j.parent < 0 {
        transform = .translated(offset + j.position) * local
      } else {
        transform = world[j.parent] * .translated(j.position - joints[j.parent].position) * local
      }
      world.append(transform)
      skin.append(transform * .translated(-j.position))
    }
    let props: [simd_float4x4] = a.props.indices.map { index in
      let p = a.props[index]
      let q = b.props[index]
      let position = simd_mix(p.position, q.position, SIMD3(repeating: fraction))
      if let offsets = emlPartOffsets {
        if index < offsets.count {
          // A rigid plate or pad rotates about its item's origin, not its own center.
          return .translated(position) * rotation(p.rotation, q.rotation) * offsets[index]
        }
        // Connection endpoints interpolate in world space, including when the line changes length.
        func direction(_ pose: PropPose) -> SIMD3<Float> {
          simd_quatf(vector: pose.rotation).act([(pose.scale ?? .one).x, 0, 0])
        }
        let delta = simd_mix(direction(p), direction(q), SIMD3(repeating: fraction))
        let length = simd_length(delta)
        let aligned =
          length > 1e-6
          ? simd_float4x4(simd_quatf(from: [1, 0, 0], to: delta / length))
          : matrix_identity_float4x4
        return .translated(position) * aligned
          * simd_float4x4(diagonal: [max(1e-6, length), 1, 1, 1])
      }
      let scale = simd_mix(p.scale ?? .one, q.scale ?? .one, SIMD3(repeating: fraction))
      return .translated(position) * rotation(p.rotation, q.rotation)
        * simd_float4x4(diagonal: SIMD4(scale, 1))
    }
    return Pose(skin: skin, positions: world.map(\.origin), props: props)
  }
}
