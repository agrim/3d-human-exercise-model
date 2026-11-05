import MetalKit
import simd

struct SceneUniforms {
  var vp, lightVP: simd_float4x4
  var right, up, back, center, key: SIMD4<Float>
  var footA, footB, handA, handB: SIMD4<Float>
  var sideWeights = SIMD4<Float>(1, 1, 0, 0)
  var passiveMuscle = SIMD4<Float>(0.27, 0.34, 0.39, 0.70)
  var wristPivots = (SIMD4<Float>.zero, SIMD4<Float>.zero)
  var wristTurns = (SIMD4<Float>(0, 0, 0, 1), SIMD4<Float>(0, 0, 0, 1))
}

@MainActor
final class Renderer {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let model: ModelData
  let body: BodyMesh
  private let wristIndices: [Int]
  let bodyPipeline, stagePipeline, shadowPipeline: MTLRenderPipelineState
  let sampleCount: Int
  private let shadowMap: MTLTexture
  let depthState, groundDepthState: MTLDepthStencilState
  let boneSlots: [MTLBuffer]
  var equipmentCache = [Equipment: PropMesh]()
  private var palette: MTLBuffer?
  private var sideRestricted = Set<String>()
  private var meshes = [PropMesh]()
  private var equipmentPalettes = [MTLBuffer]()
  private var points = [SIMD3<Float>]()
  private var fixtures = [SIMD3<Float>]()
  private var headPath = [SIMD3<Float>]()
  private var worldBounds = AABB()
  private var contact: [Int?] = []
  var mirrored = false
  private var cameraKey: SIMD4<Float>?
  private var cameraScene: SceneUniforms?
  private let flights = DispatchSemaphore(value: 3)
  private var nextSlot = 0
  private var captureTarget: (MTLRenderPassDescriptor, MTLTexture)?

