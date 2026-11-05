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
  public private(set) var isMirrored = false
  public private(set) var highlighting = true
  public private(set) var primary: Set<String>
  public private(set) var secondary: Set<String>
  public var phase: Float {
    guard isPlaying else { return anchoredPhase }
    let advance = (CACurrentMediaTime() - anchorTime) * Double(rate) / Double(clip.seconds)
    return Float((Double(anchoredPhase) + advance).truncatingRemainder(dividingBy: 1))
  }

  public func exercise(id: String) -> ExerciseDefinition? { clips[id]?.definition }

  let renderer: Renderer
  private let clips: [String: Clip]
  private var clip: Clip
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
  }

  /// Selecting an exercise resets its clock, prescribed camera and roles. It preserves playback and tempo.
  public func send(_ command: ExerciseCommand) throws {
    func setClock(_ f: Float) {
      anchoredPhase = f
      anchorTime = CACurrentMediaTime()
    }
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
      try renderer.prepare(loaded, highlighting: highlighting)
      primary = Set(loaded.primary)
      secondary = Set(loaded.secondary)
      clip = loaded
      yaw = loaded.camera[0]
      pitch = loaded.camera[1]
      setClock(0)
    case .seek(let f):
      guard f.isFinite && (0...1).contains(f) else {
        throw ExerciseDummyError.invalidCommand("Phase must be between zero and one.")
      }
      setClock(f)
    case .play:
      if !isPlaying {
        setClock(anchoredPhase)
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
    case .setHighlighting(let flag):
      try applyRoles(primary, secondary, flag)
    case .setMirrored(let value):
      isMirrored = value
      renderer.mirrored = value
    case .useExerciseMuscles:
      try applyRoles(
        Set(clip.primary), Set(clip.secondary), highlighting,
        restricted: Set(clip.sideFocus?.groups ?? []))
    }
    for view in views.allObjects { view.refresh() }
  }

  func attach(_ view: ExerciseMetalView) { views.add(view) }
  func detach(_ view: ExerciseMetalView) { views.remove(view) }
  func draw(in view: MTKView) {
    guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
      return
    }
    _ = try? renderer.encode(
      clip: clip, phase: phase, yaw: yaw, pitch: pitch,
      width: drawable.texture.width, height: drawable.texture.height,
      pass: pass, drawable: drawable)
  }

  /// Deterministic capture of the current pose through the same Metal pipelines as the live view.
  public func snapshot(width: Int, height: Int) throws -> CGImage {
    guard (1...8192).contains(width), (1...8192).contains(height) else {
      throw ExerciseDummyError.rendering("Unsupported snapshot dimensions.")
    }
    let (pass, color) = try renderer.offscreenTarget(width: width, height: height)
    let cb = try renderer.encode(
      clip: clip, phase: phase, yaw: yaw, pitch: pitch,
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
