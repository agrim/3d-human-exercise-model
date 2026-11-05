import SwiftUI
import UniformTypeIdentifiers

struct EMLEditor: View {
  let library: RecipeLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var issue: String?
  @State private var importer = false
  @FocusState private var editingSource: Bool

  var body: some View {
    NavigationStack {
      TextEditor(text: $text)
        .focused($editingSource)
        .scrollDismissesKeyboard(.interactively)
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(.horizontal, 12)
        .accessibilityLabel("Exercise JSON")
        .accessibilityIdentifier("eml.source")
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text("Paste EML JSON").font(.body).foregroundStyle(.secondary)
              .padding(.horizontal, 17).padding(.top, 8)
              .allowsHitTesting(false).accessibilityHidden(true)
          }
        }
        .navigationTitle("Load EML").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(library.busy)
          }
          ToolbarItem(placement: .confirmationAction) {
            if library.busy {
              ProgressView().accessibilityLabel("Preparing exercise")
            } else {
              Button("Save and play") {
                Task {
                  do {
                    try await library.playCustom(text)
                    dismiss()
                  } catch { issue = error.localizedDescription }
                }
              }
              .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("eml.save")
            }
          }
          ToolbarItem(placement: .bottomBar) {
            Menu("Open", systemImage: "folder") {
              Button("Choose file", systemImage: "folder") { importer = true }
              Button("Use example", systemImage: "doc.text") { replace { try library.starter() } }
            }
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("eml.open")
          }
          ToolbarItem(placement: .bottomBar) {
            Button("Preview", systemImage: "eye") {
              editingSource = false
              Task {
                do {
                  try await library.previewCustom(text)
                  dismiss()
                } catch { issue = error.localizedDescription }
              }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("eml.preview")
          }
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { editingSource = false }
              .accessibilityLabel("Dismiss keyboard")
              .accessibilityIdentifier("eml.dismissKeyboard")
          }
        }
        .disabled(library.busy).interactiveDismissDisabled(library.busy)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.json, .plainText, .data]) {
          result in
          replace {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let value = String(data: try RecipeLibrary.read(url), encoding: .utf8)
            else { throw StudioError.message("Choose a UTF-8 JSON document.") }
            return value
          }
        }
        .fileDialogDefaultDirectory(URL.documentsDirectory)
        .alert(
          "Couldn’t load EML",
          isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })
        ) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(issue ?? "")
        }
        .onAppear {
          if text.isEmpty, let preview = library.previewSource {
            text = preview
          } else if text.isEmpty, let entry = library.selected, entry.custom {
            replace { String(decoding: try RecipeLibrary.read(entry.url), as: UTF8.self) }
          }
        }
    }
  }

  private func replace(_ read: () throws -> String) {
    do { text = try read() } catch let error as CocoaError where error.code == .userCancelled {
      return
    } catch { issue = error.localizedDescription }
  }
}
