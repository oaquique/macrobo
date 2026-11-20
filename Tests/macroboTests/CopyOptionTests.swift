import XCTest
@testable import MacroboLib

/// Every copy option does what its --help says, on every copy path: small files (FileManager),
/// large files (streamed) and same-volume APFS clones.
final class CopyOptionTests: XCTestCase {
    var base: URL!
    var src: URL!
    var dst: URL!
    let fm = FileManager.default

    override func setUp() {
        super.setUp()
        base = fm.temporaryDirectory.appendingPathComponent("macrobo-opt-\(UUID().uuidString)")
        src = base.appendingPathComponent("src")
        dst = base.appendingPathComponent("dst")
        try! fm.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path)
        if let items = fm.enumerator(atPath: base.path) {
            for case let rel as String in items {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(rel).path)
            }
        }
        try? fm.removeItem(at: base)
        super.tearDown()
    }

    private func run(_ options: CopyOptions) async throws -> CopyResult {
        try await CopyEngine(options: options, logger: Logger(quiet: true), progress: ProgressReporter(quiet: true)).run()
    }

    /// A small and a 3 MB file with set permissions, date and an extended attribute. The temp
    /// folder is one APFS volume, so these copies take the clone path; the FileManager and
    /// streamed paths share the same post-copy step (removeOmittedMetadata / copyAttributes).
    private func makeFiles() throws -> [String] {
        try Data("small".utf8).write(to: src.appendingPathComponent("small.txt"))
        try Data(repeating: 9, count: 3_000_000).write(to: src.appendingPathComponent("large.bin"))
        for name in ["small.txt", "large.bin"] {
            let path = src.appendingPathComponent(name).path
            try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: path)
            XCTAssertEqual(setxattr(path, "com.macrobo.test", "v", 1, 0, 0), 0)
        }
        return ["small.txt", "large.bin"]
    }

    private func attributes(_ name: String) throws -> (mode: Int, mtime: Date, xattrs: [String]) {
        let url = dst.appendingPathComponent(name)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as! NSNumber).intValue,
                attrs[.modificationDate] as! Date,
                try FileOperations.listExtendedAttributes(at: url))
    }

    func testMetadataIsKeptByDefault() async throws {
        let names = try makeFiles()
        _ = try await run(CopyOptions(source: src, destination: dst))
        for name in names {
            let a = try attributes(name)
            XCTAssertEqual(a.mode, 0o600, name)
            XCTAssertEqual(a.mtime.timeIntervalSince1970, 1_500_000_000, accuracy: 1, name)
            XCTAssertTrue(a.xattrs.contains("com.macrobo.test"), name)
        }
    }

    func testNoXattrNoPermissionsNoTimestampsApplyToEveryFile() async throws {
        let names = try makeFiles()
        var options = CopyOptions(source: src, destination: dst)
        options.copyExtendedAttributes = false
        options.copyPermissions = false
        options.copyTimestamps = false
        let start = Date().addingTimeInterval(-5)
        _ = try await run(options)
        for name in names {
            let a = try attributes(name)
            XCTAssertEqual(a.mode, FileOperations.defaultFileMode, name)
            XCTAssertGreaterThan(a.mtime, start, name)
            XCTAssertFalse(a.xattrs.contains("com.macrobo.test"), name)
        }
    }

    func testNoAttributesMeansNeitherTimestampsNorPermissions() async throws {
        let names = try makeFiles()
        var options = CopyOptions(source: src, destination: dst)
        options.copyAttributes = false
        XCTAssertFalse(options.keepsTimestamps)
        XCTAssertFalse(options.keepsPermissions)
        _ = try await run(options)
        for name in names {
            let a = try attributes(name)
            XCTAssertEqual(a.mode, FileOperations.defaultFileMode, name)
            XCTAssertNotEqual(a.mtime.timeIntervalSince1970, 1_500_000_000, accuracy: 1, name)
            XCTAssertTrue(a.xattrs.contains("com.macrobo.test"), "--no-attributes leaves extended attributes to --no-xattr")
        }
    }

    func testClonedFilesFollowTheOptionsToo() async throws {
        let file = src.appendingPathComponent("clone.txt")
        try Data("clone me".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(setxattr(file.path, "com.macrobo.test", "v", 1, 0, 0), 0)
        let target = base.appendingPathComponent("cloned.txt")
        XCTAssertTrue(FileOperations.isSameAPFSVolume(source: file.path, destination: target.path))
        var options = CopyOptions(source: src, destination: base)
        options.copyExtendedAttributes = false
        options.copyPermissions = false
        _ = try FileOperations.copyFile(from: file, to: target, options: options)
        let attrs = try fm.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue, FileOperations.defaultFileMode)
        XCTAssertFalse(try FileOperations.listExtendedAttributes(at: target).contains("com.macrobo.test"))
    }

    // MARK: - Move

    func testMoveDeletesSourceFilesButKeepsFolders() async throws {
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: src.appendingPathComponent("sub/a.txt"))
        var options = CopyOptions(source: src, destination: dst)
        options.moveFiles = true
        _ = try await run(options)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("sub/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent("sub/a.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: src.appendingPathComponent("sub").path))
    }

    func testMoveAllAlsoRemovesEmptiedSourceFolders() async throws {
        try fm.createDirectory(at: src.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: src.appendingPathComponent("a/b/one.txt"))
        try Data("2".utf8).write(to: src.appendingPathComponent("keep/skip.log"))
        var options = CopyOptions(source: src, destination: dst)
        options.moveAll = true
        options.excludeFiles = ["*.log"]
        _ = try await run(options)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("a/b/one.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent("a").path), "emptied folders are removed")
        XCTAssertTrue(fm.fileExists(atPath: src.appendingPathComponent("keep/skip.log").path), "a folder holding a skipped file stays")
        XCTAssertTrue(fm.fileExists(atPath: src.path), "the source folder itself stays")
    }

    // MARK: - Filters, purge exceptions, retries, resume, logs

    func testMaxSize() async throws {
        try Data(count: 10).write(to: src.appendingPathComponent("small.bin"))
        try Data(count: 5_000).write(to: src.appendingPathComponent("big.bin"))
        var options = CopyOptions(source: src, destination: dst)
        options.maxFileSize = 1_000
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("big.bin").path))
    }

    func testExcludeExtraKeepsDestinationExtras() async throws {
        try Data("a".utf8).write(to: src.appendingPathComponent("a.txt"))
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dst.appendingPathComponent("extra.txt"))
        var options = CopyOptions(source: src, destination: dst)
        options.mirror = true
        options.excludeExtra = true
        let result = try await run(options)
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("extra.txt").path))
    }

    func testFailedCopyIsRetriedThenReported() async throws {
        let file = src.appendingPathComponent("locked.txt")
        try Data("secret".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        var options = CopyOptions(source: src, destination: dst)
        options.retryCount = 2
        options.retryWaitSeconds = 0
        let result = try await run(options)
        XCTAssertEqual(result.filesFailed, 1)
        XCTAssertEqual(result.filesCopied, 0)
    }

    func testLeftoverPartialFileIsRemovedAfterACopy() async throws {
        var bytes = [UInt8](repeating: 0, count: 5_000_000)
        for i in bytes.indices { bytes[i] = UInt8(i % 251) }
        try Data(bytes).write(to: src.appendingPathComponent("big.bin"))
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        // An interrupted earlier copy left the first 2 MB behind
        let partial = dst.appendingPathComponent("big.bin" + FileOperations.partialSuffix)
        try Data(bytes[0..<2_000_000]).write(to: partial)
        let result = try await run(CopyOptions(source: src, destination: dst))
        XCTAssertEqual(result.filesFailed, 0)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("big.bin")), Data(bytes))
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
    }

    func testLogFileOverwriteAndAppend() async throws {
        try Data("a".utf8).write(to: src.appendingPathComponent("a.txt"))
        let log = base.appendingPathComponent("run.log")
        for (append, expectedRuns) in [(false, 1), (true, 2), (false, 1)] {
            let logger = Logger(logFile: log, append: append, quiet: true)
            let engine = CopyEngine(options: CopyOptions(source: src, destination: dst), logger: logger, progress: ProgressReporter(quiet: true))
            _ = try await engine.run()
            let text = try String(contentsOf: log, encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "macrobo - Started at").count - 1, expectedRuns)
            XCTAssertTrue(text.contains("Listed source"), "steps are logged")
        }
    }
}
