import CryptoKit
import ExerciseDummy
import Foundation
import Observation

/// Only display metadata is read here. All EML interpretation belongs to the reference compiler.
struct RecipeHeader: Decodable {
  struct Roles: Decodable { let primary, secondary: [String] }
  struct Cycle: Decodable {
    let mode: String
    let count: Int
  }
  let eml, id, title: String
  let instructions: String?
  let muscles: Roles
  let `repeat`: Cycle
}

struct RecipeEntry: Identifiable {
  let header: RecipeHeader
  let url: URL
  let custom: Bool
  var id: String { (custom ? "mine/" : "catalog/") + header.id }
}

enum StudioError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

@Observable @MainActor
final class RecipeLibrary {
  private(set) var catalog: [RecipeEntry] = []
  private(set) var saved: [RecipeEntry] = []
  private(set) var authoredDrafts: [String: EMLDraft] = [:]
  private(set) var selected: RecipeEntry?
  private(set) var previewSource: String?
  private var previewHeader: RecipeHeader?
  var displayHeader: RecipeHeader? { previewHeader ?? selected?.header }
  private(set) var player: ExercisePlayer?
  private(set) var busy = false
  var problem: String?
  let root: URL
  private let personal: URL
  private let preferences: UserDefaults
  static let limit = 512_000

  init(
    personalDirectory: URL = URL.applicationSupportDirectory.appending(
      path: "My EML", directoryHint: .isDirectory),
    preferences: UserDefaults = .standard
  ) {
    root = Bundle.main.bundleURL.appending(path: "EML", directoryHint: .isDirectory)
    personal = personalDirectory
    self.preferences = preferences
  }

  func open() async {
    guard !busy, player == nil else { return }
    do {
      catalog = try Self.entries(in: root.appending(path: "exercises"), custom: false)
      guard !catalog.isEmpty else {
        throw StudioError.message("The EML catalog is missing from this build.")
      }
      try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
      saved = try Self.entries(in: personal, custom: true)
      for entry in saved {
        if let source = try? Self.read(entry.url) {
          authoredDrafts[entry.id] = readDraft(for: source)
        }
      }
      let remembered = preferences.string(forKey: "eml.selected")
      let initial =
        (catalog + saved).first { $0.id == remembered }
        ?? catalog.first { $0.header.id == "squat" } ?? catalog[0]
      do { try await select(initial) } catch  where initial.custom {
        try await select(catalog.first { $0.header.id == "squat" } ?? catalog[0])
        problem = "Couldn’t reopen the saved exercise: " + error.localizedDescription
      }
    } catch { problem = error.localizedDescription }
  }

  func select(_ entry: RecipeEntry) async throws {
    try await perform {
      let source = try Self.read(entry.url)
      let clip = try await EMLCompiler.compile(source)
      try activate(clip, mode: entry.header.repeat.mode)
      remember(entry)
    }
  }

  func playCustom(_ text: String) async throws {
    try await saveCustom(Data(text.utf8), draft: nil)
  }

  /// Inspect solved frames without adding the document to My EML or changing the remembered exercise.
  func previewCustom(_ text: String) async throws {
    try await perform {
      let (header, clip) = try await Self.prepareCustom(Data(text.utf8), strict: false)
      try activate(clip, mode: header.repeat.mode)
      if let player, let first = player.movementIssues.first { try player.inspectIssue(first) }
      selected = nil
      previewHeader = header
      previewSource = text
    }
  }

  func playAuthored(_ draft: EMLDraft) async throws {
    try await saveCustom(Data(try draft.source().utf8), draft: draft)
  }

