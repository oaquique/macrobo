import XCTest
@testable import MacroboLib

/// Leftover partial files, resuming safely, and what the summary shows
final class LeftoversAndSummaryTests: XCTestCase {
    var base: URL!
    var srcDir: URL!
    var dstDir: URL!
    let fm = FileManager.default
    let longAgo = Date(timeIntervalSinceNow: -3600)

    override func setUp() {
        super.setUp()
        base = fm.temporaryDirectory.appendingPathComponent("macrobo-ls-\(UUID().uuidString)")
        srcDir = base.appendingPathComponent("src")
        dstDir = base.appendingPathComponent("dst")
        try! fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: base)
        super.tearDown()
    }

    private func write(_ name: String, in dir: URL, _ data: Data, modified: Date? = nil) {
        let file = dir.appendingPathComponent(name)
        try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
        if let modified { try! fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
    }

    private func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: dstDir.appendingPathComponent(name).path)
    }

    private func run(_ configure: (inout CopyOptions) -> Void = { _ in }) async throws -> CopyResult {
        var options = CopyOptions(source: srcDir, destination: dstDir)
        configure(&options)
        let engine = CopyEngine(options: options, logger: Logger(quiet: true), progress: ProgressReporter(quiet: true))
        return try await engine.run()
    }

    /// A destination that already matches the source, plus an old partial file beside one file
    private func makeLeftover() async throws {
        write("videos/clip.mov", in: srcDir, Data("complete".utf8))
        write("other.txt", in: srcDir, Data("other".utf8))
        _ = try await run()
        write("videos/clip.mov" + FileOperations.partialSuffix, in: dstDir, Data("comp".utf8), modified: longAgo)
    }

    // MARK: - Leftover partial files

    func testNormalRunRemovesALeftoverPartialOfACompleteFile() async throws {
        try await makeLeftover()
        let result = try await run()
        XCTAssertFalse(exists("videos/clip.mov" + FileOperations.partialSuffix))
        XCTAssertTrue(exists("videos/clip.mov"))
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertEqual(result.filesDeleted, 0, "a leftover is not one of the user's files")
    }

    func testDryRunListsTheLeftoverAndKeepsIt() async throws {
        try await makeLeftover()
        let result = try await run { $0.dryRun = true }
        XCTAssertTrue(exists("videos/clip.mov" + FileOperations.partialSuffix))
        XCTAssertEqual(result.wouldRemoveLeftovers, 1)
        XCTAssertTrue(result.summary.contains("Would remove: 1 leftover partial file"), result.summary)
    }

    func testMirrorDryRunListsTheLeftoverOnce() async throws {
        try await makeLeftover()
        let result = try await run { $0.dryRun = true; $0.mirror = true }
        XCTAssertEqual(result.wouldRemoveLeftovers, 1)
        XCTAssertEqual(result.wouldDeleteFiles, 0, "the leftover must not be counted again as an extra")
    }

    func testChecksumRunRemovesTheLeftoverOfAnIdenticalFile() async throws {
        try await makeLeftover()
        // Same contents, different date: only the checksum proves the file complete
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: dstDir.appendingPathComponent("videos/clip.mov").path)
        let result = try await run { $0.checksum = true }
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertFalse(exists("videos/clip.mov" + FileOperations.partialSuffix))
    }

    func testRecentPartialIsLeftAloneInCaseACopyIsWritingIt() async throws {
        try await makeLeftover()
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dstDir.appendingPathComponent("videos/clip.mov" + FileOperations.partialSuffix).path)
        _ = try await run()
        XCTAssertTrue(exists("videos/clip.mov" + FileOperations.partialSuffix))
    }

    // MARK: - Resuming

    /// The temp folder is one APFS volume, where copies are clones and never stream through a
    /// partial file, so the resume decision is tested directly
    func testResumesOnlyAPartialWrittenAfterTheSourceChanged() {
        let edited = Date(timeIntervalSince1970: 1_700_000_000)
        func offset(_ size: UInt64?, _ written: Date?) -> UInt64? {
            FileOperations.resumableOffset(partialSize: size, partialModified: written, sourceSize: 3_000_000, sourceModified: edited)
        }
        XCTAssertEqual(offset(1_000_000, edited.addingTimeInterval(60)), 1_000_000)
        XCTAssertEqual(offset(1_000_000, edited), 1_000_000)
        XCTAssertNil(offset(1_000_000, edited.addingTimeInterval(-60)), "started before the source was edited: old bytes")
        XCTAssertNil(offset(3_000_000, edited.addingTimeInterval(60)), "as long as the source: nothing to resume")
        XCTAssertNil(offset(0, edited.addingTimeInterval(60)))
        XCTAssertNil(offset(1_000_000, nil))
    }

    // MARK: - Summary

    func testSpeedCoversTheCopyingAlone() {
        var result = CopyResult()
        result.startTime = Date(timeIntervalSinceNow: -800) // a long checksum pass came first
        result.bytesCopied = 100_000_000
        result.copyDuration = 1
        result.finish()
        XCTAssertEqual(result.bytesPerSecond, 100_000_000, accuracy: 1)
        XCTAssertTrue(result.summary.contains("Speed: 100.00 MB/s"), result.summary)
    }

    func testNothingCopiedShowsNoSpeed() {
        var result = CopyResult()
        result.filesSkipped = 5
        result.finish()
        XCTAssertFalse(result.summary.contains("Speed"), result.summary)
        XCTAssertTrue(result.summary.contains("Files copied: 0"), result.summary)
    }

    func testPurgeSummaryShowsOnlyDeletes() async throws {
        write("keep.txt", in: srcDir, Data("k".utf8))
        write("keep.txt", in: dstDir, Data("k".utf8))
        write("extra.txt", in: dstDir, Data("x".utf8))
        let summary = try await run { $0.purge = true }.summary
        XCTAssertTrue(summary.contains("Files deleted: 1"), summary)
        XCTAssertTrue(summary.contains("Directories deleted: 0"), summary)
        XCTAssertTrue(summary.contains("Duration"), summary)
        for row in ["Files copied", "Files skipped", "Bytes copied", "Speed", "Directories created"] {
            XCTAssertFalse(summary.contains(row), "\(row) means nothing when nothing is copied:\n\(summary)")
        }
    }
}
