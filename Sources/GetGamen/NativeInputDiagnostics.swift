#if DEBUG
import AppKit

/// Explicit UI-test fixture in the real app process. Never used on a normal launch.
@MainActor
final class NativeInputDiagnostics: NSObject {
    private let window: NSWindow
    private let field = NSTextField(string: "")
    init(routing: AppCommandRouting) throws {
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 440,height: 220),
                          styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Native input probe"; window.isReleasedWhenClosed = false
        field.frame = NSRect(x: 20,y: 140,width: 390,height: 30)
        field.setAccessibilityIdentifier("native-input")
        window.contentView?.addSubview(field)
        for (index, item) in [("Marked text", #selector(marked)), ("Sheet", #selector(sheet)), ("Modal", #selector(modal))].enumerated() {
            let button = NSButton(title: item.0, target: self, action: item.1)
            button.frame = NSRect(x: 20 + index * 130,y: 70,width: 120,height: 32)
            window.contentView?.addSubview(button)
        }
        var map = routing.bindings
        map[.settings] = .assigned(.init(keyCode: 1, modifiers: 0))
        try routing.replaceBindings(map)
        window.center(); window.makeKeyAndOrderFront(nil); field.selectText(nil)
    }
    @objc private func marked() {
        field.selectText(nil)
        (window.firstResponder as? NSTextView)?.setMarkedText("かな", selectedRange: NSRange(location: 2,length: 0),
            replacementRange: NSRange(location: NSNotFound,length: 0))
    }
    @objc private func sheet() {
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 340,height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextField(string: "sheet")
        text.frame = NSRect(x: 15,y: 50,width: 300,height: 25); panel.contentView?.addSubview(text)
        let button = NSButton(title: "Done", target: self, action: #selector(endSheet(_:)))
        button.frame = NSRect(x: 230,y: 10,width: 80,height: 25); panel.contentView?.addSubview(button)
        window.beginSheet(panel); text.selectText(nil)
    }
    @objc private func endSheet(_ sender: NSButton) { if let sheet = sender.window { window.endSheet(sheet) } }
    @objc private func modal() {
        let alert = NSAlert(); alert.messageText = "Native modal probe"; alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
#endif
