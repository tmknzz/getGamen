import Foundation
import XCTest
@testable import GetGamenCore

final class CaptureFilenameTests: XCTestCase {
    func testRequestedFormatUsesLocalCaptureTime() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T03:29:46Z"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(CaptureFilename.stem(createdAt: date, timeZone: tokyo), "getGamen_2026-10-07-122946")
        XCTAssertEqual(CaptureFilename.stem(createdAt: date, timeZone: TimeZone(secondsFromGMT: 0)!), "getGamen_2026-10-07-032946")
    }
}
