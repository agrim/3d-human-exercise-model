import Foundation
import simd

/// Read the symbols used by the bundled compiler, including a contributor's additional libraries.
struct EMLVocabulary {
  let poses, motions, joints, muscles, equipment, handheldEquipment: [String]
  let motionFamilies: [String: String]
  let compatibleMotions: [String: Set<String>]
  let contactPoints: [String]
  private let palmOffsets: [String: SIMD3<Double>]
  private let gripAxes: [String: SIMD3<Double>]
  private let handles: [String: SIMD3<Double>]

  static func load(from root: URL) throws -> Self {
    struct Interface: Decodable {
      struct Sources: Decodable {
        let definitions: [String]
        let equipment, rig: String
      }
      let vocabulary: Sources
      let compatibleSetups: String?
    }
    struct Names: Decodable {
      struct Entry: Decodable {}
      let poses, motions: [String: Entry]?
    }
    struct Rig: Decodable {
      struct Joint: Decodable {
        let name: String
        let position: SIMD3<Double>
      }
      let joints: [Joint]
      let landmarks: [String: SIMD3<Double>]
      let groups: [String]
    }
    struct Item: Decodable {
      let category: String
      let sockets: [String: SIMD3<Double>]
    }
    let decoder = JSONDecoder()
    func read<T: Decodable>(_ type: T.Type, at file: URL) throws -> T {
      try decoder.decode(type, from: Data(contentsOf: file))
    }
    let interface = try read(Interface.self, at: root.appending(path: "interface.json"))
    let sources = interface.vocabulary
    struct Setups: Decodable {
      struct Entry: Decodable {
        let pose: String
        let motions: [String]
      }
      let setups: [Entry]
    }
    var compatible: [String: Set<String>] = [:]
    if let path = interface.compatibleSetups {
      for setup in try read(Setups.self, at: root.appending(path: path)).setups {
        compatible[setup.pose, default: []].formUnion(setup.motions)
      }
    }
    let kitURL = root.appending(path: sources.equipment)
    let directory = kitURL.deletingLastPathComponent()
    let siblings = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != kitURL.lastPathComponent }
    let files = Set(sources.definitions.map { root.appending(path: $0).standardizedFileURL })
      .union(siblings.map(\.standardizedFileURL))
    var poses = Set<String>()
    var motions = Set<String>()
    var families: [String: String] = [:]
    for url in files {
      let library = try read(Names.self, at: url)
      poses.formUnion((library.poses ?? [:]).keys)
      let stem = url.deletingPathExtension().lastPathComponent
      let family =
        ["base": "Basic movements", "upper": "Upper body", "lower": "Lower body"][stem]
        ?? stem.replacingOccurrences(of: "-", with: " ").capitalized
      for symbol in (library.motions ?? [:]).keys {
        guard motions.insert(symbol).inserted else {
          throw DraftError("The EML vocabulary defines “" + symbol + "” twice.")
        }
        families[symbol] = family
      }
    }
    guard !poses.isEmpty, !motions.isEmpty else {
      throw DraftError("No movement vocabulary was found in this EML bundle.")
    }
    let rig = try read(Rig.self, at: root.appending(path: sources.rig))
    let names = Set(rig.joints.map(\.name))
    let bilateral = names.compactMap { name -> String? in
      guard name.hasPrefix("left") else { return nil }
      let part = name.dropFirst(4)
      return names.contains("right" + part) ? "both" + part : nil
    }
    let kit = try read([String: Item].self, at: kitURL)
    var offsets: [String: SIMD3<Double>] = [:]
    var axes: [String: SIMD3<Double>] = [:]
    for side in ["left", "right"] {
      let hand = side + "Hand"
      if let joint = rig.joints.first(where: { $0.name == hand }),
        let grip = rig.landmarks[side + "Grip"]
      {
        offsets[hand] = grip - joint.position
      }
      if let index = rig.joints.first(where: { $0.name == side + "Index1" }),
        let little = rig.joints.first(where: { $0.name == side + "Little1" })
      {
        let across = index.position - little.position
        if simd_length(across) > 0.0001 {
          axes[hand] = simd_normalize(across.x < 0 ? -across : across)
        }
      }
    }
    let handles = kit.filter { $0.value.category == "free-weight" }.compactMapValues {
      $0.sockets["handle"]
    }
    return Self(
      poses: poses.sorted(), motions: motions.sorted(), joints: names.union(bilateral).sorted(),
      muscles: Set(rig.groups).subtracting(["neutral", "bone", "tendon", "shell"]).sorted(),
      equipment: kit.keys.sorted(), handheldEquipment: handles.keys.sorted(),
      motionFamilies: families, compatibleMotions: compatible, contactPoints: rig.landmarks.keys.sorted(), palmOffsets: offsets, gripAxes: axes,
      handles: handles)
  }

  fileprivate func grasp(for kind: String, in hand: String) throws -> (
    offset: [Double], rotation: [Double]
  ) {
    guard let palm = palmOffsets[hand], let handle = handles[kind] else {
      throw DraftError(
        "Choose a handheld weight for the hand attachment, or place the equipment in the scene.")
    }
    // The handle's X axis runs across the knuckles. Rotate before aligning its socket to the palm.
    let axis = gripAxes[hand] ?? SIMD3<Double>(1, 0, 0)
    let y = -asin(max(-1, min(1, axis.z)))
    let z = atan2(axis.y, axis.x)
    let turn = simd_quatd(angle: z, axis: [0, 0, 1]) * simd_quatd(angle: y, axis: [0, 1, 0])
    let offset = palm - turn.act(handle)
    return ([offset.x, offset.y, offset.z], [0, y * 180 / .pi, z * 180 / .pi])
  }
}

