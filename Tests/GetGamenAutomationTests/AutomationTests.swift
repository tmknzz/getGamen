import XCTest
import CoreGraphics
import GetGamenCore
@testable import GetGamenAutomation

final class AutomationTests: XCTestCase {
    @MainActor
    func testLapsedLicenseRefusesToolsButStatusReportsIt() async throws {
        let free = AutomationService(licenseState: { .free })
        let status = try await free.execute("status", arguments: [:])
        let license = try XCTUnwrap(status["license"] as? [String: Any])
        XCTAssertEqual(license["state"] as? String, "free")
        XCTAssertNotNil(license["purchase_url"] as? String)
        for (name, arguments) in [("windows", [String: Any]()),
                                  ("convert", ["input": "/nonexistent.png", "output": "/tmp/getgamen-never.png"])] {
            do {
                _ = try await free.execute(name, arguments: arguments)
                XCTFail("\(name) ran without a license")
            } catch {
                XCTAssertEqual(AutomationService.failure(error)["code"] as? String, "license_required")
            }
        }
        let trial = AutomationService(licenseState: { .trial(daysRemaining: 3) })
        let trialStatus = try await trial.execute("status", arguments: [:])
        let trialLicense = try XCTUnwrap(trialStatus["license"] as? [String: Any])
        XCTAssertEqual(trialLicense["state"] as? String, "trial")
        XCTAssertEqual(trialLicense["trial_days_remaining"] as? Int, 3)
    }

    func testScreenCoordinatesConvertBetweenQuartzAndAppKit() throws {
        let primary = RegionDisplay(id: "primary", runtimeID: 1,
            frame: RegionRect(x: 0, y: 0, width: 1920, height: 1080),
            scale: 1, rotation: 0, backingWidth: 1920, backingHeight: 1080)
        let upper = RegionDisplay(id: "upper", runtimeID: 2,
            frame: RegionRect(x: 0, y: 1080, width: 1280, height: 800),
            scale: 1, rotation: 0, backingWidth: 1280, backingHeight: 800)
        let displays = [upper, primary]
        let quartz = RegionRect(x: 0, y: 0, width: 200, height: 100)
        let appKit = try AutomationService.convertScreenRect(quartz, displays: displays)
        XCTAssertEqual(appKit, RegionRect(x: 0, y: 980, width: 200, height: 100))
        XCTAssertEqual(try AutomationService.convertScreenRect(appKit, displays: displays), quartz)
        XCTAssertEqual(try AutomationService.convertScreenRect(primary.frame, displays: displays), primary.frame)
        let upperQuartz = try AutomationService.convertScreenRect(upper.frame, displays: displays)
        XCTAssertEqual(upperQuartz, RegionRect(x: 0, y: -800, width: 1280, height: 800))
        XCTAssertEqual(try AutomationService.convertScreenRect(upperQuartz, displays: displays), upper.frame)
    }

    func testDisplaysOutputUsesQuartzFramesAndPreservesScale() throws {
        let primary = RegionDisplay(id: "primary", runtimeID: 1,
            frame: RegionRect(x: 0, y: 0, width: 1920, height: 1080),
            scale: 2, rotation: 0, backingWidth: 3840, backingHeight: 2160)
        let upper = RegionDisplay(id: "upper", runtimeID: 2,
            frame: RegionRect(x: 0, y: 1080, width: 1280, height: 800),
            scale: 1, rotation: 0, backingWidth: 1280, backingHeight: 800)
        let left = RegionDisplay(id: "left", runtimeID: 3,
            frame: RegionRect(x: -1920, y: -120, width: 1920, height: 1200),
            scale: 1, rotation: 0, backingWidth: 1920, backingHeight: 1200)
        let displays = [upper, left, primary]
        let output = try AutomationService.displaysOutput(displays)
        let coordinateSystem = try XCTUnwrap(output["coordinate_system"] as? String)
        XCTAssertTrue(coordinateSystem.contains("top-left"))
        let rows = try XCTUnwrap(output["displays"] as? [[String: Any]])
        XCTAssertEqual(rows.count, displays.count)
        let expectedFrames = [
            RegionRect(x: 0, y: -800, width: 1280, height: 800),
            RegionRect(x: -1920, y: 0, width: 1920, height: 1200),
            RegionRect(x: 0, y: 0, width: 1920, height: 1080)
        ]
        for (index, row) in rows.prefix(displays.count).enumerated() {
            let expected = expectedFrames[index]
            XCTAssertEqual(row["id"] as? String, displays[index].id)
            XCTAssertEqual(row["x"] as? Double, expected.x)
            XCTAssertEqual(row["y"] as? Double, expected.y)
            XCTAssertEqual(row["width"] as? Double, expected.width)
            XCTAssertEqual(row["height"] as? Double, expected.height)
            XCTAssertEqual(row["scale"] as? Double, displays[index].scale)
        }
    }

