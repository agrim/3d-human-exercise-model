import ExerciseDummy
import SwiftUI

private enum StudioSheet: String, Identifiable {
  case catalog, muscles, credits
  var id: String { rawValue }
}

struct StudioView: View {
  let player: ExercisePlayer
  @State private var sheet: StudioSheet?
  @State private var errorMessage: String?
  @State private var dragStart: SIMD2<Float>?
  @State private var resumeAfterScrub = false
  @Environment(\.scenePhase) private var scenePhase

  private func send(_ command: ExerciseCommand) {
    do { try player.send(command) } catch { errorMessage = error.localizedDescription }
  }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        if geometry.size.width > geometry.size.height {
          HStack(spacing: 0) {
            stage
            ScrollView { inspector }.frame(width: min(340, geometry.size.width * 0.39))
          }
        } else {
          VStack(spacing: 0) {
            stage.frame(height: geometry.size.height * 0.61)
            ScrollView { inspector }
          }
        }
      }
      .navigationTitle(player.selectedExercise.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Exercises", systemImage: "list.bullet") { sheet = .catalog }
            .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Model credits", systemImage: "info.circle") { sheet = .credits }
            .labelStyle(.iconOnly)
        }
      }
      .sheet(item: $sheet) { item in
        switch item {
        case .catalog: CatalogSheet(player: player, choose: { send(.selectExercise($0)) })
        case .muscles: MuscleSheet(player: player)
        case .credits: CreditsSheet(notice: player.attribution)
        }
      }
      .alert(
        "Couldn’t update the model",
        isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .onChange(of: scenePhase) { _, phase in if phase == .background { send(.pause) } }
    }
  }

  private var stage: some View {
    ExerciseDummyView(player: player)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 3).onChanged { gesture in
          let start = dragStart ?? SIMD2(player.yaw, player.pitch)
          dragStart = start
          send(
            .orient(
              yaw: start.x - Float(gesture.translation.width) * 0.5,
              pitch: min(88, max(-30, start.y + Float(gesture.translation.height) * 0.3))))
        }.onEnded { _ in dragStart = nil }
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(player.selectedExercise.title) model")
      .accessibilityValue(
        "\(Int(player.yaw)) degrees horizontal, \(Int(player.pitch)) degrees elevation"
      )
      .accessibilityHint("Adjust to rotate the model")
      .accessibilityAdjustableAction { direction in
        send(.orient(yaw: player.yaw + (direction == .increment ? 15 : -15), pitch: player.pitch))
      }
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        Button(
          player.isPlaying ? "Pause" : "Play",
          systemImage: player.isPlaying ? "pause.fill" : "play.fill"
        ) {
          send(player.isPlaying ? .pause : .play)
        }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !player.isPlaying)) { _ in
          Slider(
            value: Binding(get: { Double(player.phase) }, set: { send(.seek(Float($0))) }),
            in: 0...1,
            onEditingChanged: { active in
              if active {
                resumeAfterScrub = player.isPlaying
                send(.pause)
              } else if resumeAfterScrub {
                send(.play)
                resumeAfterScrub = false
              }
            }
          )
          .accessibilityLabel("Exercise phase")
          .accessibilityValue("\(Int(player.phase*100)) percent")
        }
        Menu {
          ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in
            Button(rate.formatted() + "×") { send(.setTempo(rate)) }
          }
        } label: {
          Text(player.rate.formatted() + "×").monospacedDigit().frame(minHeight: 44)
        }
        .accessibilityLabel("Playback speed")
      }
      Button {
        sheet = .muscles
      } label: {
        VStack(alignment: .leading, spacing: 5) {
          MuscleLine(role: "Primary", groups: player.selectedExercise.primary, color: .coral)
          MuscleLine(role: "Secondary", groups: player.selectedExercise.secondary, color: .amber)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).accessibilityHint("Show all muscle groups")
      HStack {
        Label("Unhighlighted", systemImage: "circle.fill")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Menu("View", systemImage: "camera.rotate") {
          Button("Exercise angle") {
            let c = player.selectedExercise
            send(.orient(yaw: c.cameraYaw, pitch: c.cameraPitch))
          }
          Button("Front") { send(.orient(yaw: 0, pitch: 8)) }
          Button("Side") { send(.orient(yaw: 90, pitch: 8)) }
          Button("Back") { send(.orient(yaw: 180, pitch: 8)) }
          Toggle(
            "Mirror movement",
            isOn: Binding(get: { player.isMirrored }, set: { send(.setMirrored($0)) }))
          Toggle(
            "Show muscle highlights",
            isOn: Binding(get: { player.highlighting }, set: { send(.setHighlighting($0)) }))
        }
      }
    }.padding(.horizontal, 18).padding(.vertical, 12)
  }
}
