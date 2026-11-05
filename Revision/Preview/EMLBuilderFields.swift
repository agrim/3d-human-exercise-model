import SwiftUI

func authoringName(_ id: String) -> String {
  id.replacingOccurrences(of: "-", with: " ")
    .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    .localizedCapitalized
}

/// Upper/lower library prefixes distinguish symbols in EML; they are not movement cues.
func movementName(_ id: String, family: String?) -> String {
  if family == "Lower body", id.hasPrefix("lower-") {
    return authoringName(String(id.dropFirst(6)))
  }
  if family == "Upper body", id.hasPrefix("upper-") {
    return authoringName(String(id.dropFirst(6)))
  }
  return authoringName(id)
}

/// Search the displayed names and the underlying portable EML identifiers.
struct AuthoringChoices: View {
  private struct Choice: Identifiable {
    let id, name: String
    let family: String?
  }
  let title: String
  private let choices: [Choice]
  private let grouped: Bool
  private let compatible: Set<String>
  var current: String?
  let pick: (String) -> Void
  @State private var search = ""
  @Environment(\.dismiss) private var dismiss

  init(
    title: String, choices: [String], families: [String: String] = [:], current: String? = nil,
    compatible: Set<String> = [],
    pick: @escaping (String) -> Void
  ) {
    self.title = title
    self.current = current
    self.pick = pick
    self.grouped = !families.isEmpty
    self.compatible = compatible
    self.choices = choices.map { id in
      Choice(id: id, name: movementName(id, family: families[id]), family: families[id])
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    let matches = choices.filter {
      search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)
        || $0.name.localizedCaseInsensitiveContains(search)
    }
    List {
      if !grouped {
        rows(matches)
      } else {
        let tested = matches.filter { compatible.contains($0.id) }
        if !tested.isEmpty {
          Section("Tested from this starting pose") { rows(tested) }
        }
        let sections = Dictionary(grouping: matches.filter { !compatible.contains($0.id) }) {
          $0.family ?? "Other movements"
        }
        ForEach(sections.keys.sorted(), id: \.self) { group in
          Section(group) { rows(sections[group] ?? []) }
        }
      }
    }
    .overlay { if matches.isEmpty { ContentUnavailableView.search(text: search) } }
    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search, prompt: "Search \(title.lowercased())")
  }

  @ViewBuilder private func rows(_ choices: [Choice]) -> some View {
    ForEach(choices) { choice in
      Button {
        pick(choice.id)
        dismiss()
      } label: {
        HStack {
          Text(choice.name)
          Spacer()
          if current == choice.id { Image(systemName: "checkmark") }
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(current == choice.id ? .isSelected : [])
      .accessibilityIdentifier("builder.choice." + choice.id)
    }
  }
}

struct AuthoringNumber: View {
  let label: String
  @Binding var number: Double
  var id: String?
  var signed = true
  var body: some View {
    LabeledContent(label) {
      TextField(label, value: $number, format: .number.precision(.fractionLength(0...6)))
        .multilineTextAlignment(.trailing)
        .keyboardType(signed ? .numbersAndPunctuation : .decimalPad)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id ?? label)
    }
  }
}

struct AuthoringJoints: View {
  @Binding var edits: [EMLJointEdit]
  let vocabulary: EMLVocabulary
  var body: some View {
    Section("Joint angles") {
      ForEach($edits) { $edit in
        NavigationLink {
          Form {
            Section {
              NavigationLink {
                AuthoringChoices(title: "Joints", choices: vocabulary.joints, current: edit.joint) {
                  edit.joint = $0
                }
              } label: {
                LabeledContent("Joint", value: authoringName(edit.joint))
              }
              Picker("Axis", selection: $edit.axis) {
                ForEach(["x", "y", "z"], id: \.self) { Text($0.uppercased()).tag($0) }
              }
              AuthoringNumber(label: "Angle (degrees)", number: $edit.degrees)
              Toggle("Adjustable angle", isOn: $edit.adjustable)
            } footer: {
              Text("Joint angles are relative to the parent joint.")
            }
          }.navigationTitle("Joint angle").navigationBarTitleDisplayMode(.inline)
        } label: {
          LabeledContent(
            authoringName(edit.joint),
            value: "\(edit.axis.uppercased()) · \(edit.degrees.formatted())°")
        }
      }.onDelete { edits.remove(atOffsets: $0) }
      NavigationLink {
        AuthoringChoices(title: "Joints", choices: vocabulary.joints) { joint in
          edits.append(EMLJointEdit(joint: joint))
        }
      } label: {
        Label("Add joint angle", systemImage: "plus")
      }
      .accessibilityIdentifier("builder.addJoint")
    }
  }
}

/// A point stays at its position in the starting pose. Selecting two points on
/// the same foot also controls its orientation without inventing a floor height.
struct AuthoringContacts: View {
  @Binding var points: Set<String>?
  let choices: [String]
  var inherited: Set<String>? = nil

