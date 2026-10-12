import CoreFoundation
import Darwin
import Foundation
import XCTest
@testable import GetGamenCore

final class ExportSettingsTests: XCTestCase {
    private let formatKey = "getGamen.export.format"
    private let qualityKey = "getGamen.export.jpegQuality"
    private let destinationKey = "getGamen.export.destinationPath"

    @MainActor
    func testDefaultsAndReloadDoNotCreateFoldersOrWritePreferences() throws {
        let f = try Fixture(); defer { f.remove() }
        let settings = f.settings()
        XCTAssertEqual(settings.snapshot.format, .png)
        XCTAssertEqual(settings.snapshot.jpegQuality, 0.9)
        XCTAssertEqual(settings.snapshot.destination, .defaultFolder(f.defaultFolder))
        settings.reload()
        XCTAssertFalse(f.exists(f.pictures))
        XCTAssertFalse(f.exists(f.defaultFolder))
        for key in [formatKey, qualityKey, destinationKey] { XCTAssertNil(f.defaults.object(forKey: key)) }
        let snapshot = settings.snapshot
        settings.setFormat(.png8)
        try settings.setJPEGQuality(0.3)
        XCTAssertEqual(snapshot.format, .png)
        XCTAssertEqual(snapshot.jpegQuality, 0.9)
        XCTAssertEqual(f.settings().snapshot, settings.snapshot)
    }

