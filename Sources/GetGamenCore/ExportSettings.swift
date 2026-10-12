import Foundation
import CoreFoundation
import Observation
import Darwin

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case png, png8, jpeg

    public var slot: ExportSlot {
        switch self {
        case .png, .png8: return .png
        case .jpeg: return .jpg
        }
    }

    public func codecFormat(jpegQuality: Double) throws -> RasterImageCodec.Format {
        switch self {
        case .png: return .png
        case .png8: return .png8
        case .jpeg:
            guard jpegQuality.isFinite, (0...1).contains(jpegQuality) else {
                throw ExportSettingsError.invalidQuality
            }
            return .jpeg(quality: jpegQuality)
        }
    }
}

public enum ExportDestination: Equatable, Sendable {
    case defaultFolder(URL)
    case configuredFolder(URL)
    case invalidStoredFolder
}

public struct ExportSettingsSnapshot: Equatable, Sendable {
    public let format: ExportFormat
    public let jpegQuality: Double
    public let destination: ExportDestination

    public init(format: ExportFormat, jpegQuality: Double, destination: ExportDestination) {
        self.format = format
        self.jpegQuality = jpegQuality
        self.destination = destination
    }
}

public enum ExportSettingsError: Error, Equatable {
    case invalidQuality
    case invalidDestination
    case destinationUnavailable
}

@MainActor
@Observable
public final class ExportSettings {
    private static let formatKey = "getGamen.export.format"
    private static let qualityKey = "getGamen.export.jpegQuality"
    private static let destinationKey = "getGamen.export.destinationPath"
    private let defaults: UserDefaults
    private let defaultDestination: ExportDestination
    public private(set) var snapshot: ExportSettingsSnapshot

    public convenience init(defaults: UserDefaults = .standard) {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let folder = pictures?.appendingPathComponent("getGamen", isDirectory: true)
        self.init(defaults: defaults, defaultDestination: Self.defaultValue(folder))
    }

    convenience init(defaults: UserDefaults, defaultFolder: URL) {
        self.init(defaults: defaults, defaultDestination: Self.defaultValue(defaultFolder))
    }

    private init(defaults: UserDefaults, defaultDestination: ExportDestination) {
        self.defaults = defaults
        self.defaultDestination = defaultDestination
        snapshot = Self.read(defaults, defaultDestination: defaultDestination)
    }

    public func setFormat(_ format: ExportFormat) {
        defaults.set(format.rawValue, forKey: Self.formatKey)
        snapshot = ExportSettingsSnapshot(format: format, jpegQuality: snapshot.jpegQuality,
                                          destination: snapshot.destination)
    }

    public func setJPEGQuality(_ quality: Double) throws {
        guard quality.isFinite, (0...1).contains(quality) else { throw ExportSettingsError.invalidQuality }
        defaults.set(quality, forKey: Self.qualityKey)
        snapshot = ExportSettingsSnapshot(format: snapshot.format, jpegQuality: quality,
                                          destination: snapshot.destination)
    }

    public func setDestinationFolder(_ folder: URL) throws {
        let canonical = try Self.existingFolder(folder)
        defaults.set(canonical.path, forKey: Self.destinationKey)
        snapshot = ExportSettingsSnapshot(format: snapshot.format, jpegQuality: snapshot.jpegQuality,
                                          destination: .configuredFolder(canonical))
    }

    /// Reading preferences neither repairs malformed values nor creates output directories.
    public func reload() {
        snapshot = Self.read(defaults, defaultDestination: defaultDestination)
    }

    /// Resolves only the copied request destination. The writer still determines actual write success.
    public static func prepareDestination(for snapshot: ExportSettingsSnapshot) throws -> URL {
        switch snapshot.destination {
        case .invalidStoredFolder:
            throw ExportSettingsError.invalidDestination
        case .configuredFolder(let folder):
            return try existingFolder(folder)
        case .defaultFolder(let folder):
            try validateDefault(folder)
            let parent = folder.deletingLastPathComponent()
            guard try directoryExists(parent) else { throw ExportSettingsError.destinationUnavailable }
            if try !directoryExists(folder) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            return try existingFolder(folder)
        }
    }

    private static func read(_ defaults: UserDefaults, defaultDestination: ExportDestination) -> ExportSettingsSnapshot {
        let format = (defaults.object(forKey: formatKey) as? String).flatMap(ExportFormat.init(rawValue:)) ?? .png
        var quality = 0.9
        if let number = defaults.object(forKey: qualityKey) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           (0...1).contains(number.doubleValue),
           number.compare(NSNumber(value: 0)) != .orderedAscending,
           number.compare(NSNumber(value: 1)) != .orderedDescending {
            quality = number.doubleValue
        }
        let destination: ExportDestination
        if let stored = defaults.object(forKey: destinationKey) {
            if let path = stored as? String, path.hasPrefix("/"), !path.utf8.contains(0) {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                do {
                    try validateURL(folder)
                    destination = .configuredFolder(folder)
                } catch {
                    destination = .invalidStoredFolder
                }
            } else {
                destination = .invalidStoredFolder
            }
        } else {
            destination = defaultDestination
        }
        return ExportSettingsSnapshot(format: format, jpegQuality: quality, destination: destination)
    }

    private static func defaultValue(_ folder: URL?) -> ExportDestination {
        guard let folder else { return .invalidStoredFolder }
        do {
            try validateDefault(folder)
            return .defaultFolder(folder)
        } catch {
            return .invalidStoredFolder
        }
    }

    private static func validateDefault(_ folder: URL) throws {
        try validateURL(folder)
        guard folder.lastPathComponent == "getGamen", folder.path != folder.deletingLastPathComponent().path else {
            throw ExportSettingsError.invalidDestination
        }
    }

    private static func validateURL(_ folder: URL) throws {
        // Foundation can discard NUL from .path. Inspect the original encoding first.
        // A literal "%00" filename contains "%2500" here and remains valid.
        guard folder.isFileURL, folder.baseURL == nil, !folder.absoluteString.contains("%00"),
              folder.path.hasPrefix("/"), !folder.path.utf8.contains(0),
              folder.host == nil || folder.host == "" || folder.host?.lowercased() == "localhost",
              folder.query == nil, folder.fragment == nil, folder.user == nil,
              folder.password == nil, folder.port == nil else {
            throw ExportSettingsError.invalidDestination
        }
    }

    private static func existingFolder(_ folder: URL) throws -> URL {
        try validateURL(folder)
        // Check the original leaf before resolving trusted ancestor links, as the writer does.
        guard try directoryExists(folder) else { throw ExportSettingsError.destinationUnavailable }
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: canonical.path, isDirectory: true)
    }

    private static func directoryExists(_ folder: URL) throws -> Bool {
        var info = stat()
        var path = folder.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.withCString({ Darwin.lstat($0, &info) }) != 0 {
            let code = errno
            if code == ENOENT { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: folder.path])
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ExportSettingsError.destinationUnavailable
        }
        return true
    }
}
