import Foundation
import simd

extension Clip {
  func loaded(model: ModelData) throws -> Clip {
    guard let track = track else { return self }
    let data = try Data(contentsOf: Library.resource(track), options: .mappedIfSafe)
    return try decoded(data, model: model)
  }

  func decoded(_ data: Data, model: ModelData) throws -> Clip {
    func invalid() -> ExerciseDummyError { .invalidAsset("Malformed track for \(id).") }
    var result = self
    result.frames = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Keyframe] in
      guard raw.count >= 12 && raw.prefix(4).elementsEqual("EXM1".utf8) else { throw invalid() }
      var cursor = 4
      func read<T>(_ type: T.Type) -> T {
        defer { cursor += MemoryLayout<T>.size }
        return raw.loadUnaligned(fromByteOffset: cursor, as: T.self)
      }
      let count = Int(read(UInt32.self))
      let joints = Int(read(UInt16.self))
      let props = Int(read(UInt16.self))
      let stride = 16 + joints * 8 + props * 32
      guard count >= 2, count <= (raw.count - 12) / stride, raw.count - 12 == count * stride,
        joints == model.joints.count, props == equipment.count
      else { throw invalid() }
      func vec3() -> SIMD3<Float> { .init(read(Float.self), read(Float.self), read(Float.self)) }
      func quat() -> SIMD4<Float> {
        let q =
          SIMD4<Float>(
            Float(read(Int16.self)), Float(read(Int16.self)), Float(read(Int16.self)),
            Float(read(Int16.self))) / 32767
        return q
      }
      return (0..<count).map { _ in
        let phase = read(Float.self)
        let root = vec3()
        let r = (0..<joints).map { _ in quat() }
        let p = (0..<props).map { _ in PropPose(position: vec3(), rotation: quat(), scale: vec3()) }
        return .init(phase: phase, root: root, rotations: r, props: p)
      }
    }
    try Library.validateFrames(result, model: model)
    return result
  }
}