  init(device: MTLDevice, model: ModelData, anatomy: URL? = nil) throws {
    self.device = device
    self.model = model
    wristIndices = try (model.wristPivots ?? []).map { name in
      guard let i = model.joints.firstIndex(where: { $0.name == name }), model.joints[i].parent >= 0
      else {
        throw ExerciseDummyError.invalidAsset("Unknown wrist pivot " + name)
      }
      return i
    }
    guard wristIndices.isEmpty || wristIndices.count == 2 else {
      throw ExerciseDummyError.invalidAsset("Expected two wrist pivots")
    }
    guard let queue = device.makeCommandQueue() else {
      throw ExerciseDummyError.rendering("Metal command queue unavailable.")
    }
    self.queue = queue
    self.body = try BodyMesh(device: device, model: model, anatomy: anatomy)
    guard let shader = Bundle.module.url(forResource: "ExerciseDummy", withExtension: "metal")
    else { throw ExerciseDummyError.invalidAsset("Missing Metal shader.") }
    let library = try device.makeLibrary(
      source: String(contentsOf: shader, encoding: .utf8), options: nil)
    let samples = device.supportsTextureSampleCount(4) ? 4 : 1
    self.sampleCount = samples
    let sd = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .depth32Float, width: 1024, height: 1024, mipmapped: false)
    sd.usage = [.renderTarget, .shaderRead]
    sd.storageMode = .private
    guard let shadow = device.makeTexture(descriptor: sd) else {
      throw ExerciseDummyError.rendering("Shadow texture unavailable.")
    }
    self.shadowMap = shadow
    func pipeline(_ vertex: String, _ fragment: String?) throws -> MTLRenderPipelineState {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = library.makeFunction(name: vertex)
      if let fragment {
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        d.rasterSampleCount = samples
      }
      d.depthAttachmentPixelFormat = .depth32Float
      return try device.makeRenderPipelineState(descriptor: d)
    }
    bodyPipeline = try pipeline("bodyVertex", "bodyFragment")
    stagePipeline = try pipeline("stageVertex", "stageFragment")
    shadowPipeline = try pipeline("shadowVertex", nil)
    let d = MTLDepthStencilDescriptor()
    d.depthCompareFunction = .less
    d.isDepthWriteEnabled = true
    guard let depth = device.makeDepthStencilState(descriptor: d) else {
      throw ExerciseDummyError.rendering("Metal depth state unavailable.")
    }
    depthState = depth
    d.depthCompareFunction = .always
    guard let groundDepth = device.makeDepthStencilState(descriptor: d) else {
      throw ExerciseDummyError.rendering("Floor depth state unavailable.")
    }
    groundDepthState = groundDepth
    self.boneSlots = try (0..<3).map { _ in
      guard let b = device.makeBuffer(length: 64 * model.joints.count, options: .storageModeShared)
      else { throw ExerciseDummyError.rendering("Joint buffer allocation failed.") }
      return b
    }
    let names = model.joints.map { $0.name.lowercased() }
    for (part, side) in [("ankle", "l"), ("ankle", "r"), ("wrist", "l"), ("wrist", "r")] {
      let aliases = part == "ankle" ? ["ankle", "foot"] : ["wrist", "hand"]
      contact.append(
        names.firstIndex { name in
          aliases.contains(where: name.contains)
            && (name.hasSuffix(side) || name.hasPrefix(side)
              || name.contains(side == "l" ? "left" : "right"))
        })
    }
  }

  func prepare(_ c: Clip, highlighting: Bool = true) throws {
    let surfacePalette = try makePalette(
      primary: highlighting ? Set(c.primary) : [],
      secondary: highlighting ? Set(c.secondary) : [],
      restricted: Set(c.sideFocus?.groups ?? []))
    var newMeshes = [PropMesh]()
    var newColors = [MTLBuffer]()
    for e in c.equipment {
      if equipmentCache[e] == nil { equipmentCache[e] = try PropMesh(device: device, equipment: e) }
      newMeshes.append(equipmentCache[e]!)
      let base: SIMD4<Float>
      switch e.material {
      case "steel": base = [0.27, 0.32, 0.37, 1]
      case "band": base = [0.04, 0.31, 0.31, 0.7]
      case "rope": base = [0.26, 0.18, 0.11, 0.45]
      case "pad": base = [0.045, 0.065, 0.085, 0.45]
      default: base = [0.068, 0.086, 0.105, 0.6]
      }
      let colors: [SIMD4<Float>] = [base, [0.32, 0.38, 0.44, 1], [0.12, 0.165, 0.20, 0.7]]
      guard let buffer = device.makeBuffer(bytes: colors, length: colors.count * 16) else {
        throw ExerciseDummyError.rendering("Equipment palette allocation failed.")
      }
      newColors.append(buffer)
    }
    // Fit to the entire rep once, keeping the instructional camera fixed as the body moves.
    let corners = body.jointBounds.map(\.corners)
    let propCorners = newMeshes.map { $0.bounds.corners }
    var support = [SIMD3<Float>]()
    var station = [SIMD3<Float>]()
    headPath = []
    if let paths = c.emlFramingPaths {
      support = paths.flatMap(\.corners)
      if let head = model.joints.firstIndex(where: { $0.name == "head" }) {
        headPath = paths[head].corners
      }
      station = c.emlSceneBounds?.corners ?? []
    }
    for frame in (c.emlFramingPaths == nil ? c.frames : []) {
      let pose = c.pose(at: frame.phase, joints: model.joints)
      for (j, box) in corners.enumerated() {
        let transform = pose.skin[j]
        for p in box {
          let w = transform * SIMD4(p, 1)
          support.append([w.x, w.y, w.z])
        }
      }
      for (i, box) in propCorners.enumerated() {
        let transform = pose.props[i]
        let kind = c.equipment[i].kind
        let apparatus = kind == .box || kind == .rod || kind == .bench
        for p in box {
          let w = transform * SIMD4(p, 1)
          if apparatus {
            station.append([w.x, w.y, w.z])
          } else {
            support.append([w.x, w.y, w.z])
          }
        }
      }
    }
    sideRestricted = Set(c.sideFocus?.groups ?? [])
    palette = surfacePalette
    meshes = newMeshes
    equipmentPalettes = newColors
    points = support
    fixtures = station
    worldBounds = AABB()
    for p in support { worldBounds.include(p) }
    for p in station { worldBounds.include(p) }
    cameraKey = nil
  }

  func setRoles(primary: Set<String>, secondary: Set<String>, restricted: Set<String>? = nil) throws
  {
    palette = try makePalette(
      primary: primary, secondary: secondary,
      restricted: restricted ?? sideRestricted)
    if let restricted { sideRestricted = restricted }
  }

  private func makePalette(
    primary: Set<String>, secondary: Set<String>,
    restricted: Set<String>
  ) throws -> MTLBuffer {
    let values: [SIMD4<Float>] = model.groups.map { g in
      if primary.contains(g) {
        return [0.93, 0.123, 0.064, restricted.contains(g) ? -2.62 : -0.62]
      }
      if secondary.contains(g) {
        return [0.96, 0.53, 0.095, restricted.contains(g) ? -2.63 : -0.63]
      }
      switch g {
      case "bone": return [0.57, 0.58, 0.54, 0.64]
      case "tendon": return [0.46, 0.49, 0.49, 0.64]
      case "shell": return [0.42, 0.45, 0.46, 0.75]
      default: return [0.27, 0.34, 0.39, 0.7]
      }
    }
    guard let p = device.makeBuffer(bytes: values, length: values.count * 16) else {
      throw ExerciseDummyError.rendering("Body palette allocation failed.")
    }
    return p
  }

  private func scene(clip: Clip, pose: Pose, yaw: Float, pitch: Float, zoom: Float, aspect: Float)
    -> SceneUniforms
  {
    let key = SIMD4<Float>(yaw, pitch, aspect, mirrored ? -zoom : zoom)
    var s: SceneUniforms
    if key == cameraKey, let cached = cameraScene {
      s = cached
    } else {
      let alpha = yaw * .pi / 180
      let beta = pitch * .pi / 180
      let right = SIMD3<Float>(cos(alpha), 0, -sin(alpha))
      let back = SIMD3<Float>(sin(alpha) * cos(beta), sin(beta), cos(alpha) * cos(beta))
      let up = simd_cross(back, right)
      let flip: SIMD3<Float> = [mirrored ? -1 : 1, 1, 1]
      var box = AABB()
      func projected(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let p = point * flip
        return [simd_dot(right, p), simd_dot(up, p), simd_dot(back, p)]
      }
      for point in points { box.include(projected(point)) }
      // The head pivot sits below the crown. Credit the existing fit margins before adding
      // the measured mesh radius, so a standing head clears the frame without shrinking other poses.
      let crown = SIMD3(
        max(0, body.headRadius + 0.025 - 0.11), max(0, body.headRadius + 0.025 - 0.15), 0)
      for point in headPath {
        let p = projected(point)
        box.include(p - crown)
        box.include(p + crown)
      }
      // EML already supplied the full moving subject. Legacy clips also frame nearby fixtures.
      if clip.emlFramingPaths == nil {
        let margin = SIMD3<Float>(0.22, 0.20, Float.greatestFiniteMagnitude)
        let low = box.low - margin
        let high = box.high + margin
        for point in fixtures {
          box.include(simd_clamp(projected(point), low, high))
        }
      }
      let middle = (box.low + box.high) * 0.5
      let origin =
        clip.cameraTarget.map { $0 * flip } ?? (right * middle.x + up * middle.y + back * middle.z)
      let ox = simd_dot(origin, right)
      let oy = simd_dot(origin, up)
      let halfWidth = max(ox - box.low.x, box.high.x - ox)
      let halfHeight = max(oy - box.low.y, box.high.y - oy)
      let fit =
        clip.emlFramingPaths != nil
        ? max(0.45, (halfWidth + 0.11) / aspect, halfHeight + 0.15)
        : max(
          max(halfWidth / aspect, halfHeight) * 1.08, max(0.12, (clip.cameraDistance ?? 0) * 0.20))
      let h = fit / zoom
      let w = h * aspect
      // Metal's clip-space depth increases away from the camera and is in [0,1].
      let depth = max(4, 2 * (box.high.z - box.low.z) + 2)
      let z0 = simd_dot(back, origin)
      let vp = simd_float4x4(rows: [
        SIMD4(right / w, -ox / w), SIMD4(up / h, -oy / h), SIMD4(-back / depth, 0.5 + z0 / depth),
        [0, 0, 0, 1],
      ])
      let light = simd_normalize(-right * 0.64 + SIMD3<Float>(0, 1.30, 0) + back * 0.75)
      let lx = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), light))
      let ly = simd_cross(light, lx)
      var lightBounds = AABB()
      for corner in worldBounds.corners {
        let p = corner * flip
        // Project the caster to the actual ground plane as well as including it in light space.
        for q in [p, p - light * (p.y / light.y)] {
          lightBounds.include([simd_dot(q, lx), simd_dot(q, ly), simd_dot(q, light)])
        }
      }
      let mid = (lightBounds.low + lightBounds.high) * 0.5
      let spans =
        simd_max((lightBounds.high - lightBounds.low) * 0.5, SIMD3(repeating: 0.10)) + 0.06
      let lightVP = simd_float4x4(rows: [
        SIMD4(lx / spans.x, -mid.x / spans.x), SIMD4(ly / spans.y, -mid.y / spans.y),
        SIMD4(-light / (2 * spans.z), 0.5 + mid.z / (2 * spans.z)), [0, 0, 0, 1],
      ])
      s = .init(
        vp: vp, lightVP: lightVP, right: SIMD4(right, w), up: SIMD4(up, h), back: SIMD4(back, 0),
        center: SIMD4(origin, 1), key: SIMD4(light, 0),
        footA: .zero, footB: .zero, handA: .zero, handB: .zero)
      cameraKey = key
      cameraScene = s
    }
    func shadow(_ n: Int, _ r: Float) -> SIMD4<Float> {
      guard let j = contact[n] else { return [0, 100, 0, r] }
      var p = pose.positions[j]
      p.y = max(0, p.y - r * 0.4)
      return SIMD4(p, r)
    }
    s.footA = shadow(0, 0.145)
    s.footB = shadow(1, 0.145)
    s.handA = shadow(2, 0.085)
    s.handB = shadow(3, 0.085)
    return s
  }

  func offscreenTarget(width: Int, height: Int) throws -> (MTLRenderPassDescriptor, MTLTexture) {
    if let previous = captureTarget, previous.1.width == width, previous.1.height == height {
      return previous
    }
    func texture(_ format: MTLPixelFormat, samples: Int, storage: MTLStorageMode) throws
      -> MTLTexture
    {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: false)
      descriptor.usage = .renderTarget
      descriptor.storageMode = storage
      if samples > 1 {
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = samples
      }
      guard let t = device.makeTexture(descriptor: descriptor) else {
        throw ExerciseDummyError.rendering("Capture texture unavailable.")
      }
      return t
    }
    let attachmentStorage: MTLStorageMode = device.supportsFamily(.apple4) ? .memoryless : .private
    let color = try texture(.bgra8Unorm_srgb, samples: 1, storage: .shared)
    let pass = MTLRenderPassDescriptor()
    if sampleCount > 1 {
      pass.colorAttachments[0].texture = try texture(
        .bgra8Unorm_srgb, samples: sampleCount, storage: attachmentStorage)
      pass.colorAttachments[0].resolveTexture = color
      pass.colorAttachments[0].storeAction = .multisampleResolve
    } else {
      pass.colorAttachments[0].texture = color
      pass.colorAttachments[0].storeAction = .store
    }
    pass.colorAttachments[0].loadAction = .clear
    pass.depthAttachment.texture = try texture(
      .depth32Float, samples: sampleCount, storage: attachmentStorage)
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.clearDepth = 1
    pass.depthAttachment.storeAction = .dontCare
    captureTarget = (pass, color)
    return (pass, color)
  }

  func encode(
    clip: Clip, phase: Float, yaw: Float, pitch: Float, zoom: Float = 1, width: Int, height: Int,
    pass: MTLRenderPassDescriptor, drawable: CAMetalDrawable? = nil
  ) throws -> MTLCommandBuffer {
    guard width > 0, height > 0, let cb = queue.makeCommandBuffer(),
      let palette
    else { throw ExerciseDummyError.rendering("Metal frame unavailable.") }
    let sampled = clip.pose(at: phase, joints: model.joints)
    let pose = mirrored ? sampled.reflectingX() : sampled
    var s = scene(
      clip: clip, pose: pose, yaw: yaw, pitch: pitch, zoom: zoom,
      aspect: Float(width) / Float(height))
    if wristIndices.count == 2 {
      // Relative turns are invariant to reflection. Use the rigid, unmirrored transforms.
      func wrist(_ i: Int) -> (SIMD4<Float>, SIMD4<Float>) {
        let joint = model.joints[i]
        let turn = (simd_quatf(sampled.skin[joint.parent]).inverse * simd_quatf(sampled.skin[i]))
          .normalized.vector
        return (SIMD4(joint.position, Float(joint.parent)), turn.w < 0 ? -turn : turn)
      }
      (s.wristPivots.0, s.wristTurns.0) = wrist(wristIndices[0])
      (s.wristPivots.1, s.wristTurns.1) = wrist(wristIndices[1])
    }
    let weights =
      clip.annotation(at: phase)?.sideWeights ?? clip.sideFocus?.weights(at: phase) ?? .one
    s.sideWeights = SIMD4(weights.x, weights.y, 0, 0)
    flights.wait()
    let bones = boneSlots[nextSlot]
    nextSlot = (nextSlot + 1) % boneSlots.count
    pose.skin.withUnsafeBytes { raw in
      bones.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
    }
    let semaphore = flights
    cb.addCompletedHandler { _ in semaphore.signal() }
    func drawScene(_ enc: MTLRenderCommandEncoder, lit: Bool) {
      enc.setVertexBytes(&s, length: MemoryLayout<SceneUniforms>.stride, index: 1)
      enc.setVertexBuffer(bones, offset: 0, index: 2)
      func draw(_ mesh: GPUMesh, _ colors: MTLBuffer) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        if lit { enc.setVertexBuffer(colors, offset: 0, index: 3) }
        enc.drawIndexedPrimitives(
          type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices,
          indexBufferOffset: 0)
      }
      draw(body.gpu, palette)
      for i in meshes.indices {
        var transform = pose.props[i]
        enc.setVertexBytes(&transform, length: 64, index: 2)
        draw(meshes[i].gpu, equipmentPalettes[i])
      }
    }
    let shadowPass = MTLRenderPassDescriptor()
    shadowPass.depthAttachment.texture = shadowMap
    shadowPass.depthAttachment.loadAction = .clear
    shadowPass.depthAttachment.storeAction = .store
    shadowPass.depthAttachment.clearDepth = 1
    guard let shadow = cb.makeRenderCommandEncoder(descriptor: shadowPass) else {
      semaphore.signal()
      throw ExerciseDummyError.rendering("Shadow pass unavailable.")
    }
    shadow.setRenderPipelineState(shadowPipeline)
    shadow.setDepthStencilState(depthState)
    shadow.setDepthBias(0.00015, slopeScale: 0.25, clamp: 0.001)
    drawScene(shadow, lit: false)
    shadow.endEncoding()
    guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
      semaphore.signal()
      throw ExerciseDummyError.rendering("Color pass unavailable.")
    }
    enc.setRenderPipelineState(stagePipeline)
    enc.setDepthStencilState(groundDepthState)
    enc.setFragmentTexture(shadowMap, index: 0)
    enc.setFragmentBytes(&s, length: MemoryLayout<SceneUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.setRenderPipelineState(bodyPipeline)
    enc.setDepthStencilState(depthState)
    drawScene(enc, lit: true)
    enc.endEncoding()
    if let drawable { cb.present(drawable) }
    cb.commit()
    return cb
  }
}
