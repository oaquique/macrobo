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

    // MARK: - formatDuration
    func testFormatDurationSeconds() {
        XCTAssertEqual(formatDuration(5.3), "5.3 seconds")
    }
    func testFormatDurationMinutes() {
        XCTAssertEqual(formatDuration(125), "2m 5s")
    }
    func testFormatDurationHours() {
        XCTAssertEqual(formatDuration(7260), "2h 1m")
    }
    func testFormatDurationCompact() {
        XCTAssertEqual(formatDuration(125, compact: true), "02m05s")
        XCTAssertEqual(formatDuration(7260, compact: true), "02h01m")
        XCTAssertEqual(formatDuration(90000, compact: true), "01d01h")
    }

    // MARK: - formatTruncate
    func testTruncateShortString() {
        XCTAssertEqual(formatTruncate("hello", maxWidth: 10), "hello")
    }
    func testTruncateLongString() {
        XCTAssertEqual(formatTruncate("very_long_filename.txt", maxWidth: 10), "...ame.txt")
    }
    func testTruncateWithPad() {
        XCTAssertEqual(formatTruncate("hi", maxWidth: 5, pad: true), "hi   ")
    }

    // MARK: - parseSize
    func testParseSizeBytes() { XCTAssertEqual(parseSize("1024"), 1024) }
    func testParseSizeKilobytes() { XCTAssertEqual(parseSize("100K"), 100_000) }
    func testParseSizeMegabytes() { XCTAssertEqual(parseSize("50M"), 50_000_000) }
    func testParseSizeGigabytes() { XCTAssertEqual(parseSize("2G"), 2_000_000_000) }
    func testParseSizeCaseInsensitive() { XCTAssertEqual(parseSize("100m"), 100_000_000) }
    func testParseSizeInvalid() { XCTAssertNil(parseSize("")); XCTAssertNil(parseSize("abc")) }
}
