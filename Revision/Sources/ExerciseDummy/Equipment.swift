import Metal
import simd

struct AABB {
  private(set) var low = SIMD3<Float>(repeating: .infinity)
  private(set) var high = SIMD3<Float>(repeating: -.infinity)
  var valid: Bool { low.x <= high.x }

  mutating func include(_ p: SIMD3<Float>) {
    low = simd_min(low, p)
    high = simd_max(high, p)
  }

  var corners: [SIMD3<Float>] {
    guard valid else { return [] }
    return (0..<8).map { i in
      SIMD3(i & 1 == 0 ? low.x : high.x, i & 2 == 0 ? low.y : high.y, i & 4 == 0 ? low.z : high.z)
    }
  }
}

struct GPUMesh {
  let vertices, indices: MTLBuffer
  let count: Int
}

struct BodyMesh {
  let gpu: GPUMesh
  let jointBounds: [AABB]
  let headRadius: Float

  init(device: MTLDevice, model: ModelData, anatomy: URL?) throws {
    let v = try Data(
      contentsOf: anatomy?.appendingPathComponent("vertices.bin")
        ?? Library.resource("vertices.bin"), options: .mappedIfSafe)
    let ix = try Data(
      contentsOf: anatomy?.appendingPathComponent("indices.bin") ?? Library.resource("indices.bin"),
      options: .mappedIfSafe)
    guard model.vertexCount > 0, model.indexCount > 0, model.indexCount % 3 == 0,
      model.vertexCount == v.count / 40, v.count % 40 == 0,
      model.indexCount == ix.count / 4, ix.count % 4 == 0
    else {
      throw ExerciseDummyError.invalidAsset("Mesh and manifest counts differ.")
    }
    let head = model.joints.firstIndex { $0.name == "head" }
    var headRadiusSquared: Float = 0
    var bounds = Array(repeating: AABB(), count: model.joints.count)
    let vertices: MTLBuffer = try v.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for n in 0..<model.vertexCount {
        let b = 40 * n
        let p = raw.loadUnaligned(fromByteOffset: b, as: SIMD3Packed.self).vector
        let normal = raw.loadUnaligned(fromByteOffset: b + 12, as: SIMD3Packed.self).vector
        guard p.isFiniteVector, normal.isFiniteVector,
          raw.loadUnaligned(fromByteOffset: b + 32, as: UInt32.self) < model.groups.count,
          raw[b + 28..<b + 32].reduce(0, { $0 + Int($1) }) == 255
        else {
          throw ExerciseDummyError.invalidAsset("Invalid vertex \(n).")
        }
        for slot in 0..<4 {
          let joint = Int(raw[b + 24 + slot])
          guard joint < bounds.count else {
            throw ExerciseDummyError.invalidAsset("Unknown vertex joint.")
          }
          if raw[b + 28 + slot] > 0 {
            bounds[joint].include(p)
            if joint == head {
              headRadiusSquared = max(
                headRadiusSquared, simd_distance_squared(p, model.joints[joint].position))
            }
          }
        }
      }
      guard let buffer = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) else {
        throw ExerciseDummyError.rendering("Body vertex allocation failed.")
      }
      return buffer
    }
    let indices: MTLBuffer = try ix.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard raw.bindMemory(to: UInt32.self).allSatisfy({ $0 < model.vertexCount }),
        let buffer = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count)
      else {
        throw ExerciseDummyError.invalidAsset("Invalid body index buffer.")
      }
      return buffer
    }
    self.gpu = GPUMesh(vertices: vertices, indices: indices, count: model.indexCount)
    self.jointBounds = bounds
    self.headRadius = sqrt(headRadiusSquared)
  }
}

private struct SIMD3Packed {
  let x, y, z: Float
  init(_ v: SIMD3<Float>) { (x, y, z) = (v.x, v.y, v.z) }
  var vector: SIMD3<Float> { .init(x, y, z) }
}
private struct PropVertex {
  var p, n: SIMD3Packed
  var joints: UInt32 = 0, weights: UInt32 = 255, color: UInt32, reserved: UInt32 = 0
}

struct PropMesh {
  let gpu: GPUMesh
  let bounds: AABB