enum EMLRepeatMode: String, CaseIterable, Codable { case once, loop, hold }

struct EMLActionDraft: Identifiable, Codable, Equatable {
  private(set) var id = UUID()
  var motion: String
  var amount: Double = 1
  var adjustable = false
}

struct EMLJointEdit: Identifiable, Codable, Equatable {
  private(set) var id = UUID()
  var joint: String
  var axis = "x"
  var degrees: Double = 0
  var adjustable = false
}

struct EMLMuscleRoles: Codable, Equatable {
  var primary: Set<String> = []
  var secondary: Set<String> = []

  fileprivate var document: [String: [String]] {
    ["primary": primary.sorted(), "secondary": secondary.sorted()]
  }
}

struct EMLPhaseDraft: Identifiable, Codable, Equatable {
  private(set) var id = UUID()
  var name = ""
  var seconds: Double = 1
  var actions: [EMLActionDraft] = []
  var joints: [EMLJointEdit] = []
  var holdsPrevious = false
  var adjustableDuration = false
  var ease = "smooth"
  /// Missing from older drafts. Nil inherits the exercise roles; an empty override clears both.
  var muscleOverride: EMLMuscleRoles?
  var fixedPoints: Set<String>?
}

struct EMLEquipmentDraft: Identifiable, Codable, Equatable {
  private(set) var id = UUID()
  var kind: String
  /// "leftHand", "rightHand", or an empty string for a fixed world placement in metres.
  var hand = "rightHand"
  var x: Double = 0
  var y: Double = 0
  var z: Double = 0
}

private struct DraftError: LocalizedError {
  let reason: String
  init(_ reason: String) { self.reason = reason }
  var errorDescription: String? { reason }
}

/// An authoring form for the most useful EML sockets. EMLCompiler owns schema and semantic validation.
struct EMLDraft: Codable, Equatable {
  var title = ""
  var identifier = ""
  var instructions = ""
  var startPose = "standing"
  var startJoints: [EMLJointEdit] = []
  var stanceWidth = ""
  var fixedPoints: Set<String>?
  var toeOut: Double = 0
  var mode: EMLRepeatMode = .once
  var count = 1
  var phases = [EMLPhaseDraft(name: "Move")]
  var primary: Set<String> = []
  var secondary: Set<String> = []
  var equipment: [EMLEquipmentDraft] = []

