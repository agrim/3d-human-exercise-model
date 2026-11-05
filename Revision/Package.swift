// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "ExerciseDummy", targets: ["ExerciseDummy"])]
var targets: [Target] = [
  .target(
    name: "ExerciseDummy",
    exclude: ["Resources"],
    resources: [.copy("Shaders/ExerciseDummy.metal")]),
  .testTarget(name: "ExerciseDummyTests", dependencies: ["ExerciseDummy"]),
]
#if os(macOS)
  products.append(.executable(name: "RenderBatch", targets: ["RenderBatch"]))
  targets.append(
    .executableTarget(
      name: "RenderBatch", dependencies: ["ExerciseDummy"], path: "Tools/RenderBatch"))
#endif

let package = Package(
  name: "ExerciseDummy", platforms: [.iOS(.v17), .macOS(.v14)],
  products: products, targets: targets
)
