import AppKit
import Carbon

public struct HotKeyShortcut: Hashable, Codable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey),
                               (.shift, shiftKey), (.option, optionKey), (.control, controlKey)] {
            if flags.contains(flag) { result |= UInt32(carbon) }
        }
        return result
    }
}

public enum HotKeyRegistryError: Error, Equatable {
    case invalidShortcut, duplicateShortcut, reservedSystemShortcut
    case systemShortcutQueryFailed(OSStatus), registrationFailed(OSStatus)
    case handlerInstallationFailed(OSStatus), unregistrationFailed(OSStatus)
    case handlerRemovalFailed(OSStatus), closed, identifierExhausted
}

private let hotKeySignature: OSType = 0x67476D6E // gGmn

@MainActor
private final class HotKeyContext {
    var actions: [UInt32: () -> Void] = [:]
}

// Accessed only on the main thread, including deferred destruction.
@MainActor
private final class HotKeyResources {
    struct Entry {
        let shortcut: HotKeyShortcut
        let eventID: UInt32
        let handle: EventHotKeyRef
    }
    static var nextEventID: UInt64 = 1
    static var pendingCleanup: [HotKeyResources] = []
    let context = HotKeyContext()
    var contextPointer: UnsafeMutableRawPointer?
    var handler: EventHandlerRef?
    var entries: [UInt32: Entry] = [:]
    var orphanedHandles: [EventHotKeyRef] = []
    var closed = false

    func cleanup() throws {
        precondition(Thread.isMainThread)
        closed = true
        context.actions.removeAll()
        var firstError: HotKeyRegistryError?
        for (id, entry) in entries {
            let status = UnregisterEventHotKey(entry.handle)
            if status == noErr { entries.removeValue(forKey: id) }
            else { firstError = firstError ?? .unregistrationFailed(status) }
        }
        orphanedHandles = orphanedHandles.filter { handle in
            let status = UnregisterEventHotKey(handle)
            if status != noErr { firstError = firstError ?? .unregistrationFailed(status) }
            return status != noErr
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status == noErr {
                self.handler = nil
                releaseContext()
            } else { firstError = firstError ?? .handlerRemovalFailed(status) }
        } else { releaseContext() }
        if let firstError { throw firstError }
    }

    private func releaseContext() {
        if let contextPointer {
            Unmanaged<HotKeyContext>.fromOpaque(contextPointer).release()
            self.contextPointer = nil
        }
    }

    static func finish(_ resources: HotKeyResources) {
        do { try resources.cleanup() }
        catch {
            NSLog("getGamen hotkey cleanup failed; resources retained for retry: %@", String(describing: error))
            pendingCleanup.append(resources)
        }
    }

    static func retryPendingCleanup() {
        let pending = pendingCleanup
        pendingCleanup.removeAll()
        for resources in pending { finish(resources) }
    }
}

@MainActor
public final class GlobalHotKeyRegistry {
    private let resources: HotKeyResources

