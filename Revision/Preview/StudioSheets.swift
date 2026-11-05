import ExerciseDummy
import SwiftUI

extension Color {
  static let coral = Color(red: 1, green: 0.40, blue: 0.28)
  static let amber = Color(red: 1, green: 0.76, blue: 0.32)
}

private func muscleName(_ id: String) -> String {
  id.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    .localizedCapitalized
}

struct MuscleLine: View {
  let role: String
  let groups: [String]
  let color: Color
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(color)
        .accessibilityHidden(true)
      Text(role).fontWeight(.semibold)
      Text(groups.map(muscleName).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(2)
    }.font(.subheadline).accessibilityElement(children: .combine)
  }
}

struct CatalogSheet: View {
  let player: ExercisePlayer
  let choose: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  var body: some View {
    let matches = player.exercises.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        || ($0.primary + $0.secondary).contains(where: {
          muscleName($0).localizedCaseInsensitiveContains(query)
        })
    }
    NavigationStack {
      List(matches) { exercise in
        Button {
          choose(exercise.id)
          dismiss()
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(exercise.title)
              Text(exercise.primary.map(muscleName).joined(separator: ", ")).font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if player.selectedExercise.id == exercise.id {
              Image(systemName: "checkmark").accessibilityLabel("Selected")
            }
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
      }.overlay { if matches.isEmpty { ContentUnavailableView.search(text: query) } }
        .searchable(text: $query, prompt: "Exercise or muscle")
        .navigationTitle("Exercises")
        .toolbar { Button("Done") { dismiss() } }
    }
  }
}

struct MuscleSheet: View {
  let player: ExercisePlayer
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    let inactive = player.muscleGroups.filter {
      !player.primary.contains($0) && !player.secondary.contains($0)
    }
    NavigationStack {
      List {
        group("Primary", player.selectedExercise.primary, .coral)
        group("Secondary", player.selectedExercise.secondary, .amber)
        group("Unhighlighted", inactive, .gray)
      }.navigationTitle("Muscle groups").toolbar { Button("Done") { dismiss() } }
    }
  }
  private func group(_ title: String, _ values: [String], _ color: Color) -> some View {
    Section(title) {
      ForEach(values, id: \.self) { id in
        Label {
          Text(muscleName(id))
        } icon: {
          Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color)
        }
      }
    }
  }
}

struct CreditsSheet: View {
  let notice: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(notice.components(separatedBy: "\n\n").enumerated()), id: \.offset) {
            _, paragraph in
            if paragraph.hasPrefix("# ") {
              Text(String(paragraph.dropFirst(2))).font(.headline)
            } else {
              Text((try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph))
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled)
      }.navigationTitle("Model credits").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }
  }
}
