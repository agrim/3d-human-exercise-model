import SwiftUI
import UniformTypeIdentifiers

private struct AuthoredEMLDocument: FileDocument {
  static let readableContentTypes = [UTType.json]
  var data: Data

  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct EMLBuilderView: View {
  let library: RecipeLibrary
  private let original: EMLDraft
  private let editingID: String?
  @Environment(\.dismiss) private var dismiss
  @State private var draft: EMLDraft
  @State private var vocabulary: EMLVocabulary?
  @State private var vocabularyError: String?
  @State private var stepPath: [UUID] = []
  @State private var stepEditMode: EditMode = .inactive
  @State private var verifying = false
  @State private var issue: String?
  @State private var pendingOverwrite: String?
  @State private var discard = false
  @State private var exportDocument: AuthoredEMLDocument?
  @State private var exportName = ""
  @State private var exporter = false
  private enum Field { case title, instructions, repetitions, identifier }
  @FocusState private var rootField: Field?

  init(library: RecipeLibrary, initialDraft: EMLDraft? = nil) {
    self.library = library
    var initial = initialDraft ?? EMLDraft()
    if initialDraft == nil { initial.phases = [] }
    // Re-edit the saved ID when changing only the exercise title. Explicit ID changes save separately.
    editingID = initialDraft?.identifier
    original = initial
    _draft = State(initialValue: initial)
  }

  private var busy: Bool { verifying || library.busy }
  var body: some View {
    NavigationStack(path: $stepPath) {
      Group {
        if let vocabulary {
          form(vocabulary)
            .navigationDestination(for: UUID.self) { id in
              if let index = draft.phases.firstIndex(where: { $0.id == id }) {
                AuthoringPhase(
                  step: $draft.phases[index], mode: draft.mode, startingPose: draft.startPose,
                  exercisePoints: draft.fixedPoints ?? [],
                  exerciseRoles: .init(primary: draft.primary, secondary: draft.secondary),
                  vocabulary: vocabulary)
              }
            }
        } else if let vocabularyError {
          ContentUnavailableView(
            "Couldn’t open the vocabulary", systemImage: "list.bullet",
            description: Text(vocabularyError))
        } else {
          ProgressView("Opening vocabulary")
        }
      }
      .navigationTitle(editingID == nil ? "New EML" : "Edit EML")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if draft == original { dismiss() } else { discard = true }
          }.disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          if busy {
            ProgressView().accessibilityLabel("Checking exercise")
          } else {
            Button("Save and play") { requestSave() }
              .disabled(!canSubmit).accessibilityIdentifier("builder.play")
          }
        }
      }
    }
    .disabled(busy)
    .interactiveDismissDisabled(busy || draft != original)
    .task {
      guard vocabulary == nil else { return }
      do { vocabulary = try EMLVocabulary.load(from: library.root) } catch {
        vocabularyError = error.localizedDescription
      }
    }
    .fileExporter(
      isPresented: $exporter, document: exportDocument, contentType: .json,
      defaultFilename: exportName
    ) { result in
      if case .failure(let error) = result,
        !((error as? CocoaError)?.code == .userCancelled)
      {
        issue = error.localizedDescription
      }
    }
    .fileDialogDefaultDirectory(URL.documentsDirectory)
    .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) {
      Button("Discard changes", role: .destructive) { dismiss() }
      Button("Keep editing", role: .cancel) {}
    }
    .alert(
      "Replace saved exercise?",
      isPresented: Binding(
        get: { pendingOverwrite != nil }, set: { if !$0 { pendingOverwrite = nil } })
    ) {
      Button("Replace", role: .destructive) {
        pendingOverwrite = nil
        save()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "My EML already contains “" + (pendingOverwrite ?? "")
          + "”. Choose a different exercise ID to keep both.")
    }
    .alert(
      "Couldn’t use this exercise",
      isPresented: Binding(
        get: { issue != nil }, set: { if !$0 { issue = nil } })
    ) {
      Button("OK") { issue = nil }
    } message: {
      Text(issue ?? "")
    }
  }

  private func form(_ vocabulary: EMLVocabulary) -> some View {
    Form {
      Section("Exercise") {
        TextField("Exercise name", text: $draft.title)
          .focused($rootField, equals: .title).accessibilityIdentifier("builder.title")
        TextField("Instructions (optional)", text: $draft.instructions, axis: .vertical)
          .lineLimit(2...6).focused($rootField, equals: .instructions)
      }
      Section {
        ForEach(draft.phases) { step in
          NavigationLink(value: step.id) {
            VStack(alignment: .leading, spacing: 2) {
              Text(step.name.isEmpty ? "Unnamed step" : step.name)
              Text(summary(step, vocabulary: vocabulary)).font(.subheadline).foregroundStyle(
                .secondary)
            }
          }
        }
        .onMove { draft.phases.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { draft.phases.remove(atOffsets: $0) }
        Button {
          rootField = nil
          let names = Set(draft.phases.map(\.name))
          var next = draft.phases.count + 1
          while names.contains("Step \(next)") { next += 1 }
          let step = EMLPhaseDraft(name: "Step \(next)")
          draft.phases.append(step)
          stepPath.append(step.id)
        } label: {
          Label("Add step", systemImage: "plus")
        }
        .accessibilityIdentifier("builder.addStep")
      } header: {
        HStack {
          Text("Movement steps")
          Spacer()
          if !draft.phases.isEmpty { EditButton() }
        }
      }
      Section("Setup and playback") {
        NavigationLink {
          AuthoringSetup(draft: $draft, vocabulary: vocabulary)
        } label: {
          LabeledContent("Starting pose", value: authoringName(draft.startPose))
        }
        Picker("Playback", selection: $draft.mode) {
          Text("Once").tag(EMLRepeatMode.once)
          Text("Loop").tag(EMLRepeatMode.loop)
          Text("Hold").tag(EMLRepeatMode.hold)
        }
        if draft.mode != .once {
          LabeledContent("Repetitions") {
            TextField("Repetitions", value: $draft.count, format: .number)
              .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused(
                $rootField, equals: .repetitions)
          }
        }
        NavigationLink {
          AuthoringEquipment(items: $draft.equipment, vocabulary: vocabulary)
        } label: {
          LabeledContent(
            "Equipment", value: draft.equipment.isEmpty ? "None" : "\(draft.equipment.count)")
        }
        NavigationLink {
          AuthoringMuscles(
            roles: Binding(
              get: {
                EMLMuscleRoles(primary: draft.primary, secondary: draft.secondary)
              },
              set: {
                draft.primary = $0.primary
                draft.secondary = $0.secondary
              }), vocabulary: vocabulary)
        } label: {
          LabeledContent(
            "Muscle roles", value: "\(draft.primary.count + draft.secondary.count) selected")
        }
      }
      Section {
        DisclosureGroup("Exercise ID") {
          TextField("Generated from exercise name", text: $draft.identifier)
            .focused($rootField, equals: .identifier).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("builder.identifier")
        }
        Button {
          export()
        } label: {
          Label("Export EML", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("builder.export").disabled(!canSubmit)
      }
    }
    .environment(\.editMode, $stepEditMode)
    .scrollDismissesKeyboard(.interactively)
  }

  private func summary(_ step: EMLPhaseDraft, vocabulary: EMLVocabulary) -> String {
    let target =
      step.holdsPrevious
      ? "Hold previous position"
      : step.actions.first.map {
        movementName($0.motion, family: vocabulary.motionFamilies[$0.motion])
      }
    let detail = target ?? (step.joints.isEmpty ? "Starting pose" : "Joint angles")
    return "\(step.seconds.formatted()) s · " + detail
  }
  private var canSubmit: Bool {
    vocabulary != nil && !busy && !draft.phases.isEmpty
      && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private func payload() throws -> (Data, RecipeHeader) {
    let data = Data(try draft.source(vocabulary: vocabulary).utf8)
    return (data, try JSONDecoder().decode(RecipeHeader.self, from: data))
  }
  private func requestSave() {
    rootField = nil
    do {
      let (_, header) = try payload()
      if header.id != editingID,
        let other = library.saved.first(where: { $0.header.id == header.id })
      {
        pendingOverwrite = other.header.title
      } else {
        save()
      }
    } catch { issue = error.localizedDescription }
  }
  private func save() {
    verifying = true
    Task {
      defer { verifying = false }
      do {
        try await library.playAuthored(draft)
        dismiss()
      } catch { issue = error.localizedDescription }
    }
  }
  private func export() {
    rootField = nil
    verifying = true
    Task {
      defer { verifying = false }
      do {
        let (data, header) = try payload()
        try await library.validateCustom(data)
        exportDocument = AuthoredEMLDocument(data: data)
        exportName = header.id
        exporter = true
      } catch { issue = error.localizedDescription }
    }
  }
}
