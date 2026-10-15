import SwiftUI

@MainActor
struct CaptureChooserView: View {
    static var width: CGFloat { AppCommand.captureScroll.isAvailable ? 349 : 299 }
    let runtime: AppRuntime
    var selectTimer: @MainActor (Int) -> Void = { _ in }
    let perform: @MainActor (AppCommand) -> Void
    @State private var showsTimerChoices = false
    @AppStorage("getGamen.capture.lastMode") private var lastMode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                captureButton("ウインドウ", symbol: "macwindow", command: .captureWindow, mode: .window)
                if AppCommand.captureScroll.isAvailable {
                    captureButton("スクロール撮影", symbol: "macwindow", command: .captureScroll, mode: .scroll)
                }
                captureButton("範囲", symbol: "rectangle.dashed", command: .captureRegion, mode: .region)
                captureButton("前と同じ範囲", symbol: "arrow.counterclockwise", command: .capturePrevious, mode: .previous)
                Divider().frame(height: 30).padding(.horizontal, 4)
                Button { showsTimerChoices.toggle() } label: {
                    Group {
                        if case .countdown(let remaining) = runtime.activity {
                            Text("\(remaining)")
                                .font(.system(size: 23, weight: .medium)).monospacedDigit()
                                .frame(width: 44, height: 42)
                        } else {
                            Image(systemName: "timer")
                                .font(.system(size: 23, weight: .regular))
                                .frame(width: 44, height: 42)
                                .overlay(alignment: .bottomTrailing) {
                                    if runtime.captureSettings.snapshot.timerSeconds > 0 {
                                        Text("\(runtime.captureSettings.snapshot.timerSeconds)")
                                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                            .padding(.trailing, 2).padding(.bottom, 2)
                                    }
                                }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 7).fill(
                        runtime.captureSettings.snapshot.timerSeconds > 0 ? Color.orange.opacity(0.25) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsTimerChoices, arrowEdge: .bottom) {
                    VStack(spacing: 4) {
                        ForEach([12, 5, 3, 0], id: \.self) { seconds in
                            Button {
                                showsTimerChoices = false
                                selectTimer(seconds)
                            } label: {
                                HStack {
                                    Text(seconds == 0 ? "オフ" : "\(seconds)")
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .opacity(runtime.captureSettings.snapshot.timerSeconds == seconds ? 1 : 0)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6).frame(width: 120)
                }
                .disabled(!canSelect(.window))
                .help("タイマー：12秒・5秒・3秒・オフ")
                .accessibilityLabel("撮影タイマー")
                .accessibilityValue(timerAccessibilityValue)
                Divider().frame(height: 30).padding(.horizontal, 4)
                captureButton("設定", symbol: "gearshape", command: .settings)
            }
            if let message = runtime.failureMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if runtime.failureNeedsReselection {
                    Button("範囲を選び直す") { perform(.captureRegion) }
                }
            }

        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(width: Self.width)
        .background(.regularMaterial)
    }

    private var timerAccessibilityValue: String {
        if case .countdown(let remaining) = runtime.activity { return "残り\(remaining)秒" }
        return runtime.captureSettings.snapshot.timerSeconds > 0
            ? "オン・\(runtime.captureSettings.snapshot.timerSeconds)秒" : "オフ"
    }

    private func captureButton(_ title: String, symbol: String, command: AppCommand, mode: CaptureMode? = nil) -> some View {
        Button { perform(command) } label: {
            Group {
                if mode == .previous {
                    Image(systemName: "rectangle.dashed")
                        .overlay {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                } else if mode == .scroll {
                    Image(systemName: symbol)
                        .overlay {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                                .offset(y: 3)
                        }
                } else {
                    Image(systemName: symbol)
                }
            }
            .font(.system(size: 23, weight: .regular))
            .frame(width: 44, height: 42)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(mode?.rawValue == lastMode ? Color.orange.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect(mode))
        .help(title)
        .accessibilityLabel(title)
    }

    private func canSelect(_ mode: CaptureMode?) -> Bool {
        if runtime.activity == .idle { return true }
        guard mode != nil else { return false }
        switch runtime.activity {
        case .selecting, .countdown, .cancelling: return true
        default: return false
        }
    }

}
