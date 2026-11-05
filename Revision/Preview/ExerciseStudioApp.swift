import SwiftUI

@main
struct ExerciseStudioApp: App {
  var body: some Scene { WindowGroup { StudioRoot() } }
}

struct StudioRoot: View {
  @State private var library = RecipeLibrary()
  var body: some View {
    Group {
      if let player = library.player {
        StudioView(player: player, library: library)
      } else if let message = library.problem {
        ContentUnavailableView {
          Label("Couldn’t open Exercise Studio", systemImage: "figure.strengthtraining.traditional")
        } description: {
          Text(message)
        } actions: {
          Button("Retry") {
            library.problem = nil
            Task { await library.open() }
          }
        }
      } else {
        ProgressView("Preparing the anatomy model")
      }
    }.task { await library.open() }
  }
}
