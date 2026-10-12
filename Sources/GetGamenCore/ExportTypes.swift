import Foundation

public enum ExportSlot: String, Codable, Equatable, Sendable { case png, jpg }

public struct ExportStamp: Codable, Equatable, Sendable {
    public let request: UInt64
    public let documentRevision: UInt64
    public init(request: UInt64, documentRevision: UInt64) {
        self.request = request; self.documentRevision = documentRevision
    }
}

public struct PublishedExport: Equatable, Sendable {
    public let url: URL
    public let stamp: ExportStamp
    public init(url: URL, stamp: ExportStamp) { self.url = url; self.stamp = stamp }
}

public enum ExportWriteError: Error, Equatable {
    case invalidData, invalidReceipt, ownershipLost, destinationUnavailable
    case interruptedPublication, staleRequest, sequenceOverflow
}