    public init() throws {
        precondition(Thread.isMainThread)
        HotKeyResources.retryPendingCleanup()
        let resources = HotKeyResources()
        self.resources = resources
        let pointer = Unmanaged.passRetained(resources.context).toOpaque()
        resources.contextPointer = pointer
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard Thread.isMainThread, let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == hotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let context = Unmanaged<HotKeyContext>.fromOpaque(userData).takeUnretainedValue()
                guard let action = context.actions[identifier.id] else { return OSStatus(eventNotHandledErr) }
                action()
                return noErr
            }
        }, 1, &type, pointer, &resources.handler)
        guard status == noErr, resources.handler != nil else {
            HotKeyResources.finish(resources)
            throw HotKeyRegistryError.handlerInstallationFailed(status == noErr ? OSStatus(paramErr) : status)
        }
    }

    public var shortcuts: [UInt32: HotKeyShortcut] {
        resources.entries.mapValues(\.shortcut)
    }

    public func register(id: UInt32, shortcut: HotKeyShortcut, action: @escaping () -> Void) throws {
        precondition(Thread.isMainThread)
        guard !resources.closed else { throw HotKeyRegistryError.closed }
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        guard shortcut.keyCode <= UInt32(UInt16.max), shortcut.modifiers & ~allowed == 0 else {
            throw HotKeyRegistryError.invalidShortcut
        }
        let previous = resources.entries[id]
        if let previous, previous.shortcut == shortcut {
            resources.context.actions[previous.eventID] = action
            return
        }
        guard !resources.entries.contains(where: { $0.key != id && $0.value.shortcut == shortcut }) else {
            throw HotKeyRegistryError.duplicateShortcut
        }
        try Self.checkSystemShortcut(shortcut)
        guard HotKeyResources.nextEventID <= UInt64(UInt32.max) else {
            throw HotKeyRegistryError.identifierExhausted
        }
        let eventID = UInt32(HotKeyResources.nextEventID)
        HotKeyResources.nextEventID += 1
        var handle: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: hotKeySignature, id: eventID),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &handle)
        guard status == noErr, let handle else {
            if let handle { releaseUnused(handle) }
            throw HotKeyRegistryError.registrationFailed(status == noErr ? OSStatus(paramErr) : status)
        }
        if let previous {
            let status = UnregisterEventHotKey(previous.handle)
            guard status == noErr else {
                releaseUnused(handle)
                throw HotKeyRegistryError.unregistrationFailed(status)
            }
            resources.context.actions.removeValue(forKey: previous.eventID)
        }
        resources.entries[id] = .init(shortcut: shortcut, eventID: eventID, handle: handle)
        resources.context.actions[eventID] = action
    }

    private func releaseUnused(_ handle: EventHotKeyRef) {
        let status = UnregisterEventHotKey(handle)
        if status != noErr {
            resources.orphanedHandles.append(handle)
            NSLog("getGamen compensating hotkey release failed; retained for close: %d", status)
        }
    }

    public func unregister(id: UInt32) throws {
        precondition(Thread.isMainThread)
        guard !resources.closed else { throw HotKeyRegistryError.closed }
        guard let entry = resources.entries[id] else { return }
        let status = UnregisterEventHotKey(entry.handle)
        guard status == noErr else { throw HotKeyRegistryError.unregistrationFailed(status) }
        resources.entries.removeValue(forKey: id)
        resources.context.actions.removeValue(forKey: entry.eventID)
    }

    public func close() throws {
        try resources.cleanup()
    }

    func eventIdentifier(for id: UInt32) -> EventHotKeyID? {
        resources.entries[id].map { EventHotKeyID(signature: hotKeySignature, id: $0.eventID) }
    }

    private static func checkSystemShortcut(_ shortcut: HotKeyShortcut) throws {
        var unmanaged: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanaged)
        let array = unmanaged?.takeRetainedValue()
        guard status == noErr, let array else {
            throw HotKeyRegistryError.systemShortcutQueryFailed(status == noErr ? OSStatus(paramErr) : status)
        }
        for case let dictionary as NSDictionary in array as NSArray {
            guard let enabled = dictionary[kHISymbolicHotKeyEnabled] as? NSNumber,
                  enabled.boolValue,
                  let code = dictionary[kHISymbolicHotKeyCode] as? NSNumber,
                  let modifiers = dictionary[kHISymbolicHotKeyModifiers] as? NSNumber else { continue }
            if code.uint32Value == shortcut.keyCode && modifiers.uint32Value == shortcut.modifiers {
                throw HotKeyRegistryError.reservedSystemShortcut
            }
        }
    }

    deinit {
        let resources = resources
        if Thread.isMainThread { MainActor.assumeIsolated { HotKeyResources.finish(resources) } }
        else { DispatchQueue.main.async { HotKeyResources.finish(resources) } }
    }
}
