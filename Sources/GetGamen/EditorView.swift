import AppKit
import SwiftUI
import GetGamenCore

@MainActor
struct EditorView: View {
    let session: EditorSession
    let settings: ExportSettings
    @State private var interaction: EditorInteraction
    @State private var viewport = EditorViewport()
    @State private var temporaryQuality: Double
    @State private var editingQuality = false
    @State private var qualityError: String?

    init(session: EditorSession, settings: ExportSettings, interaction: EditorInteraction? = nil, viewport: EditorViewport? = nil) {
        self.session = session; self.settings = settings
        _interaction = State(initialValue: interaction ?? EditorInteraction(session: session))
        _viewport = State(initialValue: viewport ?? EditorViewport())
        _temporaryQuality = State(initialValue: settings.snapshot.jpegQuality)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                controls
                Divider()
                editControls
            }
            .padding(12)
            .background(.bar)
            Divider()
            if let preview = displayedPreview {
                EditorCanvas(image: preview, cropOrigin: cropOrigin, viewport: viewport, interaction: interaction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        if let label = interaction.selectionSizeLabel {
                            Text(label)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(20)
                                .allowsHitTesting(false)
                                .accessibilityLabel("選択範囲のサイズ")
                                .accessibilityValue(label)
                        }
                    }
            } else {
                ContentUnavailableView("画像を表示できません", systemImage: "exclamationmark.triangle",
                    description: Text("編集データの描画に失敗しました。元画像と編集データは保持されています。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onChange(of: settings.snapshot.jpegQuality) { _, quality in
            if !editingQuality { temporaryQuality = quality }
        }
        .onChange(of: session.draft.border) { _, border in
            if let border {
                interaction.borderBrightness = border.brightness
                interaction.borderColor = border.color
                interaction.borderWidth = Double(border.width)
            }
        }
        .disabled(session.isTerminationPending)
    }

    private var editControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { toolButtons; Spacer(minLength: 12); editActions }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { toolButtons }
                    HStack { Spacer(); editActions }
                }
            }
            toolAttributes
            if let message = interaction.errorMessage { Text(message).foregroundStyle(.red) }
        }
    }

    private var toolButtons: some View {
        HStack(spacing: 4) {
            ForEach(EditorInteraction.Tool.allCases.filter { $0 != .none }, id: \.self) { tool in
                Button { interaction.chooseTool(tool) } label: {
                    toolIcon(tool)
                        .font(.system(size: 20))
                        .frame(width: 38, height: 34)
                        .foregroundStyle(interaction.tool == tool ? Color.orange : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(interaction.tool == tool ? Color.orange.opacity(0.18) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.rawValue)
                .accessibilityLabel(tool.rawValue)
                .accessibilityValue(interaction.tool == tool ? "選択中" : "未選択")
                .accessibilityIdentifier("editor-tool-" + tool.symbol)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ツール")
    }

    private var toolbarDivider: some View { Divider().frame(height: 24) }

    private var editActions: some View {
        HStack(spacing: 6) {
            Button { interaction.selectAll() } label: { Image(systemName: "cursorarrow.and.square.on.square.dashed") }
                .help("すべて選択（Command+A）").accessibilityLabel("すべて選択")
            Button { interaction.deleteSelection() } label: { Image(systemName: "trash") }
                .help("選択を削除").accessibilityLabel("選択を削除").disabled(interaction.selected.isEmpty)
            toolbarDivider
            Button { interaction.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("取り消す（Command+Z）").accessibilityLabel("取り消す").disabled(!session.canUndo)
            Button { interaction.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("やり直す（Command+Shift+Z）").accessibilityLabel("やり直す").disabled(!session.canRedo)
        }
        .controlSize(.large)
    }

    private var toolAttributes: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                Text(interaction.tool.rawValue).font(.callout.weight(.medium)).frame(width: interaction.tool == .imageBorder ? 100 : 84, alignment: .leading)
                if interaction.tool == .none {
                    Text("範囲をドラッグ、またはツールを選択")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if interaction.tool == .imageBorder {
                    Toggle("有効", isOn: Binding(get: { session.draft.border != nil }, set: { interaction.setBorder(enabled: $0) }))
                        .toggleStyle(.checkbox)
                }
                if [.select, .rectangle, .rounded, .circle, .ellipse, .imageBorder].contains(interaction.tool) {
                    ColorPicker("枠色", selection: Binding(get: {
                    let c = interaction.tool == .imageBorder
                        ? (interaction.borderColor ?? RGBColor(red: interaction.borderBrightness, green: interaction.borderBrightness, blue: interaction.borderBrightness))
                        : interaction.color
                    return Color(red: c.red, green: c.green, blue: c.blue)
                }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    let c = RGBColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                    if interaction.tool == .imageBorder {
                        interaction.borderColor = c; interaction.setBorder(enabled: true)
                    } else {
                        interaction.color = c; interaction.commitAttributes(.outline)
                    }
                }), supportsOpacity: false)
                if interaction.tool == .imageBorder {
                    lineWidthField(.imageBorder, value: $interaction.borderWidth)
                } else {
                    lineWidthField(.outline, value: $interaction.lineWidth)
                }
                }
                if [.select, .rounded].contains(interaction.tool) {
                    attributeSlider("角丸", value: $interaction.radius, range: 0...100, group: .outline)
                }
                if [.select, .mask].contains(interaction.tool) {
                    ColorPicker("マスク色", selection: Binding(get: {
                        let c = interaction.maskColor ?? RGBColor(red: interaction.brightness, green: interaction.brightness, blue: interaction.brightness)
                        return Color(red: c.red, green: c.green, blue: c.blue)
                    }, set: { value in
                        guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
                        interaction.maskColor = RGBColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
                        interaction.commitAttributes(.mask)
                    }), supportsOpacity: false)
                }
                if [.select, .mosaic].contains(interaction.tool) {
                    attributeSlider("粗さ", value: $interaction.blockSize, range: EditorInteraction.blockSizeRange, group: .mosaic)
                    // Shows the truncated size the renderer uses, not the slider's fractional position.
                    WidthComboBox(rule: .mosaic, label: "粗さ", value: Double(Int(interaction.blockSize))) { size in
                        interaction.blockSize = size
                        commitAttribute(.mosaic)
                    }
                    .frame(width: 64)
                }
                if interaction.tool == .crop {
                    Text("ドラッグで範囲を指定・調整 ／ ⌘Zで取り消す")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(height: 30)
        }
        .scrollIndicators(.hidden)
        .frame(height: 30)
    }

    @ViewBuilder
    private func toolIcon(_ tool: EditorInteraction.Tool) -> some View {
        if tool == .mosaic {
            let shades: [Double] = [0.08, 0.55, 1, 0.75, 1, 0.25, 0.08, 0.55, 0.55, 0.08, 0.75, 1, 0.25, 0.75, 1, 0.08]
            Canvas { context, size in
                let tile = size.width / 4
                for index in shades.indices {
                    let rect = CGRect(x: CGFloat(index % 4) * tile, y: CGFloat(index / 4) * tile,
                                      width: tile, height: tile)
                    context.fill(Path(rect), with: .color(Color(white: shades[index])))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.gray.opacity(0.6), lineWidth: 0.5) }
        } else if tool == .imageBorder {
            Image(systemName: "photo")
                .resizable().frame(width: 24, height: 18)
                .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 2.5) }
        } else if tool == .rounded {
            RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5).frame(width: 24, height: 17)
        } else if tool == .rectangle {
            Rectangle().stroke(lineWidth: 1.5).frame(width: 24, height: 17)
        } else {
            Image(systemName: tool.symbol)
        }
    }

    private func lineWidthField(_ rule: LineWidthRule, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text("線幅").font(.caption).fixedSize()
            WidthComboBox(rule: rule, label: "線幅", value: value.wrappedValue) { width in
                value.wrappedValue = width
                commitAttribute(.outline)
            }
            .frame(width: 64)
            Text("px").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func attributeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, group: EditorInteraction.AttributeGroup) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).fixedSize()
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { commitAttribute(group) }
            }).frame(width: 140)
        }
    }

    private func commitAttribute(_ group: EditorInteraction.AttributeGroup) {
        if interaction.tool == .imageBorder { interaction.setBorder(enabled: true) }
        else { interaction.commitAttributes(group) }
    }

    private var displayedPreview: CGImage? {
        interaction.previewEdits == session.draft ? (interaction.preview ?? session.preview) : session.preview
    }
    private var displayedEdits: EditState? {
        interaction.previewEdits == session.draft ? interaction.previewEdits : session.previewEdits
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { formatControls; Spacer(minLength: 16); zoomControls }
                VStack(alignment: .leading, spacing: 8) { formatControls; zoomControls }
            }
            if session.format == .jpeg {
                HStack {
                    Text("JPG品質")
                    Slider(value: Binding(get: { temporaryQuality }, set: { value in
                        temporaryQuality = value
                        if !editingQuality { commitQuality() }
                    }), in: 0...1, onEditingChanged: { editing in
                        editingQuality = editing
                        if !editing { commitQuality() }
                    }).frame(maxWidth: 250)
                    Text(temporaryQuality.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
            }
            if let qualityError { Text(qualityError).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private var formatControls: some View {
        HStack(spacing: 8) {
            Text("保存形式")
            Picker("保存形式", selection: Binding(get: { session.format }, set: { session.commitFormat($0) })) {
                Text("PNG").tag(ExportFormat.png)
                Text("PNG8").tag(ExportFormat.png8)
                Text("JPG").tag(ExportFormat.jpeg)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 200)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Text("表示").font(.caption).foregroundStyle(.secondary)
            Button("全体") { viewport.select(.fitAll) }.help("全体表示")
            Button("幅") { viewport.select(.fitWidth) }.help("幅に合わせる")
            Button("100%") { viewport.select(.actualPixels) }.help("実ピクセル / 100%")
            Text(zoomLabel).monospacedDigit().foregroundStyle(.secondary).frame(width: 48)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ScrollView(.vertical) {
                status
            }
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            Button("名前を付けて保存…") { interaction.saveAs(jpegQuality: settings.snapshot.jpegQuality) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                .accessibilityIdentifier("editor-save-as")
        }
        .padding(12)
        .background(.bar)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(persistenceText)
                Spacer()
                Text("元画像 \(session.persisted.pixelSize.width) × \(session.persisted.pixelSize.height) px")
                if let image = displayedPreview { Text("表示 \(image.width) × \(image.height) px") }
            }
            if displayedPreview != nil, displayedEdits != session.draft {
                Text("前回描画できた状態を表示しています。未保存の変更はこの画像に反映されていません。")
                    .foregroundStyle(.secondary)
            }
            switch session.issue {
            case .persistence(let error):
                HStack {
                    Text("編集データの保存に失敗: \(error.localizedDescription)").textSelection(.enabled)
                    Button("保存を再試行") { session.retryPending() }.disabled(session.isProcessing)
                }
            case .rendering(let error):
                Text("描画できません: \(error.localizedDescription)").foregroundStyle(.red).textSelection(.enabled)
            case .exportPreparation(let error):
                HStack {
                    Text("書き出しを開始できません: \(error.localizedDescription)").textSelection(.enabled)
                    Button("書き出しを再試行") { session.retryExport() }.disabled(!exportRetryAllowed)
                }
            case nil: EmptyView()
            }
            HStack {
                Text(exportText).textSelection(.enabled)
                if case .failed = session.exportStatus, exportRetryAllowed {
                    Button("書き出しを再試行") { session.retryExport() }
                }
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cropOrigin: CGPoint {
        guard let crop = displayedEdits?.crop else { return .zero }
        return CGPoint(x: CGFloat(crop.x), y: CGFloat(crop.y))
    }
    private var exportRetryAllowed: Bool {
        guard !session.isProcessing else { return false }
        switch session.issue {
        case .rendering, .persistence: return false
        default: return true
        }
    }
    private var persistenceText: String {
        if session.isProcessing { return "編集データを保存中…" }
        if session.hasUnpersistedChanges { return "未保存の変更があります" }
        return "編集データ保存済み"
    }
    private var zoomLabel: String {
        let percent = Double(viewport.magnification * viewport.backingScale * 100)
        guard percent.isFinite else { return "—" }
        return "\(percent.formatted(.number.precision(.fractionLength(0))))%"
    }
    private var exportText: String {
        switch session.exportStatus {
        case .idle: return "まだ書き出していません"
        case .saving: return "書き出し中…"
        case .saved(_, let revision, let url):
            let current = revision == session.persisted.revision && !session.isProcessing && !session.hasUnpersistedChanges
            return "\(current ? "書き出し済み" : "前回の書き出し"): \(url.lastPathComponent)"
        case .failed(_, _, let message): return "書き出し失敗: \(message)"
        }
    }
    private func commitQuality() {
        guard temporaryQuality != settings.snapshot.jpegQuality else { return }
        do { try session.commitJPEGQuality(temporaryQuality); qualityError = nil }
        catch { qualityError = "JPG品質を設定できません: \(error.localizedDescription)" }
    }
}

/// AppKit's combo box (SwiftUI has none): type a width or pick a preset.
/// Commits on Return, focus loss or selection; an unchanged shown value commits nothing.
/// A repeated commit of the same width adds no undo step (EditorSession.commitDraft).
private struct WidthComboBox: NSViewRepresentable {
    let rule: LineWidthRule
    let label: String
    let value: Double
    let commit: (Double) -> Void

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = false
        box.setAccessibilityLabel(label)
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.commitTyped(_:))
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        let items = rule.presets.map(rule.text(for:))
        if box.objectValues as? [String] != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
            box.numberOfVisibleItems = items.count
        }
        // Never overwrite what the user is typing.
        if box.currentEditor() == nil { box.stringValue = rule.text(for: value) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: WidthComboBox

        init(_ parent: WidthComboBox) { self.parent = parent }

        @objc func commitTyped(_ sender: NSComboBox) { commit(sender.stringValue, in: sender) }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            commit(box.stringValue, in: box)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let text = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            commit(text, in: box)
        }

        private func commit(_ text: String, in box: NSComboBox) {
            let rule = parent.rule
            guard let width = rule.value(from: text) else {
                box.stringValue = rule.text(for: parent.value)
                return
            }
            box.stringValue = rule.text(for: width)
            // An existing 3.47 shows as 3.5; leaving "3.5" untouched must not rewrite it.
            guard width != rule.value(from: rule.text(for: parent.value)) else { return }
            parent.commit(width)
        }
    }
}
