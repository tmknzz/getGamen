import Foundation
import CryptoKit
import Darwin

enum PublicationCheckpoint { case beforeRename, afterRename }

/// Synchronous and exclusively owned by one coordinator. No competing writers to receiptsRoot.
struct OwnedExportWriter {
    private struct Identity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }
    private struct Association: Codable {
        let folder: String
        let folderIdentity: Identity
        let basename: String
        let outputIdentity: Identity
        let sha256: String
        let byteCount: Int
        let stamp: ExportStamp
        var url: URL { URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(basename) }
    }
    private struct Pending: Codable {
        let intended: Association
        let stagingBasename: String
        var stagingURL: URL {
            URL(fileURLWithPath: intended.folder, isDirectory: true).appendingPathComponent(stagingBasename)
        }
    }
    private struct Receipt: Codable {
        var schemaVersion = 1
        let documentID: UUID
        let slot: ExportSlot
        var maximumRequest: UInt64 = 0
        var maximumDocumentRevision: UInt64?
        var settled: Association?
        var pending: Pending?
    }
    private let root: URL
    private let rootIdentity: Identity
    private let checkpoint: (PublicationCheckpoint, URL, URL) throws -> Void
    private let files = FileManager.default

    init(receiptsRoot: URL,
         checkpoint: @escaping (PublicationCheckpoint, URL, URL) throws -> Void = { _, _, _ in }) throws {
        guard receiptsRoot.isFileURL else { throw ExportWriteError.invalidReceipt }
        let supplied = receiptsRoot.standardizedFileURL
        if let info = try Self.stat(supplied) { try Self.require(info, type: S_IFDIR) }
        let canonical = supplied.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(supplied.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        guard let info = try Self.stat(canonical) else { throw ExportWriteError.invalidReceipt }
        try Self.require(info, type: S_IFDIR)
        root = canonical; rootIdentity = Self.identity(info); self.checkpoint = checkpoint
    }

    mutating func publish(documentID: UUID, createdAt: Date, slot: ExportSlot,
                          destinationFolder: URL, data: Data, stamp: ExportStamp) throws -> PublishedExport {
        guard !data.isEmpty, createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExportWriteError.invalidData
        }
        var receipt = try read(documentID, slot) ?? Receipt(documentID: documentID, slot: slot)
        try recover(&receipt)
        guard stamp.request > receipt.maximumRequest else { throw ExportWriteError.staleRequest }
        if let old = receipt.settled, old.folder == destinationFolder.standardizedFileURL.path,
           !(try matches(old)) { throw ExportWriteError.ownershipLost }
        let folder = try Self.destination(destinationFolder)
        guard let folderStat = try Self.stat(folder) else { throw ExportWriteError.destinationUnavailable }
        let folderIdentity = Self.identity(folderStat)
        let old = receipt.settled
        let updating = old?.folder == folder.path
        if updating, let old, !(try matches(old)) { throw ExportWriteError.ownershipLost }
        let stem = CaptureFilename.stem(createdAt: createdAt)
        let staging = folder.appendingPathComponent(".getgamen-stage-\(UUID().uuidString)")
        var recoveryOwnsStage = false
        defer {
            if !recoveryOwnsStage {
                do { try files.removeItem(at: staging) }
                catch { NSLog("getGamen export staging cleanup: %@", String(describing: error)) }
            }
        }
        // Set cleanup ownership only after exclusive creation succeeded.
        do { try data.write(to: staging, options: .withoutOverwriting) }
        catch { recoveryOwnsStage = true; throw error }
        guard let stageStat = try Self.stat(staging) else { throw ExportWriteError.interruptedPublication }
        try Self.require(stageStat, type: S_IFREG)
        let stageIdentity = Self.identity(stageStat)
        let hash = Self.digest(data)
        let basenames = (0..<32).map { attempt in
            "\(stem)\(attempt == 0 ? "" : "-" + String(attempt + 1)).\(slot.rawValue)"
        } + ["\(stem)-\(UUID().uuidString).\(slot.rawValue)"]
        for basename in basenames {
            let intended = Association(folder: folder.path, folderIdentity: folderIdentity, basename: basename,
                                       outputIdentity: stageIdentity, sha256: hash, byteCount: data.count, stamp: stamp)
            receipt.maximumRequest = stamp.request
            receipt.maximumDocumentRevision = max(receipt.maximumDocumentRevision ?? stamp.documentRevision,
                                                   stamp.documentRevision)
            receipt.pending = Pending(intended: intended, stagingBasename: staging.lastPathComponent)
            try write(receipt)
            recoveryOwnsStage = true
            guard try folderMatches(intended) else { throw ExportWriteError.ownershipLost }
            if updating, let old, !(try matches(old)) { throw ExportWriteError.ownershipLost }
            do { try checkpoint(.beforeRename, staging, intended.url) }
            catch { throw ExportWriteError.interruptedPublication }
            let result = staging.path.withCString { source in
                intended.url.path.withCString { target in
                    // Never replace a path: it may have changed since ownership validation.
                    Darwin.renamex_np(source, target, UInt32(RENAME_EXCL))
                }
            }
            if result != 0 {
                let code = errno
                if code == EEXIST { continue }
                throw Self.posix(code, intended.url)
            }
            do {
                try checkpoint(.afterRename, staging, intended.url)
                guard try matches(intended) else { throw ExportWriteError.interruptedPublication }
                receipt.settled = intended
                receipt.pending = nil
                try write(receipt)
                return PublishedExport(url: intended.url, stamp: stamp)
            } catch { throw ExportWriteError.interruptedPublication }
        }
        throw Self.posix(EEXIST, folder)
    }

    func existing(documentID: UUID, slot: ExportSlot) throws -> PublishedExport? {
        guard var receipt = try read(documentID, slot) else { return nil }
        try recover(&receipt)
        guard let settled = receipt.settled else { return nil }
        guard try matches(settled) else { throw ExportWriteError.ownershipLost }
        return PublishedExport(url: settled.url, stamp: settled.stamp)
    }

    func maximumRequestNumber() throws -> UInt64 {
        try checkRoot()
        var maximum: UInt64 = 0
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard url.pathExtension.lowercased() == "json" else { continue }
            guard let key = receiptKey(url), let receipt = try read(key.id, key.slot) else {
                throw ExportWriteError.invalidReceipt
            }
            maximum = max(maximum, receipt.maximumRequest)
        }
        return maximum
    }

    /// Settles or cleans each pending publication, then forgets the receipt.
    /// Unreadable receipts stay, so maximumRequestNumber still reports them.
    func discardReceipts() throws {
        try checkRoot()
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let key = receiptKey(url) else { continue }
            do {
                guard var receipt = try read(key.id, key.slot) else { continue }
                try recover(&receipt, persist: false)
                try files.removeItem(at: url)
            } catch { NSLog("getGamen kept an export receipt it could not discard: %@", String(describing: error)) }
        }
    }

    private func receiptKey(_ url: URL) -> (id: UUID, slot: ExportSlot)? {
        let pieces = url.deletingPathExtension().lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, let id = UUID(uuidString: String(pieces[0])),
              let slot = ExportSlot(rawValue: String(pieces[1])),
              url.lastPathComponent == receiptURL(id, slot).lastPathComponent else { return nil }
        return (id, slot)
    }

    /// Receipt history survives output loss; reading it does not trigger pending recovery.
    func maximumDocumentRevision(documentID: UUID) throws -> UInt64? {
        var maximum: UInt64?
        for slot in [ExportSlot.png, .jpg] {
            if let revision = try read(documentID, slot)?.maximumDocumentRevision {
                maximum = max(maximum ?? revision, revision)
            }
        }
        return maximum
    }

    private func recover(_ receipt: inout Receipt, persist: Bool = true) throws {
        guard let pending = receipt.pending else { return }
        if try matches(pending.intended) {
            receipt.settled = pending.intended
        } else {
            let oldMatches = try receipt.settled.map { try matches($0) } ?? false
            // A stage is removable only after identity, bytes and folder checks establish ownership.
            if try stageMatches(pending) {
                try files.removeItem(at: pending.stagingURL)
            }
            if !oldMatches { receipt.settled = nil }
            // A verified old migration output remains owned; unknown new external files remain untouched.
        }
        receipt.pending = nil
        if persist { try write(receipt) }
    }

    private func stageMatches(_ pending: Pending) throws -> Bool {
        let a = pending.intended
        let staged = Association(folder: a.folder, folderIdentity: a.folderIdentity,
                                 basename: pending.stagingBasename, outputIdentity: a.outputIdentity,
                                 sha256: a.sha256, byteCount: a.byteCount, stamp: a.stamp)
        return try matches(staged)
    }

    private func folderMatches(_ association: Association) throws -> Bool {
        guard let info = try Self.stat(URL(fileURLWithPath: association.folder)),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        return Self.identity(info) == association.folderIdentity
    }

    private func matches(_ association: Association) throws -> Bool {
        guard try folderMatches(association), let info = try Self.stat(association.url),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Self.identity(info) == association.outputIdentity, info.st_size == Int64(association.byteCount) else { return false }
        return Self.digest(try Data(contentsOf: association.url)) == association.sha256
    }

    private func receiptURL(_ id: UUID, _ slot: ExportSlot) -> URL {
        root.appendingPathComponent("\(id.uuidString).\(slot.rawValue).json")
    }

    private func read(_ id: UUID, _ slot: ExportSlot) throws -> Receipt? {
        try checkRoot()
        let url = receiptURL(id, slot)
        guard let info = try Self.stat(url) else { return nil }
        try Self.require(info, type: S_IFREG)
        let data = try Data(contentsOf: url)
        var receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: data) }
        catch { throw ExportWriteError.invalidReceipt }
        guard receipt.schemaVersion == 1, receipt.documentID == id, receipt.slot == slot else {
            throw ExportWriteError.invalidReceipt
        }
        for a in [receipt.settled, receipt.pending?.intended].compactMap({ $0 }) {
            guard a.folder.hasPrefix("/"), URL(fileURLWithPath: a.folder).standardizedFileURL.path == a.folder,
                  Self.validName(a.basename), a.basename.hasSuffix(".\(slot.rawValue)"),
                  a.byteCount > 0, a.sha256.count == 64,
                  a.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  a.stamp.request > 0, a.stamp.request <= receipt.maximumRequest,
                  Self.validIdentity(a.folderIdentity), Self.validIdentity(a.outputIdentity) else {
                throw ExportWriteError.invalidReceipt
            }
        }
        if let pending = receipt.pending {
            guard Self.validName(pending.stagingBasename), pending.stagingBasename.hasPrefix(".getgamen-stage-") else {
                throw ExportWriteError.invalidReceipt
            }
        }
        let containedMaximum = [receipt.settled, receipt.pending?.intended]
            .compactMap { $0?.stamp.documentRevision }.max()
        if let explicit = receipt.maximumDocumentRevision,
           let containedMaximum, explicit < containedMaximum {
            throw ExportWriteError.invalidReceipt
        }
        // Missing legacy metadata derives only from surviving stamps; nil is not revision zero.
        if receipt.maximumDocumentRevision == nil {
            receipt.maximumDocumentRevision = containedMaximum
        }
        return receipt
    }

    private func write(_ receipt: Receipt) throws {
        try checkRoot()
        let url = receiptURL(receipt.documentID, receipt.slot)
        if let info = try Self.stat(url) { try Self.require(info, type: S_IFREG) }
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
    }

    private func checkRoot() throws {
        guard let info = try Self.stat(root), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              Self.identity(info) == rootIdentity else { throw ExportWriteError.invalidReceipt }
    }

    private static func destination(_ supplied: URL) throws -> URL {
        guard supplied.isFileURL, let info = try stat(supplied),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ExportWriteError.destinationUnavailable }
        return supplied.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    private static func validIdentity(_ identity: Identity) -> Bool {
        identity.birthNanoseconds >= 0 && identity.birthNanoseconds < 1_000_000_000
    }
    private static func require(_ info: Darwin.stat, type: mode_t) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(type) else { throw ExportWriteError.invalidReceipt }
    }
    private static func identity(_ info: Darwin.stat) -> Identity {
        Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                 birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
    private static func stat(_ url: URL) throws -> Darwin.stat? {
        var info = Darwin.stat()
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let result = path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw posix(code, url)
        }
        return info
    }
    private static func posix(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