    func testScreenCoordinateConversionRequiresPrimaryDisplay() {
        let upper = RegionDisplay(id: "upper", runtimeID: 2,
            frame: RegionRect(x: 0, y: 1080, width: 1280, height: 800),
            scale: 1, rotation: 0, backingWidth: 1280, backingHeight: 800)
        let rect = RegionRect(x: 0, y: 0, width: 200, height: 100)
        for displays in [[], [upper]] {
            XCTAssertThrowsError(try AutomationService.convertScreenRect(rect, displays: displays)) { error in
                XCTAssertEqual((error as? AutomationFailure)?.code, "operation_failed")
            }
        }
    }

    @MainActor
    func testLauncherPathUsesParentAppOrBuildDirectoryAndQuotesShellPaths() {
        XCTAssertEqual(AutomationService.launcherPath(
            bundleURL: URL(fileURLWithPath: "/Applications/getGamen.app/Contents/Helpers/GetGamenAutomation.app"),
            executableURL: nil), "/Applications/getGamen.app/Contents/MacOS/getGamen")
        XCTAssertEqual(AutomationService.launcherPath(
            bundleURL: URL(fileURLWithPath: "/repo/.build/debug"),
            executableURL: URL(fileURLWithPath: "/repo/.build/debug/getGamenAutomation")),
            "/repo/.build/debug/getGamen")
        XCTAssertEqual(AutomationService.launcherPath(
            bundleURL: URL(fileURLWithPath: "/Applications/My Apps/getGamen.app/Contents/Helpers/GetGamenAutomation.app"),
            executableURL: nil), "'/Applications/My Apps/getGamen.app/Contents/MacOS/getGamen'")
        XCTAssertEqual(AutomationService.launcherPath(
            bundleURL: URL(fileURLWithPath: "/repo/.build/debug"),
            executableURL: URL(fileURLWithPath: "/repo/it's here/getGamenAutomation")),
            "'/repo/it'\"'\"'s here/getGamen'")
        XCTAssertEqual(AutomationService.launcherPath(
            bundleURL: URL(fileURLWithPath: "/repo/.build/debug"), executableURL: nil), "getGamen")
    }

    @MainActor
    func testCLIRejectsAmbiguousAndMalformedArguments() throws {
        for args in [["status", "--cursor"], ["windows", "--json", "[1]"],
                     ["convert", "--input", "a", "--input", "b", "--output", "c"],
                     ["capture-region", "--x", "nan"], ["edit", "--edits", "{"]] {
            XCTAssertThrowsError(try AutomationCLI.parse(args), "\(args)")
        }
        let (name, args) = try AutomationCLI.parse(["capture-region", "--x", "-10", "--y", "0", "--width", "100", "--height", "50", "--output", "/tmp/a b.png", "--cursor"])
        XCTAssertEqual(name, "capture_region")
        XCTAssertEqual(args["x"] as? Double, -10)
        XCTAssertEqual(args["cursor"] as? Bool, true)
        let (fractionalName, fractionalArgs) = try AutomationCLI.parse(["capture-window", "--window-id", "1.5", "--output", "out"])
        XCTAssertThrowsError(try AutomationCatalog.validate(name: fractionalName, arguments: fractionalArgs))
        XCTAssertThrowsError(try AutomationCatalog.validate(name: "capture_window", arguments: ["window_id": true, "output": "x"]))
        XCTAssertThrowsError(try AutomationCatalog.validate(name: "convert", arguments: ["input": "a", "output": "b", "quality": 2]))
    }

    @MainActor
    func testFractionalWindowIDIsRejectedThroughProductionCLIAndMCP() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let exitCode = await AutomationCLI.run(["capture-window", "--window-id", "1.5",
            "--output", output.path])
        XCTAssertEqual(exitCode, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let service = AutomationService(licenseState: { .licensed })
        let server = MCPServer(execute: service.execute)
        let initialize = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "initialize", "params": ["protocolVersion": MCPServer.protocolVersion,
                "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]]])
        _ = await server.handle(initialize)
        _ = await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2,
            "method": "tools/call", "params": ["name": "capture_window",
                "arguments": ["window_id": 1.5, "output": output.path]]])
        let response = await server.handle(request)
        let reply = try XCTUnwrap(response)
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testInvalidWindowGeometryHasReadableFailure() {
        let failure = AutomationService.failure(WindowCaptureService.CaptureError.invalidGeometry)
        XCTAssertEqual(failure["code"] as? String, "image_too_large")
        XCTAssertEqual(failure["message"] as? String, "Window size is invalid or too large to capture.")
    }

