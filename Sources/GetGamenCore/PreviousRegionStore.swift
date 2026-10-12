import Foundation
import Darwin

/// Synchronous, single-owner storage for the last successfully captured region.
struct PreviousRegionRecordStore {
    private struct Record: Codable {
        let schemaVersion: Int
        let selection: RegionSelection
    }

    private let fileURL: URL
    private let parentURL: URL
    private let beforeAtomicWrite: () throws -> Void

    init(fileURL: URL, beforeAtomicWrite: @escaping () throws -> Void = {}) throws {
        guard fileURL.isFileURL, !fileURL.absoluteString.contains("%00"), !fileURL.path.utf8.contains(0) else {
            throw Self.fileError(EINVAL, fileURL)
        }
        let supplied = fileURL.standardizedFileURL
        guard supplied.path != "/", !supplied.lastPathComponent.isEmpty else {
            throw Self.fileError(EINVAL, supplied)
        }
        let parent = supplied.deletingLastPathComponent()
        _ = try Self.requireType(parent, directory: true, allowMissing: true)
        // Only ancestors are trusted/resolved; the owned parent itself must not be a link.
        let canonicalParent = parent.path == "/" ? parent : parent.deletingLastPathComponent()
            .resolvingSymlinksInPath().appendingPathComponent(parent.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalParent, withIntermediateDirectories: true)
        _ = try Self.requireType(canonicalParent, directory: true)
        let canonicalFile = canonicalParent.appendingPathComponent(supplied.lastPathComponent)
        _ = try Self.requireType(canonicalFile, directory: false, allowMissing: true)
        self.fileURL = canonicalFile
        self.parentURL = canonicalParent
        self.beforeAtomicWrite = beforeAtomicWrite
        // Deliberately do not decode: a later successful capture may replace corrupt bytes.
    }

    func load() throws -> RegionSelection? {
        _ = try Self.requireType(parentURL, directory: true)
        guard try Self.requireType(fileURL, directory: false, allowMissing: true) else { return nil }
        let data = try Data(contentsOf: fileURL)
        struct Version: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let version: Int
        do { version = try decoder.decode(Version.self, from: data).schemaVersion }
        catch { throw PreviousRegionError.corruptRecord }
        guard version == 1 else { throw PreviousRegionError.unsupportedRecordVersion(version) }
        do { return try decoder.decode(Record.self, from: data).selection }
        catch { throw PreviousRegionError.corruptRecord }
    }

    func remember(_ selection: RegionSelection) throws {
        let data = try JSONEncoder().encode(Record(schemaVersion: 1, selection: selection))
        _ = try Self.requireType(parentURL, directory: true)
        _ = try Self.requireType(fileURL, directory: false, allowMissing: true)
        try beforeAtomicWrite()
        try data.write(to: fileURL, options: .atomic)
    }

    /// Returns false only for ENOENT when missing is explicitly permitted.
    private static func requireType(_ url: URL, directory: Bool, allowMissing: Bool = false) throws -> Bool {
        var info = stat()
        var path = url.path
        // A trailing slash otherwise lets lstat follow a directory symlink.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let result = path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            let code = errno
            if allowMissing && code == ENOENT { return false }
            throw fileError(code, url)
        }
        let type = info.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { throw fileError(ELOOP, url) }
        guard type == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)) else {
            throw fileError(directory ? ENOTDIR : EFTYPE, url)
        }
        return true
    }

    private static func fileError(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