  private func saveCustom(_ source: Data, draft: EMLDraft?) async throws {
    try await perform {
      let version = try? JSONDecoder().decode(RecipeHeader.self, from: source).eml
      let (header, clip) = try await Self.prepareCustom(
        source, strict: draft != nil || version == "1.1")
      // A validated EML id is a portable slug. A personal recipe never overwrites a catalog file.
      let url = personal.appendingPathComponent(header.id).appendingPathExtension("json")
      let entry = RecipeEntry(header: header, url: url, custom: true)
      // Save first so a full disk cannot switch the player underneath an unchanged selection.
      let previous = FileManager.default.fileExists(atPath: url.path) ? try Self.read(url) : nil
      // The editable form is app-local. Its key is the exact portable EML, so importing a
      // changed document under the same ID can never reopen an obsolete set of steps.
      let record = draftURL(for: source)
      var editable = draft
      if editable?.identifier.isEmpty == true { editable?.identifier = header.id }
      let createdRecord = draft != nil && !FileManager.default.fileExists(atPath: record.path)
      var committed = false
      defer { if createdRecord && !committed { try? FileManager.default.removeItem(at: record) } }
      if let editable {
        try FileManager.default.createDirectory(
          at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(editable).write(to: record, options: .atomic)
      }
      try source.write(to: url, options: .atomic)
      do { try activate(clip, mode: entry.header.repeat.mode) } catch {
        if let previous {
          try previous.write(to: url, options: .atomic)
        } else {
          try FileManager.default.removeItem(at: url)
        }
        throw error
      }
      committed = true
      authoredDrafts[entry.id] = editable ?? readDraft(for: source)
      if let previous, previous != source {
        try? FileManager.default.removeItem(at: draftURL(for: previous))
      }
      saved = (saved.filter { $0.id != entry.id } + [entry]).sorted {
        $0.header.title < $1.header.title
      }
      remember(entry)
    }
  }

  private func draftURL(for source: Data) -> URL {
    let key = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    return personal.appending(path: "Authoring", directoryHint: .isDirectory)
      .appendingPathComponent(key)
  }

  private func readDraft(for source: Data) -> EMLDraft? {
    guard let data = try? Data(contentsOf: draftURL(for: source)) else { return nil }
    return try? JSONDecoder().decode(EMLDraft.self, from: data)
  }

  /// Export checks the same input as playback, without saving a recipe or replacing the model.
  func validateCustom(_ source: Data) async throws {
    try await perform { _ = try await Self.prepareCustom(source, strict: true) }
  }

  private static func prepareCustom(_ source: Data, strict: Bool) async throws -> (
    RecipeHeader, Data
  ) {
    let clip = try await EMLCompiler.compile(source, strict: strict)
    return (try JSONDecoder().decode(RecipeHeader.self, from: source), clip)
  }

  private func perform(_ work: () async throws -> Void) async throws {
    guard !busy else { throw StudioError.message("Another exercise is still opening.") }
    busy = true
    defer { busy = false }
    try await work()
  }
  private func activate(_ clip: Data, mode: String) throws {
    let next: ExercisePlayer
    if let player {
      try player.load(compiledClip: clip)
      next = player
    } else {
      next = try ExercisePlayer(emlRoot: root, compiledClip: clip)
      player = next
    }
    next.loopsPreview = mode != "once"
    try next.send(.play)
  }
  private func remember(_ entry: RecipeEntry) {
    previewSource = nil
    previewHeader = nil
    selected = entry
    preferences.set(entry.id, forKey: "eml.selected")
  }
  private static func entries(in directory: URL, custom: Bool) throws -> [RecipeEntry] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map {
        RecipeEntry(
          header: try JSONDecoder().decode(RecipeHeader.self, from: read($0)), url: $0,
          custom: custom)
      }
      .sorted {
        $0.header.title.localizedCaseInsensitiveCompare($1.header.title) == .orderedAscending
      }
  }
  static func read(_ url: URL) throws -> Data {
    // Also bounds a file from a provider whose reported size is unavailable or stale.
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var bytes = Data()
    while let piece = try file.read(upToCount: min(65_536, limit + 1 - bytes.count)), !piece.isEmpty
    {
      bytes.append(piece)
      guard bytes.count <= limit else {
        throw StudioError.message("EML files must be 512 KB or smaller.")
      }
    }
    return bytes
  }

  func starter() throws -> String {
    struct Interface: Decodable { let example: String }
    let manifest = try JSONDecoder().decode(Interface.self, from: Self.read(root.appending(path: "interface.json")))
    let url = root.appending(path: manifest.example)
    return String(decoding: try Self.read(url), as: UTF8.self)
  }
}
