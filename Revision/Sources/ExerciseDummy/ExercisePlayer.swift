import CoreGraphics
import Foundation
import MetalKit
import Observation
import QuartzCore

/// A small version-independent wire form, e.g. {"op":"selectExercise","id":"push-up"}.
public enum ExerciseCommand: Equatable, Codable, Sendable {
  case selectExercise(String)
  case orient(yaw: Float, pitch: Float)
  case seek(Float)
  case play, pause
  case setTempo(Float)
  case setMuscles(primary: [String], secondary: [String])
  case setHighlighting(Bool)
  case setMirrored(Bool)
  case useExerciseMuscles

  enum Op: String, Codable {
    case selectExercise, orient, seek, play, pause, setTempo, setMuscles, setHighlighting,
      useExerciseMuscles, setMirrored
  }
  enum Keys: String, CodingKey {
    case op, id, yaw, pitch, phase, rate, primary, secondary, enabled
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(Op.self, forKey: .op) {
    case .selectExercise: self = .selectExercise(try c.decode(String.self, forKey: .id))
    case .orient:
      self = try .orient(
        yaw: c.decode(Float.self, forKey: .yaw), pitch: c.decode(Float.self, forKey: .pitch))
    case .seek: self = .seek(try c.decode(Float.self, forKey: .phase))
    case .play: self = .play
    case .pause: self = .pause
    case .setTempo: self = .setTempo(try c.decode(Float.self, forKey: .rate))
    case .setMuscles:
      self = try .setMuscles(
        primary: c.decode([String].self, forKey: .primary),
        secondary: c.decode([String].self, forKey: .secondary))
    case .setHighlighting: self = .setHighlighting(try c.decode(Bool.self, forKey: .enabled))
    case .setMirrored: self = .setMirrored(try c.decode(Bool.self, forKey: .enabled))
    case .useExerciseMuscles: self = .useExerciseMuscles
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    let op: Op
    switch self {
    case .selectExercise(let id):
      op = .selectExercise
      try c.encode(id, forKey: .id)
    case .orient(let y, let p):
      op = .orient
      try c.encode(y, forKey: .yaw)
      try c.encode(p, forKey: .pitch)
    case .seek(let f):
      op = .seek
      try c.encode(f, forKey: .phase)
    case .play: op = .play
    case .pause: op = .pause
    case .setTempo(let r):
      op = .setTempo
      try c.encode(r, forKey: .rate)
    case .setMuscles(let p, let s):
      op = .setMuscles
      try c.encode(p, forKey: .primary)
      try c.encode(s, forKey: .secondary)
    case .setHighlighting(let e):
      op = .setHighlighting
      try c.encode(e, forKey: .enabled)
    case .setMirrored(let value):
      op = .setMirrored
      try c.encode(value, forKey: .enabled)
    case .useExerciseMuscles: op = .useExerciseMuscles
    }
    try c.encode(op, forKey: .op)
  }
}

/// Controller for one exercise presentation. Retain it when switching SwiftUI screens.
@Observable
@MainActor
public final class ExercisePlayer {
  public let exercises: [ExerciseDefinition]
  public let muscleGroups: [String]
  public let attribution: String
  public var selectedExercise: ExerciseDefinition { clip.definition }
  public private(set) var isPlaying = false
  public private(set) var rate: Float = 1
  public private(set) var yaw: Float
  public private(set) var pitch: Float
  public private(set) var zoom: Float = 1
  public private(set) var isMirrored = false
  public private(set) var highlighting = true
  public private(set) var primary: Set<String>
  public private(set) var secondary: Set<String>
  /// Repeat the entire demonstration in a studio preview, including its authored cycle count.
  public var loopsPreview = false
  public var movementIssues: [MovementIssue] { clip.movementIssues }
  public var contactWarning: String? { clip.movementIssues.first?.message }
  public var phaseName: String { clip.annotation(at: phase)?.phase ?? "" }
  /// Authored pose names in movement order. A stationary hold has no distinct positions to inspect.
  public var inspectablePositions: [String] { positions.map(\.name) }
  public var demonstrationSeconds: Float { clip.duration }
  public var phase: Float {
    guard isPlaying else { return anchoredPhase }
    let advance = (CACurrentMediaTime() - anchorTime) * Double(rate) / Double(clip.duration)
    let elapsed = Double(anchoredPhase) + advance
    return loopsPreview ? Float(elapsed.truncatingRemainder(dividingBy: 1)) : Float(min(1, elapsed))
  }

