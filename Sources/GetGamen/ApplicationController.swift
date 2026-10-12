import AppKit
import GetGamenCore

@MainActor
final class ApplicationController {
    let captureSettings: CaptureSettings
    let exportSettings: ExportSettings
    let store: DocumentStore
    let exports: AutomaticExportCoordinator
    let editors: EditorWindowCoordinator
    let runtime: AppRuntime
    let scroll: ScrollCaptureController
    let regionOutline = CapturedRegionOutline()
    let license: LicenseManager
    private let captureSound = CaptureSound()
    private var localKeys: Any?
    private let defaults: UserDefaults
    private(set) var terminating = false
    private var terminationTask: Task<Void, Never>?

    lazy var routing: AppCommandRouting = {
        // The static default map is exhaustively validated by command-contract tests.
        do {
            return try AppCommandRouting(bindings: AppCommand.defaultBindings,
                isEnabled: { [weak self] in self?.isEnabled($0) ?? false },
                perform: { [weak self] in self?.menus.acceptRoutedCommand($0) })
        } catch { preconditionFailure("Invalid built-in command map: \(error)") }
    }()
    lazy var menus = AppMenuController(routing: routing) { [weak self] in self?.execute($0) }
    lazy var chooser = CaptureChooserController(runtime: runtime, defaults: defaults) { [weak self] in self?.routing.perform($0) }
    lazy var shortcuts: ShortcutSettings = {
        let settings = ShortcutSettings(routing: routing, defaults: defaults)
        settings.didChange = { [weak self, weak settings] in
            guard let self else { return }
            if case .assigned(let key) = settings?.bindings[.captureCancel] { self.runtime.cancelShortcut = key }
            else { self.runtime.cancelShortcut = nil }
            self.scroll.cancelShortcut = self.runtime.cancelShortcut
        }
        return settings
    }()
    lazy var settings = SettingsWindowController(capture: captureSettings, export: exportSettings, shortcuts: shortcuts, license: license)
    lazy var library = LibraryController(store: store, editors: editors, settings: exportSettings)

    init(root: URL? = nil, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("getGamen", isDirectory: true)
        license = LicenseManager(directory: root?.appendingPathComponent("License", isDirectory: true) ?? LicenseManager.defaultDirectory)
        captureSettings = CaptureSettings(defaults: defaults)
        exportSettings = ExportSettings(defaults: defaults)
        store = try DocumentStore(root: support.appendingPathComponent("documents"), removesPreviousDocuments: true)
        exports = try AutomaticExportCoordinator(receiptsRoot: support.appendingPathComponent("receipts"),
                                                 discardsPreviousReceipts: true)
        editors = EditorWindowCoordinator(store: store, exports: exports, settings: exportSettings)
        scroll = try ScrollCaptureController(root: support, capture: captureSettings, export: exportSettings, store: store, editors: editors, didConfirmCapture: { [captureSound] in captureSound.play() })
        weak var feedbackRuntime: AppRuntime?
        let regionService = RegionCaptureService()
        let preparation = CapturePreparation(windowService: WindowCaptureService(),
            regionController: RegionSelectionController(captureService: regionService),
            previousController: try PreviousRegionController(captureService: regionService,
                recordURL: support.appendingPathComponent("previous-region.json")),
            didConfirmCapture: { feedbackRuntime?.confirmCapture() })
        let handoff = CapturedDocumentHandoff(store: store, editorWindows: editors)
        let outline = regionOutline
        runtime = AppRuntime(captureSettings: captureSettings, exportSettings: exportSettings,
            cancelShortcut: HotKeyShortcut(keyCode: 53, modifiers: 0),
            prepare: { mode, windows, shortcut in
                outline.clear()
                return try await preparation.prepare(mode: mode, windows: windows, cancelShortcut: shortcut,
                                                     reviewsPrevious: true)
            }, handoff: handoff)
        feedbackRuntime = runtime
    }

