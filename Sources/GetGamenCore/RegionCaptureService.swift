import AppKit
import ScreenCaptureKit

public enum RegionCaptureError: Error, Equatable {
    case permissionRequired, busy, invalidExclusions, missingExcludedWindow(Int)
    case staleRequest, unavailableDisplay, invalidImage, compositionFailed
}

@MainActor
public final class RegionCaptureService {
    @MainActor
    public final class PreparedExclusions {
        fileprivate let owner: UUID
        fileprivate let token: UUID
        fileprivate let lease: RegionExclusionLease
        fileprivate var consumed = false
        fileprivate init(owner: UUID, token: UUID, lease: RegionExclusionLease) {
            self.owner = owner; self.token = token; self.lease = lease
        }
    }

    private let owner = UUID()
    private let dependencies: RegionCaptureDependencies
    private var active: UUID?

    public convenience init() { self.init(dependencies: .native) }
    init(dependencies: RegionCaptureDependencies) { self.dependencies = dependencies }

    public func requestAuthorizationForUserAction() -> Bool {
        if dependencies.preflight() { return true }
        _ = dependencies.request()
        return dependencies.preflight()
    }

    public func snapshot() async throws -> [RegionDisplay] {
        try Task.checkCancellation()
        try permission()
        do {
            let snapshot = try await dependencies.snapshot()
            try Task.checkCancellation()
            try permission()
            return snapshot.displays
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    public func prepareExclusions(windows: [NSWindow]) async throws -> PreparedExclusions {
        try await prepareExclusions(windows: windows, onAcquired: { _ in })
    }

    func prepareExclusions(windows: [NSWindow],
                           onAcquired: (@escaping @MainActor () -> Void) -> Void) async throws -> PreparedExclusions {
        try Task.checkCancellation()
        guard active == nil else { throw RegionCaptureError.busy }
        try permission()
        let token = UUID()
        active = token
        onAcquired { [weak self] in self?.cancel(token: token) }
        return try await withTaskCancellationHandler {
            do {
                try current(token)
                let lease = try await dependencies.prepare(windows)
                try current(token)
                try lease.validate()
                return PreparedExclusions(owner: owner, token: token, lease: lease)
            } catch {
                let cancelled = active != token || Task.isCancelled
                finish(token)
                if cancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(token: token) }
        }
    }

    public func capture(selection: RegionSelection, exclusions: PreparedExclusions,
                        showsCursor: Bool) async throws -> CGImage {
        guard exclusions.owner == owner, active == exclusions.token, !exclusions.consumed else {
            throw RegionCaptureError.invalidExclusions
        }
        let token = exclusions.token
        exclusions.consumed = true
        return try await withTaskCancellationHandler {
            defer { finish(token) }
            do {
                try current(token)
                try exclusions.lease.validate()
                let initial = try await dependencies.snapshot()
                try current(token)
                try exclusions.lease.validate()
                let plan = try RegionGeometry.plan(selection: selection, displays: initial.displays)
                var images: [String: CGImage] = [:]
                for tile in plan.tiles {
                    let snapshot = try await checkedSnapshot(token: token, selection: selection,
                                                             plan: plan, lease: exclusions.lease)
                    let configuration = PlatformSupport.captureConfiguration(showsCursor: showsCursor)
                    configuration.sourceRect = CGRect(x: tile.sourceRect.x, y: tile.sourceRect.y,
                                                      width: tile.sourceRect.width, height: tile.sourceRect.height)
                    configuration.width = tile.pixelSize.width
                    configuration.height = tile.pixelSize.height
                    let image = try await snapshot.capture(tile.displayID, exclusions.lease.excludedWindows, configuration)
                    try current(token)
                    try exclusions.lease.validate()
                    _ = try await checkedSnapshot(token: token, selection: selection, plan: plan, lease: exclusions.lease)
                    guard image.width == tile.pixelSize.width, image.height == tile.pixelSize.height else {
                        throw RegionCaptureError.invalidImage
                    }
                    images[tile.displayID] = image
                }
                _ = try await checkedSnapshot(token: token, selection: selection, plan: plan, lease: exclusions.lease)
                let result = try RegionTileCompositor.compose(plan: plan, images: images)
                try current(token)
                return result
            } catch {
                if active != token || Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(token: token) }
        }
    }

    public func cancel() { active = nil }
    private func cancel(token: UUID) { if active == token { active = nil } }
    private func finish(_ token: UUID) { if active == token { active = nil } }
    private func permission() throws {
        guard dependencies.preflight() else { throw RegionCaptureError.permissionRequired }
    }
    private func current(_ token: UUID) throws {
        try Task.checkCancellation()
        guard active == token else { throw CancellationError() }
        try permission()
    }
    private func checkedSnapshot(token: UUID, selection: RegionSelection, plan: RegionCapturePlan,
                                 lease: RegionExclusionLease) async throws -> RegionCaptureSnapshot {
        try current(token)
        try lease.validate()
        let snapshot = try await dependencies.snapshot()
        try current(token)
        try lease.validate()
        // Includes runtime IDs: they may change between attempts, never within this attempt.
        guard try RegionGeometry.plan(selection: selection, displays: snapshot.displays) == plan else {
            throw RegionGeometryError.topologyChanged
        }
        return snapshot
    }
}
