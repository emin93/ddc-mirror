import DDCMirrorCore
import XCTest

final class ConfigurationFileTests: XCTestCase {
    func testParsesEnvironmentFile() {
        let values = ConfigurationFile.parse("""
        # comment
        DDC_MIRROR_BACKEND=betterdisplay
        DDC_MIRROR_DISPLAYS="abc-123"
        EMPTY =
        """)

        XCTAssertEqual(values["DDC_MIRROR_BACKEND"], "betterdisplay")
        XCTAssertEqual(values["DDC_MIRROR_DISPLAYS"], "abc-123")
        XCTAssertEqual(values["EMPTY"], "")
    }
}
