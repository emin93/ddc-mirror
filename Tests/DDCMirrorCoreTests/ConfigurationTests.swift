import DDCMirrorCore
import XCTest

final class ConfigurationTests: XCTestCase {
    func testParsesArgumentsAndEnvironment() throws {
        let configuration = try Configuration.parse(
            arguments: [
                "ddc-mirror",
                "--backend", "m1ddc",
                "--display", "1",
                "--interval", "1.5",
                "--min-delta", "0.02",
                "--min", "5",
                "--max", "90",
                "--once",
                "--verbose",
            ],
            environment: [:]
        )

        XCTAssertEqual(configuration.backend, .m1ddc)
        XCTAssertEqual(configuration.displayTargets, ["1"])
        XCTAssertEqual(configuration.interval, 1.5)
        XCTAssertEqual(configuration.minimumDelta, 0.02)
        XCTAssertEqual(configuration.mapper.percent(forInternalBrightness: 0), 5)
        XCTAssertEqual(configuration.mapper.percent(forInternalBrightness: 1), 90)
        XCTAssertTrue(configuration.once)
        XCTAssertTrue(configuration.verbose)
    }

    func testParsesDisplayListFromEnvironment() throws {
        let configuration = try Configuration.parse(
            arguments: ["ddc-mirror"],
            environment: ["DDC_MIRROR_DISPLAYS": "1, 2"]
        )

        XCTAssertEqual(configuration.displayTargets, ["1", "2"])
    }

    func testParsesBetterDisplayBackend() throws {
        let configuration = try Configuration.parse(
            arguments: ["ddc-mirror", "--backend", "betterdisplay"],
            environment: [:]
        )

        XCTAssertEqual(configuration.backend, .betterdisplay)
    }
}
