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

    // MARK: - areFilesIdentical

    func testIdenticalFiles() {
        let file = tempDir.appendingPathComponent("test.txt")
        try! Data("hello world".utf8).write(to: file)
        XCTAssertTrue(FileOperations.areFilesIdentical(source: file, destination: file))
    }

    func testDifferentSizeFiles() {
        let src = tempDir.appendingPathComponent("src.txt")
        let dst = tempDir.appendingPathComponent("dst.txt")
        try! Data("short".utf8).write(to: src)
        try! Data("much longer content".utf8).write(to: dst)
        XCTAssertFalse(FileOperations.areFilesIdentical(source: src, destination: dst))
    }

    func testNonexistentFile() {
        let src = tempDir.appendingPathComponent("exists.txt")
        let dst = tempDir.appendingPathComponent("missing.txt")
        try! Data("data".utf8).write(to: src)
        XCTAssertFalse(FileOperations.areFilesIdentical(source: src, destination: dst))
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

    // MARK: - isSourceNewer

    func testSourceNewer() {
        let older = tempDir.appendingPathComponent("older.txt")
        try! Data("old".utf8).write(to: older)
        let pastDate = Date().addingTimeInterval(-3600)
        try! FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: older.path)

        let newer = tempDir.appendingPathComponent("newer.txt")
        try! Data("new".utf8).write(to: newer)

        XCTAssertTrue(FileOperations.isSourceNewer(source: newer, destination: older))
        XCTAssertFalse(FileOperations.isSourceNewer(source: older, destination: newer))
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
}
