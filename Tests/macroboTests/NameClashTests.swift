import XCTest
@testable import MacroboLib

/// Source names that are one name at the destination (case, ß/ss, NFC/NFD)
final class NameClashTests: XCTestCase {

    private func file(_ path: String, size: UInt64 = 1) -> FileInfo {
        FileInfo(url: URL(fileURLWithPath: "/src" + path), size: size, relativePath: path)
    }

    // MARK: - Keys

    func testIgnoresCaseFoldsCaseSharpSAndNormalization() {
        let m = NameMatching.ignoresCase
        XCTAssertEqual(m.key("/Die großen Erfolge 4"), m.key("/Die Grossen Erfolge 4"))
        XCTAssertEqual(m.key("/Song.m4a"), m.key("/song.M4A"))
        XCTAssertEqual(m.key("/Caf\u{e9}"), m.key("/Cafe\u{301}"))
        XCTAssertNotEqual(m.key("/a.txt"), m.key("/b.txt"))
    }

    func testIgnoresNormalizationKeepsCaseApart() {
        let m = NameMatching.ignoresNormalization
        XCTAssertEqual(m.key("/Caf\u{e9}"), m.key("/Cafe\u{301}"))
        XCTAssertNotEqual(m.key("/Song.m4a"), m.key("/song.m4a"))
    }

    func testExactKeepsEveryNameApart() {
        let m = NameMatching.exact
        // Swift's String == already treats the two encodings as equal; the key must not change them
        XCTAssertNotEqual(Array(m.key("/Caf\u{e9}").unicodeScalars), Array(m.key("/Cafe\u{301}").unicodeScalars))
        XCTAssertNotEqual(m.key("/Song.m4a"), m.key("/song.m4a"))
    }

    // MARK: - Resolving

    func testKeepsFirstInAlphabeticalOrderOfFullPath() {
        // Real case from MusicStaging: "G" sorts before "g", so Die Grossen's track is kept
        let files = [
            file("/Die großen Erfolge 4/05 - Irgendwo auf der Welt.m4a"),
            file("/Die großen Erfolge 4/13 - Heut Nacht oder nie.m4a"),
            file("/Die Grossen Erfolge 4/05 - Irgendwo Auf Der Welt.m4a"),
            file("/Die Grossen Erfolge 4/13 - Heute Nacht Oder Nie.m4a"),
        ]
        let (keep, clashes) = NameClashes.resolve(files, matching: .ignoresCase)
        XCTAssertEqual(keep.count, 3, "merged folders: only the clashing file is left out")
        XCTAssertEqual(clashes, [NameClash(
            path: "/Die großen Erfolge 4/05 - Irgendwo auf der Welt.m4a",
            sameAs: "/Die Grossen Erfolge 4/05 - Irgendwo Auf Der Welt.m4a"
        )])
        XCTAssertFalse(keep.contains { $0.relativePath == clashes[0].path })
    }

    func testSameChoiceWhateverTheListingOrder() {
        let a = [file("/b.txt"), file("/B.txt"), file("/x/A.txt"), file("/x/a.txt")]
        let first = NameClashes.resolve(a, matching: .ignoresCase)
        let second = NameClashes.resolve(a.reversed(), matching: .ignoresCase)
        XCTAssertEqual(first.clashes, second.clashes)
        XCTAssertEqual(Set(first.keep.map(\.relativePath)), ["/B.txt", "/x/A.txt"])
    }

    func testThreeWayClashKeepsOne() {
        let files = [file("/readme"), file("/README"), file("/ReadMe")]
        let (keep, clashes) = NameClashes.resolve(files, matching: .ignoresCase)
        XCTAssertEqual(keep.map(\.relativePath), ["/README"])
        XCTAssertEqual(clashes.map(\.sameAs), ["/README", "/README"])
    }

    func testNoClashesOnExactDestination() {
        let files = [file("/a.txt"), file("/A.txt")]
        let (keep, clashes) = NameClashes.resolve(files, matching: .exact)
        XCTAssertEqual(keep.count, 2)
        XCTAssertTrue(clashes.isEmpty)
    }

