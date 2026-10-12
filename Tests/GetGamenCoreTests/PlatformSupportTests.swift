import XCTest
@testable import GetGamenCore

final class PlatformSupportTests: XCTestCase {
    func testCaptureDefaultsExcludeShadowsAndAudio() {
        let configuration = PlatformSupport.captureConfiguration(showsCursor: false)
        XCTAssertTrue(configuration.ignoreShadowsSingleWindow)
        XCTAssertFalse(configuration.capturesAudio)
        XCTAssertFalse(configuration.showsCursor)
    }

    func testCursorSettingIsAppliedIndependently() {
        let visible = PlatformSupport.captureConfiguration(showsCursor: true)
        let hidden = PlatformSupport.captureConfiguration(showsCursor: false)
        XCTAssertTrue(visible.showsCursor)
        XCTAssertFalse(hidden.showsCursor)
        XCTAssertTrue(visible.ignoreShadowsSingleWindow)
    }
}
