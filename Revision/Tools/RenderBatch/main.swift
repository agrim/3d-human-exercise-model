import CoreGraphics
import ExerciseDummy
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

@MainActor
func render() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let path = args.first else {
        throw ExerciseDummyError.invalidCommand("Usage: RenderBatch directory [frames-per-exercise] [exercise-id ...]")
    }
    let count = args.count > 1 ? Int(args[1]) ?? 0 : 3
    guard (2...180).contains(count) else { throw ExerciseDummyError.invalidCommand("Choose 2–180 frames.") }
    let out = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let player = try ExercisePlayer()
    let ids = args.count > 2 ? Array(args[2...]) : player.exercises.map(\.id)
    for id in ids {
        try player.send(.selectExercise(id))
        try player.send(.pause)
        for frame in 0..<count {
            try autoreleasepool {
                let phase = count == 3 ? Float(frame) / 4 : Float(frame) / Float(count)
                try player.send(.seek(phase))
                let captured = try player.snapshot(width: 640, height: 640)
                let file = out.appendingPathComponent(String(format: "%@-%03d.png", id, frame))
                guard let png = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw ExerciseDummyError.rendering("Could not open \(file.path)")
                }
                CGImageDestinationAddImage(png, captured, nil)
                guard CGImageDestinationFinalize(png) else { throw ExerciseDummyError.rendering("Could not save PNG") }
            }
        }
        print("Rendered \(id)")
    }
}
try MainActor.assumeIsolated { try render() }