  var body: some View {
    Form {
      if let inherited {
        Toggle("Use exercise contacts", isOn: Binding(
          get: { points == nil }, set: { points = $0 ? nil : inherited }))
      }
      Section {
        ForEach(choices, id: \.self) { point in
          Toggle(authoringName(point), isOn: Binding(
            get: { (points ?? inherited ?? []).contains(point) },
            set: { selected in
              var next = points ?? inherited ?? []
              if selected { next.insert(point) } else { next.remove(point) }
              points = next
            }))
        }
        .disabled(inherited != nil && points == nil)
      } footer: {
        Text("Keep each selected point at its starting position during movement. For a planted foot, select both its heel and its ball.")
      }
    }
    .navigationTitle("Fixed points").navigationBarTitleDisplayMode(.inline)
  }
}

struct AuthoringSetup: View {
  @Binding var draft: EMLDraft
  let vocabulary: EMLVocabulary
  var body: some View {
    Form {
      Section {
        NavigationLink {
          AuthoringChoices(title: "Poses", choices: vocabulary.poses, current: draft.startPose) {
            draft.startPose = $0
          }
        } label: {
          LabeledContent("Pose", value: authoringName(draft.startPose))
        }
        Picker("Stance width", selection: $draft.stanceWidth) {
          Text("Use pose").tag("")
          Text("Hip width").tag("hip-width")
          Text("Shoulder width").tag("shoulder-width")
        }
        if !draft.stanceWidth.isEmpty {
          AuthoringNumber(label: "Toe angle (degrees)", number: $draft.toeOut)
        }
      }
      AuthoringJoints(edits: $draft.startJoints, vocabulary: vocabulary)
      Section {
        NavigationLink {
          AuthoringContacts(points: $draft.fixedPoints, choices: vocabulary.contactPoints)
        } label: {
          LabeledContent("Fixed points", value: "\(draft.fixedPoints?.count ?? 0) selected")
        }
      }
    }.navigationTitle("Starting pose").navigationBarTitleDisplayMode(.inline)
  }
}

struct AuthoringPhase: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var step: EMLPhaseDraft
  let mode: EMLRepeatMode
  let startingPose: String
  let exercisePoints: Set<String>
  let exerciseRoles: EMLMuscleRoles
  let vocabulary: EMLVocabulary
  var body: some View {
    Form {
      Section("Step") {
        TextField("Step name", text: $step.name).accessibilityIdentifier("builder.stepName")
        AuthoringNumber(
          label: "Duration (seconds)", number: $step.seconds,
          id: "builder.stepSeconds", signed: false)
        Toggle("Adjustable duration", isOn: $step.adjustableDuration)
        Picker("Transition", selection: $step.ease) {
          ForEach(["smooth", "linear", "ease-in", "ease-out"], id: \.self) {
            Text(authoringName($0)).tag($0)
          }
        }
      }
      if mode != .hold {
        Section {
          Toggle("Hold previous position", isOn: $step.holdsPrevious)
            .disabled(!step.actions.isEmpty || !step.joints.isEmpty)
        } footer: {
          if step.holdsPrevious {
            Text("The model stays at the previous step’s position for this duration.")
          }
        }
      }
      if !step.holdsPrevious && (mode != .hold || !step.actions.isEmpty || !step.joints.isEmpty) {
        Section {
          ForEach($step.actions) { $action in
            NavigationLink {
              Form {
                NavigationLink {
                  AuthoringChoices(
                    title: "Movements", choices: vocabulary.motions,
                    families: vocabulary.motionFamilies, current: action.motion,
                    compatible: vocabulary.compatibleMotions[startingPose] ?? []
                  ) {
                    action.motion = $0
                  }
                } label: {
                  LabeledContent(
                    "Movement",
                    value: movementName(
                      action.motion, family: vocabulary.motionFamilies[action.motion]))
                }
                Section {
                  AuthoringNumber(label: "Amount", number: $action.amount)
                  Toggle("Adjustable amount", isOn: $action.adjustable)
                } footer: {
                  Text(
                    "Use 1 for the full movement, 0 for none, or a negative value to reverse it.")
                }
              }.navigationTitle("Movement").navigationBarTitleDisplayMode(.inline)
            } label: {
              LabeledContent(
                movementName(action.motion, family: vocabulary.motionFamilies[action.motion]),
                value: action.amount.formatted() + "×")
            }
          }.onDelete { step.actions.remove(atOffsets: $0) }
          NavigationLink {
            AuthoringChoices(
              title: "Movements", choices: vocabulary.motions,
              families: vocabulary.motionFamilies,
              compatible: vocabulary.compatibleMotions[startingPose] ?? []
            ) {
              step.actions.append(EMLActionDraft(motion: $0))
            }
          } label: {
            Label("Add movement", systemImage: "plus")
          }
          .accessibilityIdentifier("builder.addMovement")
        } header: {
          Text("Movements")
        } footer: {
          Text("Movements in one step happen together. An empty step returns to the starting pose.")
        }
        AuthoringJoints(edits: $step.joints, vocabulary: vocabulary)
      }
      Section {
        NavigationLink {
          AuthoringContacts(points: $step.fixedPoints, choices: vocabulary.contactPoints, inherited: exercisePoints)
        } label: {
          LabeledContent("Fixed points", value: step.fixedPoints.map { "\($0.count) selected" } ?? "Use exercise contacts")
        }
        NavigationLink {
          AuthoringMuscles(roles: stepRoles, inherit: usesExerciseRoles, vocabulary: vocabulary)
        } label: {
          LabeledContent("Muscle roles", value: roleDescription)
        }
        .accessibilityIdentifier("builder.stepRoles")
      }
      if mode == .hold {
        Section {
          Text("This exercise stays in its starting pose. Edit joint angles under Starting pose.")
        }
      }
    }.navigationTitle("Edit step").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("builder.finishStep")
        }
      }
  }
  private var stepRoles: Binding<EMLMuscleRoles> {
    Binding(get: { step.muscleOverride ?? exerciseRoles }, set: { step.muscleOverride = $0 })
  }
  private var usesExerciseRoles: Binding<Bool> {
    Binding(
      get: { step.muscleOverride == nil },
      set: { inherit in
        step.muscleOverride = inherit ? nil : exerciseRoles
      })
  }
  private var roleDescription: String {
    guard let roles = step.muscleOverride else { return "Use exercise roles" }
    let count = roles.primary.count + roles.secondary.count
    return count == 0 ? "Unhighlighted" : "\(count) selected"
  }
}

