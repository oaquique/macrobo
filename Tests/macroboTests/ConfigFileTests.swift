import XCTest
@testable import MacroboLib

final class ConfigFileTests: XCTestCase {
    func testParseBasicConfig() {
        let content = "source: ~/Photos\ndestination: /Volumes/NAS\nmirror: true\nthreads: 4"
        let config = ConfigFile.parse(content)
        XCTAssertEqual(config.values["source"], "~/Photos")
        XCTAssertEqual(config.values["mirror"], "true")
        XCTAssertEqual(config.values["threads"], "4")
    }

    func testSkipsCommentsAndEmptyLines() {
        let content = "# comment\nsource: /src\n\ndestination: /dst"
        let config = ConfigFile.parse(content)
        XCTAssertEqual(config.values.count, 2)
    }

    func testApplyToOptions() {
        let content = "mirror: true\nthreads: 16\nexclude-dirs: .git node_modules\nbwlimit: 50M"
        let config = ConfigFile.parse(content)
        var options = CopyOptions(source: URL(fileURLWithPath: "/src"), destination: URL(fileURLWithPath: "/dst"))
        var warnings: [String] = []
        config.apply(to: &options, warnings: &warnings)
        XCTAssertTrue(options.mirror)
        XCTAssertEqual(options.threadCount, 16)
        XCTAssertEqual(options.excludeDirectories, [".git", "node_modules"])
        XCTAssertEqual(options.bandwidthLimit, 50_000_000)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testUnknownKeyWarning() {
        let config = ConfigFile.parse("future-flag: value")
        var options = CopyOptions(source: URL(fileURLWithPath: "/src"), destination: URL(fileURLWithPath: "/dst"))
        var warnings: [String] = []
        config.apply(to: &options, warnings: &warnings)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("future-flag"))
    }
}