  /// Produce ordinary EML JSON. Core language fields remain subject to the same EML compiler as imports.
  func source(vocabulary supplied: EMLVocabulary? = nil) throws -> String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw DraftError("Give the exercise a title.") }
    let explicitID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = explicitID.isEmpty ? Self.slug(title) : explicitID
    guard !id.isEmpty else { throw DraftError("Enter an exercise ID using letters and hyphens.") }
    guard !phases.isEmpty else { throw DraftError("Add at least one phase.") }
    var parameters: [String: [String: Double]] = [:]
    func scalar(_ value: Double, adjustable: Bool, key: String, bounds: ClosedRange<Double>) -> Any
    {
      guard adjustable else { return value }
      parameters[key] = ["default": value, "min": bounds.lowerBound, "max": bounds.upperBound]
      return ["param": key]
    }
    func channels(_ edits: [EMLJointEdit], prefix: String) throws -> [String: [String: Any]] {
      var result: [String: [String: Any]] = [:]
      for (index, edit) in edits.enumerated() {
        guard result[edit.joint]?[edit.axis] == nil else {
          throw DraftError("Set the \(edit.axis) angle of \(edit.joint) only once in this pose.")
        }
        result[edit.joint, default: [:]][edit.axis] =
          scalar(
            edit.degrees, adjustable: edit.adjustable, key: prefix + "-angle-\(index + 1)",
            bounds: -360...360)
      }
      return result
    }

    var setup: [String: Any] = ["pose": startPose]
    if !startJoints.isEmpty { setup["joints"] = try channels(startJoints, prefix: "start") }
    if !stanceWidth.isEmpty {
      setup["stance"] = ["width": stanceWidth, "toeOut": toeOut] as [String: Any]
    }
    var doc: [String: Any] = [
      "eml": "1.1", "id": id, "title": title, "start": setup,
      "muscles": EMLMuscleRoles(primary: primary, secondary: secondary).document,
      "repeat": ["mode": mode.rawValue, "count": mode == .once ? 1 : count] as [String: Any],
    ]
    func contacts(_ points: Set<String>) -> [[String: String]] {
      points.sorted().map { ["effector": $0, "target": "start"] }
    }
    if let fixedPoints, !fixedPoints.isEmpty { doc["contacts"] = contacts(fixedPoints) }
    if !instructions.isEmpty { doc["instructions"] = instructions }
    var actions: [[String: Any]] = []
    var overrides: [String: [String: Any]] = [:]
    var phaseNames = Set<String>()
    var steps: [[String: Any]] = []
    for (index, phase) in phases.enumerated() {
      let name = Self.slug(phase.name)
      guard !name.isEmpty else { throw DraftError("Give phase \(index + 1) a name.") }
      guard phaseNames.insert(name).inserted else {
        throw DraftError("Give each phase a different name. “\(name)” appears twice.")
      }
      let prefix = "phase-\(index + 1)"
      let hasTargets = !phase.actions.isEmpty || !phase.joints.isEmpty
      if phase.holdsPrevious && hasTargets {
        throw DraftError(
          "A pause keeps the preceding pose. Remove the movements from “\(phase.name)” or turn off the pause."
        )
      }
      if !phase.holdsPrevious {
        actions = phase.actions.enumerated().map { index, action in
          [
            "use": action.motion,
            "amount": scalar(
              action.amount, adjustable: action.adjustable,
              key: prefix + "-amount-\(index + 1)", bounds: -4...4),
          ]
        }
        overrides = try channels(phase.joints, prefix: prefix)
      }
      var step: [String: Any] = [
        "id": name, "actions": actions,
        "seconds": scalar(
          phase.seconds, adjustable: phase.adjustableDuration, key: prefix + "-seconds",
          bounds: 0.02...600),
      ]
      if phase.ease != "smooth" { step["ease"] = phase.ease }
      if let roles = phase.muscleOverride { step["muscles"] = roles.document }
      if let points = phase.fixedPoints { step["contacts"] = contacts(points) }
      if !overrides.isEmpty { step["detail"] = ["joints": overrides] }
      steps.append(step)
    }
    doc["phases"] = steps
    if !parameters.isEmpty { doc["parameters"] = parameters }
    if !equipment.isEmpty {
      let vocab =
        try supplied ?? EMLVocabulary.load(from: Bundle.main.bundleURL.appending(path: "EML"))
      doc["equipment"] = try equipment.enumerated().map { index, item -> [String: Any] in
        var result: [String: Any] = ["id": "item-\(index + 1)", "kind": item.kind]
        guard !item.hand.isEmpty else {
          result["position"] = [item.x, item.y, item.z]
          return result
        }
        let grip = try vocab.grasp(for: item.kind, in: item.hand)
        result["rotation"] = grip.rotation
        result["follow"] =
          [
            "joint": item.hand, "grip": true,
            "offset": grip.offset,
          ] as [String: Any]
        return result
      }
    }
    let data = try JSONSerialization.data(
      withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  /// Form labels become portable identifiers. Explicit exercise identifiers pass through unchanged.
  private static func slug(_ value: String) -> String {
    let latin = (value.applyingTransform(.toLatin, reverse: false) ?? value)
      .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
      .lowercased()
    let parts = latin.components(
      separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted
    )
    .filter { !$0.isEmpty }
    let name = parts.joined(separator: "-")
    guard let first = name.first else { return "" }
    return first.isNumber ? "position-" + name : name
  }
}