    @MainActor
    func testPublicInitializerUsesNativePicturesDiscoveryWithoutPreparingIt() throws {
        let f = try Fixture(); defer { f.remove() }
        let actual = ExportSettings(defaults: f.defaults).snapshot.destination
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            XCTAssertEqual(actual, .defaultFolder(pictures.appendingPathComponent("getGamen", isDirectory: true)))
        } else { XCTAssertEqual(actual, .invalidStoredFolder) }
        XCTAssertNil(f.defaults.object(forKey: destinationKey))
    }

    @MainActor
    func testFormatPersistenceAndExactCodecMapping() throws {
        let f = try Fixture(); defer { f.remove() }
        let settings = f.settings()
        for format in ExportFormat.allCases {
            settings.setFormat(format)
            XCTAssertEqual(f.defaults.string(forKey: formatKey), format.rawValue)
            XCTAssertEqual(f.settings().snapshot.format, format)
        }
        XCTAssertEqual(ExportFormat.png.slot, .png)
        XCTAssertEqual(ExportFormat.png8.slot, .png)
        XCTAssertEqual(ExportFormat.jpeg.slot, .jpg)
        guard case .png = try ExportFormat.png.codecFormat(jpegQuality: .nan) else { return XCTFail("PNG substituted") }
        guard case .png8 = try ExportFormat.png8.codecFormat(jpegQuality: .infinity) else { return XCTFail("PNG8 substituted") }
        for quality in [0.0, 0.9, 1.0] {
            guard case .jpeg(let actual) = try ExportFormat.jpeg.codecFormat(jpegQuality: quality) else { return XCTFail("JPEG substituted") }
            XCTAssertEqual(actual, quality)
            try settings.setJPEGQuality(quality)
            XCTAssertEqual(f.settings().snapshot.jpegQuality, quality)
        }
        for quality in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            let before = settings.snapshot
            let stored = f.defaults.object(forKey: qualityKey) as? NSNumber
            XCTAssertThrowsError(try settings.setJPEGQuality(quality)) { XCTAssertEqual($0 as? ExportSettingsError, .invalidQuality) }
            XCTAssertThrowsError(try ExportFormat.jpeg.codecFormat(jpegQuality: quality)) { XCTAssertEqual($0 as? ExportSettingsError, .invalidQuality) }
            XCTAssertEqual(settings.snapshot, before)
            XCTAssertEqual(f.defaults.object(forKey: qualityKey) as? NSNumber, stored)
        }
    }

    @MainActor
    func testNumericQualityAndMalformedFieldsAreIndependentAndNotRewritten() throws {
        let f = try Fixture(); defer { f.remove() }
        let settings = f.settings()
        for value in [NSNumber(value: Int(0)), NSNumber(value: UInt(1)), NSNumber(value: 0.375)] {
            f.defaults.set(value, forKey: qualityKey)
            let read = try XCTUnwrap(f.defaults.object(forKey: qualityKey) as? NSNumber)
            XCTAssertNotEqual(CFGetTypeID(read), CFBooleanGetTypeID())
            settings.reload()
            XCTAssertEqual(settings.snapshot.jpegQuality, value.doubleValue)
        }
        let malformed: [Any] = [true, false, "0.9", [1], ["quality": 1], Data([1]), -0.1, 1.1]
        for value in malformed {
            f.defaults.set(value, forKey: qualityKey)
            f.defaults.set("jpeg", forKey: formatKey)
            let before = try XCTUnwrap(f.defaults.object(forKey: qualityKey) as? NSObject)
            settings.reload()
            XCTAssertEqual(settings.snapshot.jpegQuality, 0.9)
            XCTAssertEqual(settings.snapshot.format, .jpeg)
            XCTAssertTrue(before.isEqual(f.defaults.object(forKey: qualityKey)))
        }
        let invalidFormats: [Any] = ["unknown", 4, true, Data([1])]
        for invalid in invalidFormats {
            f.defaults.set(invalid, forKey: formatKey)
            f.defaults.set(0.25, forKey: qualityKey)
            let before = try XCTUnwrap(f.defaults.object(forKey: formatKey) as? NSObject)
            settings.reload()
            XCTAssertEqual(settings.snapshot.format, .png)
            XCTAssertEqual(settings.snapshot.jpegQuality, 0.25)
            XCTAssertTrue(before.isEqual(f.defaults.object(forKey: formatKey)))
        }
    }

    @MainActor
    func testNonfiniteReadbackClassificationAndPrecisionBoundary() throws {
        let f = try Fixture(); defer { f.remove() }
        let settings = f.settings()
        for input in [Double.nan, .infinity, -.infinity] {
            f.defaults.set(input, forKey: qualityKey)
            let before = try XCTUnwrap(f.defaults.object(forKey: qualityKey) as? NSNumber).doubleValue
            XCTAssertFalse(before.isFinite)
            settings.reload()
            XCTAssertEqual(settings.snapshot.jpegQuality, 0.9)
            let after = try XCTUnwrap(f.defaults.object(forKey: qualityKey) as? NSNumber).doubleValue
            if before.isNaN { XCTAssertTrue(after.isNaN) }
            else { XCTAssertEqual(after, before) }
        }
        for text in ["1.0000000000000000001", "-0.0000000000000000001", "0.9999999999999999999"] {
            f.defaults.set(NSDecimalNumber(string: text), forKey: qualityKey)
            let actual = try XCTUnwrap(f.defaults.object(forKey: qualityKey) as? NSNumber)
            // The oracle concerns actual storage, not precision discarded by UserDefaults.
            let isInside = actual.compare(NSNumber(value: 0)) != .orderedAscending && actual.compare(NSNumber(value: 1)) != .orderedDescending
            settings.reload()
            XCTAssertEqual(settings.snapshot.jpegQuality, isInside ? actual.doubleValue : 0.9)
            let retained = try XCTUnwrap(f.defaults.object(forKey: qualityKey) as? NSNumber)
            XCTAssertEqual(retained.compare(actual), .orderedSame)
        }
    }

    @MainActor
    func testMalformedDestinationNeverFallsBackOrRepairsStoredValue() throws {
        let f = try Fixture(); defer { f.remove() }
        let malformed: [Any] = ["", "relative", "~/Pictures", "file:///tmp/output", "/tmp/bad\0tail", true, ["path"]]
        for value in malformed {
            f.defaults.set(value, forKey: destinationKey)
            let before = try XCTUnwrap(f.defaults.object(forKey: destinationKey) as? NSObject)
            let settings = f.settings()
            XCTAssertEqual(settings.snapshot.destination, .invalidStoredFolder)
            XCTAssertThrowsError(try ExportSettings.prepareDestination(for: settings.snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .invalidDestination) }
            settings.reload()
            XCTAssertEqual(settings.snapshot.destination, .invalidStoredFolder)
            XCTAssertTrue(before.isEqual(f.defaults.object(forKey: destinationKey)))
            XCTAssertFalse(f.exists(f.pictures))
        }
        let absent = f.root.appendingPathComponent("configured-missing", isDirectory: true)
        f.defaults.set(absent.path, forKey: destinationKey)
        let settings = f.settings()
        XCTAssertEqual(settings.snapshot.destination, .configuredFolder(absent))
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: settings.snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertFalse(f.exists(absent))
        XCTAssertFalse(f.exists(f.pictures))
    }

    @MainActor
    func testDefaultCreatesOnlyChildReusesAndRejectsMissingParentAndWrongBasename() throws {
        let f = try Fixture(); defer { f.remove() }
        let snapshot = f.settings().snapshot
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertFalse(f.exists(f.pictures))
        try f.make(f.pictures)
        let first = try ExportSettings.prepareDestination(for: snapshot)
        XCTAssertEqual(first.path, f.defaultFolder.resolvingSymlinksInPath().path)
        XCTAssertEqual(try ExportSettings.prepareDestination(for: snapshot), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.pictures.path), ["getGamen"])
        for wrong in [f.pictures.appendingPathComponent("Other"), URL(fileURLWithPath: "/")] {
            XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.snapshot(.defaultFolder(wrong)))) { XCTAssertEqual($0 as? ExportSettingsError, .invalidDestination) }
        }
        XCTAssertFalse(f.exists(f.pictures.appendingPathComponent("Other")))
    }

    @MainActor
    func testConfiguredSnapshotsDoNotRecreateOrMigrateAndPreserveSnapshotA() throws {
        let f = try Fixture(); defer { f.remove() }
        let a = f.root.appendingPathComponent("A", isDirectory: true)
        let b = f.root.appendingPathComponent("B", isDirectory: true)
        try f.make(a); try f.make(b)
        let settings = f.settings()
        try settings.setDestinationFolder(a)
        let frozen = settings.snapshot
        try settings.setDestinationFolder(b)
        XCTAssertEqual(try ExportSettings.prepareDestination(for: frozen).path, a.path)
        XCTAssertEqual(f.settings().snapshot.destination, .configuredFolder(b))
        try FileManager.default.moveItem(at: a, to: f.root.appendingPathComponent("A-renamed"))
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: frozen)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertFalse(f.exists(a))
        try f.make(f.pictures)
        _ = try ExportSettings.prepareDestination(for: f.snapshot(.defaultFolder(f.defaultFolder)))
        try settings.setDestinationFolder(f.defaultFolder)
        try FileManager.default.removeItem(at: f.defaultFolder)
        let reopened = f.settings()
        XCTAssertEqual(reopened.snapshot.destination, .configuredFolder(f.defaultFolder))
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: reopened.snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertFalse(f.exists(f.defaultFolder))
    }

    @MainActor
    func testRegularFileAndLeafLinksIncludingTrailingSlashAreNeverReplaced() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.make(f.pictures)
        let bytes = Data("keep me".utf8)
        try bytes.write(to: f.defaultFolder)
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.settings().snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.snapshot(.configuredFolder(f.defaultFolder)))) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertEqual(try Data(contentsOf: f.defaultFolder), bytes)
        try FileManager.default.removeItem(at: f.defaultFolder)
        let real = f.root.appendingPathComponent("real", isDirectory: true)
        try f.make(real)
        for target in [real, f.root.appendingPathComponent("missing-target")] {
            try FileManager.default.createSymbolicLink(at: f.defaultFolder, withDestinationURL: target)
            for url in [f.defaultFolder, URL(fileURLWithPath: f.defaultFolder.path + "/", isDirectory: true)] {
                for destination in [ExportDestination.defaultFolder(url), .configuredFolder(url)] {
                    XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.snapshot(destination))) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
                }
                XCTAssertThrowsError(try f.settings().setDestinationFolder(url)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.defaultFolder.path), target.path)
            try FileManager.default.removeItem(at: f.defaultFolder)
        }
        XCTAssertTrue(f.exists(real))
        XCTAssertFalse(f.exists(f.root.appendingPathComponent("missing-target")))
    }

    @MainActor
    func testParentLinkAndFileRejectedAndENOTDIRPreserved() throws {
        let f = try Fixture(); defer { f.remove() }
        let target = f.root.appendingPathComponent("realPictures", isDirectory: true)
        try f.make(target)
        try FileManager.default.createSymbolicLink(at: f.pictures, withDestinationURL: target)
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.settings().snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertFalse(f.exists(target.appendingPathComponent("getGamen")))
        try FileManager.default.removeItem(at: f.pictures)
        try Data([7]).write(to: f.pictures)
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.settings().snapshot)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.snapshot(.configuredFolder(f.defaultFolder)))) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(ENOTDIR))
        }
        XCTAssertEqual(try Data(contentsOf: f.pictures), Data([7]))
    }

    @MainActor
    func testOriginalNULURLsRejectedButLiteralPercentAndEscapedNamesAccepted() throws {
        let f = try Fixture(); defer { f.remove() }
        let prefix = f.root.appendingPathComponent("prefix", isDirectory: true)
        try f.make(prefix)
        let settings = f.settings()
        let before = settings.snapshot
        let nul = URL(fileURLWithPath: prefix.path + "\0tail", isDirectory: true)
        let encoded = try XCTUnwrap(URL(string: prefix.absoluteString + "%00tail"))
        for bad in [nul, encoded] {
            XCTAssertTrue(bad.absoluteString.lowercased().contains("%00"))
            XCTAssertThrowsError(try settings.setDestinationFolder(bad)) { XCTAssertEqual($0 as? ExportSettingsError, .invalidDestination) }
            XCTAssertThrowsError(try ExportSettings.prepareDestination(for: f.snapshot(.configuredFolder(bad)))) { XCTAssertEqual($0 as? ExportSettingsError, .invalidDestination) }
            XCTAssertEqual(settings.snapshot, before)
            XCTAssertNil(f.defaults.object(forKey: destinationKey))
        }
        XCTAssertTrue(f.exists(prefix))
        for name in ["literal%00", "space 日本 # folder"] {
            let valid = f.root.appendingPathComponent(name, isDirectory: true)
            try f.make(valid)
            if name == "literal%00" { XCTAssertTrue(valid.absoluteString.contains("%2500")) }
            try settings.setDestinationFolder(valid)
            XCTAssertEqual(try ExportSettings.prepareDestination(for: settings.snapshot).path, valid.path)
            XCTAssertEqual(f.settings().snapshot.destination, .configuredFolder(valid))
        }
    }

    @MainActor
    func testInvalidURLSettersPreserveExistingPreference() throws {
        let f = try Fixture(); defer { f.remove() }
        let settings = f.settings()
        try settings.setDestinationFolder(f.root)
        let before = settings.snapshot
        let stored = f.defaults.string(forKey: destinationKey)
        let strings = ["https://example.com/folder", "file://remote.invalid/tmp/folder", "file:///tmp/folder?query", "file:///tmp/folder#fragment"]
        let bad = try strings.map { try XCTUnwrap(URL(string: $0)) } + [try XCTUnwrap(URL(string: "relative", relativeTo: f.root))]
        for url in bad {
            XCTAssertThrowsError(try settings.setDestinationFolder(url)) { XCTAssertEqual($0 as? ExportSettingsError, .invalidDestination) }
            XCTAssertEqual(settings.snapshot, before)
            XCTAssertEqual(f.defaults.string(forKey: destinationKey), stored)
        }
        let absent = f.root.appendingPathComponent("absent", isDirectory: true)
        XCTAssertThrowsError(try settings.setDestinationFolder(absent)) { XCTAssertEqual($0 as? ExportSettingsError, .destinationUnavailable) }
        XCTAssertFalse(f.exists(absent))
        XCTAssertEqual(settings.snapshot, before)
        XCTAssertEqual(f.defaults.string(forKey: destinationKey), stored)
    }

    @MainActor private final class Fixture {
        let suite = "getGamen.ExportSettingsTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        var pictures: URL { root.appendingPathComponent("Pictures", isDirectory: true) }
        var defaultFolder: URL { pictures.appendingPathComponent("getGamen", isDirectory: true) }
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("getGamen-settings-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func settings() -> ExportSettings { ExportSettings(defaults: defaults, defaultFolder: defaultFolder) }
        func snapshot(_ destination: ExportDestination) -> ExportSettingsSnapshot { ExportSettingsSnapshot(format: .png, jpegQuality: 0.9, destination: destination) }
        func make(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
}
