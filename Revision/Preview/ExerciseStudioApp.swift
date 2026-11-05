import ExerciseDummy
import SwiftUI

@main
struct ExerciseStudioApp: App {
  var body: some Scene { WindowGroup { StudioRoot().preferredColorScheme(.dark) } }
}

struct StudioRoot: View {
  @State private var player: ExercisePlayer?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let player {
        StudioView(player: player)
      } else if let errorMessage {
        ContentUnavailableView(
          "Couldn’t open the model", systemImage: "figure.strengthtraining.traditional",
          description: Text(errorMessage))
      } else {
        ProgressView("Preparing the model")
      }
    }
    .task {
      guard player == nil, errorMessage == nil else { return }
      do {
        let loaded = try ExercisePlayer(exerciseID: "squat")
        try loaded.send(.play)
        player = loaded
      } catch { errorMessage = error.localizedDescription }
    }
  }
}
