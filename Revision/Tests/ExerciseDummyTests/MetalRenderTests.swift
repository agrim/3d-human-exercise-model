import Metal
import QuartzCore
import XCTest

@testable import ExerciseDummy

/// Uses actual GPU timestamps on an offscreen drawable, excluding PNG readback and screen presentation.
final class MetalRenderTests: XCTestCase {
  @MainActor func testBatchRenderTimings() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal GPU unavailable.")
    }
    let model = try Library.load("model.json", as: ModelData.self)
    let catalog = try Library.load("motions.json", as: MotionData.self)
    let start = CACurrentMediaTime()
    let r = try Renderer(device: device, model: model)
    let setupMilliseconds = (CACurrentMediaTime() - start) * 1000
    let size = (width: 960, height: 1200)
    let (pass, _) = try r.offscreenTarget(width: size.width, height: size.height)
    print(
      "Metal QA on \(device.name), \(model.indexCount/3) body triangles, \(size.width)×\(size.height), renderer setup \(String(format: "%.2f",setupMilliseconds)) ms"
    )
    let ids = ["squat", "push-up", "bench-press", "leg-press", "kettlebell-swing"]
    let clips = catalog.exercises.filter { ids.contains($0.id) }
    XCTAssertFalse(clips.isEmpty)
    for item in clips {
      let select = CACurrentMediaTime()
      let clip = try item.loaded(model: model)
      try r.prepare(clip)
      let prep = (CACurrentMediaTime() - select) * 1000
      var milliseconds: [Double] = []
      for i in 0..<21 {
        let cb = try r.encode(
          clip: clip, phase: Float(i) / 20, yaw: clip.camera[0], pitch: clip.camera[1],
          width: size.width, height: size.height, pass: pass)
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        if i > 0 && cb.gpuEndTime > cb.gpuStartTime {
          milliseconds.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
      }
      if !milliseconds.isEmpty {
        milliseconds.sort()
        let p50 = milliseconds[milliseconds.count / 2]
        let p95 = milliseconds[Int(Double(milliseconds.count - 1) * 0.95)]
        print(
          String(
            format: "Metal QA %@, %d props, prepare %.2f ms, GPU p50 %.2f ms, p95 %.2f ms", clip.id,
            clip.equipment.count, prep, p50, p95))
      }
    }
  }
}
