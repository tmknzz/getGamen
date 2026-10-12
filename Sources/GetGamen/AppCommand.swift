import Carbon
import GetGamenCore

enum AppCommand: String, CaseIterable, Codable {
    case chooser, captureWindow, captureRegion, capturePrevious
    case captureScroll, openImages, batchConvert
    case toolSelect, toolRectangle, toolRounded, toolCircle, toolEllipse, toolMask, toolMosaic, toolCrop
    case undoEdit, redoEdit
    case copyImage, selectAll, deleteSelection, resetCrop, fitAll, fitWidth, actualPixels
    case scrollPause, scrollFinish
    case captureCancel, settings, closeWindow, quit, hide, minimize

    var isAvailable: Bool {
        switch self {
        case .captureScroll, .scrollPause, .scrollFinish: return false
        default: return true
        }
    }

    static var available: [AppCommand] { allCases.filter(\.isAvailable) }

    enum Scope { case globalCapture, localApplication }

    var scope: Scope {
        switch self {
        case .chooser, .captureWindow, .captureRegion, .capturePrevious, .captureScroll: return .globalCapture
        default: return .localApplication
        }
    }

    var title: String {
        switch self {
        case .captureScroll: return "スクロール撮影"
        case .openImages: return "画像を開く…"
        case .batchConvert: return "一括形式変換…"
        case .toolSelect: return "選択ツール"
        case .toolRectangle: return "四角の枠"
        case .toolRounded: return "角丸の枠"
        case .toolCircle: return "丸の枠"
        case .toolEllipse: return "楕円の枠"
        case .toolMask: return "マスク"
        case .toolMosaic: return "モザイク"
        case .toolCrop: return "クロップ"
        case .undoEdit: return "取り消す"
        case .redoEdit: return "やり直す"
        case .copyImage: return "画像をコピー"
        case .selectAll: return "すべて選択"
        case .deleteSelection: return "選択を削除"
        case .resetCrop: return "クロップ解除"
        case .fitAll: return "全体表示"
        case .fitWidth: return "幅に合わせる"
        case .actualPixels: return "実ピクセル / 100%"
        case .scrollPause: return "スクロール撮影を一時停止／再開"
        case .scrollFinish: return "スクロール撮影を完了"
        case .chooser: return "撮影方法を選ぶ"
        case .captureWindow: return "ウインドウを撮影"
        case .captureRegion: return "範囲を選んで撮影"
        case .capturePrevious: return "前回と同じ範囲を撮影"
        case .captureCancel: return "撮影を取り消す"
        case .settings: return "設定…"
        case .closeWindow: return "ウインドウを閉じる"
        case .quit: return "getGamenを終了"
        case .hide: return "getGamenを隠す"
        case .minimize: return "しまう"
        }
    }

    static var defaultBindings: [AppCommand: CommandBinding] {
        let captureModifiers = UInt32(controlKey | optionKey | cmdKey)
        var result = Dictionary(uniqueKeysWithValues: allCases.map { ($0, CommandBinding.unassigned) })
        let assigned: [AppCommand: CommandBinding] = [
            .captureScroll: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: captureModifiers)),
            .openImages: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey))),
            .undoEdit: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))),
            .redoEdit: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey))),
            .copyImage: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))),
            .selectAll: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))),
            .deleteSelection: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_Delete), modifiers: 0)),
            .chooser: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: captureModifiers)),
            .captureWindow: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: captureModifiers)),
            .captureRegion: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: captureModifiers)),
            .capturePrevious: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: captureModifiers)),
            .captureCancel: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)),
            .settings: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey))),
            .closeWindow: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey))),
            .quit: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))),
            .hide: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey))),
            .minimize: .assigned(HotKeyShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)))
        ]
        result.merge(assigned) { _, new in new }
        return result
    }
}

enum CommandBinding: Equatable, Codable {
    case assigned(HotKeyShortcut)
    case unassigned
}

