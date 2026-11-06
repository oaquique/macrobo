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

    /// Regression: a large file (streaming-copy path) must keep the source mtime so
    /// the second run recognizes it as identical and skips it. On network volumes
    /// (SMB/NFS) with delayed write-back, failing to fsync the destination before
    /// stamping the mtime lets the server bump the mtime to commit-time, causing the
    /// file to be re-copied on every run. See streamingCopy() fsync-before-rename.
    func testLargeFilePreservesMtimeAndSkipsOnSecondRun() async throws {
        // > 2 * chunkSize (1MB) to force the streaming path rather than simpleFileCopy.
        let big = srcDir.appendingPathComponent("large.bin")
        try Data(repeating: 0x5A, count: 3 * 1024 * 1024).write(to: big)
        let pastDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: big.path)

        let options = CopyOptions(source: srcDir, destination: dstDir)
        let first = try await runCopy(options: options)
        XCTAssertEqual(first.filesCopied, 1)

        // Destination mtime must match the source (streaming path stamped it).
        let dst = dstDir.appendingPathComponent("large.bin")
        let srcMtime = FileOperations.modificationDate(at: big)!
        let dstMtime = FileOperations.modificationDate(at: dst)!
        XCTAssertLessThan(abs(srcMtime.timeIntervalSince(dstMtime)), 1.0,
                          "large-file dest mtime drifted from source: \(srcMtime) vs \(dstMtime)")

        // Second run must skip it (this is the behavior that broke on SMB).
        let second = try await runCopy(options: options)
        XCTAssertEqual(second.filesCopied, 0, "identical large file was re-copied on the second run")
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

    // MARK: - Scan phase (parallel compare, purge lookup)

    private func setMtime(_ date: Date, _ relative: String, in dir: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: dir.appendingPathComponent(relative).path)
    }

    func testEnumerationRelativePathsThroughSymlinkedParent() throws {
        // /tmp -> /private/tmp: relative paths must not depend on how the root is spelled
        let base = URL(fileURLWithPath: "/tmp/macrobo-enum-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        createFile("a.txt", in: base)
        createFile("sub/b.txt", in: base)
        createFile("sub/deep/c.txt", in: base)
        createFile("node_modules/x.js", in: base)
        let result = try FileEnumerator.enumerateSource(
            source: base, skipHidden: true, excludeDirs: ["node_modules"],
            excludeFiles: [], includeFiles: [], minSize: nil, maxSize: nil
        )
        XCTAssertEqual(Set(result.files.map(\.relativePath)), ["/a.txt", "/sub/b.txt", "/sub/deep/c.txt"])
        XCTAssertEqual(result.directoryRelativePaths, ["/sub", "/sub/deep"])
        XCTAssertTrue(result.files.allSatisfy { $0.modificationDate != nil })
    }

    func testIncrementalRunAcrossManyFiles() async throws {
        // Enough files to spread the compare across several workers and chunks
        for i in 0..<400 { createFile("dir\(i % 10)/file\(i).txt", in: srcDir, content: "content \(i)") }
        let options = CopyOptions(source: srcDir, destination: dstDir)
        let first = try await runCopy(options: options)
        XCTAssertEqual(first.filesCopied, 400)
        createFile("dir1/file11.txt", in: srcDir, content: "changed and longer")
        createFile("dir5/file105.txt", in: srcDir, content: "changed and longer")
        createFile("dir9/new.txt", in: srcDir, content: "new")
        let second = try await runCopy(options: options)
        XCTAssertEqual(second.filesCopied, 3)
        let third = try await runCopy(options: options)
        XCTAssertEqual(third.filesCopied, 0)
    }

    func testMirrorKeepsDestinationFilesThatExistInSourceButAreNotCopied() async throws {
        createFile("keep.txt", in: srcDir)
        createFile("sub/nested.txt", in: srcDir)
        createFile("skip.log", in: srcDir)          // excluded by pattern
        createFile(".hidden", in: srcDir)           // skipped by the scan
        createFile("cache/blob.bin", in: srcDir)    // excluded directory
        createFile("skip.log", in: dstDir)
        createFile(".hidden", in: dstDir)
        createFile("cache/blob.bin", in: dstDir)
        createFile("extra.txt", in: dstDir)
        createFile("gone/old.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        options.excludeFiles = ["*.log"]
        options.excludeDirectories = ["cache"]
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesFailed, 0)
        let fm = FileManager.default
        for kept in ["keep.txt", "sub/nested.txt", "skip.log", ".hidden", "cache/blob.bin"] {
            XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent(kept).path), kept)
        }
        XCTAssertFalse(fm.fileExists(atPath: dstDir.appendingPathComponent("extra.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: dstDir.appendingPathComponent("gone").path))
    }

    func testMirrorThroughSymlinkedParentKeepsNestedFiles() async throws {
        let base = URL(fileURLWithPath: "/tmp/macrobo-mirror-test-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        defer { try? FileManager.default.removeItem(at: base) }
        createFile("sub/keep.txt", in: src)
        createFile("sub/extra.txt", in: dst)
        var options = CopyOptions(source: src, destination: dst)
        options.mirror = true
        _ = try await runCopy(options: options)
        let second = try await runCopy(options: options)
        XCTAssertEqual(second.filesCopied, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("sub/keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("sub/extra.txt").path))
    }

    func testExcludeOlderSkipsWhenDestinationIsNewer() async throws {
        createFile("newer-dst.txt", in: srcDir, content: "source version")
        createFile("older-dst.txt", in: srcDir, content: "source version")
        createFile("newer-dst.txt", in: dstDir, content: "dest")
        createFile("older-dst.txt", in: dstDir, content: "dest")
        let now = Date()
        try setMtime(now.addingTimeInterval(-100), "newer-dst.txt", in: srcDir)
        try setMtime(now, "newer-dst.txt", in: dstDir)
        try setMtime(now, "older-dst.txt", in: srcDir)
        try setMtime(now.addingTimeInterval(-100), "older-dst.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.excludeOlder = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
        let kept = try String(contentsOf: dstDir.appendingPathComponent("newer-dst.txt"), encoding: .utf8)
        XCTAssertEqual(kept, "dest")
    }

    func testChecksumCopiesChangedContentOfSameSize() async throws {
        createFile("file.txt", in: srcDir, content: "AAAA")
        createFile("file.txt", in: dstDir, content: "BBBB")
        try setMtime(Date().addingTimeInterval(-100), "file.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.checksum = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
    }

    func testIncludeSameRecopiesIdenticalFiles() async throws {
        createFile("same.txt", in: srcDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        _ = try await runCopy(options: options)
        options.includeSame = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 1)
    }

    func testDestinationAttributesTreatDanglingSymlinkAsMissing() throws {
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let link = dstDir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(DestinationComparator.destinationAttributes(atPath: link.path))
        XCTAssertNil(DestinationComparator.destinationAttributes(atPath: dstDir.appendingPathComponent("missing").path))
        createFile("real.txt", in: dstDir, content: "12345")
        XCTAssertEqual(DestinationComparator.destinationAttributes(atPath: dstDir.appendingPathComponent("real.txt").path)?.size, 5)
    }
}