    func install() {
        // Starts the trial on first launch and rechecks a stale license in the background.
        Task { [license] in _ = await license.automationState() }
        runtime.didConfirmImmediately = { [weak self] in self?.captureSound.play() }
        runtime.didFinishCountdown = { [weak self] in self?.captureSound.play() }
        editors.willPresentEditor = { [weak self] in self?.regionOutline.clear() }
        runtime.didCompleteRegion = { [weak self] _ in self?.regionOutline.clear() }
        scroll.mayStart = { [weak self] in self?.runtime.activity == .idle }
        chooser.mayShow = { [weak self] in self?.scroll.isActive != true }
        scroll.willStartCapture = { [chooser] in chooser.window.orderOut(nil) }
        menus.install(in: NSApp)
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                return self?.routing.performKeyEquivalent(event) == true
            }
            return handled ? nil : event
        }
        LaunchDiagnostics.shared.observe(chooser.window, role: "main")
        if let window = settings.window { LaunchDiagnostics.shared.observe(window, role: "settings") }
        Task { @MainActor in
            await LaunchDiagnostics.shared.runIfRequested { self.settings.present() }
        }
        shortcuts.install()
        if let message = shortcuts.errorMessage {
            let alert = NSAlert()
            alert.messageText = "ショートカット設定を確認してください"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func uninstall() {
        regionOutline.clear()
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        localKeys = nil
        menus.uninstall()
        do { try shortcuts.close() }
        catch { NSLog("getGamen shortcut cleanup failed: %@", String(describing: error)) }
    }

    private func isEnabled(_ command: AppCommand) -> Bool {
        guard !terminating else { return false }
        guard command.isAvailable else { return false }
        switch command {
        case .chooser, .captureWindow, .captureRegion, .capturePrevious: return runtime.activity == .idle && !scroll.isActive
        case .toolSelect, .toolRectangle, .toolRounded, .toolCircle, .toolEllipse, .toolMask, .toolMosaic, .toolCrop,
             .selectAll, .deleteSelection, .resetCrop, .fitAll, .fitWidth, .actualPixels: return editors.active != nil
        case .undoEdit: return runtime.activity == .idle && editors.active?.0.session.canUndo == true
        case .redoEdit: return runtime.activity == .idle && editors.active?.0.session.canRedo == true
        case .copyImage: return runtime.activity == .idle && editors.active != nil
        case .captureScroll: return runtime.activity == .idle
        case .scrollPause: return runtime.activity == .idle
        case .scrollFinish: return scroll.canFinish
        case .captureCancel: return regionOutline.isVisible || scroll.running || (runtime.activity != .idle && runtime.activity != .cancelling)
        default: return true
        }
    }

    private func execute(_ command: AppCommand) {
        guard isEnabled(command) else { return }
        do {
            switch command {
            case .chooser: chooser.show()
            case .captureWindow: try chooser.start(.window)
            case .captureRegion: try chooser.start(.region)
            case .capturePrevious: try chooser.start(.previous)
            case .captureCancel: if scroll.running { scroll.pause() } else { chooser.cancel(); regionOutline.clear() }
            case .openImages: library.chooseImages()
            case .batchConvert: library.chooseImages(batch: true)
            case .toolSelect: editors.active?.0.chooseTool(.select)
            case .toolRectangle: editors.active?.0.chooseTool(.rectangle)
            case .toolRounded: editors.active?.0.chooseTool(.rounded)
            case .toolCircle: editors.active?.0.chooseTool(.circle)
            case .toolEllipse: editors.active?.0.chooseTool(.ellipse)
            case .toolMask: editors.active?.0.chooseTool(.mask)
            case .toolMosaic: editors.active?.0.chooseTool(.mosaic)
            case .toolCrop: editors.active?.0.chooseTool(.crop)
            case .undoEdit: editors.active?.0.undo()
            case .redoEdit: editors.active?.0.redo()
            case .copyImage: try editors.active?.0.copyImage()
            case .selectAll: editors.active?.0.selectAll()
            case .deleteSelection: editors.active?.0.deleteSelection()
            case .resetCrop: editors.active?.0.resetCrop()
            case .fitAll: editors.active?.1.select(.fitAll)
            case .fitWidth: editors.active?.1.select(.fitWidth)
            case .actualPixels: editors.active?.1.select(.actualPixels)
            case .captureScroll: regionOutline.clear(); chooser.remember(.scroll); scroll.present()
            case .scrollPause: scroll.togglePause()
            case .scrollFinish: scroll.finish()
            case .settings: settings.present()
            case .closeWindow: NSApp.keyWindow?.performClose(nil)
            case .minimize: NSApp.keyWindow?.miniaturize(nil)
            case .hide: NSApp.hide(nil)
            case .quit: NSApp.terminate(nil)
            }
        } catch { showError("操作を完了できません", error: error) }
    }

    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) {
        guard !terminating else { return }
        terminating = true
        library.freeze()
        scroll.freeze()
        shortcuts.freeze()
        runtime.beginTermination()
        editors.beginTermination()
        terminationTask = Task { @MainActor in
            await self.runtime.waitUntilIdle()
            await self.library.waitUntilIdle()
            await self.scroll.waitUntilIdle()
            let sessions = await self.editors.waitForTerminationReadiness()
            let statuses = await self.exports.waitForCurrentWorkers()
            let allowed: Bool
            if sessions.contains(where: { $0.hasUnpersistedChanges }) {
                self.editors.presentDirtyEditors()
                let alert = NSAlert()
                alert.messageText = "未保存の編集があります"
                alert.informativeText = "終了を取り消しました。編集画面で保存の失敗を確認し、再試行してください。"
                alert.addButton(withTitle: "戻る")
                alert.runModal()
                allowed = false
            } else {
                let failed = self.scroll.deliveryFailed || !self.library.failures.isEmpty || statuses.values.contains { if case .failed = $0 { return true }; return false }
                    || sessions.contains { if case .exportPreparation = $0.issue { return true }; return false }
                if failed {
                    let alert = NSAlert()
                    alert.messageText = "書き出せていない画像があります"
                    alert.informativeText = "今回失敗した書き出しは保存されていません。終了すると、書き出せなかった画像の原本と編集情報は次回起動時に削除されます。以前の書き出し画像は残ります。"
                    alert.addButton(withTitle: "戻る")
                    alert.addButton(withTitle: "破棄して終了")
                    allowed = alert.runModal() == .alertSecondButtonReturn
                } else { allowed = true }
            }
            if !allowed {
                self.library.resume()
                self.scroll.resume()
                self.shortcuts.resume()
                self.runtime.endTermination()
                self.editors.endTermination()
                self.terminating = false
            }
            self.terminationTask = nil
            reply(allowed)
        }
    }

    private func showError(_ title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}
