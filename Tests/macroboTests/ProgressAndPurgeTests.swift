import XCTest
@testable import MacroboLib

/// Live counts, purge-only, dry-run lists, the mass-delete guard, hidden files and errors
final class ProgressAndPurgeTests: XCTestCase {
    var base: URL!
    var srcDir: URL!
    var dstDir: URL!
    let fm = FileManager.default

    override func setUp() {
        super.setUp()
        base = fm.temporaryDirectory.appendingPathComponent("macrobo-pp-\(UUID().uuidString)")
        srcDir = base.appendingPathComponent("src")
        dstDir = base.appendingPathComponent("dst")
        try! fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Restore permissions changed by a test so cleanup can remove everything
        if let paths = fm.enumerator(atPath: base.path) {
            for case let rel as String in paths {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(rel).path)
            }
        }
        for dir in [base!, srcDir!, dstDir!] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try? fm.removeItem(at: base)
        super.tearDown()
    }

    private func createFile(_ name: String, in dir: URL, content: String = "test content") {
        let file = dir.appendingPathComponent(name)
        try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: file)
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func run(_ options: CopyOptions) async throws -> CopyResult {
        let engine = CopyEngine(options: options, logger: Logger(quiet: true), progress: ProgressReporter(quiet: true))
        return try await engine.run()
    }

    // MARK: - Formatting

    func testCountsUseThousandsSeparatorsAndPlurals() {
        XCTAssertEqual(formatCount(0), "0")
        XCTAssertEqual(formatCount(999), "999")
        XCTAssertEqual(formatCount(6779), "6,779")
        XCTAssertEqual(formatCount(1_234_567), "1,234,567")
        XCTAssertEqual(formatCount(1, "file"), "1 file")
        XCTAssertEqual(formatCount(2, "file"), "2 files")
        XCTAssertEqual(formatCount(1337, "folder"), "1,337 folders")
    }

    func testStepLinesMatchTheApprovedLayout() {
        // Decision F4 B: every time ends at column 79 (77 in the log, which has no mark)
        let lines = [
            formatStepLine(mark: "✓", name: "Listed source", detail: "121,522 files, 3,410 folders", seconds: 4.1),
            formatStepLine(mark: "✓", name: "Compared", detail: "121,522 files, 246 to copy, 38,906 to checksum", seconds: 2.3),
            formatStepLine(mark: "✓", name: "Checksummed", detail: "38,906 files, 3 changed", seconds: 880),
        ]
        XCTAssertEqual(lines, [
            "✓ Listed source        121,522 files, 3,410 folders                       4.1 s",
            "✓ Compared             121,522 files, 246 to copy, 38,906 to checksum     2.3 s",
            "✓ Checksummed          38,906 files, 3 changed                           14m40s",
        ])
        XCTAssertTrue(lines.allSatisfy { $0.count == 79 })
        XCTAssertEqual(
            formatStepLine(mark: "", name: "Compared", detail: "6,779 files, 3 to copy", seconds: 0.4).count, 77
        )
        // The live line has no time
        XCTAssertEqual(
            formatStepLine(mark: "/", name: "Listing source", detail: "4,212 files, 803 folders"),
            "/ Listing source       4,212 files, 803 folders"
        )
        // Text too long for the column keeps two spaces before the time
        let long = formatStepLine(mark: "✓", name: "Compared", detail: String(repeating: "x", count: 60), seconds: 1)
        XCTAssertTrue(long.hasSuffix("x  1.0 s"), long)
    }

    func testTimeLeftWording() {
        XCTAssertNil(formatTimeLeft(elapsed: 4, done: 10, total: 100), "no estimate in the first 5 seconds")
        XCTAssertNil(formatTimeLeft(elapsed: 10, done: 0, total: 100))
        XCTAssertNil(formatTimeLeft(elapsed: 10, done: 100, total: 100))
        XCTAssertEqual(formatTimeLeft(elapsed: 10, done: 50, total: 100), "under a minute left")
        XCTAssertEqual(formatTimeLeft(elapsed: 60, done: 10, total: 150), "about 14 min left")
        XCTAssertEqual(formatTimeLeft(elapsed: 600, done: 10, total: 80), "about 1 h 10 min left")
        XCTAssertEqual(formatTimeLeft(elapsed: 600, done: 10, total: 70), "about 1 h left")
    }

    func testJSONEscaping() {
        XCTAssertEqual(ProgressReporter.jsonEscape("say \"hi\".txt"), "say \\\"hi\\\".txt")
        XCTAssertEqual(ProgressReporter.jsonEscape("a\\b\nc"), "a\\\\b\\nc")
        XCTAssertEqual(ProgressReporter.jsonEscape("tab\there\u{1}"), "tab\\there\\u0001")
    }

    // MARK: - Purge-only (--purge)

    func testPurgeDeletesExtrasWithoutCopying() async throws {
        createFile("keep.txt", in: srcDir)
        createFile("new.txt", in: srcDir)
        createFile("keep.txt", in: dstDir)
        createFile("a.txt", in: dstDir)
        createFile("b.txt", in: dstDir)
        createFile("old/x.txt", in: dstDir)
        createFile("old/y.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.purge = true
        options.allowMassDelete = true
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertFalse(exists("new.txt", in: dstDir), "--purge must not copy")
        XCTAssertTrue(exists("keep.txt", in: dstDir))
        XCTAssertFalse(exists("old", in: dstDir))
        XCTAssertFalse(exists("a.txt", in: dstDir))
        // Files inside the deleted folder are counted too
        XCTAssertEqual(result.filesDeleted, 4)
        XCTAssertEqual(result.directoriesDeleted, 1)
    }

    func testMirrorStillCopiesAndDeletes() async throws {
        createFile("new.txt", in: srcDir)
        createFile("keep.txt", in: srcDir)
        createFile("keep.txt", in: dstDir)
        createFile("stale.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        let result = try await run(options)
        XCTAssertTrue(exists("new.txt", in: dstDir))
        XCTAssertFalse(exists("stale.txt", in: dstDir))
        XCTAssertEqual(result.filesDeleted, 1)
    }

    func testDeletedCountsIncludeNestedFolders() async throws {
        createFile("keep.txt", in: srcDir)
        for name in ["keep.txt", "a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] { createFile(name, in: dstDir) }
        createFile("gone/one.txt", in: dstDir)
        createFile("gone/deeper/two.txt", in: dstDir)
        createFile("gone/deeper/three.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        options.allowMassDelete = true
        let result = try await run(options)
        XCTAssertEqual(result.filesDeleted, 8)       // 5 top-level + 3 inside gone/
        XCTAssertEqual(result.directoriesDeleted, 2) // gone, gone/deeper
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dstDir.path), ["keep.txt"])
    }

    // MARK: - Mass-delete guard

    func testEmptySourceStopsMirrorAndPurge() async throws {
        createFile("precious.txt", in: dstDir)
        for mirror in [true, false] {
            var options = CopyOptions(source: srcDir, destination: dstDir)
            if mirror { options.mirror = true } else { options.purge = true }
            do {
                _ = try await run(options)
                XCTFail("an empty source must stop the run")
            } catch let error as MacroboError {
                let text = error.localizedDescription
                XCTAssertTrue(text.contains("The source has no files"), text)
                XCTAssertTrue(text.contains(mirror ? "mirroring" : "purging"), text)
                XCTAssertTrue(text.contains("--allow-mass-delete"), text)
            }
            XCTAssertTrue(exists("precious.txt", in: dstDir))
        }
    }

    func testEmptySourceIntoEmptyDestinationIsFine() async throws {
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        let result = try await run(options)
        XCTAssertEqual(result.filesDeleted, 0)
    }

    func testDeletingMoreThanHalfStops() async throws {
        createFile("keep.txt", in: srcDir)
        createFile("keep.txt", in: dstDir)
        createFile("x1.txt", in: dstDir)
        createFile("x2.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        do {
            _ = try await run(options)
            XCTFail("deleting 2 of 3 items must stop")
        } catch let error as MacroboError {
            XCTAssertTrue(error.localizedDescription.contains("would delete 2 of 3 items (67%)"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"))
        }
        XCTAssertTrue(exists("x1.txt", in: dstDir))
        XCTAssertTrue(exists("x2.txt", in: dstDir))

        options.allowMassDelete = true
        let result = try await run(options)
        XCTAssertEqual(result.filesDeleted, 2)
    }

    func testDeletingHalfOrLessProceeds() async throws {
        createFile("a.txt", in: srcDir)
        createFile("a.txt", in: dstDir)
        createFile("x.txt", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.purge = true
        let result = try await run(options)
        XCTAssertEqual(result.filesDeleted, 1)
    }

    // MARK: - Dry run

    func testDryRunCountsWhatWouldChangeAndChangesNothing() async throws {
        createFile("same.txt", in: srcDir)
        createFile("new1.txt", in: srcDir, content: "12345")
        createFile("new2.txt", in: srcDir, content: "123")
        var first = CopyOptions(source: srcDir, destination: dstDir)
        first.includeFiles = ["same.txt"]
        _ = try await run(first)
        createFile("old/a.txt", in: dstDir)
        createFile("b.txt", in: dstDir)

        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        options.dryRun = true
        options.allowMassDelete = true
        let result = try await run(options)
        XCTAssertTrue(result.isDryRun)
        XCTAssertEqual(result.wouldCopyFiles, 2)
        XCTAssertEqual(result.wouldCopyBytes, 8)
        XCTAssertEqual(result.unchangedFiles, 1)
        XCTAssertEqual(result.wouldDeleteFiles, 2)
        XCTAssertEqual(result.wouldDeleteFolders, 1)
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertEqual(result.filesSkipped, 0, "files a dry run would copy are not 'skipped'")
        XCTAssertFalse(exists("new1.txt", in: dstDir))
        XCTAssertTrue(exists("old/a.txt", in: dstDir))
        XCTAssertTrue(exists("b.txt", in: dstDir))

        let summary = result.summary
        XCTAssertTrue(summary.contains("Would copy: 2 files (8 B)"), summary)
        XCTAssertTrue(summary.contains("Would delete: 2 files, 1 folder"), summary)
        XCTAssertTrue(summary.contains("Unchanged: 1 file"), summary)
        XCTAssertFalse(summary.contains("Files skipped"), summary)
    }

    func testDryRunIntoMissingDestination() async throws {
        createFile("a.txt", in: srcDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        options.dryRun = true
        let result = try await run(options)
        XCTAssertEqual(result.wouldCopyFiles, 1)
        XCTAssertEqual(result.wouldDeleteFiles, 0)
        XCTAssertFalse(fm.fileExists(atPath: dstDir.path))
    }

    func testNormalRunCountsUnchangedFilesAsSkipped() async throws {
        createFile("a.txt", in: srcDir)
        createFile("b.txt", in: srcDir)
        let options = CopyOptions(source: srcDir, destination: dstDir)
        _ = try await run(options)
        createFile("c.txt", in: srcDir)
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesSkipped, 2)
    }

    // MARK: - Hidden files

    func testHiddenFilesAreCopiedByDefault() async throws {
        createFile(".env", in: srcDir)
        createFile(".git/HEAD", in: srcDir)
        createFile("visible.txt", in: srcDir)
        let result = try await run(CopyOptions(source: srcDir, destination: dstDir))
        XCTAssertEqual(result.filesCopied, 3)
        XCTAssertTrue(exists(".env", in: dstDir))
        XCTAssertTrue(exists(".git/HEAD", in: dstDir))
    }

    func testSkipHiddenSkipsThemAndMirrorKeepsHiddenDestinationFilesThatExistInSource() async throws {
        createFile(".env", in: srcDir)
        createFile("visible.txt", in: srcDir)
        createFile(".env", in: dstDir, content: "older copy")
        createFile(".stale", in: dstDir)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.skipHidden = true
        options.mirror = true
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertTrue(exists(".env", in: dstDir), "exists in the source, so a mirror keeps it")
        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent(".env"), encoding: .utf8), "older copy")
        XCTAssertFalse(exists(".stale", in: dstDir))
    }

    // MARK: - Errors

    func testUnreadableDestinationSaysWhy() async throws {
        createFile("a.txt", in: srcDir)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dstDir.path)
        do {
            _ = try await run(CopyOptions(source: srcDir, destination: dstDir))
            XCTFail("an unreadable destination must fail")
        } catch let error as MacroboError {
            XCTAssertEqual(error.localizedDescription, "Can't open the destination \(dstDir.path): Permission denied")
        }
    }

    func testNetworkShareHint() {
        let error = MacroboError.cannotOpen(role: "destination", path: "/Volumes/CodeProjects", reason: "Permission denied", networkType: "nfs")
        XCTAssertEqual(error.localizedDescription, """
            Can't open the destination /Volumes/CodeProjects: Permission denied
            It's on a network share (nfs). If the server was just updated or restarted,
            remount the share and try again.
            """)
    }

    func testLocalDiskIsNotANetworkShare() {
        XCTAssertNil(VolumeInfo.networkFileSystemType(of: NSTemporaryDirectory()))
        XCTAssertNil(VolumeInfo.networkFileSystemType(of: "/"))
    }

    func testUnreadableSourceFolderIsNotPurged() async throws {
        createFile("ok.txt", in: srcDir)
        createFile("locked/inside.txt", in: srcDir)
        createFile("ok.txt", in: dstDir)
        createFile("locked/inside.txt", in: dstDir)
        createFile("locked/only-at-destination.txt", in: dstDir)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: srcDir.appendingPathComponent("locked").path)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        _ = try await run(options)
        XCTAssertTrue(exists("locked/inside.txt", in: dstDir))
        XCTAssertTrue(exists("locked/only-at-destination.txt", in: dstDir),
                      "the source folder's contents are unknown, so nothing under it is deleted")
    }

    // MARK: - Parallel passes

    func testParallelListingFindsEveryFileAndFolder() throws {
        for d in 0..<30 {
            for f in 0..<7 { createFile("d\(d)/sub\(d % 3)/f\(f).txt", in: srcDir) }
        }
        let counts = LiveCounts(slots: 2)
        let listing = try FileEnumerator.enumerateSource(
            source: srcDir, skipHidden: false, excludeDirs: [], excludeFiles: [], includeFiles: [],
            minSize: nil, maxSize: nil, counts: counts
        )
        XCTAssertEqual(listing.files.count, 210)
        XCTAssertEqual(listing.directoryRelativePaths.count, 60)
        XCTAssertEqual(counts.all, [210, 60])
        XCTAssertEqual(listing.files.map(\.relativePath), listing.files.map(\.relativePath).sorted())
    }

    func testChecksumPassAcrossManyWorkers() async throws {
        // More files than workers, so every worker claims several
        for i in 0..<130 {
            createFile("f\(i).txt", in: srcDir, content: "AAAA")
            createFile("f\(i).txt", in: dstDir, content: i < 5 ? "BBBB" : "AAAA")
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-100)],
                                 ofItemAtPath: dstDir.appendingPathComponent("f\(i).txt").path)
        }
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.checksum = true
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 5)
    }

    // MARK: - Checksums (decisions F2, F3)

    func testFullCompareCatchesAChangeTheSamplesMiss() throws {
        // 100 KB files that differ only in one byte away from the first, middle and last 4 KB
        var bytes = [UInt8](repeating: 7, count: 100_000)
        let a = srcDir.appendingPathComponent("a.bin")
        let b = srcDir.appendingPathComponent("b.bin")
        try Data(bytes).write(to: a)
        bytes[20_000] = 8
        try Data(bytes).write(to: b)
        XCTAssertEqual(try FileOperations.checksumFile(at: a), try FileOperations.checksumFile(at: b),
                       "the samples alone can't tell these apart")
        XCTAssertTrue(FileOperations.areFileContentsIdentical(source: a, destination: b),
                      "--checksum compares samples, as documented")
        XCTAssertFalse(FileOperations.areFileContentsIdentical(source: a, destination: b, full: true))
        let c = srcDir.appendingPathComponent("c.bin")
        try Data(contentsOf: a).write(to: c)
        XCTAssertTrue(FileOperations.areFileContentsIdentical(source: a, destination: c, full: true))
    }

    func testChecksumFullCopiesAFileChangedOutsideTheSamples() async throws {
        var bytes = [UInt8](repeating: 1, count: 100_000)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try Data(bytes).write(to: dstDir.appendingPathComponent("photo.jpg"))
        bytes[50_100] = 2 // past the middle sample
        try Data(bytes).write(to: srcDir.appendingPathComponent("photo.jpg"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-100)],
                             ofItemAtPath: dstDir.appendingPathComponent("photo.jpg").path)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.checksumFull = true
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(try Data(contentsOf: dstDir.appendingPathComponent("photo.jpg")), Data(bytes))
    }

    private func mtime(_ url: URL) throws -> Date {
        try fm.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }

    func testIdenticalFilesGetTheSourceTimeSoTheyAreCheckedOnce() async throws {
        createFile("same.txt", in: srcDir, content: "identical")
        createFile("same.txt", in: dstDir, content: "identical")
        let old = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: dstDir.appendingPathComponent("same.txt").path)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.checksum = true
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 0)
        let src = try mtime(srcDir.appendingPathComponent("same.txt"))
        let dst = try mtime(dstDir.appendingPathComponent("same.txt"))
        XCTAssertEqual(src.timeIntervalSince1970, dst.timeIntervalSince1970, accuracy: 0.001)
        // The next run matches on size and time: nothing left to checksum
        let verdict = DestinationComparator.verdict(
            for: try FileEnumerator.enumerateSource(source: srcDir, skipHidden: false, excludeDirs: [], excludeFiles: [],
                                                    includeFiles: [], minSize: nil, maxSize: nil).files[0],
            destinationPath: dstDir.appendingPathComponent("same.txt").path,
            settings: CompareSettings(includeSame: false, checksum: true, excludeOlder: false)
        )
        XCTAssertEqual(verdict, .skip)
    }

    func testTimesAreLeftAloneInDryRunAndWithNoTimestamps() async throws {
        createFile("same.txt", in: srcDir, content: "identical")
        createFile("same.txt", in: dstDir, content: "identical")
        let old = Date(timeIntervalSince1970: 1_577_836_800)
        let dstFile = dstDir.appendingPathComponent("same.txt")
        for configure in [{ (o: inout CopyOptions) in o.dryRun = true }, { (o: inout CopyOptions) in o.copyTimestamps = false }] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: dstFile.path)
            var options = CopyOptions(source: srcDir, destination: dstDir)
            options.checksum = true
            configure(&options)
            _ = try await run(options)
            XCTAssertEqual(try mtime(dstFile), old)
        }
    }

    func testChangedFilesDontGetTheSourceTime() async throws {
        createFile("f.txt", in: srcDir, content: "AAAA")
        createFile("f.txt", in: dstDir, content: "BBBB")
        let old = Date(timeIntervalSince1970: 1_577_836_800)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: dstDir.appendingPathComponent("f.txt").path)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.checksum = true
        options.excludeOlder = true // a changed file that --exclude-older keeps: must not look synced
        try fm.setAttributes([.modificationDate: old.addingTimeInterval(-100)], ofItemAtPath: srcDir.appendingPathComponent("f.txt").path)
        _ = try await run(options)
        XCTAssertEqual(try mtime(dstDir.appendingPathComponent("f.txt")), old)
        XCTAssertEqual(try String(contentsOf: dstDir.appendingPathComponent("f.txt"), encoding: .utf8), "BBBB")
    }

    func testParallelVerify() async throws {
        for i in 0..<40 { createFile("v\(i).txt", in: srcDir, content: "content \(i)") }
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.verify = true
        let result = try await run(options)
        XCTAssertEqual(result.filesCopied, 40)
        XCTAssertEqual(result.filesFailed, 0)
    }

    // MARK: - Empty folders (-e default, -s skips)

    func testEmptyFoldersAreCopiedUnlessSkipped() async throws {
        createFile("full/a.txt", in: srcDir)
        try fm.createDirectory(at: srcDir.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.includeEmptyDirectories = false
        _ = try await run(options)
        XCTAssertFalse(exists("empty", in: dstDir))

        options.includeEmptyDirectories = true
        options.dryRun = true
        let dry = try await run(options)
        XCTAssertEqual(dry.wouldCopyFolders, 2, "only the empty folders; full/ is created by its file")
        XCTAssertFalse(exists("empty", in: dstDir))

        options.dryRun = false
        let result = try await run(options)
        XCTAssertTrue(exists("empty/nested", in: dstDir))
        XCTAssertEqual(result.directoriesCreated, 2)
    }
}