    @MainActor
    func testUnknownOperationIsRejectedThroughProductionCLIAndMCP() async throws {
        let exitCode = await AutomationCLI.run(["no-such-command"])
        XCTAssertEqual(exitCode, 2)

        let service = AutomationService(licenseState: { .licensed })
        let server = MCPServer(execute: service.execute)
        let initialize = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "initialize", "params": ["protocolVersion": MCPServer.protocolVersion,
                "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]]])
        _ = await server.handle(initialize)
        _ = await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2,
            "method": "tools/call", "params": ["name": "no_such_tool", "arguments": [:]]])
        let response = await server.handle(request)
        let reply = try XCTUnwrap(response)
        XCTAssertNil(reply["result"])
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    @MainActor
    func testIncompatibleEditOptionIsAnArgumentErrorThroughProductionCLIAndMCP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let input = root.appendingPathComponent("source.png")
        try RasterImageCodec.encode(try XCTUnwrap(context.makeImage()), format: .png).write(to: input)
        let output = root.appendingPathComponent("invalid.png")
        let edits: [String: Any] = ["objects": [["type": "mask", "line_width": 3,
            "bounds": ["x": 0, "y": 0, "width": 10, "height": 10]]]]
        let arguments: [String: Any] = ["input": input.path, "output": output.path, "edits": edits]