  public func exercise(id: String) -> ExerciseDefinition? { clips[id]?.definition }

  let renderer: Renderer
  private let clips: [String: Clip]
  private var kit: [String: EMLProp]?
  private var legacyKit: [String: EMLProp]?
  private var usesFrameRoles = true
  @ObservationIgnored private var lastFrameRoles: MuscleRoles?
  private var clip: Clip
  private var positions = [InspectionPosition]()
  private var anchoredPhase: Float = 0
  private var anchorTime: CFTimeInterval = 0
  private let views = NSHashTable<ExerciseMetalView>.weakObjects()

  public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), exerciseID: String? = nil) throws
  {
    guard let device else {
      throw ExerciseDummyError.rendering("This device has no Metal renderer.")
    }
    let model = try Library.load("model.json", as: ModelData.self)
    let motion = try Library.load("motions.json", as: MotionData.self)
    try Library.validate(model, motion)
    let catalog = Dictionary(uniqueKeysWithValues: motion.exercises.map { ($0.id, $0) })
    guard
      let initial = exerciseID.flatMap({ catalog[$0] })
        ?? (exerciseID == nil ? motion.exercises.first : nil)
    else {
      throw ExerciseDummyError.invalidCommand("Unknown starting exercise.")
    }
    let loaded = try initial.loaded(model: model)
    let renderer = try Renderer(device: device, model: model)
    try renderer.prepare(loaded)
    let p = Set(loaded.primary)
    let s = Set(loaded.secondary)
    self.attribution = try String(contentsOf: Library.resource("ATTRIBUTION.md"), encoding: .utf8)
    self.renderer = renderer
    self.clips = catalog
    self.clip = loaded
    self.exercises = motion.exercises.map(\.definition)
    self.muscleGroups = model.groups.filter { !Library.structural.contains($0) }
    self.yaw = loaded.camera[0]
    self.pitch = loaded.camera[1]
    self.primary = p
    self.secondary = s
    self.loopsPreview = true
  }

  /// Load geometry and equipment directly from the same EML tree that compiled this clip.
  public init(emlRoot: URL, compiledClip: Data, device: MTLDevice? = MTLCreateSystemDefaultDevice())
    throws
  {
    guard let device else {
      throw ExerciseDummyError.rendering("This device has no Metal renderer.")
    }
    let anatomy = emlRoot.appendingPathComponent("anatomy", isDirectory: true)
    let model = try JSONDecoder().decode(
      ModelData.self, from: Data(contentsOf: anatomy.appendingPathComponent("model.json")))
    let kit = try JSONDecoder().decode(
      [String: EMLProp].self,
      from: Data(contentsOf: emlRoot.appendingPathComponent("library/equipment.json")))
    let previous = emlRoot.appendingPathComponent("compat/1.0/library/equipment.json")
    let legacyKit =
      FileManager.default.fileExists(atPath: previous.path)
      ? try JSONDecoder().decode([String: EMLProp].self, from: Data(contentsOf: previous)) : nil
    let wire = try JSONDecoder().decode(CompiledEML.self, from: compiledClip)
    let clip = try wire.makeClip(model: model, kit: wire.eml == "1.0" ? legacyKit ?? kit : kit)
    let renderer = try Renderer(device: device, model: model, anatomy: anatomy)
    try renderer.prepare(clip)
    self.attribution = try String(
      contentsOf: anatomy.appendingPathComponent("ATTRIBUTION.md"), encoding: .utf8)
    self.renderer = renderer
    self.clips = [:]
    self.kit = kit
    self.legacyKit = legacyKit
    self.clip = clip
    self.positions = clip.inspectionPositions()
    self.exercises = []
    self.muscleGroups = model.groups.filter { !Library.structural.contains($0) }
    self.yaw = clip.camera[0]
    self.pitch = clip.camera[1]
    self.primary = Set(clip.primary)
    self.secondary = Set(clip.secondary)
    try updateFrameRoles(at: 0)
  }

  /// Replace the displayed exercise only after validation and GPU preparation succeed.
  public func load(compiledClip: Data) throws {
    guard let kit else {
      throw ExerciseDummyError.invalidCommand("Initialize with an EML root first.")
    }
    let wire = try JSONDecoder().decode(CompiledEML.self, from: compiledClip)
    let next = try wire.makeClip(
      model: renderer.model, kit: wire.eml == "1.0" ? legacyKit ?? kit : kit)
    try replaceClip(next)
    for view in views.allObjects { view.refresh() }
  }

  private func replaceClip(_ next: Clip) throws {
    try renderer.prepare(next, highlighting: highlighting)
    clip = next
    positions = next.inspectionPositions()
    primary = Set(next.primary)
    secondary = Set(next.secondary)
    usesFrameRoles = true
    lastFrameRoles = nil
    yaw = next.camera[0]
    pitch = next.camera[1]
    zoom = 1
    setClock(0)
    try updateFrameRoles(at: 0)
  }

  private func setClock(_ f: Float) {
    anchoredPhase = f
    anchorTime = CACurrentMediaTime()
  }

  /// Change camera magnification relative to this exercise's fitted view.
  public func setZoom(_ factor: Float) {
    guard factor.isFinite else { return }
    let bounded = min(3, max(0.75, factor))
    guard zoom != bounded else { return }
    zoom = bounded
    for view in views.allObjects { view.refresh() }
  }

  /// Restore the authored view without seeking or changing playback.
  public func resetView() {
    yaw = clip.camera[0]
    pitch = clip.camera[1]
    zoom = 1
    for view in views.allObjects { view.refresh() }
  }

  /// Pause at the selected position. Identifiers come from the current EML recipe.
  public func inspectPosition(_ name: String) throws {
    guard let position = positions.first(where: { $0.name == name }) else {
      throw ExerciseDummyError.invalidCommand("No position named \(name) in this exercise.")
    }
    try pauseAt(position.progress)
  }

  public func inspectIssue(_ issue: MovementIssue) throws {
    guard let current = movementIssues.first(where: { $0.id == issue.id }) else {
      throw ExerciseDummyError.invalidCommand("This issue is no longer in the selected exercise.")
    }
    try pauseAt(min(1, max(0, current.seconds / clip.duration)))
  }

  private func pauseAt(_ progress: Float) throws {
    try updateFrameRoles(at: progress)
    setClock(progress)
    isPlaying = false
    for view in views.allObjects { view.refresh() }
  }

  private func updateFrameRoles(at phase: Float) throws {
    guard usesFrameRoles, let a = clip.annotation(at: phase) else { return }
    // Allocate a new immutable Metal palette only when the authored role actually changes.
    if lastFrameRoles == a.roles { return }
    let p = Set(a.roles.primary)
    let s = Set(a.roles.secondary)
    if primary == p, secondary == s {
      lastFrameRoles = a.roles
      return
    }
    try renderer.setRoles(primary: highlighting ? p : [], secondary: highlighting ? s : [])
    lastFrameRoles = a.roles
    primary = p
    secondary = s
  }

  /// Selecting an exercise resets its clock, prescribed camera and roles. It preserves playback and tempo.
  public func send(_ command: ExerciseCommand) throws {
    func applyRoles(
      _ p: Set<String>, _ s: Set<String>, _ show: Bool, restricted: Set<String>? = nil
    ) throws {
      try renderer.setRoles(
        primary: show ? p : [], secondary: show ? s : [], restricted: restricted)
      primary = p
      secondary = s
      highlighting = show
    }
    switch command {
    case .selectExercise(let id):
      guard let selected = clips[id] else {
        throw ExerciseDummyError.invalidCommand("Unknown exercise \(id).")
      }
      let loaded = try selected.loaded(model: renderer.model)
      try replaceClip(loaded)
    case .seek(let f):
      guard f.isFinite && (0...1).contains(f) else {
        throw ExerciseDummyError.invalidCommand("Phase must be between zero and one.")
      }
      setClock(f)
      try updateFrameRoles(at: f)
    case .play:
      if !isPlaying {
        setClock(anchoredPhase >= 1 ? 0 : anchoredPhase)
        isPlaying = true
      }
    case .pause:
      if isPlaying {
        setClock(phase)
        isPlaying = false
      }
    case .setTempo(let r):
      guard r.isFinite && (0.1...4).contains(r) else {
        throw ExerciseDummyError.invalidCommand("Tempo must be within 0.1...4.")
      }
      setClock(phase)
      rate = r
    case .orient(let y, let p):
      guard y.isFinite, p.isFinite, (-90...90).contains(p) else {
        throw ExerciseDummyError.invalidCommand(
          "Use a finite yaw and a pitch within -90...90 degrees.")
      }
      yaw = y.truncatingRemainder(dividingBy: 360)
      pitch = p
    case .setMuscles(let p, let s):
      let p = Set(p)
      let s = Set(s)
      guard p.isDisjoint(with: s), p.union(s).isSubset(of: Set(muscleGroups)) else {
        throw ExerciseDummyError.invalidCommand("Muscle IDs must exist and have one role each.")
      }
      try applyRoles(p, s, highlighting, restricted: [])
      usesFrameRoles = false
    case .setHighlighting(let flag):
      try applyRoles(primary, secondary, flag)
    case .setMirrored(let value):
      isMirrored = value
      renderer.mirrored = value
    case .useExerciseMuscles:
      try applyRoles(
        Set(clip.primary), Set(clip.secondary), highlighting,
        restricted: Set(clip.sideFocus?.groups ?? []))
      usesFrameRoles = true
      lastFrameRoles = nil
      try updateFrameRoles(at: phase)
    }
    for view in views.allObjects { view.refresh() }
  }

  func attach(_ view: ExerciseMetalView) { views.add(view) }
  func detach(_ view: ExerciseMetalView) { views.remove(view) }
  func draw(in view: MTKView) {
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
      return
    }
    let progress = phase
    if isPlaying && !loopsPreview && progress == 1 {
      setClock(1)
      isPlaying = false
      for view in views.allObjects { view.refresh() }
    }
    try? updateFrameRoles(at: progress)
    _ = try? renderer.encode(
      clip: clip, phase: progress, yaw: yaw, pitch: pitch, zoom: zoom,
      width: drawable.texture.width, height: drawable.texture.height,
      pass: pass, drawable: drawable)
  }

  /// Deterministic capture of the current pose through the same Metal pipelines as the live view.
  public func snapshot(width: Int, height: Int) throws -> CGImage {
    guard (1...8192).contains(width), (1...8192).contains(height) else {
      throw ExerciseDummyError.rendering("Unsupported snapshot dimensions.")
    }
    let progress = phase
    try updateFrameRoles(at: progress)
    let (pass, color) = try renderer.offscreenTarget(width: width, height: height)
    let cb = try renderer.encode(
      clip: clip, phase: progress, yaw: yaw, pitch: pitch, zoom: zoom,
      width: width, height: height, pass: pass)
    cb.waitUntilCompleted()
    if let error = cb.error { throw error }
    var data = Data(count: width * height * 4)
    data.withUnsafeMutableBytes {
      color.getBytes(
        $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0)
    }
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: [
          .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
        ],
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { throw ExerciseDummyError.rendering("Snapshot conversion failed.") }
    return image
  }
}
