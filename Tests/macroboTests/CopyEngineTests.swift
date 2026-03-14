import XCTest
@testable import MacroboLib

final class CopyEngineTests: XCTestCase {
    var srcDir: URL!
    var dstDir: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrobo-integration-\(UUID().uuidString)")
        srcDir = base.appendingPathComponent("src")
        dstDir = base.appendingPathComponent("dst")
        try! FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: srcDir.deletingLastPathComponent())
        super.tearDown()
    }

    private func createFile(_ name: String, in dir: URL, content: String = "test content") {
        let file = dir.appendingPathComponent(name)
        let parent = file.deletingLastPathComponent()
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: file)
    }

    private func runCopy(options: CopyOptions) async throws -> CopyResult {
        let logger = Logger(quiet: true)
        let progress = ProgressReporter(quiet: true)
        let engine = CopyEngine(options: options, logger: logger, progress: progress)
        return try await engine.run()
    }

    func testBasicCopy() async throws {
        createFile("file1.txt", in: srcDir, content: "hello")
        createFile("subdir/file2.txt", in: srcDir, content: "world")
        let options = CopyOptions(source: srcDir, destination: dstDir)
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertEqual(result.filesFailed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("file1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("subdir/file2.txt").path))
    }

    func testSkipsIdenticalFiles() async throws {
        createFile("same.txt", in: srcDir, content: "unchanged")
        let options = CopyOptions(source: srcDir, destination: dstDir)
        _ = try await runCopy(options: options)
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 0)
    }

    func testExcludeFiles() async throws {
        createFile("keep.txt", in: srcDir)
        createFile("skip.log", in: srcDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.excludeFiles = ["*.log"]
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("skip.log").path))
    }

    func testIncludeFiles() async throws {
        createFile("wanted.swift", in: srcDir)
        createFile("unwanted.txt", in: srcDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.includeFiles = ["*.swift"]
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
    }

    func testExcludeDirectories() async throws {
        createFile("root.txt", in: srcDir)
        createFile("node_modules/dep.js", in: srcDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.excludeDirectories = ["node_modules"]
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
    }

    func testMirrorDeletesExtras() async throws {
        createFile("src_file.txt", in: srcDir)
        try! FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        createFile("extra.txt", in: dstDir, content: "should be deleted")
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertTrue(result.filesDeleted > 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("extra.txt").path))
    }

    func testDryRunCopiesNothing() async throws {
        createFile("file.txt", in: srcDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.dryRun = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 0)
    }

    func testUnicodeFilenames() async throws {
        createFile("日本語ファイル.txt", in: srcDir, content: "unicode")
        createFile("émojis 🎉.txt", in: srcDir, content: "fun")
        let options = CopyOptions(source: srcDir, destination: dstDir)
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertEqual(result.filesFailed, 0)
    }

    func testEmptyFile() async throws {
        createFile("empty.txt", in: srcDir, content: "")
        let options = CopyOptions(source: srcDir, destination: dstDir)
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        let dstSize = FileOperations.fileSize(at: dstDir.appendingPathComponent("empty.txt"))
        XCTAssertEqual(dstSize, 0)
    }

    func testMinSizeFilter() async throws {
        createFile("small.txt", in: srcDir, content: "hi")
        createFile("big.txt", in: srcDir, content: String(repeating: "x", count: 1000))
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.minFileSize = 500
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("big.txt").path))
    }

    func testCopyFromSymlinkedParentPath() async throws {
        // /tmp is a symlink to /private/tmp on macOS, so using /tmp as parent
        // tests that resolving symlinks produces correct relative paths
        let tmpBase = URL(fileURLWithPath: "/tmp/macrobo-symlink-test-\(UUID().uuidString)")
        let tmpSrc = tmpBase.appendingPathComponent("src")
        let tmpDst = tmpBase.appendingPathComponent("dst")
        defer { try? FileManager.default.removeItem(at: tmpBase) }
        try FileManager.default.createDirectory(at: tmpSrc.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try Data("from symlink".utf8).write(to: tmpSrc.appendingPathComponent("subdir/nested.txt"))
        // Pass the /tmp path (unresolved symlink) as source
        let options = CopyOptions(source: tmpSrc, destination: tmpDst)
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesFailed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDst.appendingPathComponent("subdir/nested.txt").path
        ))
    }

    func testVerifyMode() async throws {
        createFile("verified.txt", in: srcDir, content: "verify me please")
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.verify = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesFailed, 0)
    }

    func testChecksumSkipsIdenticalContent() async throws {
        createFile("file.txt", in: srcDir, content: "same content")
        var options = CopyOptions(source: srcDir, destination: dstDir)
        _ = try await runCopy(options: options)
        let dstFile = dstDir.appendingPathComponent("file.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-100)],
            ofItemAtPath: dstFile.path
        )
        options.checksum = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 0)
    }
}
