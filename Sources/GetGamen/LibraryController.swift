import AppKit
import UniformTypeIdentifiers
import GetGamenCore

/// Image import and batch conversion entry points from the menu, Finder and the Dock.
@MainActor
final class LibraryController {
    private let store: DocumentStore
    private let editors: EditorWindowCoordinator
    private let settings: ExportSettings
    private let converter = BatchConverter()
    private var task: Task<Void, Never>?
    var busy: Bool { task != nil }
    private(set) var frozen = false
    private(set) var failures: [String] = []

    init(store: DocumentStore, editors: EditorWindowCoordinator, settings: ExportSettings) {
        self.store = store; self.editors = editors; self.settings = settings
    }

    func chooseImages(batch: Bool = false) {
        guard !frozen, !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = batch ? "設定の形式・JPEG品質で変換します。入力画像は保持します。" : "原本をコピーして加工画面を開きます。"
        guard panel.runModal() == .OK else { return }
        if batch { convert(panel.urls) } else { importImages(panel.urls) }
    }

    func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let snapshot = settings.snapshot
        launch { await self.importFiles(urls, snapshot: snapshot) }
    }

    private func importFiles(_ urls: [URL], snapshot: ExportSettingsSnapshot) async {
        var errors: [String] = []
        for url in urls {
            do {
                let stored = try await Task.detached {
                    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let data = try RasterImageDecoder.readFile(url)
                    let image = try RasterImageDecoder.decode(data)
                    return (data, PixelSize(width: image.width, height: image.height))
                }.value
                let document = try await self.store.create(original: stored.0, pixelSize: stored.1)
                do {
                    let session = try await self.editors.openEditor(documentID: document.documentID, initialSettings: snapshot)
                    guard !session.isTerminationPending else { throw EditorWindowError.terminationInProgress }
                    session.requestExport(using: snapshot)
                } catch {
                    errors.append("\(url.lastPathComponent): 編集画面を開けませんでした。\(error.localizedDescription)")
                }
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        self.failures = errors
        if !errors.isEmpty { self.presentResult(errors.joined(separator: "\n")) }
    }

    func convert(_ urls: [URL]) {
        let snapshot = settings.snapshot
        launch {
            let folder = try ExportSettings.prepareDestination(for: snapshot)
            let result = try await self.converter.convert(urls, destination: folder,
                                                          format: snapshot.format, jpegQuality: snapshot.jpegQuality)
            self.failures = result.items.compactMap { item in item.error.map { "\(item.input.lastPathComponent): \($0)" } }
            let completed = result.items.filter { $0.output != nil }.count
            self.presentResult("\(completed)/\(result.items.count)件を変換しました。\n\(result.folder.path)\n" + self.failures.joined(separator: "\n"))
        }
    }

    private func presentResult(_ message: String) {
        guard !frozen else { return }
        let alert = NSAlert()
        alert.messageText = failures.isEmpty ? "処理が完了しました" : "処理を完了できませんでした"
        alert.informativeText = message
        alert.runModal()
    }

    func freeze() { frozen = true }
    func resume() { frozen = false }
    func waitUntilIdle() async { await task?.value }

    private func launch(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !frozen, !busy else { return }
        failures = []
        task = Task { @MainActor in
            defer { self.task = nil }
            do { try await operation() }
            catch { self.failures = [error.localizedDescription]; self.presentResult(error.localizedDescription) }
        }
    }
}

