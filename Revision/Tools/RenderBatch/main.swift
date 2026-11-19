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
        throw ExerciseDummyError.invalidCommand("Usage: RenderBatch directory [frame-count] [exercise-id ... | --eml root compiled-clip.json ...]")
    }
    let count = args.count > 1 ? Int(args[1]) ?? 0 : 3
    guard (2...180).contains(count) else { throw ExerciseDummyError.invalidCommand("Choose 2–180 frames.") }
    let out = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let selection = Array(args.dropFirst(2))
    let player: ExercisePlayer
    let inputs: [String]
    let compiled = selection.first == "--eml"
    if compiled {
        guard selection.count >= 3 else {
            throw ExerciseDummyError.invalidCommand("--eml needs an EML root and compiled clip JSON paths.")
        }
        let root = URL(fileURLWithPath: selection[1], isDirectory: true)
        inputs = Array(selection.dropFirst(2))
        player = try ExercisePlayer(emlRoot: root, compiledClip: Data(contentsOf: URL(fileURLWithPath: inputs[0])))
    } else {
        player = try ExercisePlayer()
        inputs = selection.isEmpty ? player.exercises.map(\.id) : selection
    }
    for (index, input) in inputs.enumerated() {
        if compiled {
            if index > 0 { try player.load(compiledClip: Data(contentsOf: URL(fileURLWithPath: input))) }
        } else {
            try player.send(.selectExercise(input))
        }
        let id = player.selectedExercise.id
        guard !id.isEmpty, !id.contains("/"), !id.utf8.contains(0) else {
            throw ExerciseDummyError.invalidCommand("Exercise ID cannot be used as a snapshot filename.")
        }
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