    func testFolderSpellingsPicksFirstOfEachGroup() {
        let folders: Set<String> = ["/Music", "/music", "/Music/Die großen", "/Music/Die Grossen", "/Other"]
        XCTAssertEqual(NameClashes.folderSpellings(folders, matching: .ignoresCase), ["/Music", "/Music/Die Grossen"])
        XCTAssertEqual(NameClashes.folderSpellings(folders, matching: .exact), [])
    }

    // MARK: - Summary

    func testSummaryRowAndList() {
        var result = CopyResult()
        result.filesCopied = 3
        result.nameClashes = [NameClash(path: "/x/a.txt", sameAs: "/x/A.txt")]
        result.nameClashReason = NameMatching.ignoresCase.reason
        result.finish()
        let summary = result.summary
        XCTAssertTrue(summary.contains("           Name clashes: 1 (not copied)"), summary)
        XCTAssertTrue(summary.contains(" Name clashes (the destination ignores capital letters, so only one fits):"))
        XCTAssertTrue(summary.contains("   Not copied:   x/a.txt"))
        XCTAssertTrue(summary.contains("   Same name as: x/A.txt"))
    }

    func testDryRunSummaryRow() {
        var result = CopyResult()
        result.isDryRun = true
        result.nameClashes = [NameClash(path: "/a", sameAs: "/A")]
        result.nameClashReason = NameMatching.ignoresCase.reason
        XCTAssertTrue(result.summary.contains("Name clashes: 1 (would not be copied)"))
    }

    func testSummaryListsTenThenCounts() {
        var result = CopyResult()
        result.nameClashes = (0..<12).map { NameClash(path: "/f\($0)", sameAs: "/F\($0)") }
        result.nameClashReason = NameMatching.ignoresCase.reason
        let summary = result.summary
        XCTAssertEqual(summary.components(separatedBy: "Not copied:").count - 1, 10)
        XCTAssertTrue(summary.contains("... and 2 more name clashes"))
    }

    func testNoClashSectionWhenNone() {
        var result = CopyResult()
        result.filesCopied = 1
        XCTAssertFalse(result.summary.contains("Name clash"))
    }

    // MARK: - Detecting the destination

    func testTemporaryFolderIgnoresCase() {
        // macOS's default APFS volume, where the temporary folder lives, ignores case
        XCTAssertEqual(NameMatching.of(NSTemporaryDirectory()), .ignoresCase)
        // A destination that doesn't exist yet is judged by its nearest existing parent
        XCTAssertEqual(NameMatching.of(NSTemporaryDirectory() + "macrobo-missing-\(UUID())/a/b"), .ignoresCase)
    }
}

/// End to end, with the source on a case-sensitive disk image (the only way to hold
/// "a.txt" and "A.txt" side by side on a Mac) and the destination in the temporary folder
final class NameClashEngineTests: XCTestCase {
    private static var mountPoint: URL?
    private static var image: URL?
    var srcDir: URL!
    var dstDir: URL!