  init(device: MTLDevice, equipment e: Equipment) throws {
    var vertices = [PropVertex]()
    var indices = [UInt32]()
    var box = AABB()
    @discardableResult func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ c: UInt32) -> UInt32 {
      box.include(p)
      vertices.append(.init(p: .init(p), n: .init(n), color: c))
      return UInt32(vertices.count - 1)
    }
    // Revolved profile along a segment. End caps have independent normals.
    func cylinder(
      _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ radius: Float, _ c: UInt32, _ steps: Int = 24
    ) {
      let axis = simd_normalize(b - a)
      let u = simd_normalize(simd_cross(axis, abs(axis.y) < 0.8 ? [0, 1, 0] : [1, 0, 0]))
      let v = simd_cross(axis, u)
      let first = UInt32(vertices.count)
      for i in 0...steps {
        let angle = 2 * Float.pi * Float(i) / Float(steps)
        let n = u * cos(angle) + v * sin(angle)
        vertex(a + n * radius, n, c)
        vertex(b + n * radius, n, c)
        vertex(a + n * radius, -axis, c)
        vertex(b + n * radius, axis, c)
      }
      let ca = vertex(a, -axis, c)
      let cb = vertex(b, axis, c)
      for i in 0..<steps {
        let j = first + UInt32(i * 4)
        indices += [j, j + 4, j + 1, j + 1, j + 4, j + 5, ca, j + 6, j + 2, cb, j + 3, j + 7]
      }
    }
    func cuboid(_ center: SIMD3<Float>, _ size: SIMD3<Float>, _ color: UInt32) {
      let h = size * 0.5
      for d in 0..<3 {
        for s: Float in [-1, 1] {
          var n = SIMD3<Float>.zero
          n[d] = s
          let first = UInt32(vertices.count)
          for (a, b): (Float, Float) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] {
            var p = h * n
            p[(d + 1) % 3] = a * h[(d + 1) % 3]
            p[(d + 2) % 3] = b * h[(d + 2) % 3]
            vertex(center + p, n, color)
          }
          indices += [first, first + 1, first + 2, first, first + 2, first + 3]
        }
      }
    }
    switch e.kind {
    case .barbell, .dumbbell:
      let h = e.length / 2
      let r = e.radius
      let db = e.kind == .dumbbell
      cylinder([-h, 0, 0], [h, 0, 0], db ? 0.014 : 0.0145, 1)
      for s: Float in [-1, 1] {
        let t = db ? h * 0.48 : min(0.12, h * 0.18)
        let tip = h - (db ? 0.004 : 0.055)
        cylinder([s * (tip - t - 0.012), 0, 0], [s * (tip - t), 0, 0], r * 0.52, 1)
        cylinder([s * (tip - t), 0, 0], [s * tip, 0, 0], r, 0, db ? 8 : 40)
        if !db {
          cylinder([s * (tip - t * 0.58), 0, 0], [s * (tip - t * 0.55), 0, 0], r * 1.003, 2)
          cylinder([s * tip, 0, 0], [s * h, 0, 0], 0.024, 1)
        }
        cylinder([s * tip, 0, 0], [s * (tip + 0.003), 0, 0], r * 0.43, 2)
      }
    case .rod:
      cylinder([-e.length / 2, 0, 0], [e.length / 2, 0, 0], e.radius, 0)
    case .box:
      cuboid(.zero, e.size ?? [2 * e.radius, e.height ?? 2 * e.radius, e.length], 0)
    case .kettlebell, .ball:
      let r = e.radius
      let w = e.length / 2
      let center = e.kind == .ball ? .zero : SIMD3<Float>(0, -(1.55 * r + 0.02), 0)
      let rows = 20
      let cols = 32
      for j in 0...rows {
        let lat = Float.pi * Float(j) / Float(rows)
        for i in 0...cols {
          let a = 2 * Float.pi * Float(i) / Float(cols)
          let n = SIMD3<Float>(sin(lat) * cos(a), cos(lat), sin(lat) * sin(a))
          let radii =
            e.kind == .ball ? (e.size.map { $0 / 2 } ?? SIMD3(repeating: r)) : SIMD3(repeating: r)
          vertex(center + n * radii, simd_normalize(n / radii), 0)
        }
      }
      for j in 0..<rows {
        for i in 0..<cols {
          let p = UInt32(j * (cols + 1) + i)
          let q = p + UInt32(cols + 1)
          indices += [p, q, p + 1, p + 1, q, q + 1]
        }
      }
      guard e.kind == .kettlebell else { break }
      cylinder([-w * 0.74, 0, 0], [w * 0.74, 0, 0], 0.0165, 1)
      for s: Float in [-1, 1] {
        cylinder([s * w * 0.74, 0, 0], [s * w, -0.04, 0], 0.017, 1)
        cylinder([s * w, -0.04, 0], [s * r * 0.55, center.y + r * 0.65, 0], 0.017, 1)
      }
    case .bench:
      cuboid([0, 0.4075, 0], [2 * e.radius, 0.065, e.length], 0)
      cuboid([0, 0.345, 0], [0.06, 0.06, e.length * 0.82], 2)
      for s: Float in [-1, 1] {
        let z = s * e.length * 0.34
        cuboid([0, 0.17, z], [0.055, 0.31, 0.055], 2)
        cuboid([0, 0.018, z], [2 * e.radius + 0.14, 0.036, 0.065], 2)
      }
    }
    precondition(MemoryLayout<PropVertex>.stride == 40)
    guard let v = device.makeBuffer(bytes: vertices, length: vertices.count * 40),
      let i = device.makeBuffer(bytes: indices, length: indices.count * 4)
    else { throw ExerciseDummyError.rendering("Equipment allocation failed.") }
    self.gpu = GPUMesh(vertices: v, indices: i, count: indices.count)
    self.bounds = box
  }
}
