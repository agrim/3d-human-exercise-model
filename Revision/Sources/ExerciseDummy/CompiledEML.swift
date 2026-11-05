import Foundation
import simd

/// The worst sampled occurrence of one compiler finding in an authored phase.
public struct MovementIssue: Identifiable, Sendable {
  public let id, phase, subject, reason, message: String
  public let seconds: Float
  let residual: Float
}

struct MuscleRoles: Decodable, Equatable {
  let primary, secondary: [String]

  func valid(in groups: Set<String>) -> Bool {
    let p = Set(primary)
    let s = Set(secondary)
    return p.count == primary.count && s.count == secondary.count && p.isDisjoint(with: s)
      && p.union(s).isSubset(of: groups)
  }
}

struct FrameAnnotation: Decodable {
  let phase: String
  let roles: MuscleRoles
  let sideWeights: SIMD2<Float>
}

struct EMLProp: Decodable {
  struct Part: Decodable {
    let shape: PropKind
    let dimensions, position, rotation: SIMD3<Float>
    let material: String

    var equipment: Equipment {
      Equipment(
        kind: shape, length: dimensions.x, radius: max(dimensions.y, dimensions.z) / 2,
        size: dimensions, height: nil, material: material)
    }

    var quaternion: simd_quatf {
      let r = rotation * (.pi / 180)
      return simd_quatf(angle: r.z, axis: [0, 0, 1])
        * simd_quatf(angle: r.y, axis: [0, 1, 0]) * simd_quatf(angle: r.x, axis: [1, 0, 0])
    }
  }
  let visual: [Part]
  let category: String
  let dimensions: SIMD3<Float>
}

/// JSON emitted by eml.Program.compile(). A travelling loop includes separately solved
/// cycles because an anchored cable or hand may stay in world coordinates.
struct CompiledEML: Decodable {
  struct Repetition: Decodable {
    enum Mode: String, Decodable { case once, hold, loop }
    let mode: Mode
    let count: Int
    let travel: SIMD3<Float>?
  }
  struct Item: Decodable {
    let id, kind: String
  }
  struct Connection: Decodable {
    struct Socket: Decodable { let item, socket: String }
    let from, to: Socket
    let kind: String
  }
  struct ItemPose: Decodable {
    let position: SIMD3<Float>
    let rotation: SIMD4<Float>
    let sockets: [String: SIMD3<Float>]
  }
  struct ContactDiagnostic: Decodable {
    let effector, reason: String
    let path, message: String?
    let residual: Float?
  }
  struct Sample: Decodable {
    let time: Double
    let phase: String
    let root: SIMD3<Float>
    let rotations: [String: SIMD4<Float>]
    let equipment: [String: ItemPose]
    let muscles: MuscleRoles
    let sideWeights: SIMD2<Float>?
    let diagnostics: [ContactDiagnostic]?
  }
  let eml, id, title: String
  let duration: Float
  let joints: [String]
  let muscles: MuscleRoles
  let repeatPolicy: Repetition
  let equipment: [Item]
  let connections: [Connection]
  let camera: [Float]
  let frames: [Sample]
  let travelCycles: [[Sample]]?
  let sideFocus: SideFocus?

  enum CodingKeys: String, CodingKey {
    case eml, id, title, duration, joints, muscles, equipment, connections, camera, frames,
      sideFocus, travelCycles
    case repeatPolicy = "repeat"
  }

