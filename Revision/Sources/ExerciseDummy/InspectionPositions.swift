import simd

struct InspectionPosition {
  let name: String
  let progress: Float
}

extension Clip {
  /// EML includes every authored endpoint. If a phase arcs out and back, its most distant
  /// sampled pose can describe it better than its ending. Inspect only the first repetition.
  func inspectionPositions() -> [InspectionPosition] {
    guard !frames.isEmpty, frames.allSatisfy({ $0.annotation != nil }) else { return [] }
    var positions = [InspectionPosition]()
    var seen = Set<String>()
    var hasMovement = false
    var first = frames.startIndex
    while first < frames.endIndex, let name = frames[first].annotation?.phase {
      let start = frames[max(0, first - 1)]
      var next = first
      var peak = first
      var peakChange: Float = 0
      var endChange: Float = 0
      while next < frames.endIndex, frames[next].annotation?.phase == name {
        endChange = frames[next].change(from: start)
        if endChange >= peakChange {
          peakChange = endChange
          peak = next
        }
        next += 1
      }
      hasMovement = hasMovement || peakChange > 1e-8
      if seen.insert(name).inserted {
        // Prefer the completed phase unless its endpoint loses a substantial interior excursion.
        let target = frames[endChange >= 0.8 * peakChange ? next - 1 : peak].phase
        let count = Float(cycles)
        var progress = target / count
        // Labels belong to the completed phase at its endpoint. Avoid rounding into the next
        // label, including the exact seam at the end of a non-final rep.
        while progress > 0 && (progress * count > target || (cycles > 1 && progress * count >= 1)) {
          progress = progress.nextDown
        }
        positions.append(.init(name: name, progress: progress))
      }
      first = next
    }
    return hasMovement ? positions : []
  }
}

extension Keyframe {
  /// Compare positions, local joint and prop orientations, and prop size (e.g. a moving cable).
  /// Quaternion signs are equivalent. All frames here have the same validated rig and prop order.
  fileprivate func change(from start: Self) -> Float {
    func rotationChange(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
      simd_distance_squared(a, simd_dot(a, b) < 0 ? -b : b)
    }
    var delta = simd_distance_squared(root, start.root)
    for (a, b) in zip(rotations, start.rotations) {
      delta = max(delta, rotationChange(a, b))
    }
    for (a, b) in zip(props, start.props) {
      delta = max(
        delta, simd_distance_squared(a.position, b.position),
        rotationChange(a.rotation, b.rotation),
        simd_distance_squared(a.scale ?? .one, b.scale ?? .one))
    }
    return delta
  }
}