    override class func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("macrobo-cs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dmg = base.appendingPathComponent("cs.dmg")
        let mount = base.appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "20m", "-fs", "Case-sensitive APFS",
                                       "-volname", "macrobo-cs", dmg.path]),
              run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, dmg.path])
        else { return }
        image = base
        mountPoint = mount
    }

    override class func tearDown() {
        if let mountPoint { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path]) }
        if let image { try? FileManager.default.removeItem(at: image) }
        super.tearDown()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    override func setUpWithError() throws {
        guard let mount = Self.mountPoint else { throw XCTSkip("couldn't create a case-sensitive disk image") }
        srcDir = mount.appendingPathComponent("src-\(UUID().uuidString)")
        dstDir = FileManager.default.temporaryDirectory.appendingPathComponent("macrobo-clash-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let srcDir { try? FileManager.default.removeItem(at: srcDir) }
        if let dstDir { try? FileManager.default.removeItem(at: dstDir) }
        super.tearDown()
    }

    private func write(_ path: String, _ content: String) {
        let url = srcDir.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: url)
    }

    private func run(_ configure: (inout CopyOptions) -> Void = { _ in }) async throws -> CopyResult {
        var options = CopyOptions(source: srcDir, destination: dstDir)
        configure(&options)
        let engine = CopyEngine(options: options, logger: Logger(quiet: true), progress: ProgressReporter(quiet: true))
        return try await engine.run()
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: dstDir.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The MusicStaging case: two folders that differ in spelling, each with a track 05
    /// whose names differ only in case, plus a track 13 in each that doesn't clash
    private func writeAlbum() {
        write("Die großen Erfolge 4/05 - Irgendwo auf der Welt.m4a", "großen 05")
        write("Die großen Erfolge 4/13 - Heut Nacht oder nie.m4a", "großen 13")
        write("Die Grossen Erfolge 4/05 - Irgendwo Auf Der Welt.m4a", "Grossen 05, longer")
        write("Die Grossen Erfolge 4/13 - Heute Nacht Oder Nie.m4a", "Grossen 13")
    }

    func testCopySkipsClashAndKeepsFirst() async throws {
        writeAlbum()
        let result = try await run()
        XCTAssertEqual(result.filesCopied, 3)
        XCTAssertEqual(result.filesFailed, 0)
        XCTAssertEqual(result.nameClashes.map(\.path), ["/Die großen Erfolge 4/05 - Irgendwo auf der Welt.m4a"])
        XCTAssertEqual(read("Die Grossen Erfolge 4/05 - Irgendwo Auf Der Welt.m4a"), "Grossen 05, longer")
        XCTAssertEqual(read("Die Grossen Erfolge 4/13 - Heut Nacht oder nie.m4a"), "großen 13")
        XCTAssertEqual(read("Die Grossen Erfolge 4/13 - Heute Nacht Oder Nie.m4a"), "Grossen 13")
        // The merged folder takes the first spelling
        let names = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
        XCTAssertEqual(names, ["Die Grossen Erfolge 4"])
    }

    func testSecondRunCopiesNothing() async throws {
        writeAlbum()
        _ = try await run()
        let again = try await run()
        XCTAssertEqual(again.filesCopied, 0, "the clash must not swap files on every run")
        XCTAssertEqual(again.nameClashes.count, 1)
        XCTAssertEqual(read("Die Grossen Erfolge 4/05 - Irgendwo Auf Der Welt.m4a"), "Grossen 05, longer")
    }

    func testMirrorDeletesNothingFromMergedFolder() async throws {
        writeAlbum()
        _ = try await run()
        let mirror = try await run { $0.mirror = true }
        XCTAssertEqual(mirror.filesDeleted, 0)
        XCTAssertEqual(mirror.filesCopied, 0)
        XCTAssertEqual(read("Die Grossen Erfolge 4/13 - Heut Nacht oder nie.m4a"), "großen 13")
    }

    func testMirrorStillDeletesRealExtras() async throws {
        writeAlbum()
        _ = try await run()
        try Data("old".utf8).write(to: dstDir.appendingPathComponent("Die Grossen Erfolge 4/gone.m4a"))
        let mirror = try await run { $0.mirror = true }
        XCTAssertEqual(mirror.filesDeleted, 1)
        XCTAssertNil(read("Die Grossen Erfolge 4/gone.m4a"))
    }

    func testDryRunReportsClashAndChangesNothing() async throws {
        writeAlbum()
        let result = try await run { $0.dryRun = true }
        XCTAssertEqual(result.nameClashes.count, 1)
        XCTAssertEqual(result.wouldCopyFiles, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.path))
    }

    func testNoClashesCopiesEverything() async throws {
        write("a.txt", "a")
        write("b/c.txt", "c")
        let result = try await run()
        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertTrue(result.nameClashes.isEmpty)
    }

    func testCaseSensitiveDestinationKeepsBoth() async throws {
        write("x.txt", "lower")
        write("X.txt", "upper")
        // Destination on the case-sensitive image too: both names fit
        dstDir = Self.mountPoint!.appendingPathComponent("dst-\(UUID().uuidString)")
        let result = try await run()
        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertTrue(result.nameClashes.isEmpty)
        XCTAssertEqual(read("x.txt"), "lower")
        XCTAssertEqual(read("X.txt"), "upper")
    }
}
