import ExerciseDummy
import SwiftUI

extension Color {
  static let coral = Color(red: 1, green: 0.40, blue: 0.28)
  static let amber = Color(red: 1, green: 0.76, blue: 0.32)
}

func muscleName(_ id: String) -> String {
  id.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    .localizedCapitalized
}

struct CatalogSheet: View {
  let library: RecipeLibrary
  let onLoadEML: () -> Void
  let onBuild: (EMLDraft?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var issue: String?
  var body: some View {
    NavigationStack {
      List {
        if query.isEmpty {
          Section("Author an exercise") {
            Button("Create custom EML", systemImage: "list.number") { onBuild(nil) }
              .accessibilityIdentifier("eml.create")
            Button("Load EML", systemImage: "doc", action: onLoadEML)
          }
        }
        section("My EML", library.saved)
        section("EML catalog · " + String(library.catalog.count), library.catalog)
      }
      .overlay {
        if library.busy {
          ProgressView("Preparing exercise").padding().background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if (library.catalog + library.saved).allSatisfy({ !matches($0) }) {
          ContentUnavailableView.search(text: query)
        }
      }
      .disabled(library.busy)
      .searchable(text: $query, prompt: "Exercise or muscle")
      .navigationTitle("Exercises")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .alert(
        "Couldn’t open exercise",
        isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(issue ?? "")
      }
    }
  }
  func matches(_ entry: RecipeEntry) -> Bool {
    let h = entry.header
    return query.isEmpty || h.title.localizedCaseInsensitiveContains(query)
      || h.id.localizedCaseInsensitiveContains(query)
      || (h.muscles.primary + h.muscles.secondary).contains {
        muscleName($0).localizedCaseInsensitiveContains(query)
      }
  }
  @ViewBuilder func section(_ title: String, _ entries: [RecipeEntry]) -> some View {
    let found = entries.filter(matches)
    if !found.isEmpty {
      Section(title) {
        ForEach(found) { entry in
          Button {
            Task {
              do {
                try await library.select(entry)
                dismiss()
              } catch { issue = error.localizedDescription }
            }
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.header.title)
                Text(entry.header.muscles.primary.map(muscleName).joined(separator: ", "))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if library.selected?.id == entry.id {
                Image(systemName: "checkmark").accessibilityLabel("Selected")
              }
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityIdentifier(entry.id)
            .contextMenu {
              if let draft = library.authoredDrafts[entry.id] {
                Button("Edit steps", systemImage: "pencil") { onBuild(draft) }
              }
            }
        }
      }
    }
  }
}

struct StudioDetails: View {
  let player: ExercisePlayer
  let library: RecipeLibrary
  let onEdit: (EMLDraft?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var issue: String?
  var body: some View {
    let inactive = player.muscleGroups.filter {
      !player.primary.contains($0) && !player.secondary.contains($0)
    }
    NavigationStack {
      List {
        if let instructions = library.displayHeader?.instructions, !instructions.isEmpty {
          Section("Instructions") { Text(instructions) }
        }
        if !player.movementIssues.isEmpty {
          Section("Movement checks") {
            ForEach(player.movementIssues) { finding in
              Button {
                do {
                  try player.inspectIssue(finding)
                  dismiss()
                } catch { issue = error.localizedDescription }
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(finding.message)
                  Text(
                    "\(authoringName(finding.phase)) · \(finding.seconds.formatted(.number.precision(.fractionLength(1)))) s"
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
              }
              .accessibilityHint("Pause the model at the measured pose")
            }
          }
        }
        if !player.inspectablePositions.isEmpty {
          Section("Inspect a position") {
            ForEach(player.inspectablePositions, id: \.self) { name in
              Button(name.replacingOccurrences(of: "-", with: " ").capitalized) {
                do {
                  try player.inspectPosition(name)
                  dismiss()
                } catch { issue = error.localizedDescription }
              }
              .accessibilityHint("Pause the model at this position")
            }
          }
        }
        group("Primary", player.primary.sorted(), .coral)
        group("Secondary", player.secondary.sorted(), .amber)
        Section {
          DisclosureGroup("Unhighlighted") { muscleNames(inactive.sorted(), .gray) }
        }
        Section {
          if let entry = library.selected, entry.custom {
            if let draft = library.authoredDrafts[entry.id] {
              Button("Edit steps", systemImage: "pencil") { onEdit(draft) }
            }
            ShareLink(item: entry.url) { Label("Export EML", systemImage: "square.and.arrow.up") }
          }
          NavigationLink("Model credits") { ModelCredits(notice: player.attribution) }
        }
      }
      .navigationTitle("Exercise details").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .alert(
        "Couldn’t inspect this position",
        isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
      ) {
        Button("OK") {}
      } message: {
        Text(issue ?? "")
      }
    }
  }
  private func group(_ title: String, _ values: [String], _ color: Color) -> some View {
    Section(title) { muscleNames(values, color) }
  }

  @ViewBuilder func muscleNames(_ values: [String], _ color: Color) -> some View {
    if values.isEmpty {
      Text("None").foregroundStyle(.secondary)
    } else {
      ForEach(values, id: \.self) { id in
        Label {
          Text(muscleName(id))
        } icon: {
          Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color)
            .accessibilityHidden(true)
        }
      }
    }
  }
}

private struct ModelCredits: View {
  let notice: String
  var body: some View {
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
  }
}