struct AuthoringMuscles: View {
  @Binding var roles: EMLMuscleRoles
  var inherit: Binding<Bool>?
  let vocabulary: EMLVocabulary
  @State private var search = ""

  var body: some View {
    let matches = vocabulary.muscles.filter {
      search.isEmpty || authoringName($0).localizedCaseInsensitiveContains(search)
    }
    List {
      if let inherit {
        Section {
          Toggle("Use exercise roles", isOn: inherit)
            .accessibilityIdentifier("builder.inheritRoles")
        }
      }
      if inherit?.wrappedValue == true {
        Section {
          LabeledContent("Primary", value: groupNames(roles.primary))
          LabeledContent("Secondary", value: groupNames(roles.secondary))
        } footer: {
          Text("Turn off “Use exercise roles” to change the highlights for this step.")
        }
      } else {
        Section {
          ForEach(matches, id: \.self) { muscle in
            Picker(authoringName(muscle), selection: role(muscle)) {
              Text("Unhighlighted").tag(0)
              Text("Primary").tag(1)
              Text("Secondary").tag(2)
            }.pickerStyle(.menu).accessibilityIdentifier("builder.role." + muscle)
          }
        } footer: {
          Text("Each muscle has one role. Other muscles stay unhighlighted.")
        }
        if inherit != nil, !roles.primary.isEmpty || !roles.secondary.isEmpty {
          Section { Button("Unhighlight all muscles") { roles = EMLMuscleRoles() } }
        }
      }
    }.navigationTitle("Muscle roles").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: "Search muscles")
  }
  private func groupNames(_ groups: Set<String>) -> String {
    groups.isEmpty ? "None" : groups.sorted().map(authoringName).joined(separator: ", ")
  }
  private func role(_ name: String) -> Binding<Int> {
    Binding {
      roles.primary.contains(name) ? 1 : roles.secondary.contains(name) ? 2 : 0
    } set: { value in
      var updated = roles
      updated.primary.remove(name)
      updated.secondary.remove(name)
      if value == 1 { updated.primary.insert(name) }
      if value == 2 { updated.secondary.insert(name) }
      roles = updated
    }
  }
}

struct AuthoringEquipment: View {
  @Binding var items: [EMLEquipmentDraft]
  let vocabulary: EMLVocabulary
  var body: some View {
    List {
      ForEach($items) { $item in
        NavigationLink {
          Form {
            Picker("Placement", selection: $item.hand) {
              Text("In scene").tag("")
              if vocabulary.handheldEquipment.contains(item.kind) {
                Text("Left hand").tag("leftHand")
                Text("Right hand").tag("rightHand")
              }
            }
            if item.hand.isEmpty {
              Section("Position in metres") {
                AuthoringNumber(label: "Left (X)", number: $item.x)
                AuthoringNumber(label: "Up (Y)", number: $item.y)
                AuthoringNumber(label: "Forward (Z)", number: $item.z)
              }
            }
          }.navigationTitle(authoringName(item.kind)).navigationBarTitleDisplayMode(.inline)
        } label: {
          LabeledContent(
            authoringName(item.kind),
            value: item.hand.isEmpty ? "In scene" : authoringName(item.hand))
        }
      }.onDelete { items.remove(atOffsets: $0) }
      NavigationLink {
        AuthoringChoices(title: "Equipment", choices: vocabulary.equipment) { kind in
          let hand = vocabulary.handheldEquipment.contains(kind) ? "rightHand" : ""
          items.append(EMLEquipmentDraft(kind: kind, hand: hand))
        }
      } label: {
        Label("Add equipment", systemImage: "plus")
      }
    }.navigationTitle("Equipment").navigationBarTitleDisplayMode(.inline)
  }
}
