import DDCMirrorCore
import XCTest

final class BrightnessMapperTests: XCTestCase {
    func testMapsInternalBrightnessToPercent() throws {
        let mapper = try BrightnessMapper(minimumPercent: 10, maximumPercent: 80)

        XCTAssertEqual(mapper.percent(forInternalBrightness: 0), 10)
        XCTAssertEqual(mapper.percent(forInternalBrightness: 0.5), 45)
        XCTAssertEqual(mapper.percent(forInternalBrightness: 1), 80)
    }

    func testClampsInternalBrightness() throws {
        let mapper = try BrightnessMapper(minimumPercent: 0, maximumPercent: 100)

        XCTAssertEqual(mapper.percent(forInternalBrightness: -1), 0)
        XCTAssertEqual(mapper.percent(forInternalBrightness: 2), 100)
    }

    func testRejectsInvalidRange() {
        XCTAssertThrowsError(try BrightnessMapper(minimumPercent: 80, maximumPercent: 10))
    }
}
