import Foundation

enum EMLCompiler {
  private static let queue = DispatchQueue(label: "exercise-studio.eml", qos: .userInitiated)
  struct Failure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
  }

  static func compile(_ source: Data, strict: Bool = false) async throws -> Data {
    guard !source.isEmpty, source.count <= 512_000 else {
      throw Failure(reason: "Choose a nonempty EML JSON file up to 512 KB.")
    }
    let bundle = Bundle.main.bundlePath
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        var output: UnsafeMutablePointer<UInt8>?
        var size = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = source.withUnsafeBytes { bytes in
          EMLCompile(bundle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, strict ? 1 : 0, &output, &size, &error)
        }
        defer { EMLRelease(error) }
        guard status == 0, let output else {
          continuation.resume(throwing: Failure(reason: error.map { String(cString: $0) } ?? "EML compilation failed."))
          return
        }
        continuation.resume(returning: Data(bytesNoCopy: output, count: size, deallocator: .free))
      }
    }
  }
}