  func makeClip(model: ModelData, kit: [String: EMLProp]) throws -> Clip {
    func invalid(_ detail: String) -> ExerciseDummyError { .invalidAsset("EML \(id): \(detail)") }
    try Library.validateModel(model)
    let groups = Set(model.groups).subtracting(Library.structural)
    guard ["1.0", "1.1"].contains(eml), duration.isFinite, duration > 0,
      joints == model.joints.map(\.name),
      (1...1000).contains(repeatPolicy.count), muscles.valid(in: groups),
      repeatPolicy.mode != .once || repeatPolicy.count == 1,
      Set(equipment.map(\.id)).count == equipment.count
    else {
      throw invalid("Invalid version, skeleton, muscles, duration or repetition policy.")
    }
    let moving = (repeatPolicy.travel ?? .zero) != .zero
    let later = travelCycles ?? []
    guard later.count == (moving ? repeatPolicy.count - 1 : 0) else {
      throw invalid("Travelling repetitions require a compiled frame series for each cycle.")
    }
    let props = try equipment.map { item -> EMLProp in
      guard let prop = kit[item.kind] else { throw invalid("Unknown equipment \(item.kind).") }
      return prop
    }
    let shapes =
      props.flatMap { $0.visual.map(\.equipment) }
      + connections.map { edge in
        Equipment(
          kind: .rod, length: 1, radius: edge.kind == "rope" ? 0.012 : 0.006,
          size: nil, height: nil, material: edge.kind == "band" ? "band" : "steel")
      }
    let offsets = props.flatMap { prop in
      prop.visual.map { simd_float4x4.translated($0.position) * simd_float4x4($0.quaternion) }
    }
    // A box per moving point fits the whole rep without enclosing empty space between the body and bar.
    var paths = Array(repeating: AABB(), count: joints.count + props.count * 8)
    var sceneBounds = AABB()
    func convert(_ samples: [Sample]) throws -> [Keyframe] {
      var converted = [Keyframe]()
      converted.reserveCapacity(samples.count)
      for s in samples {
        guard s.time.isFinite, s.muscles.valid(in: groups), s.rotations.count == joints.count,
          !s.phase.isEmpty, s.equipment.count == equipment.count
        else {
          throw invalid("Invalid frame at \(s.time) seconds.")
        }
        let phase = Float(s.time) / duration
        let q = try joints.map { name -> SIMD4<Float> in
          guard let v = s.rotations[name], v.isUnitRotation else {
            throw invalid("Invalid joint \(name).")
          }
          return v
        }
        var worldRotations = [simd_quatf]()
        var positions = [SIMD3<Float>]()
        for (i, j) in model.joints.enumerated() {
          let local = simd_quatf(vector: q[i])
          let pos: SIMD3<Float>
          if j.parent < 0 {
            worldRotations.append(local)
            pos = j.position + s.root
          } else {
            let parent = worldRotations[j.parent]
            worldRotations.append(parent * local)
            pos = positions[j.parent] + parent.act(j.position - model.joints[j.parent].position)
          }
          positions.append(pos)
          paths[i].include(pos)
        }
        var transforms = [PropPose]()
        for (i, item) in equipment.enumerated() {
          guard let pose = s.equipment[item.id], pose.rotation.isUnitRotation,
            pose.position.isFiniteVector
          else { throw invalid("Invalid transform for \(item.id).") }
          let orient = simd_quatf(vector: pose.rotation)
          var extent = AABB()
          extent.include(props[i].dimensions * -0.5)
          extent.include(props[i].dimensions * 0.5)
          for (corner, p) in extent.corners.enumerated() {
            let world = pose.position + orient.act(p)
            if props[i].category == "free-weight" {
              paths[joints.count + i * 8 + corner].include(world)
            }
            sceneBounds.include(world)
          }
          for _ in props[i].visual {
            transforms.append(.init(position: pose.position, rotation: pose.rotation, scale: nil))
          }
        }
        for edge in connections {
          func point(_ endpoint: Connection.Socket) throws -> SIMD3<Float> {
            guard let p = s.equipment[endpoint.item]?.sockets[endpoint.socket], p.isFiniteVector
            else {
              throw invalid("Missing connection socket \(endpoint.item).\(endpoint.socket).")
            }
            return p
          }
          let a = try point(edge.from)
          let b = try point(edge.to)
          let delta = b - a
          let length = simd_length(delta)
          let rot =
            length > 1e-6
            ? simd_quatf(from: [1, 0, 0], to: delta / length)
            : simd_quatf(angle: 0, axis: [1, 0, 0])
          transforms.append(
            .init(
              position: (a + b) * 0.5, rotation: rot.vector,
              scale: [max(1e-6, length), 1, 1]))
          sceneBounds.include(a)
          sceneBounds.include(b)
        }
        let f = Keyframe(
          phase: phase, root: s.root, rotations: q, props: transforms,
          annotation: .init(phase: s.phase, roles: s.muscles, sideWeights: s.sideWeights ?? .one))
        // Phase boundaries can coincide with a sample grid point within Float precision.
        if converted.last?.phase == phase {
          converted[converted.count - 1] = f
        } else {
          converted.append(f)
        }
      }
      return converted
    }
    let first = try convert(frames)
    let rest = try later.map(convert)
    for path in paths where path.valid {
      sceneBounds.include(path.low)
      sceneBounds.include(path.high)
    }
    var clip = Clip(
      eml: self, equipment: shapes, frames: first, travelFrames: rest,
      partOffsets: offsets, framing: paths, scene: sceneBounds)
    var issues = [String: MovementIssue]()
    for (cycle, samples) in ([frames] + later).enumerated() {
      for sample in samples {
        for diagnostic in sample.diagnostics ?? [] {
          let key = [sample.phase, diagnostic.path ?? "", diagnostic.effector, diagnostic.reason]
            .joined(separator: "|")
          let residual = diagnostic.residual ?? 0
          if let previous = issues[key], previous.residual >= residual { continue }
          let message = diagnostic.message ?? (diagnostic.effector + " · " + diagnostic.reason)
          issues[key] = MovementIssue(
            id: key, phase: sample.phase, subject: diagnostic.effector,
            reason: diagnostic.reason, message: message,
            seconds: Float(cycle) * duration + Float(sample.time),
            residual: residual)
        }
      }
    }
    clip.movementIssues = issues.values.sorted { ($0.seconds, $0.id) < ($1.seconds, $1.id) }
    try Library.validate(model, .init(version: 1, joints: joints, exercises: [clip]))
    for frames in rest {
      var cycle = clip
      cycle.frames = frames
      try Library.validateFrames(cycle, model: model)
    }
    return clip
  }
}