        let exitCode = await AutomationCLI.run(["edit", "--input", input.path, "--output", output.path,
            "--edits", try MCPServer.json(edits)])
        XCTAssertEqual(exitCode, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let service = AutomationService(licenseState: { .licensed })
        let server = MCPServer(execute: service.execute)
        let initialize = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "initialize", "params": ["protocolVersion": MCPServer.protocolVersion,
                "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]]])
        _ = await server.handle(initialize)
        _ = await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2,
            "method": "tools/call", "params": ["name": "edit", "arguments": arguments]])
        let response = await server.handle(request)
        let reply = try XCTUnwrap(response)
        XCTAssertNil(reply["error"])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "invalid_arguments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testMCPLifecycleAndFailureSeparation() async throws {
        let server = MCPServer { name, arguments in
            do {
                try AutomationCatalog.validate(name: name, arguments: arguments)
            } catch let failure as AutomationFailure {
                throw SchemaViolation(failure: failure)
            }
            if name == "windows" { throw AutomationFailure("permission_required", "No access") }
            return ["screen_recording": false]
        }
        func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "req", "method": method, "params": params])
            return await server.handle(data)!
        }
        let premature = try await request("tools/list")
        XCTAssertEqual((premature["error"] as? [String: Any])?["code"] as? Int, -32002)
        let initReply = try await request("initialize", ["protocolVersion": "future", "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]])
        XCTAssertEqual((initReply["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.protocolVersion)
        let notice = await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(notice)
        let list = try await request("tools/list")
        XCTAssertEqual(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count, 7)
        let success = try await request("tools/call", ["name": "status"])
        XCTAssertEqual((success["result"] as? [String: Any])?["isError"] as? Bool, false)
        let failed = try await request("tools/call", ["name": "windows"])
        XCTAssertEqual((failed["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = try await request("tools/call", ["name": "delete_everything"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
        let invalid = try await request("tools/call", ["name": "capture_window", "arguments": ["window_id": 1.5, "output": "out"]])
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32602)
        let malformed = await server.handle(Data("{".utf8))!
        XCTAssertEqual((malformed["error"] as? [String: Any])?["code"] as? Int, -32700)
        let notification = await server.handle(Data(#"{"jsonrpc":"2.0","method":"something/unknown"}"#.utf8))
        XCTAssertNil(notification)
    }

    @MainActor
    func testOutOfBoundsEditIsAnArgumentErrorAcrossServiceCLIAndMCP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let input = root.appendingPathComponent("source.png")
        try RasterImageCodec.encode(context.makeImage()!, format: .png).write(to: input)
        let output = root.appendingPathComponent("invalid.png")
        let edits: [String: Any] = ["crop": ["x": 15, "y": 0, "width": 10, "height": 10]]
        let arguments: [String: Any] = ["input": input.path, "output": output.path, "edits": edits]
        let service = AutomationService(licenseState: { .licensed })
        do {
            _ = try await service.execute("edit", arguments: arguments)
            XCTFail("Out-of-bounds crop must fail")
        } catch {
            XCTAssertEqual((error as? AutomationFailure)?.code, "invalid_arguments")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let exitCode = await AutomationCLI.run(["edit", "--input", input.path, "--output", output.path,
            "--edits", try MCPServer.json(edits)])
        XCTAssertEqual(exitCode, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let server = MCPServer(execute: service.execute)
        let initialize = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "initialize", "params": ["protocolVersion": MCPServer.protocolVersion,
                "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]]])
        _ = await server.handle(initialize)
        _ = await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2,
            "method": "tools/call", "params": ["name": "edit", "arguments": arguments]])
        let response = await server.handle(request)
        let reply = try XCTUnwrap(response)
        XCTAssertNil(reply["error"])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "invalid_arguments")

        let convertRequest = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 3,
            "method": "tools/call", "params": ["name": "convert",
                "arguments": ["input": input.path, "output": output.path, "format": "png", "quality": 0.5]]])
        let convertResponse = await server.handle(convertRequest)
        let convertReply = try XCTUnwrap(convertResponse)
        XCTAssertNil(convertReply["error"])
        let convertResult = try XCTUnwrap(convertReply["result"] as? [String: Any])
        XCTAssertEqual(convertResult["isError"] as? Bool, true)
        let convertContent = try XCTUnwrap(convertResult["content"] as? [[String: Any]])
        let convertText = try XCTUnwrap(convertContent.first?["text"] as? String)
        let convertBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(convertText.utf8)) as? [String: Any])
        XCTAssertEqual((convertBody["error"] as? [String: Any])?["code"] as? String, "invalid_arguments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testMCPServeSkipsBlankLines() async throws {
        let input = Pipe()
        let output = Pipe()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let server = MCPServer { _, _ in
            XCTFail("Ping must not execute a tool")
            return [:]
        }
        let text = "\n  \t\n\r\n" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n"
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
        try await server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, "")
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(reply["id"] as? Int, 1)
        XCTAssertNotNil(reply["result"] as? [String: Any])
        XCTAssertNil(reply["error"])
    }

    @MainActor
    func testMCPInitializeUsesInjectedVersion() async throws {
        let server = MCPServer(version: "9.8.7") { _, _ in [:] }
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": "initialize", "params": ["protocolVersion": MCPServer.protocolVersion,
                "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]]])
        let response = await server.handle(request)
        let reply = try XCTUnwrap(response)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["version"] as? String, "9.8.7")
    }

    @MainActor
    func testEditConvertAndNoOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let original = try RasterImageCodec.encode(context.makeImage()!, format: .png)
        let input = root.appendingPathComponent("source.png")
        try original.write(to: input)
        let output = root.appendingPathComponent("result.png")
        let edits: [String: Any] = ["crop": ["x": 0, "y": 0, "width": 8, "height": 6],
            "objects": [["type": "mask", "bounds": ["x": 0, "y": 0, "width": 20, "height": 10]]]]
        let service = AutomationService(licenseState: { .licensed })
        let result = try await service.execute("edit", arguments: ["input": input.path, "output": output.path, "edits": edits])
        XCTAssertEqual(result["width"] as? Int, 8)
        XCTAssertEqual(result["height"] as? Int, 6)
        let decoded = try RasterImageDecoder.decode(Data(contentsOf: output))
        var pixel = [UInt8](repeating: 255, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let sample = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            sample.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(Array(pixel.prefix(3)), [0, 0, 0])
        XCTAssertEqual(try Data(contentsOf: input), original)
        do {
            _ = try await service.execute("convert", arguments: ["input": input.path, "output": input.path])
            XCTFail("Must not overwrite")
        } catch { XCTAssertEqual((error as? AutomationFailure)?.code, "output_exists") }
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        do { _ = try await service.execute("convert", arguments: ["input": input.path, "output": link.path]); XCTFail("Must not follow output symlink") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: input), original)
        let jpeg = root.appendingPathComponent("new.jpg")
        _ = try await service.execute("convert", arguments: ["input": input.path, "output": jpeg.path, "format": "jpeg", "quality": 0.7])
        XCTAssertEqual(Array(try Data(contentsOf: jpeg).prefix(2)), [0xff, 0xd8])
        let invalid = root.appendingPathComponent("invalid.png")
        do {
            _ = try await service.execute("edit", arguments: ["input": input.path, "output": invalid.path,
                "edits": ["crop": ["x": 0, "y": 0, "width": -1, "height": 10]]])
            XCTFail("Invalid crop must fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
    }
}
