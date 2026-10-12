import AppKit

@MainActor
final class AppMenuController: NSObject, NSMenuDelegate {
    let mainMenu: AppCommandMenu
    let statusMenu = NSMenu(title: "getGamen")

    private let routing: AppCommandRouting
    private let execute: @MainActor (AppCommand) -> Void
    private(set) var statusItem: NSStatusItem?
    private let deferDelivery: (@escaping @MainActor () -> Void) -> Void
    private weak var installedApplication: NSApplication?
    private var previousMainMenu: NSMenu?
    private var tracking: MenuSession?
    private var closedUnselected: MenuSession?
    private var acceptedCommands: [AppCommand] = []
    private var deliveryScheduled = false
    private var generation = 0

    private(set) var isInstalled = false
    var isTrackingStatusMenu: Bool { tracking != nil }

    init(routing: AppCommandRouting,
         deferDelivery: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
             Task { @MainActor in await Task.yield(); action() }
         }, execute: @escaping @MainActor (AppCommand) -> Void) {
        self.routing = routing
        self.execute = execute
        self.deferDelivery = deferDelivery
        mainMenu = AppCommandMenu(title: "Main", routing: routing)
        super.init()
        statusMenu.delegate = self
        buildMainMenu()
    }

    func install(in application: NSApplication) {
        guard !isInstalled else { return }
        NSMenuItem.usesUserKeyEquivalents = false
        previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "getGamen")
        item.button?.title = item.button?.image == nil ? "getGamen" : ""
        item.menu = statusMenu
        statusItem = item
        installedApplication = application
        isInstalled = true
    }

    func uninstall() {
        guard isInstalled || tracking != nil || closedUnselected != nil || !acceptedCommands.isEmpty else { return }
        generation &+= 1
        deliveryScheduled = false
        tracking?.invalidate()
        closedUnselected?.invalidate()
        tracking = nil
        closedUnselected = nil
        acceptedCommands.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let application = installedApplication, application.mainMenu === mainMenu {
            application.mainMenu = previousMainMenu
        }
        previousMainMenu = nil
        installedApplication = nil
        isInstalled = false
        statusMenu.removeAllItems()
    }

    func acceptRoutedCommand(_ command: AppCommand) {
        guard routing.isEnabled(command) else { return }
        if tracking != nil {
            acceptedCommands.append(command)
            return
        }
        execute(command)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        closedUnselected?.invalidate()
        closedUnselected = nil
        tracking?.invalidate()
        let session = MenuSession()
        tracking = session
        rebuildStatusMenu(for: session)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu, let session = tracking else { return }
        tracking = nil
        session.closed = true
        if let command = session.command {
            acceptedCommands.append(command)
            session.invalidate()
            scheduleDelivery()
        } else {
            closedUnselected?.invalidate()
            closedUnselected = session
        }
        if !acceptedCommands.isEmpty { scheduleDelivery() }
    }

    private func statusAction(_ command: AppCommand, sessionID: UUID) {
        let session: MenuSession?
        if tracking?.id == sessionID { session = tracking }
        else if closedUnselected?.id == sessionID { session = closedUnselected }
        else { session = nil }
        guard let session, session.command == nil else { return }
        session.command = command
        if session.closed {
            acceptedCommands.append(command)
            closedUnselected = nil
            session.invalidate()
            scheduleDelivery()
        }
    }

    private func scheduleDelivery() {
        guard !deliveryScheduled, tracking == nil, !acceptedCommands.isEmpty else { return }
        deliveryScheduled = true
        let token = generation
        deferDelivery { [weak self] in
            guard let self else { return }
            guard token == self.generation else { return }
            self.deliveryScheduled = false
            guard self.tracking == nil, !self.acceptedCommands.isEmpty else { return }
            let command = self.acceptedCommands.removeFirst()
            if self.routing.isEnabled(command) { self.execute(command) }
            self.scheduleDelivery()
        }
    }

    private func buildMainMenu() {
        let groups: [(String, [AppCommand])] = [
            ("getGamen", [.settings, .hide, .quit]),
            ("撮影", [.chooser, .captureWindow, .captureRegion, .capturePrevious, .captureScroll, .captureCancel, .scrollPause, .scrollFinish]),
            ("ファイル", [.openImages, .batchConvert]),
            ("編集", [.undoEdit, .redoEdit, .copyImage, .toolSelect, .toolRectangle, .toolRounded, .toolCircle, .toolEllipse, .toolMask, .toolMosaic, .toolCrop, .selectAll, .deleteSelection, .resetCrop]),
            ("表示", [.fitAll, .fitWidth, .actualPixels]),
            ("ウインドウ", [.closeWindow, .minimize])
        ]
        for (title, commands) in groups {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = AppCommandMenu(title: title, routing: routing)
            if title == "編集" {
                for (label, selector, key) in [
                    ("テキストを切り取り", "cut:", "x"),
                    ("テキストをコピー", "copy:", "c"),
                    ("テキストを貼り付け", "paste:", "v"),
                    ("テキストをすべて選択", "selectAll:", "a"),
                    ("テキストの変更を取り消す", "undo:", "z")
                ] {
                    submenu.addItem(NativeTextMenuItem(title: label, selector: NSSelectorFromString(selector), key: key))
                }
                submenu.addItem(.separator())
            }
            if title == "getGamen" {
                submenu.addItem(AboutMenuItem())
                submenu.addItem(.separator())
            }
            commands.filter(\.isAvailable).forEach { submenu.addItem(AppCommandMenuItem(command: $0, routing: routing)) }
            parent.submenu = submenu
            mainMenu.addItem(parent)
        }
    }

    private func rebuildStatusMenu(for session: MenuSession) {
        statusMenu.removeAllItems()
        for command in AppCommand.available {
            let target = StatusActionTarget(command: command, sessionID: session.id) { [weak self] command, id in
                self?.statusAction(command, sessionID: id)
            } isEnabled: { [weak self] command in self?.routing.isEnabled(command) ?? false }
            session.targets.append(target)
            let item = NSMenuItem(title: command.title, action: #selector(StatusActionTarget.invoke(_:)), keyEquivalent: "")
            item.target = target
            item.keyEquivalentModifierMask = []
            item.isEnabled = routing.isEnabled(command)
            statusMenu.addItem(item)
        }
    }
}

