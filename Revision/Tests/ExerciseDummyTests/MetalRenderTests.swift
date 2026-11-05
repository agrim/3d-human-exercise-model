import Metal
import QuartzCore
import XCTest
import simd

@testable import ExerciseDummy

/// Uses actual GPU timestamps on an offscreen drawable, excluding PNG readback and screen presentation.
final class MetalRenderTests: XCTestCase {
  /// A 50:50 blend at a 150° wrist turn previously collapsed to cos(75°) of
  /// the bind radius. Run the same skin function used by the surface and shadow passes.
  @MainActor func testWristTwistPreservesRadiusOnGPU() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/ExerciseDummy/Shaders/ExerciseDummy.metal")
    let shader =
      try String(contentsOf: source, encoding: .utf8) + """

        kernel void inspectWrist(const device float4x4 *bones [[buffer(0)]], constant Scene &scene [[buffer(1)]],
                                 device float4 *out [[buffer(2)]], uint i [[thread_position_in_grid]]) {
          Vertex v = {};
          v.joints = uchar4(0,1,0,0); v.weights = uchar4(127,128,0,0);
          v.reserved = i==0 ? 0u : (1u<<8) | (127u<<16) | (128u<<24);
          out[i] = skinMatrix(v,bones,scene)*float4(1,0,0,1);
        }
        """
    let lib = try device.makeLibrary(source: shader, options: nil)
    let pipe = try device.makeComputePipelineState(
      function: XCTUnwrap(lib.makeFunction(name: "inspectWrist")))
    let q = simd_quatf(angle: 150 * .pi / 180, axis: [0, 1, 0])
    let bones = [matrix_identity_float4x4, simd_float4x4(q)]
    let zero = SIMD4<Float>.zero
    var scene = SceneUniforms(
      vp: matrix_identity_float4x4, lightVP: matrix_identity_float4x4,
      right: zero, up: zero, back: zero, center: zero, key: zero, footA: zero, footB: zero,
      handA: zero, handB: zero)
    scene.wristTurns.0 = q.vector
    let buffer = try XCTUnwrap(device.makeBuffer(length: 32, options: .storageModeShared))
    let cb = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    let encoder = try XCTUnwrap(cb.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipe)
    bones.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
    encoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 1)
    encoder.setBuffer(buffer, offset: 0, index: 2)
    let two = MTLSize(width: 2, height: 1, depth: 1)
    encoder.dispatchThreads(two, threadsPerThreadgroup: two)
    encoder.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    if let error = cb.error { throw error }
    let result = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
    func radius(_ p: SIMD4<Float>) -> Float { hypot(p.x, p.z) }
    XCTAssertEqual(radius(result[0]), cos(75 * .pi / 180), accuracy: 0.001)
    XCTAssertEqual(radius(result[1]), 1, accuracy: 0.0001)
  }
  @MainActor func testCameraZoomAndResetKeepTheInspectedPose() throws {
    try requireDesktopFixtures()
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal GPU unavailable.")
    }
    let player = try ExercisePlayer(device: device, exerciseID: "bench-press")
    try player.send(.seek(0.45))
    try player.send(.setMuscles(primary: player.muscleGroups, secondary: []))
    func bodyWidth() throws -> Int {
      let shot = try player.snapshot(width: 500, height: 360)
      let bytes = Array(try XCTUnwrap(shot.dataProvider?.data) as Data)
      let xs = stride(from: 0, to: bytes.count, by: 4).lazy.filter {
        Int(bytes[$0 + 2]) > 100 && Int(bytes[$0 + 2]) > Int(bytes[$0]) + 38
      }.map { $0 / 4 % shot.width }
      return try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min())
    }
    let fit = try bodyWidth()
    player.setZoom(1.25)
    XCTAssertGreaterThan(Double(try bodyWidth()) / Double(fit), 1.15)
    try player.send(.orient(yaw: 0, pitch: -20))
    player.resetView()
    XCTAssertEqual(player.zoom, 1)
    XCTAssertEqual(player.yaw, player.selectedExercise.cameraYaw)
    XCTAssertEqual(player.pitch, player.selectedExercise.cameraPitch)
    XCTAssertEqual(try bodyWidth(), fit, accuracy: 1)
    XCTAssertEqual(player.phase, 0.45)
    XCTAssertFalse(player.isPlaying)
    try player.send(.play)
    player.resetView()
    XCTAssertTrue(player.isPlaying)
    player.setZoom(0.1)
    XCTAssertEqual(player.zoom, 0.75)
    player.setZoom(9)
    XCTAssertEqual(player.zoom, 3)
    try player.send(.selectExercise("push-up"))
    XCTAssertEqual(player.zoom, 1)
  }

  @MainActor func testBatchRenderTimings() throws {
    try requireDesktopFixtures()
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
