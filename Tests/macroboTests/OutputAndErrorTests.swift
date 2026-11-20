import XCTest
@testable import MacroboLib

/// An unwritable destination, how failures are named, folder counts, the log, and line widths
final class OutputAndErrorTests: XCTestCase {
    var base: URL!
    var srcDir: URL!
    var dstDir: URL!
    let fm = FileManager.default

    override func setUp() {
        super.setUp()
        base = fm.temporaryDirectory.appendingPathComponent("macrobo-oe-\(UUID().uuidString)")
        srcDir = base.appendingPathComponent("src")
        dstDir = base.appendingPathComponent("dst")
        try! fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let paths = fm.enumerator(atPath: base.path) {
            for case let rel as String in paths {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(rel).path)
            }
        }
        try? fm.removeItem(at: base)
        super.tearDown()
    }

    private func write(_ name: String, in dir: URL, _ text: String = "data") {
        let file = dir.appendingPathComponent(name)
        try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: file)
    }

    private func run(logFile: URL? = nil, _ configure: (inout CopyOptions) -> Void = { _ in }) async throws -> CopyResult {
        var options = CopyOptions(source: srcDir, destination: dstDir)
        configure(&options)
        let logger = Logger(logFile: logFile, quiet: true)
        return try await CopyEngine(options: options, logger: logger, progress: ProgressReporter(quiet: true)).run()
    }

    // MARK: - M1: a destination that can't be written to

    func testUnwritableDestinationStopsBeforeCopying() async throws {
        write("a.txt", in: srcDir)
        write("b/c.txt", in: srcDir)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dstDir.path)
        do {
            _ = try await run { $0.mirror = true }
            XCTFail("expected the run to stop")
        } catch let error as MacroboError {
            XCTAssertEqual(error.localizedDescription, "Can't write to the destination \(dstDir.path): Permission denied")
        }
    }

    func testDryRunIntoUnwritableDestinationStillLists() async throws {
        write("a.txt", in: srcDir)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dstDir.path)
        let result = try await run { $0.dryRun = true }
        XCTAssertEqual(result.wouldCopyFiles, 1)
    }

    func testLeftoverFolderUnderVolumesGetsTheHint() throws {
        // A stand-in for /Volumes: a plain folder in it is on the same device, like a mount
        // point left behind after its share was unmounted
        let volumes = base.appendingPathComponent("Volumes")
        try fm.createDirectory(at: volumes.appendingPathComponent("Share/sub"), withIntermediateDirectories: true)
        XCTAssertTrue(VolumeInfo.isUnderUnmountedVolumeFolder(volumes.path + "/Share", volumesRoot: volumes.path))
        XCTAssertTrue(VolumeInfo.isUnderUnmountedVolumeFolder(volumes.path + "/Share/sub/new", volumesRoot: volumes.path))
        XCTAssertFalse(VolumeInfo.isUnderUnmountedVolumeFolder(base.path + "/elsewhere", volumesRoot: volumes.path))
        XCTAssertFalse(VolumeInfo.isUnderUnmountedVolumeFolder(volumes.path + "/Missing", volumesRoot: volumes.path))

        let message = MacroboError.cannotWriteDestination(path: "/Volumes/CodeProjects", reason: "Permission denied", unmountedVolume: true)
            .localizedDescription
        XCTAssertEqual(message, """
            Can't write to the destination /Volumes/CodeProjects: Permission denied
            It's a folder on this Mac, not a mounted drive or share. Mount it and try again.
            """)
    }

    func testMountedVolumesGetNoHint() throws {
        // Every entry in the real /Volumes that is a mount point must not get the hint
        let entries = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in entries {
            let path = "/Volumes/" + name
            guard VolumeInfo.networkFileSystemType(of: path) != nil || isMountPoint(path) else { continue }
            XCTAssertFalse(VolumeInfo.isUnderUnmountedVolumeFolder(path), path)
        }
    }

    private func isMountPoint(_ path: String) -> Bool {
        var a = stat(), b = stat()
        return stat(path, &a) == 0 && stat("/Volumes", &b) == 0 && a.st_dev != b.st_dev
    }

    // MARK: - M3: which side failed

    func testFailureAtTheDestinationNamesTheDestinationFile() async throws {
        write("locked/a.txt", in: srcDir)
        try fm.createDirectory(at: dstDir.appendingPathComponent("locked"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dstDir.appendingPathComponent("locked").path)
        let result = try await run { $0.retryCount = 0 }
        XCTAssertEqual(result.filesFailed, 1)
        let expected = "Can't copy to \(dstDir.path)/locked/a.txt: Permission denied"
        XCTAssertEqual(result.errors.first.map { CopyResult.failureText(path: $0.path, error: $0.error) }, expected)
        XCTAssertTrue(result.summary.contains("   " + expected), result.summary)
    }

    func testUnreadableSourceFileNamesTheSourceFile() async throws {
        write("secret.txt", in: srcDir)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: srcDir.appendingPathComponent("secret.txt").path)
        let result = try await run { $0.retryCount = 0 }
        XCTAssertEqual(result.filesFailed, 1)
        XCTAssertEqual(result.errors.first?.error.localizedDescription,
                       "Can't read \(String(cString: realpath(srcDir.path, nil)))/secret.txt: Permission denied")
    }

    func testOtherErrorsKeepTheirPathInFront() {
        let error = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        XCTAssertEqual(CopyResult.failureText(path: "/a/b", error: error), "/a/b: Something broke")
    }

    // MARK: - S3: every created folder is counted

    func testParentFoldersAreCounted() async throws {
        write("objects/00/a", in: srcDir)
        write("objects/01/b", in: srcDir)
        let result = try await run()
        XCTAssertEqual(result.directoriesCreated, 4, "dst, objects, 00 and 01")
    }

    func testEmptyNestedFoldersAreCountedOnce() async throws {
        try fm.createDirectory(at: srcDir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: srcDir.appendingPathComponent("a/b/d"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let result = try await run()
        XCTAssertEqual(result.directoriesCreated, 4, "a, a/b, a/b/c and a/b/d")
    }

    func testMakeDirectoriesReportsEachFolderOnceAcrossThreads() throws {
        let target = base.appendingPathComponent("deep")
        let created = ResultSlots<[String]>(count: 32)
        parallelForEach(count: 32, workers: 16) { i in
            created[i] = (try? FileOperations.makeDirectories(target.path + "/x/y/z\(i % 4)")) ?? []
        }
        let all = created.all.compactMap { $0 }.flatMap { $0 }
        XCTAssertEqual(all.count, Set(all).count, "no folder reported twice")
        XCTAssertEqual(Set(all).count, 7, "deep, x, y and four z folders")
    }

    // MARK: - S2: one log line per copied file

    func testLogHasOneLinePerCopiedFile() async throws {
        write("a.txt", in: srcDir)
        write("b.txt", in: srcDir)
        let log = base.appendingPathComponent("run.log")
        _ = try await run(logFile: log)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.contains("COPY:") }
        XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
        for line in lines {
            XCTAssertTrue(line.contains(" -> \(dstDir.path)/"), String(line))
            XCTAssertTrue(line.hasSuffix("/2]"), String(line))
        }
    }

    // MARK: - M4: progress lines fit the terminal

    func testProgressLinesFitAndKeepTheTimeLeft() async {
        for (width, files, cells) in [(80, 7_892, 14), (80, 14_681, 12), (80, 5, 20), (120, 14_681, 20)] {
            let reporter = ProgressReporter()
            await reporter.useTerminalWidth(width)
            await reporter.simulate(totalFiles: files, completed: files / 2, bytes: 400_000_000)
            let total = await reporter.formatTotalLine(now: Date().addingTimeInterval(60))
            let active = await reporter.formatActiveLine(
                FileProgress(index: files / 2, fileName: String(repeating: "f", count: 38), totalBytes: 2_000,
                             copiedBytes: 1_000, startTime: Date().addingTimeInterval(-1)),
                now: Date())
            for line in [total, active] {
                XCTAssertEqual(line.count, width - 1, "\(width) columns, \(files) files: \(line)")
                XCTAssertNotNil(line.range(of: #"\d\dm\d\ds$"#, options: .regularExpression), line)
            }
            let bar = total.split(separator: "[").last!.split(separator: "]").first!
            XCTAssertEqual(bar.count, cells, "\(width) columns, \(files) files")
        }
    }
}

/// --bwlimit holds across many copy threads
final class RateLimiterTests: XCTestCase {
    func testManyThreadsStayWithinTheLimit() {
        // 2 MB/s with a 2 MB burst: 6 MB from 16 threads must take at least 2 seconds
        let limiter = RateLimiter(bytesPerSecond: 2_000_000)
        let start = Date()
        parallelForEach(count: 48, workers: 16) { _ in limiter.acquire(125_000) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 1.9)
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testUnlimitedNeverWaits() {
        let limiter = RateLimiter(bytesPerSecond: 0)
        let start = Date()
        for _ in 0..<1000 { limiter.acquire(10_000_000) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }
}
