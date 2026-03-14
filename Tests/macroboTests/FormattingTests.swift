import XCTest
@testable import MacroboLib

final class FormattingTests: XCTestCase {
    func testFormatBytesZero() {
        XCTAssertEqual(formatBytes(0), "0 B")
    }
    func testFormatBytesSmall() {
        XCTAssertEqual(formatBytes(500), "500 B")
        XCTAssertEqual(formatBytes(999), "999 B")
    }
    func testFormatBytesKilobytes() {
        XCTAssertEqual(formatBytes(1000), "1.00 KB")
        XCTAssertEqual(formatBytes(1500), "1.50 KB")
    }
    func testFormatBytesMegabytes() {
        XCTAssertEqual(formatBytes(1_000_000), "1.00 MB")
        XCTAssertEqual(formatBytes(2_500_000), "2.50 MB")
    }
    func testFormatBytesGigabytes() {
        XCTAssertEqual(formatBytes(1_000_000_000), "1.00 GB")
    }
    func testFormatBytesTerabytes() {
        XCTAssertEqual(formatBytes(1_000_000_000_000), "1.00 TB")
    }
    func testFormatBytesPrecision() {
        XCTAssertEqual(formatBytes(1_500_000, precision: 1), "1.5 MB")
        XCTAssertEqual(formatBytes(1_500_000, precision: 0), "2 MB")
    }
}
