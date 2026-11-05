import ExerciseDummy
import SwiftUI

private enum StudioSheet: Identifiable {
  case catalog, inspect, editor
  case builder(EMLDraft?)
  var id: String {
    switch self {
    case .catalog: "catalog"
    case .inspect: "inspect"
    case .editor: "editor"
    case .builder(let draft): draft.map { "builder/edit/" + $0.identifier } ?? "builder/create"
    }
  }
}

struct StudioView: View {
  let player: ExercisePlayer
  let library: RecipeLibrary
  @State private var sheet: StudioSheet?
  @State private var errorMessage: String?
  @State private var resumeAfterBrowsing = false
  @State private var dragStart: SIMD2<Float>?
  @GestureState private var pinchStart: Float?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.verticalSizeClass) private var heightClass
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .headline) private var readingHeight: CGFloat = 72

  var body: some View {
    NavigationStack {
      scene
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Exercises") {
              resumeAfterBrowsing = player.isPlaying
              send(.pause)
              sheet = .catalog
            }
          }
          if typeSize.isAccessibilitySize {
            ToolbarItem(placement: .topBarTrailing) { playButton }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Reset view", systemImage: "arrow.counterclockwise", action: player.resetView)
              .labelStyle(.iconOnly).accessibilityIdentifier("studio.resetView")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              send(.pause)
              sheet = .inspect
            } label: {
              if player.movementIssues.isEmpty {
                Text("Inspect")
              } else {
                Label("Inspect", systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon)
              }
            }
            .accessibilityValue(player.contactWarning ?? "")
          }
        }
    }
    .sheet(
      item: $sheet,
      onDismiss: {
        guard sheet == nil else { return }
        if resumeAfterBrowsing && scenePhase == .active
          && !(library.previewSource != nil && !player.movementIssues.isEmpty)
        {
          send(.play)
        }
        resumeAfterBrowsing = false
      }
    ) { item in
      switch item {
      case .catalog:
        CatalogSheet(library: library, onLoadEML: { sheet = .editor }, onBuild: openBuilder)
      case .editor: EMLEditor(library: library)
      case .builder(let draft): EMLBuilderView(library: library, initialDraft: draft)
      case .inspect:
        StudioDetails(player: player, library: library, onEdit: openBuilder)
          .presentationDetents([.medium, .large])
      }
    }
    .alert(
      "Couldn’t update the model",
      isPresented: Binding(
        get: { (errorMessage ?? library.problem) != nil },
        set: {
          if !$0 {
            errorMessage = nil
            library.problem = nil
          }
        })
    ) {
      Button("OK") {}
    } message: {
      Text(errorMessage ?? library.problem ?? "")
    }
    .onChange(of: scenePhase) { _, phase in if phase == .background { send(.pause) } }
  }

  private func openBuilder(_ draft: EMLDraft?) {
    sheet = .builder(draft)
  }

  // A wide display has room for the controls in its corners without shortening the model.
  @ViewBuilder private var scene: some View {
    if typeSize.isAccessibilitySize {
      VStack(spacing: 0) {
        orbitableModel
        caption
      }.background(stageBackdrop)
    } else if heightClass == .compact {
      ZStack(alignment: .bottom) {
        orbitableModel.ignoresSafeArea()
        caption
      }
    } else if #available(iOS 26, *) {
      orbitableModel.safeAreaBar(edge: .bottom, spacing: 0) { caption }
        .background(stageBackdrop)
    } else {
      orbitableModel.safeAreaInset(edge: .bottom, spacing: 0) { caption }
        .background(stageBackdrop)
    }
  }

  // Continue the neutral stage outside the drawable without reflecting anatomy into the margins.
  private var stageBackdrop: some View {
    let sky = Color(red: 0.215, green: 0.248, blue: 0.291)
    let floor = Color(red: 0.259, green: 0.293, blue: 0.334)
    return LinearGradient(
      stops: [
        .init(color: sky, location: 0.25),
        .init(color: floor, location: 0.75),
      ],
      startPoint: .top, endPoint: .bottom
    ).ignoresSafeArea()
  }

  @ViewBuilder private var caption: some View {
    if typeSize.isAccessibilitySize {
      // Long personal titles can be read in full without displacing the anatomy off screen.
      ViewThatFits(in: .vertical) {
        readingTitle
        ScrollView { readingTitle }.scrollBounceBehavior(.basedOnSize)
      }
      .frame(maxHeight: readingHeight, alignment: .leading)
      .padding(.horizontal, 20).padding(.vertical, 6)
    } else {
      standardCaption
    }
  }

  private var readingTitle: some View {
    Text(player.selectedExercise.title).font(.headline).foregroundStyle(.white)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }

  private var standardCaption: some View {
    HStack(alignment: .center, spacing: 12) {
      if heightClass == .compact {
        captionText.containerRelativeFrame(
          .horizontal, count: 4, span: 1, spacing: 0,
          alignment: .leading)
      } else {
        captionText
      }
      Spacer(minLength: 0)
      if #available(iOS 26, *) {
        playButton.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
      } else {
        playButton.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 8)
  }

  private var captionText: some View {
    VStack(alignment: .leading, spacing: 3) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          exerciseTitle
          if !player.isPlaying, !player.phaseName.isEmpty {
            Text(player.phaseName.replacingOccurrences(of: "-", with: " ").capitalized)
              .font(.subheadline.weight(.medium)).foregroundStyle(.white)
          }
        }
        exerciseTitle
      }
      targets
    }
  }

  private var exerciseTitle: some View {
    Text(player.selectedExercise.title)
      .font(heightClass == .compact ? .headline.bold() : .title2.bold())
      .fontWidth(.expanded).foregroundStyle(.white)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder private var targets: some View {
    target(
      "Primary", groups: player.primary, order: library.displayHeader?.muscles.primary ?? [],
      color: .coral)
    target(
      "Secondary", groups: player.secondary,
      order: library.displayHeader?.muscles.secondary ?? [], color: .amber)
  }

  private func target(_ role: String, groups: Set<String>, order: [String], color: Color)
    -> some View
  {
    let names = (order.filter(groups.contains) + groups.subtracting(order).sorted()).map(muscleName)
    let preview = names.prefix(2)
    let more = names.count - preview.count
    let label =
      (preview.isEmpty ? "None" : preview.joined(separator: ", ")) + (more > 0 ? " +\(more)" : "")
    return HStack(spacing: 5) {
      Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
        .accessibilityHidden(true)
      Text(role + ": " + label)
        .font(heightClass == .compact ? .caption : .footnote).foregroundStyle(.white)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(role + ": " + (names.isEmpty ? "None" : names.joined(separator: ", ")))
  }

  private var playButton: some View {
    Button(
      player.isPlaying ? "Pause" : "Play",
      systemImage: player.isPlaying ? "pause.fill" : "play.fill"
    ) { send(player.isPlaying ? .pause : .play) }
    .labelStyle(.iconOnly)
    .accessibilityValue(!player.isPlaying ? player.phaseName : "")
  }

  private var orbitableModel: some View {
    ExerciseDummyView(player: player)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 3).onChanged { gesture in
          guard pinchStart == nil else { return }
          let start = dragStart ?? SIMD2(player.yaw, player.pitch)
          dragStart = start
          send(
            .orient(
              yaw: start.x - Float(gesture.translation.width) * 0.5,
              pitch: min(88, max(-30, start.y + Float(gesture.translation.height) * 0.3))))
        }.onEnded { _ in dragStart = nil }
      )
      .simultaneousGesture(
        MagnifyGesture()
          .updating($pinchStart) { _, start, _ in
            if start == nil { start = player.zoom }
          }
          .onChanged { value in
            player.setZoom((pinchStart ?? player.zoom) * Float(value.magnification))
          }
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(player.selectedExercise.title) model")
      .accessibilityValue(
        "\(Int(player.yaw)) degrees horizontal, \(Int(player.pitch)) degrees elevation, \(Int((player.zoom * 100).rounded())) percent zoom"
      )
      .accessibilityHint("Adjust to rotate the model")
      .accessibilityAction(named: "Zoom in") { player.setZoom(player.zoom * 1.25) }
      .accessibilityAction(named: "Zoom out") { player.setZoom(player.zoom / 1.25) }
      .accessibilityAdjustableAction { direction in
        send(.orient(yaw: player.yaw + (direction == .increment ? 15 : -15), pitch: player.pitch))
      }
  }

  private func send(_ command: ExerciseCommand) {
    do { try player.send(command) } catch { errorMessage = error.localizedDescription }
  }
}
