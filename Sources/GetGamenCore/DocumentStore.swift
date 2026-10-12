import Foundation
import CryptoKit
import Darwin

/// One store owns a private root. Concurrent writers to the same root are unsupported.
public actor DocumentStore {
    private let root: URL
    private let files = FileManager.default

    /// `removesPreviousDocuments` discards every document an earlier run left behind.
    public init(root: URL, removesPreviousDocuments: Bool = false) throws {
        guard root.isFileURL else { throw DocumentStoreError.unsafeFileType }
        let supplied = root.standardizedFileURL
        try Self.requireType(supplied, directory: true, allowMissing: true)
        // Resolve trusted ancestors once, while rejecting a link at the root itself.
        let canonical = supplied.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(supplied.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Self.requireType(canonical, directory: true)
        self.root = canonical
        let stagingPrefix = ".staging-"
        for url in (try? FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            let staging = name.hasPrefix(stagingPrefix) && UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil
            let previous = removesPreviousDocuments && UUID(uuidString: name) != nil
            guard staging || previous, (try? Self.requireType(url, directory: true)) != nil else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch { NSLog("getGamen could not remove a stale document directory: %@", String(describing: error)) }
        }
    }

    public func create(original: Data, pixelSize: PixelSize) throws -> EditDocument {
        try Self.requireType(root, directory: true)
        guard !original.isEmpty else { throw DocumentStoreError.emptyOriginal }
        try pixelSize.validate()
        let id = UUID()
        let document = EditDocument(schemaVersion: 1, documentID: id, originalID: id,
                                    originalSHA256: Self.digest(original), originalByteCount: original.count,
                                    pixelSize: pixelSize, createdAt: Date(), revision: 0, edits: EditState())
        let json = try JSONEncoder().encode(document)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published {
                do { try files.removeItem(at: staging) }
                catch { NSLog("getGamen could not remove its incomplete staging directory: %@", String(describing: error)) }
            }
        }
        try original.write(to: staging.appendingPathComponent("original.bin"), options: .withoutOverwriting)
        try json.write(to: staging.appendingPathComponent("document.json"), options: .withoutOverwriting)
        // Both files are complete before the directory becomes visible under its document UUID.
        try files.moveItem(at: staging, to: directory(id))
        published = true
        return document
    }

    public func load(id: UUID) throws -> StoredDocument {
        try validatePaths(id)
        let json = try Data(contentsOf: directory(id).appendingPathComponent("document.json"))
        struct Version: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let version: Int
        do { version = try decoder.decode(Version.self, from: json).schemaVersion }
        catch { throw DocumentStoreError.corruptDocument }
        guard version == 1 else { throw DocumentStoreError.unsupportedSchemaVersion(version) }
        let document: EditDocument
        do { document = try decoder.decode(EditDocument.self, from: json) }
        catch { throw DocumentStoreError.corruptDocument }
        guard document.documentID == id, document.originalID == id else {
            throw DocumentStoreError.documentIdentityMismatch
        }
        guard document.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DocumentStoreError.corruptDocument
        }
        try document.pixelSize.validate()
        try document.edits.validate(pixelSize: document.pixelSize)
        let original = try Data(contentsOf: directory(id).appendingPathComponent("original.bin"))
        guard !original.isEmpty, document.originalByteCount == original.count,
              document.originalSHA256 == Self.digest(original) else {
            throw DocumentStoreError.originalMismatch
        }
        return StoredDocument(document: document, originalData: original)
    }

    public func save(id: UUID, edits: EditState, expectedRevision: UInt64) throws -> EditDocument {
        let previous = try load(id: id).document
        guard previous.revision == expectedRevision else {
            throw DocumentStoreError.revisionConflict(expected: expectedRevision, actual: previous.revision)
        }
        try edits.validate(pixelSize: previous.pixelSize)
        let next = previous.revision.addingReportingOverflow(1)
        guard !next.overflow else { throw DocumentStoreError.revisionOverflow }
        let updated = EditDocument(schemaVersion: previous.schemaVersion, documentID: previous.documentID,
                                   originalID: previous.originalID, originalSHA256: previous.originalSHA256,
                                   originalByteCount: previous.originalByteCount, pixelSize: previous.pixelSize,
                                   createdAt: previous.createdAt, revision: next.partialValue, edits: edits)
        let json = try JSONEncoder().encode(updated)
        try json.write(to: directory(id).appendingPathComponent("document.json"), options: .atomic)
        return updated
    }

    /// Only published UUID directories are history; incomplete staging files are excluded.
    public func documentIDs() throws -> [UUID] {
        try Self.requireType(root, directory: true)
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }.sorted { $0.uuidString < $1.uuidString }
    }

    /// The caller must first freeze and drain this document's producers.
    /// Export receipts and output files live outside this document directory.
    public func delete(id: UUID) throws {
        try Self.requireType(root, directory: true)
        try Self.requireType(directory(id), directory: true)
        try files.removeItem(at: directory(id))
    }

    private func directory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func validatePaths(_ id: UUID) throws {
        try Self.requireType(root, directory: true)
        let folder = directory(id)
        try Self.requireType(folder, directory: true)
        try Self.requireType(folder.appendingPathComponent("original.bin"), directory: false)
        try Self.requireType(folder.appendingPathComponent("document.json"), directory: false)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// lstat rejects links even when their targets do not exist; no file is opened here.
    private static func requireType(_ url: URL, directory: Bool, allowMissing: Bool = false) throws {
        var info = stat()
        // A trailing slash can make POSIX follow a directory symlink even with lstat.
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let result = path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            let code = errno
            if allowMissing && code == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        let expected = directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard info.st_mode & mode_t(S_IFMT) == expected else {
            throw DocumentStoreError.unsafeFileType
        }
    }
}
