import AppKit
import ScreenCaptureKit
import ColorSync

@MainActor
struct RegionCaptureSnapshot {
    let displays: [RegionDisplay]
    let capture: @MainActor (String, [SCWindow], SCStreamConfiguration) async throws -> CGImage
}

@MainActor
struct RegionExclusionLease {
    let excludedWindows: [SCWindow]
    let validate: @MainActor () throws -> Void

}

/// Pure metadata matching shared by the live adapter and native-independent tests.
enum RegionExclusionMatching {
    static func indices(requestedIDs: [Int], windows: [(id: UInt32, processID: Int32?)],
                        processID: Int32) throws -> [Int] {
        var seen = Set<Int>()
        let validatedIDs = try requestedIDs.map { id -> UInt32 in
            guard id > 0, let nativeID = UInt32(exactly: id), seen.insert(id).inserted else {
                throw RegionCaptureError.invalidExclusions
            }
            return nativeID
        }
        return try validatedIDs.map { nativeID in
            let matches = windows.indices.filter { windows[$0].id == nativeID }
            guard matches.count == 1, let index = matches.first, windows[index].processID == processID else {
                throw RegionCaptureError.missingExcludedWindow(Int(nativeID))
            }
            return index
        }
    }
}

@MainActor
struct RegionCaptureDependencies {
    let preflight: @MainActor () -> Bool
    let request: @MainActor () -> Bool
    let snapshot: @MainActor () async throws -> RegionCaptureSnapshot
    let prepare: @MainActor ([NSWindow]) async throws -> RegionExclusionLease

    static var native: Self {
        Self(preflight: { CGPreflightScreenCaptureAccess() }, request: { CGRequestScreenCaptureAccess() },
             snapshot: { try await RegionNativeSnapshot.make() },
             prepare: { try await RegionNativeSnapshot.prepare($0) })
    }
}

struct ScreenFacts: Equatable {
    let runtimeID: UInt32
    let id: String
    let frame: RegionRect
    let backingScaleFactor: Double
    let rotation: Double
    let backingWidth: Int
    let backingHeight: Int
    let mirrorRuntimeID: UInt32
    let inMirrorSet: Bool
}

@MainActor
func currentScreenFacts() throws -> [ScreenFacts] {
    var ids = Set<UInt32>(), persistent = Set<String>()
    return try NSScreen.screens.map { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let runtimeID = UInt32(exactly: number.doubleValue), runtimeID != 0,
              ids.insert(runtimeID).inserted,
              let mode = CGDisplayCopyDisplayMode(runtimeID),
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(runtimeID) else {
            throw RegionCaptureError.unavailableDisplay
        }
        let uuid = unmanaged.takeRetainedValue()
        let id = CFUUIDCreateString(nil, uuid) as String
        guard persistent.insert(id).inserted else { throw RegionGeometryError.invalidDisplayIdentity }
        let frame = screen.frame
        return ScreenFacts(runtimeID: runtimeID, id: id,
                           frame: RegionRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                           backingScaleFactor: Double(screen.backingScaleFactor),
                           rotation: CGDisplayRotation(runtimeID), backingWidth: mode.pixelWidth,
                           backingHeight: mode.pixelHeight, mirrorRuntimeID: CGDisplayMirrorsDisplay(runtimeID),
                           inMirrorSet: CGDisplayIsInMirrorSet(runtimeID) != 0)
    }.sorted { $0.runtimeID < $1.runtimeID }
}

/// Screen notifications also fire without topology changes at launch or for menu bar/Dock changes.
/// Compare only the facts capture geometry depends on.
@MainActor
public final class ScreenChangeFilter {
    private let facts: @MainActor () throws -> [ScreenFacts]
    private let initial: [ScreenFacts]?

    init(facts: @escaping @MainActor () throws -> [ScreenFacts]) {
        self.facts = facts
        initial = try? facts()
    }

    /// Compares against the screens as they are now.
    public convenience init() { self.init(facts: currentScreenFacts) }

    public func changed() -> Bool {
        guard let current = try? facts(), let initial else { return true }
        return current != initial
    }
}

@MainActor
private enum RegionNativeSnapshot {
    static func make() async throws -> RegionCaptureSnapshot {
        let before = try currentScreenFacts()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        let after = try currentScreenFacts()
        guard before == after else { throw RegionGeometryError.topologyChanged }
        var native: [UInt32: SCDisplay] = [:]
        for display in content.displays {
            guard display.displayID != 0, native.updateValue(display, forKey: display.displayID) == nil else {
                throw RegionCaptureError.unavailableDisplay
            }
        }
        let facts = Dictionary(uniqueKeysWithValues: after.map { ($0.runtimeID, $0) })
        var sourceIDs: [UInt32: String] = [:]
        for fact in after where fact.inMirrorSet || fact.mirrorRuntimeID != 0 {
            var current = fact
            var visited = Set<UInt32>()
            while current.mirrorRuntimeID != 0 {
                guard visited.insert(current.runtimeID).inserted,
                      let source = facts[current.mirrorRuntimeID] else {
                    throw RegionGeometryError.invalidDisplayIdentity
                }
                current = source
            }
            guard current.inMirrorSet else { throw RegionGeometryError.invalidDisplayIdentity }
            sourceIDs[fact.runtimeID] = current.id
            sourceIDs[current.runtimeID] = current.id
        }
        var mapping: [String: SCDisplay] = [:]
        let displays = try after.map { fact in
            guard let display = native[fact.runtimeID] else { throw RegionCaptureError.unavailableDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            mapping[fact.id] = display
            return RegionDisplay(id: fact.id, runtimeID: fact.runtimeID, frame: fact.frame,
                                 scale: Double(filter.pointPixelScale), rotation: fact.rotation,
                                 backingWidth: fact.backingWidth, backingHeight: fact.backingHeight,
                                 mirrorSourceID: sourceIDs[fact.runtimeID])
        }
        // Invoke the same topology validation used by planning without trusting native data blindly.
        if let first = displays.first {
            _ = try RegionGeometry.select(drag: first.frame, displays: displays)
        } else { throw RegionCaptureError.unavailableDisplay }
        let retainedMapping = mapping
        return RegionCaptureSnapshot(displays: displays) { id, exclusions, configuration in
            guard let display = retainedMapping[id] else { throw RegionCaptureError.unavailableDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: exclusions)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    static func prepare(_ windows: [NSWindow]) async throws -> RegionExclusionLease {
        var ids = Set<Int>()
        let retained = try windows.map { window -> (NSWindow, Int) in
            let id = window.windowNumber
            guard NSApp.windows.contains(where: { $0 === window }), window.isVisible,
                  id > 0, UInt32(exactly: id) != nil, ids.insert(id).inserted else {
                throw RegionCaptureError.invalidExclusions
            }
            return (window, id)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        let indices = try RegionExclusionMatching.indices(requestedIDs: retained.map { $0.1 },
            windows: content.windows.map { ($0.windowID, $0.owningApplication?.processID) },
            processID: ProcessInfo.processInfo.processIdentifier)
        let descriptors = try zip(retained, indices).map { pair, index -> SCWindow in
            let (window, id) = pair
            guard window.windowNumber == id, window.isVisible,
                  NSApp.windows.contains(where: { $0 === window }) else { throw RegionCaptureError.invalidExclusions }
            return content.windows[index]
        }
        return RegionExclusionLease(excludedWindows: descriptors) {
            for (window, id) in retained {
                guard window.windowNumber == id, NSApp.windows.contains(where: { $0 === window }) else {
                    throw RegionCaptureError.invalidExclusions
                }
            }
        }
    }
}
