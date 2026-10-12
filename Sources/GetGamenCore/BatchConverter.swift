import Foundation

/// Serial conversion bounds peak raster memory and gives every input its own output name.
public actor BatchConverter {
    public struct Item: Sendable {
        public let input: URL
        public let output: URL?
        public let error: String?
    }
    public struct Result: Sendable {
        public let folder: URL
        public let items: [Item]
    }

    public init() {}

    public func convert(_ inputs: [URL], destination: URL, format: ExportFormat,
                        jpegQuality: Double) throws -> Result {
        let codec = try format.codecFormat(jpegQuality: jpegQuality)
        let folder = destination.appendingPathComponent("getGamen-変換-\(UUID().uuidString)", isDirectory: true)
        // No recursive creation: a missing/inaccessible destination is a visible failure.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var items: [Item] = []
        for (index, input) in inputs.enumerated() {
            do {
                try Task.checkCancellation()
                guard input.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                let bytes = try RasterImageDecoder.readFile(input)
                let image = try RasterImageDecoder.decode(bytes)
                let encoded = try RasterImageCodec.encode(image, format: codec)
                let name = input.deletingPathExtension().lastPathComponent
                let output = folder.appendingPathComponent("\(index + 1)-\(name).\(format == .jpeg ? "jpg" : "png")")
                // A new job directory plus exclusive publication cannot overwrite an input or another job.
                let staging = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
                defer { if FileManager.default.fileExists(atPath: staging.path) { try? FileManager.default.removeItem(at: staging) } }
                try encoded.write(to: staging, options: .withoutOverwriting)
                try FileManager.default.moveItem(at: staging, to: output)
                items.append(Item(input: input, output: output, error: nil))
            } catch {
                items.append(Item(input: input, output: nil, error: error.localizedDescription))
            }
        }
        return Result(folder: folder, items: items)
    }
}
