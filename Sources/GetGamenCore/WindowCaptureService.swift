import Foundation
import CoreGraphics
import ScreenCaptureKit

/// Internal adapter target; test targets never represent proof of a native picker selection.
@MainActor
struct WindowCaptureTarget {
    let geometry: () throws -> (CGRect, Double)
    let capture: (SCStreamConfiguration) async throws -> CGImage
    var copiesToClipboard = false
}

@MainActor
enum WindowPickerEvent {
    case selected(WindowCaptureTarget)
    case cancelled
    case failed(Error)
}

@MainActor
struct WindowCaptureDependencies {
    /// Acquires a picker session and returns its idempotent cleanup operation.
    let begin: ([Int], @escaping @MainActor (WindowPickerEvent) -> Void) throws -> (@MainActor () -> Void)

    static var native: Self {
        Self { exclusions, receive in
            let session = try DirectWindowPickerSession(exclusions: exclusions, receive: receive)
            session.present()
            return { session.close() }
        }
    }
}

@MainActor
public final class WindowCaptureService {
    public struct Selection {
        fileprivate let owner: UUID
        fileprivate let token: UUID
        public let copiesToClipboard: Bool
        fileprivate init(owner: UUID, token: UUID, copiesToClipboard: Bool) {
            self.owner = owner; self.token = token; self.copiesToClipboard = copiesToClipboard
        }
    }

    public enum CaptureError: Error, Equatable, LocalizedError {
        case busy, invalidSelection, invalidGeometry, invalidImage, permissionRequired
        public var errorDescription: String? {
            switch self {
            case .permissionRequired: return "システム設定の「プライバシーとセキュリティ」→「画面収録」でgetGamenを許可してください。"
            case .busy: return "撮影処理が進行中です。"
            case .invalidSelection: return "撮影できるウインドウが見つかりません。選び直してください。"
            case .invalidGeometry: return "ウインドウのサイズを取得できません。"
            case .invalidImage: return "ウインドウの画像を取得できませんでした。"
            }
        }
    }

    private let resources: WindowCaptureResources

    public convenience init() { self.init(dependencies: .native) }

    init(dependencies: WindowCaptureDependencies) {
        resources = WindowCaptureResources(dependencies: dependencies)
    }

    public var didConfirmCapture: (() -> Void)? {
        get { resources.didConfirmCapture }
        set { resources.didConfirmCapture = newValue }
    }

    public func selectWindow(excludingWindowIDs: [Int] = []) async throws -> Selection {
        try await resources.select(exclusions: excludingWindowIDs)
    }

    public func capture(_ selection: Selection, showsCursor: Bool) async throws -> CGImage {
        try await resources.capture(selection, showsCursor: showsCursor)
    }

    public func cancel() { resources.cancel() }

    deinit {
        let resources = resources
        if Thread.isMainThread { MainActor.assumeIsolated { resources.cancel() } }
        else { DispatchQueue.main.async { resources.cancel() } }
    }
}

@MainActor
private final class WindowCaptureResources {
    enum Phase { case selecting, selected, capturing }
    var didConfirmCapture: (() -> Void)?
    let owner = UUID()
    let dependencies: WindowCaptureDependencies
    var token: UUID?
    var phase: Phase?
    var target: WindowCaptureTarget?
    var selectionContinuation: CheckedContinuation<WindowCaptureService.Selection, Error>?
    var cleanup: (@MainActor () -> Void)?

    init(dependencies: WindowCaptureDependencies) { self.dependencies = dependencies }

    func select(exclusions: [Int]) async throws -> WindowCaptureService.Selection {
        try Task.checkCancellation()
        guard token == nil else { throw WindowCaptureService.CaptureError.busy }
        let request = UUID()
        token = request
        phase = .selecting
        let selected: WindowCaptureService.Selection = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                selectionContinuation = continuation
                if Task.isCancelled { cancel(request: request); return }
                do {
                    let release = try dependencies.begin(exclusions) { [weak self] event in
                        self?.receive(event, request: request)
                    }
                    // A dependency can synchronously fail/cancel during presentation.
                    if token == request { cleanup = release } else { release() }
                } catch {
                    finish(error: error, request: request)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request: request) }
        }
        if Task.isCancelled {
            cancel(request: request)
            throw CancellationError()
        }
        guard token == request, phase == .selected else { throw CancellationError() }
        return selected
    }

    func receive(_ event: WindowPickerEvent, request: UUID) {
        guard token == request, phase == .selecting else { return }
        switch event {
        case .selected(let picked):
            didConfirmCapture?()
            target = picked
            phase = .selected
            let continuation = selectionContinuation
            selectionContinuation = nil
            continuation?.resume(returning: WindowCaptureService.Selection(owner: owner, token: request, copiesToClipboard: picked.copiesToClipboard))
        case .cancelled:
            finish(error: CancellationError(), request: request)
        case .failed(let error):
            finish(error: error, request: request)
        }
    }

    func capture(_ selection: WindowCaptureService.Selection, showsCursor: Bool) async throws -> CGImage {
        guard selection.owner == owner, selection.token == token, phase == .selected, let target else {
            throw WindowCaptureService.CaptureError.invalidSelection
        }
        let request = selection.token
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let (rect, scale) = try target.geometry()
                let configuration = try WindowCaptureGeometry.configuration(contentRect: rect,
                                                                             pointPixelScale: scale,
                                                                             showsCursor: showsCursor)
                phase = .capturing
                let image = try await target.capture(configuration)
                guard token == request, phase == .capturing else { throw CancellationError() }
                try Task.checkCancellation()
                guard image.width > 0, image.height > 0 else { throw WindowCaptureService.CaptureError.invalidImage }
                finish(error: nil, request: request)
                return image
            } catch {
                // Explicit cancellation takes priority over a late native error as well as success.
                let cancelled = token != request || Task.isCancelled
                finish(error: error, request: request)
                if cancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request: request) }
        }
    }

    func cancel() {
        if let token { cancel(request: token) }
    }

    func cancel(request: UUID) { finish(error: CancellationError(), request: request) }

    private func finish(error: Error?, request: UUID) {
        guard token == request else { return }
        token = nil
        phase = nil
        target = nil
        let continuation = selectionContinuation
        selectionContinuation = nil
        let release = cleanup
        cleanup = nil
        release?()
        continuation?.resume(throwing: error ?? CancellationError())
    }
}