/// The standard About panel shows the version and the daily build identifier.
@MainActor
private final class AboutMenuItem: NSMenuItem {
    init() {
        super.init(title: "getGamenについて", action: nil, keyEquivalent: "")
        target = self
        action = #selector(showAbout(_:))
    }
    required init(coder: NSCoder) { fatalError("Use init()") }
    @objc private func showAbout(_ sender: Any?) {
        // AppKit fills in CFBundleShortVersionString; only the build identifier is ours.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: Bundle.main.object(forInfoDictionaryKey: "getGamenBuildNumber") as? String ?? "開発版"
        ])
    }
}

/// Standard editing belongs to the active field editor, never the image canvas.
@MainActor
private final class NativeTextMenuItem: NSMenuItem, NSMenuItemValidation {
    private let textAction: Selector
    init(title: String, selector: Selector, key: String) {
        textAction = selector
        super.init(title: title, action: nil, keyEquivalent: key)
        target = self
        action = #selector(invoke(_:))
        keyEquivalentModifierMask = .command
    }
    required init(coder: NSCoder) { fatalError("Use init(title:selector:key:)") }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return text.isEditable || text.isSelectable
    }
    @objc private func invoke(_ sender: Any?) {
        guard validateMenuItem(self), let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        _ = text.tryToPerform(textAction, with: sender)
    }
}

@MainActor
private final class MenuSession {
    let id = UUID()
    var closed = false
    var command: AppCommand?
    var targets: [StatusActionTarget] = []

    func invalidate() {
        targets.forEach { $0.invalidate() }
        targets.removeAll()
    }
}

@MainActor
private final class StatusActionTarget: NSObject, NSMenuItemValidation {
    let command: AppCommand
    let sessionID: UUID
    private var action: (@MainActor (AppCommand, UUID) -> Void)?
    private var enabled: (@MainActor (AppCommand) -> Bool)?

    init(command: AppCommand, sessionID: UUID,
         action: @escaping @MainActor (AppCommand, UUID) -> Void,
         isEnabled: @escaping @MainActor (AppCommand) -> Bool) {
        self.command = command
        self.sessionID = sessionID
        self.action = action
        enabled = isEnabled
    }

    func invalidate() { action = nil; enabled = nil }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled?(command) ?? false }
    @objc func invoke(_ sender: Any?) {
        guard let action, enabled?(command) == true else { return }
        action(command, sessionID)
    }
}
