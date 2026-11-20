import XCTest
@testable import MacroboLib

final class FileOperationsTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrobo-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - DestinationComparator.verdict

    private func info(_ url: URL) -> FileInfo {
        let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
        return FileInfo(url: url, size: attrs[.size] as! UInt64, relativePath: "/" + url.lastPathComponent,
                        modificationDate: attrs[.modificationDate] as? Date)
    }

    private let defaults = CompareSettings(includeSame: false, checksum: false, excludeOlder: false)

    func testVerdictSkipsIdenticalFile() {
        let file = tempDir.appendingPathComponent("test.txt")
        try! Data("hello world".utf8).write(to: file)
        XCTAssertEqual(DestinationComparator.verdict(for: info(file), destinationPath: file.path, settings: defaults), .skip)
    }

    func testVerdictCopiesDifferentSize() {
        let src = tempDir.appendingPathComponent("src.txt")
        let dst = tempDir.appendingPathComponent("dst.txt")
        try! Data("short".utf8).write(to: src)
        try! Data("much longer content".utf8).write(to: dst)
        XCTAssertEqual(DestinationComparator.verdict(for: info(src), destinationPath: dst.path, settings: defaults), .copy)
    }

    func testVerdictCopiesMissingDestination() {
        let src = tempDir.appendingPathComponent("exists.txt")
        try! Data("data".utf8).write(to: src)
        let dst = tempDir.appendingPathComponent("missing.txt")
        XCTAssertEqual(DestinationComparator.verdict(for: info(src), destinationPath: dst.path, settings: defaults), .copy)
    }

    func testVerdictFallsBackToStatWhenDateWasNotPrefetched() {
        let file = tempDir.appendingPathComponent("nodate.txt")
        try! Data("x".utf8).write(to: file)
        let noDate = FileInfo(url: file, size: 1, relativePath: "/nodate.txt")
        XCTAssertEqual(DestinationComparator.verdict(for: noDate, destinationPath: file.path, settings: defaults), .skip)
    }

    // MARK: - fileSize

    func testFileSize() {
        let file = tempDir.appendingPathComponent("sized.txt")
        try! Data(repeating: 0x41, count: 1024).write(to: file)
        XCTAssertEqual(FileOperations.fileSize(at: file), 1024)
    }

    func testFileSizeEmpty() {
        let file = tempDir.appendingPathComponent("empty.txt")
        try! Data().write(to: file)
        XCTAssertEqual(FileOperations.fileSize(at: file), 0)
    }

    func testFileSizeMissing() {
        let file = tempDir.appendingPathComponent("nope.txt")
        XCTAssertNil(FileOperations.fileSize(at: file))
    }

    // MARK: - DestinationComparator.verdict with --exclude-older / --checksum

    func testVerdictExcludeOlder() {
        let older = tempDir.appendingPathComponent("older.txt")
        try! Data("old".utf8).write(to: older)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: older.path)
        let newer = tempDir.appendingPathComponent("newer.txt")
        try! Data("newer".utf8).write(to: newer)

        var settings = defaults
        settings.excludeOlder = true
        XCTAssertEqual(DestinationComparator.verdict(for: info(newer), destinationPath: older.path, settings: settings), .copy)
        XCTAssertEqual(DestinationComparator.verdict(for: info(older), destinationPath: newer.path, settings: settings), .skip)
    }

    func testVerdictChecksumWhenSameSizeDifferentDate() {
        let src = tempDir.appendingPathComponent("a.txt")
        let dst = tempDir.appendingPathComponent("b.txt")
        try! Data("same".utf8).write(to: src)
        try! Data("diff".utf8).write(to: dst)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: dst.path)
        var settings = defaults
        settings.checksum = true
        XCTAssertEqual(DestinationComparator.verdict(for: info(src), destinationPath: dst.path, settings: settings),
                       .checksum(skipIfDifferent: false))
        settings.excludeOlder = true
        XCTAssertEqual(DestinationComparator.verdict(for: info(src), destinationPath: dst.path, settings: settings),
                       .checksum(skipIfDifferent: false))
        XCTAssertEqual(DestinationComparator.verdict(for: info(dst), destinationPath: src.path, settings: settings),
                       .checksum(skipIfDifferent: true))
    }

    // MARK: - checksumFile

    func testChecksumIdenticalContent() throws {
        let file1 = tempDir.appendingPathComponent("a.bin")
        let file2 = tempDir.appendingPathComponent("b.bin")
        let data = Data(repeating: 0xAB, count: 100)
        try data.write(to: file1)
        try data.write(to: file2)
        let hash1 = try FileOperations.checksumFile(at: file1)
        let hash2 = try FileOperations.checksumFile(at: file2)
        XCTAssertEqual(hash1, hash2)
    }

    func testChecksumDifferentContent() throws {
        let file1 = tempDir.appendingPathComponent("a.bin")
        let file2 = tempDir.appendingPathComponent("b.bin")
        try Data(repeating: 0xAA, count: 100).write(to: file1)
        try Data(repeating: 0xBB, count: 100).write(to: file2)
        let hash1 = try FileOperations.checksumFile(at: file1)
        let hash2 = try FileOperations.checksumFile(at: file2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testChecksumLargeFile() throws {
        let file = tempDir.appendingPathComponent("large.bin")
        var data = Data(count: 50_000)
        for i in 0..<data.count { data[i] = UInt8(i % 256) }
        try data.write(to: file)
        let hash = try FileOperations.checksumFile(at: file)
        XCTAssertNotNil(hash)
    }

    // MARK: - areFileContentsIdentical

    func testContentsIdentical() {
        let src = tempDir.appendingPathComponent("src.bin")
        let dst = tempDir.appendingPathComponent("dst.bin")
        let data = Data(repeating: 0xCC, count: 200)
        try! data.write(to: src)
        try! data.write(to: dst)
        XCTAssertTrue(FileOperations.areFileContentsIdentical(source: src, destination: dst))
    }

    func testContentsDifferent() {
        let src = tempDir.appendingPathComponent("src.bin")
        let dst = tempDir.appendingPathComponent("dst.bin")
        try! Data(repeating: 0xAA, count: 200).write(to: src)
        try! Data(repeating: 0xBB, count: 200).write(to: dst)
        XCTAssertFalse(FileOperations.areFileContentsIdentical(source: src, destination: dst))
    }

    // MARK: - Extended Attributes

    func testExtendedAttributes() throws {
        let file = tempDir.appendingPathComponent("xattr.txt")
        try Data("content".utf8).write(to: file)
        let testValue = Data("test-value".utf8)
        try FileOperations.setExtendedAttribute(name: "com.macrobo.test", value: testValue, at: file)
        let names = try FileOperations.listExtendedAttributes(at: file)
        XCTAssertTrue(names.contains("com.macrobo.test"))
        let retrieved = try FileOperations.getExtendedAttribute(name: "com.macrobo.test", at: file)
        XCTAssertEqual(retrieved, testValue)
    }

    // MARK: - APFS Clone Detection

    func testSameVolumeDetection() {
        // Use tempDir itself (which exists) as source
        let src = tempDir.path
        let dst = tempDir.appendingPathComponent("dst_file.txt").path
        XCTAssertTrue(FileOperations.isSameAPFSVolume(source: src, destination: dst))
    }

    func testSameVolumeDetectionWhenDestinationFolderDoesNotExistYet() {
        let dst = tempDir.appendingPathComponent("not/created/yet/file.txt").path
        XCTAssertTrue(FileOperations.isSameAPFSVolume(source: tempDir.path, destination: dst))
    }

    func testDifferentVolumesAreNotSame() {
        // /dev is devfs, never the same APFS volume as the temp folder
        XCTAssertFalse(FileOperations.isSameAPFSVolume(source: tempDir.path, destination: "/dev/null"))
        XCTAssertFalse(FileOperations.isSameAPFSVolume(source: "/dev", destination: tempDir.appendingPathComponent("x").path))
    }
}
