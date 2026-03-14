# macrobo v2.0 Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade macrobo from v1.0 to v2.0 with performance optimizations (APFS clonefile, F_NOCACHE), a test suite, code quality improvements (extract shared utilities, split large files), and new features (bandwidth limiting, config files, JSON progress, verify mode).

**Architecture:** macrobo is a Swift 5.9 CLI tool using actors for concurrency (CopyEngine, ProgressReporter, Logger). Changes are layered: Phase 1 adds performance fast paths to existing I/O code, Phase 2 adds tests and edge case fixes, Phase 3 refactors for maintainability, Phase 4 adds user-facing features. Each task produces a compiling, working binary. Shared code lives in a `MacroboLib` library target so the `@main` executable and XCTest can both link it.

**Deferred:** Spec item 2.2 (Streaming/Lazy File Enumeration with `AsyncStream`) and 3.4 (Reduce FileManager.default calls) are deferred to a future iteration. Streaming enumeration is a significant architectural change that benefits from landing after the test suite and refactoring stabilize.

**Tech Stack:** Swift 5.9, macOS 13+, swift-argument-parser, Darwin/POSIX APIs (clonefile, fcntl, statfs), CryptoKit (SHA256), XCTest

**Spec:** `docs/superpowers/specs/2026-03-14-macrobo-v2-improvements-design.md`

**Build command:** `./build.sh` (never `swift build` directly — build.sh generates BuildInfo.swift)

**Test command:** `swift test`

---

## Chunk 1: Phase 1 — Quick Wins

### Task 1: Version Bump to 2.0

**Files:**
- Modify: `build.sh:20,26,66`

- [ ] **Step 1: Update version string in build.sh**

In `build.sh`, change three occurrences of `1.0` to `2.0`:

Line 20 — the generated BuildInfo.swift content:
```bash
    static let version = "2.0"
```

Line 26 — the echo during build:
```bash
echo "Building macrobo version 2.0.$BUILD_NUMBER"
```

Line 66 — the echo after build:
```bash
echo "Build complete: macrobo 2.0.$BUILD_NUMBER"
```

- [ ] **Step 2: Verify build succeeds**

Run: `./build.sh --debug`
Expected: `Build complete: macrobo 2.0.XX` (where XX is the current commit count)

- [ ] **Step 3: Commit**

```bash
git add build.sh Sources/macrobo/BuildInfo.swift
git commit -m "chore: bump version to 2.0"
```

---

### Task 2: Create Formatting.swift — Shared formatBytes

**Files:**
- Create: `Sources/macrobo/Formatting.swift`
- Modify: `Sources/macrobo/CopyEngine.swift:548-563` (remove `formatBytes`)
- Modify: `Sources/macrobo/Logger.swift:215-231` (remove `formatBytes`)
- Modify: `Sources/macrobo/Models/CopyResult.swift:122-137` (remove `formatBytes`)

- [ ] **Step 1: Create Formatting.swift with shared formatBytes**

Create `Sources/macrobo/Formatting.swift`:

```swift
import Foundation

/// Shared formatting utilities used across macrobo components
/// Format bytes for human-readable display (macOS decimal units, base 1000)
func formatBytes(_ bytes: UInt64, precision: Int = 2) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0

    while value >= 1000 && unitIndex < units.count - 1 {
        value /= 1000
        unitIndex += 1
    }

    if unitIndex == 0 {
        return "\(bytes) \(units[unitIndex])"
    } else {
        return String(format: "%.\(precision)f %@", value, units[unitIndex])
    }
}
```

- [ ] **Step 2: Replace CopyEngine.formatBytes with shared version**

In `Sources/macrobo/CopyEngine.swift`, delete the `formatBytes` method (lines 548–563, the entire function including the `/// Format bytes...` doc comment). Then update the one call site at line 66 inside `run()`:

The existing call `formatBytes(totalBytes)` will now resolve to the free function. Since the old method used precision 1 (`%.1f`), update the call:

```swift
print("Copying \(filesToCopy.count) files (\(formatBytes(totalBytes, precision: 1)))...")
```

- [ ] **Step 3: Replace Logger.formatBytes with shared version**

In `Sources/macrobo/Logger.swift`, delete the `formatBytes` method (lines 215–231). The existing call sites in `logFileProgress` and `logOperation` use `formatBytes(bytes)` which will now resolve to the free function with default precision 2. No call site changes needed.

- [ ] **Step 4: Replace CopyResult.formatBytes with shared version**

In `Sources/macrobo/Models/CopyResult.swift`, delete the `formatBytes` method (lines 122–137). The existing call sites in the `summary` computed property use `formatBytes(bytesCopied)` etc., which will resolve to the free function. No call site changes needed.

- [ ] **Step 5: Verify build succeeds**

Run: `./build.sh --debug`
Expected: Build succeeds with no errors or warnings about `formatBytes`

- [ ] **Step 6: Commit**

```bash
git add Sources/macrobo/Formatting.swift Sources/macrobo/CopyEngine.swift Sources/macrobo/Logger.swift Sources/macrobo/Models/CopyResult.swift
git commit -m "refactor: extract shared formatBytes into Formatting.swift"
```

---

### Task 3: APFS Clonefile Fast Path

**Files:**
- Modify: `Sources/macrobo/FileOperations.swift:9-71`

- [ ] **Step 1: Add clonefile helper to FileOperations**

In `Sources/macrobo/FileOperations.swift`, add these two static methods after the `partialSuffix` declaration (after line 7):

```swift
    /// Checks if two paths are on the same APFS volume using statfs
    static func isSameAPFSVolume(source: String, destination: String) -> Bool {
        var srcStat = statfs()
        var dstStat = statfs()
        // Get the parent directory of destination (file may not exist yet)
        let dstDir = (destination as NSString).deletingLastPathComponent
        guard Darwin.statfs(source, &srcStat) == 0,
              Darwin.statfs(dstDir, &dstStat) == 0 else {
            return false
        }
        // Check filesystem type is APFS
        let srcType = withUnsafePointer(to: srcStat.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        guard srcType == "apfs" else { return false }
        // Compare filesystem IDs
        return srcStat.f_fsid.val.0 == dstStat.f_fsid.val.0
            && srcStat.f_fsid.val.1 == dstStat.f_fsid.val.1
    }

    /// Attempts an APFS clone. Returns true if successful, false if fallback needed.
    static func tryCloneFile(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        // Remove existing destination (clonefile fails with EEXIST)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        let result = source.path.withCString { srcPath in
            destination.path.withCString { dstPath in
                Darwin.clonefile(srcPath, dstPath, UInt32(CLONE_NOFOLLOW))
            }
        }
        if result == 0 { return true }
        // Fall back to streaming copy for any error
        // Expected: EXDEV (cross-device), ENOTSUP (not APFS), EEXIST (race)
        // Unexpected errors (e.g., EACCES) also fall back — let the normal copy path report them
        return false
    }
```

- [ ] **Step 2: Add clonefile fast path to copyFile**

In `FileOperations.copyFile()`, after getting `sourceSize` (after line 23) and before the resume check (line 26), insert the clone fast path:

```swift
        // APFS clone fast path: instant copy-on-write for same-volume copies
        if isSameAPFSVolume(source: source.path, destination: destination.path) {
            // Create parent directory if needed
            let parentDir = destination.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if tryCloneFile(from: source, to: destination) {
                // clonefile preserves all metadata — skip attribute copying
                await progressHandler?(sourceSize, sourceSize)
                return sourceSize
            }
            // Clone failed with unexpected error — fall through to streaming copy
        }
```

- [ ] **Step 3: Verify build succeeds**

Run: `./build.sh --debug`
Expected: Build succeeds

- [ ] **Step 4: Manual smoke test**

Create a test scenario on the same APFS volume:
```bash
mkdir -p /tmp/macrobo_clone_test/src /tmp/macrobo_clone_test/dst
dd if=/dev/urandom of=/tmp/macrobo_clone_test/src/testfile bs=1M count=10 2>/dev/null
.build/debug/macrobo /tmp/macrobo_clone_test/src /tmp/macrobo_clone_test/dst
diff /tmp/macrobo_clone_test/src/testfile /tmp/macrobo_clone_test/dst/testfile
rm -rf /tmp/macrobo_clone_test
```
Expected: Copy succeeds, diff shows no differences. Speed should be near-instant.

- [ ] **Step 5: Commit**

```bash
git add Sources/macrobo/FileOperations.swift
git commit -m "feat: add APFS clonefile fast path for same-volume copies"
```

---

### Task 4: F_NOCACHE for Large Sequential Reads

**Files:**
- Modify: `Sources/macrobo/FileOperations.swift` (inside `streamingCopy`)

- [ ] **Step 1: Add nocache threshold constant**

In `FileOperations`, add a constant after `partialSuffix` (line 7):

```swift
    private static let nocacheThreshold: UInt64 = 10 * 1024 * 1024  // 10MB
```

- [ ] **Step 2: Apply F_NOCACHE after opening file handles in streamingCopy**

In `streamingCopy()`, after opening `sourceHandle` (after the `defer { try? sourceHandle.close() }` line) add:

```swift
        // Bypass page cache for large files to avoid polluting system memory
        if sourceSize >= nocacheThreshold {
            fcntl(sourceHandle.fileDescriptor, F_NOCACHE, 1)
        }
```

After opening `destHandle` (after the `defer { try? destHandle.close() }` line for the destination) add:

```swift
        if sourceSize >= nocacheThreshold {
            fcntl(destHandle.fileDescriptor, F_NOCACHE, 1)
        }
```

- [ ] **Step 3: Verify build succeeds**

Run: `./build.sh --debug`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/macrobo/FileOperations.swift
git commit -m "perf: bypass page cache (F_NOCACHE) for files over 10MB"
```

---

## Chunk 2: Phase 2 — Reliability (Test Suite)

### Task 5: Set Up Test Target with Library Extraction

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/macrobo/MacroboCommand.swift` (move to thin wrapper)
- Create: `Sources/MacroboLib/` (all shared source files move here)
- Create: `Tests/macroboTests/FormattingTests.swift`

Swift's `@main` attribute on `MacroboCommand` generates an entry point that conflicts with XCTest's test runner. The fix is to extract all shared code into a `MacroboLib` library target. The executable target becomes a thin wrapper that just re-exports `@main`.

- [ ] **Step 1: Restructure into library + executable targets**

Move all source files except `MacroboCommand.swift` into a new library:

```bash
mkdir -p Sources/MacroboLib/Models
mv Sources/macrobo/CopyEngine.swift Sources/MacroboLib/
mv Sources/macrobo/FileOperations.swift Sources/MacroboLib/
mv Sources/macrobo/ProgressReporter.swift Sources/MacroboLib/
mv Sources/macrobo/Logger.swift Sources/MacroboLib/
mv Sources/macrobo/Formatting.swift Sources/MacroboLib/
mv Sources/macrobo/Models/CopyOptions.swift Sources/MacroboLib/Models/
mv Sources/macrobo/Models/CopyResult.swift Sources/MacroboLib/Models/
mv Sources/macrobo/BuildInfo.swift Sources/MacroboLib/
```

Keep `MacroboCommand.swift` in `Sources/macrobo/` and add `import MacroboLib` at the top.

- [ ] **Step 2: Update Package.swift**

Replace the `targets` array in `Package.swift` with:

```swift
    targets: [
        .target(
            name: "MacroboLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "macrobo",
            dependencies: ["MacroboLib"]
        ),
        .testTarget(
            name: "macroboTests",
            dependencies: ["MacroboLib"]
        )
    ]
```

- [ ] **Step 3: Update build.sh to generate BuildInfo.swift in MacroboLib**

In `build.sh`, change the `BUILD_INFO` path:

```bash
BUILD_INFO="$SCRIPT_DIR/Sources/MacroboLib/BuildInfo.swift"
```

- [ ] **Step 4: Add `import MacroboLib` to MacroboCommand.swift**

At the top of `Sources/macrobo/MacroboCommand.swift`, add:

```swift
import MacroboLib
```

- [ ] **Step 5: Make shared types and functions public**

All types, functions, and properties that `MacroboCommand` or tests need must be `public`. This includes:
- `formatBytes`, `parseSize`, `formatDuration`, `formatTruncate` in `Formatting.swift`
- `CopyOptions` struct and all its properties
- `CopyEngine` actor, its `init` and `run()` method
- `CopyResult` struct and its public properties
- `Logger` actor, its `init`
- `ProgressReporter` actor, its `init`
- `FileOperations` struct and its static methods
- `BuildInfo` enum
- `MacroboError` enum
- `FileOperationResult` enum
- `FileInfo` struct

Add `public` access modifier to all these declarations and their members that are accessed from outside `MacroboLib`.

- [ ] **Step 6: Verify build succeeds**

Run: `./build.sh --debug`
Expected: Build succeeds with the library structure

- [ ] **Step 7: Create first test file for formatting**

Create `Tests/macroboTests/FormattingTests.swift`:

```swift
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
}
```

- [ ] **Step 8: Run tests**

Run: `swift test`
Expected: All FormattingTests pass

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/MacroboLib/ Sources/macrobo/MacroboCommand.swift build.sh Tests/macroboTests/FormattingTests.swift
git commit -m "refactor: extract MacroboLib for testability, add formatting tests"
```

---

### Task 6: FileOperations Unit Tests

**Files:**
- Create: `Tests/macroboTests/FileOperationsTests.swift`

- [ ] **Step 1: Create FileOperations test file**

Create `Tests/macroboTests/FileOperationsTests.swift`:

```swift
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
        let data = Data("hello world".utf8)
        try! data.write(to: file)

        // Same file compared to itself
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
        let data = Data(repeating: 0x41, count: 1024)
        try! data.write(to: file)

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

        // Set modification date to the past
        let pastDate = Date().addingTimeInterval(-3600)
        try! FileManager.default.setAttributes(
            [.modificationDate: pastDate], ofItemAtPath: older.path
        )

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
        // File larger than 3 * 4KB to trigger sampling mode
        let file = tempDir.appendingPathComponent("large.bin")
        var data = Data(count: 50_000)
        for i in 0..<data.count { data[i] = UInt8(i % 256) }
        try data.write(to: file)

        let hash = try FileOperations.checksumFile(at: file)
        // Just verify it doesn't crash and returns a value
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
        // Both paths in the same temp directory (same APFS volume)
        // Use the temp dir itself (which exists) as the source,
        // and a file in the same dir as destination (statfs checks parent)
        let src = tempDir.path
        let dst = tempDir.appendingPathComponent("dst_file.txt").path
        XCTAssertTrue(FileOperations.isSameAPFSVolume(source: src, destination: dst))
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter FileOperationsTests`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/macroboTests/FileOperationsTests.swift
git commit -m "test: add FileOperations unit tests"
```

---

### Task 7: CopyEngine Integration Tests

**Files:**
- Create: `Tests/macroboTests/CopyEngineTests.swift`

- [ ] **Step 1: Create integration test file**

Create `Tests/macroboTests/CopyEngineTests.swift`:

```swift
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
        let base = srcDir.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
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

    // MARK: - Basic Copy

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
        // First copy
        _ = try await runCopy(options: options)
        // Second copy — should skip
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 0)
    }

    // MARK: - Filtering

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
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("wanted.swift").path))
    }

    func testExcludeDirectories() async throws {
        createFile("root.txt", in: srcDir)
        createFile("node_modules/dep.js", in: srcDir)

        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.excludeDirectories = ["node_modules"]
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("node_modules").path))
    }

    // MARK: - Mirror/Purge

    func testMirrorDeletesExtras() async throws {
        createFile("src_file.txt", in: srcDir)
        // Pre-populate destination with an extra file
        try! FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        createFile("extra.txt", in: dstDir, content: "should be deleted")

        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.mirror = true
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertTrue(result.filesDeleted > 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("extra.txt").path))
    }

    // MARK: - Dry Run

    func testDryRunCopiesNothing() async throws {
        createFile("file.txt", in: srcDir)

        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.dryRun = true
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 0)
        // Destination may or may not be created depending on implementation
    }

    // MARK: - Unicode Filenames

    func testUnicodeFilenames() async throws {
        createFile("日本語ファイル.txt", in: srcDir, content: "unicode")
        createFile("émojis 🎉.txt", in: srcDir, content: "fun")

        let options = CopyOptions(source: srcDir, destination: dstDir)
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 2)
        XCTAssertEqual(result.filesFailed, 0)
    }

    // MARK: - Empty Files

    func testEmptyFile() async throws {
        createFile("empty.txt", in: srcDir, content: "")

        let options = CopyOptions(source: srcDir, destination: dstDir)
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 1)
        let dstSize = FileOperations.fileSize(at: dstDir.appendingPathComponent("empty.txt"))
        XCTAssertEqual(dstSize, 0)
    }

    // MARK: - Size Filtering

    func testMinSizeFilter() async throws {
        createFile("small.txt", in: srcDir, content: "hi")
        createFile("big.txt", in: srcDir, content: String(repeating: "x", count: 1000))

        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.minFileSize = 500
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("big.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("small.txt").path))
    }

    // MARK: - Checksum Skip

    func testChecksumSkipsIdenticalContent() async throws {
        createFile("file.txt", in: srcDir, content: "same content")

        var options = CopyOptions(source: srcDir, destination: dstDir)
        // First copy
        _ = try await runCopy(options: options)

        // Modify destination timestamp to trigger checksum comparison
        let dstFile = dstDir.appendingPathComponent("file.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-100)],
            ofItemAtPath: dstFile.path
        )

        // Second copy with checksum — should detect identical content and skip
        options.checksum = true
        let result = try await runCopy(options: options)
        XCTAssertEqual(result.filesCopied, 0)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter CopyEngineTests`
Expected: All integration tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/macroboTests/CopyEngineTests.swift
git commit -m "test: add CopyEngine integration tests"
```

---

## Chunk 3: Phase 2 — Edge Case Fixes

### Task 8: Fix Relative Path Fallback

**Files:**
- Modify: `Sources/macrobo/CopyEngine.swift:338-346`

- [ ] **Step 1: Write failing test**

Add to `Tests/macroboTests/CopyEngineTests.swift`:

```swift
    // MARK: - Symlinked Source Path

    func testCopyFromSymlinkedSource() async throws {
        // Create real source directory with files
        let realSrc = srcDir.deletingLastPathComponent().appendingPathComponent("real_src")
        try FileManager.default.createDirectory(at: realSrc, withIntermediateDirectories: true)
        createFile("subdir/nested.txt", in: realSrc, content: "from symlink")

        // Create symlink pointing to real source
        let symlinkSrc = srcDir.deletingLastPathComponent().appendingPathComponent("link_src")
        try FileManager.default.createSymbolicLink(at: symlinkSrc, withDestinationURL: realSrc)

        let options = CopyOptions(source: symlinkSrc, destination: dstDir)
        let result = try await runCopy(options: options)

        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesFailed, 0)
        // The key assertion: file must be in the correct subdirectory, not flattened
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dstDir.appendingPathComponent("subdir/nested.txt").path
        ))
    }
```

- [ ] **Step 2: Run test to verify behavior**

Run: `swift test --filter testCopyFromSymlinkedSource`
Observe whether it passes or fails — this tests the edge case.

- [ ] **Step 3: Fix the relative path calculation in enumerateSourceFilesSync**

In `CopyEngine.swift`, replace the relative path calculation block (lines ~338-346):

```swift
            // Calculate relative path by removing source prefix
            // Use realpath for both to handle symlinked sources correctly
            let urlResolved = url.resolvingSymlinksInPath().path
            let sourceResolved = source.resolvingSymlinksInPath().path
            let relativePath: String
            if urlResolved.hasPrefix(sourceResolved) {
                relativePath = String(urlResolved.dropFirst(sourceResolved.count))
            } else if urlPathStandardized.hasPrefix(sourcePathStandardized) {
                relativePath = String(urlPathStandardized.dropFirst(sourcePathStandardized.count))
            } else {
                // Last resort fallback — log this case for debugging
                relativePath = "/" + url.lastPathComponent
            }
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: All tests pass including the new symlink test

- [ ] **Step 5: Commit**

```bash
git add Sources/macrobo/CopyEngine.swift Tests/macroboTests/CopyEngineTests.swift
git commit -m "fix: resolve symlinked source paths for correct relative path calculation"
```

---

### Task 9: Fix gatherFilesToPurge Nonisolated Safety

**Files:**
- Modify: `Sources/macrobo/CopyEngine.swift:471-545`

- [ ] **Step 1: Pass values as explicit parameters**

Change `gatherFilesToPurge` to accept parameters instead of reading actor properties. Update the signature and the call site.

Change the function signature (line ~510):

```swift
    private nonisolated func gatherFilesToPurge(
        destination: URL,
        resolvedDestPath: String,
        resolvedSourcePath: String
    ) -> (files: [URL], dirs: [URL]) {
```

Inside the function, replace `options.destination` with `destination`, and the property references are already `resolvedDestPath` and `resolvedSourcePath` — those just become the parameters.

Update the call site in `purgeExtraFiles()` (line ~477):

```swift
        let (filesToDelete, dirsToDelete) = gatherFilesToPurge(
            destination: options.destination,
            resolvedDestPath: resolvedDestPath,
            resolvedSourcePath: resolvedSourcePath
        )
```

- [ ] **Step 2: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 3: Commit**

```bash
git add Sources/macrobo/CopyEngine.swift
git commit -m "fix: pass explicit parameters to nonisolated gatherFilesToPurge"
```

---

### Task 10: Dynamic Terminal Width

**Files:**
- Modify: `Sources/macrobo/ProgressReporter.swift:61,67-73`
- Modify: `Sources/macrobo/Logger.swift:10,16-27`

- [ ] **Step 1: Make ProgressReporter terminal width dynamic**

In `ProgressReporter.swift`, change `terminalWidth` from a stored `let` to a computed property:

Replace the property declaration and init (lines ~61, 67-73):

```swift
    private var cachedTerminalWidth: Int = 0
    private var lastWidthCheck: Date = .distantPast

    private var terminalWidth: Int {
        let now = Date()
        if now.timeIntervalSince(lastWidthCheck) >= 1.0 {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
                cachedTerminalWidth = Int(ws.ws_col)
            } else if cachedTerminalWidth == 0 {
                cachedTerminalWidth = 120
            }
            lastWidthCheck = now
        }
        return cachedTerminalWidth
    }

    init(quiet: Bool = false) {
        self.quiet = quiet
    }
```

- [ ] **Step 2: Make Logger terminal width dynamic**

In `Logger.swift`, apply the same pattern. Replace the `terminalWidth` property and init (lines ~10, 16-27):

```swift
    private var cachedTerminalWidth: Int = 0
    private var lastWidthCheck: Date = .distantPast

    private var terminalWidth: Int {
        let now = Date()
        if now.timeIntervalSince(lastWidthCheck) >= 1.0 {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
                cachedTerminalWidth = Int(ws.ws_col)
            } else if cachedTerminalWidth == 0 {
                cachedTerminalWidth = 80
            }
            lastWidthCheck = now
        }
        return cachedTerminalWidth
    }

    init(logFile: URL? = nil, append: Bool = false, verbose: Bool = false, quiet: Bool = false) {
        self.logFile = logFile
        self.appendMode = append
        self.verbose = verbose
        self.quiet = quiet
    }
```

- [ ] **Step 3: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/macrobo/ProgressReporter.swift Sources/macrobo/Logger.swift
git commit -m "fix: refresh terminal width dynamically instead of caching at init"
```

---

## Chunk 4: Phase 3 — Code Quality

### Task 11: Extract FileEnumerator from CopyEngine

**Files:**
- Create: `Sources/macrobo/FileEnumerator.swift`
- Modify: `Sources/macrobo/CopyEngine.swift`

- [ ] **Step 1: Create FileEnumerator.swift**

Create `Sources/macrobo/FileEnumerator.swift` containing the `FileInfo` struct, enumeration logic, and glob pattern helpers extracted from CopyEngine:

```swift
import Foundation

/// File info with size and relative path captured during enumeration
struct FileInfo: Sendable {
    let url: URL
    let size: UInt64
    let relativePath: String
}

/// Enumerates and filters source files for copying
struct FileEnumerator {

    /// Compiles a glob pattern (*, ?) into a pre-compiled NSRegularExpression
    static func compileGlobPattern(_ pattern: String) -> NSRegularExpression? {
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        return try? NSRegularExpression(pattern: "^\(regexPattern)$", options: .caseInsensitive)
    }

    /// Checks if a name matches a pre-compiled regex
    static func matches(_ name: String, regex: NSRegularExpression?, fallbackPattern: String) -> Bool {
        guard let regex = regex else {
            return name.lowercased() == fallbackPattern.lowercased()
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Enumerates source files synchronously with filtering
    static func enumerateSourceFiles(
        source: URL,
        skipHidden: Bool,
        excludeDirs: [String],
        excludeFiles: [String],
        includeFiles: [String],
        minSize: UInt64?,
        maxSize: UInt64?
    ) throws -> [FileInfo] {
        let fm = FileManager.default
        var files: [FileInfo] = []

        let excludeDirRegexes = excludeDirs.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let excludeFileRegexes = excludeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let includeFileRegexes = includeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }

        let sourcePathStandardized = source.standardizedFileURL.path

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if skipHidden {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        let resolvedSource = source.resolvingSymlinksInPath()
        var visitedDirs: Set<String> = [resolvedSource.path]

        let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: enumeratorOptions
        )

        guard let enumerator = enumerator else {
            throw MacroboError.sourceNotFound(source.path)
        }

        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])

            if resourceValues?.isDirectory == true {
                let resolvedDir = url.resolvingSymlinksInPath().path
                if visitedDirs.contains(resolvedDir) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedDirs.insert(resolvedDir)

                let dirName = url.lastPathComponent
                let shouldSkip = excludeDirRegexes.contains { matches(dirName, regex: $0.regex, fallbackPattern: $0.pattern) }
                if shouldSkip {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }

            guard resourceValues?.isRegularFile == true else { continue }

            let fileName = url.lastPathComponent

            let shouldExclude = excludeFileRegexes.contains { matches(fileName, regex: $0.regex, fallbackPattern: $0.pattern) }
            if shouldExclude { continue }

            if !includeFileRegexes.isEmpty {
                let shouldInclude = includeFileRegexes.contains { matches(fileName, regex: $0.regex, fallbackPattern: $0.pattern) }
                if !shouldInclude { continue }
            }

            let fileSize = UInt64(resourceValues?.fileSize ?? 0)
            let actualSize = fileSize > 0 ? fileSize : (FileOperations.fileSize(at: url) ?? 0)

            if let min = minSize, actualSize < min { continue }
            if let max = maxSize, actualSize > max { continue }

            // Calculate relative path — try resolved paths first for symlink safety
            let urlResolved = url.resolvingSymlinksInPath().path
            let sourceResolved = source.resolvingSymlinksInPath().path
            let relativePath: String
            if urlResolved.hasPrefix(sourceResolved) {
                relativePath = String(urlResolved.dropFirst(sourceResolved.count))
            } else {
                let urlPathStandardized = url.standardizedFileURL.path
                if urlPathStandardized.hasPrefix(sourcePathStandardized) {
                    relativePath = String(urlPathStandardized.dropFirst(sourcePathStandardized.count))
                } else {
                    relativePath = "/" + url.lastPathComponent
                }
            }

            files.append(FileInfo(url: url, size: actualSize, relativePath: relativePath))
        }

        return files
    }
}
```

- [ ] **Step 2: Update CopyEngine to use FileEnumerator**

In `CopyEngine.swift`:

1. Remove `FileInfo` struct (lines 3-8) — it's now in FileEnumerator.swift
2. Remove `compileGlobPattern` method (lines ~236-242)
3. Remove `matches` method (lines ~245-251)
4. Remove `enumerateSourceFilesSync` method (lines ~254-352)
5. Update `gatherSourceFiles()` to call `FileEnumerator.enumerateSourceFiles(...)` instead of `Self.enumerateSourceFilesSync(...)`

In the `gatherSourceFiles()` method, replace the `Task.detached` call:

```swift
        candidates = try await Task.detached {
            try FileEnumerator.enumerateSourceFiles(
                source: sourceURL,
                skipHidden: skipHidden,
                excludeDirs: excludeDirs,
                excludeFiles: excludeFilesPatterns,
                includeFiles: includeFilesPatterns,
                minSize: minSize,
                maxSize: maxSize
            )
        }.value
```

- [ ] **Step 3: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests still pass

- [ ] **Step 4: Commit**

```bash
git add Sources/macrobo/FileEnumerator.swift Sources/macrobo/CopyEngine.swift
git commit -m "refactor: extract FileEnumerator from CopyEngine"
```

---

### Task 12: Extract Shared Formatting Utilities

**Files:**
- Modify: `Sources/macrobo/Formatting.swift`
- Modify: `Sources/macrobo/Models/CopyResult.swift:140-152`
- Modify: `Sources/macrobo/ProgressReporter.swift:411-426,454-475`
- Modify: `Sources/macrobo/Logger.swift:188-198`

- [ ] **Step 1: Add formatDuration to Formatting.swift**

Add to `Sources/macrobo/Formatting.swift`:

```swift
/// Format a time duration for display
/// - Parameter compact: If true, uses compact format (02m35s). If false, uses readable format (2m 35s).
func formatDuration(_ seconds: TimeInterval, compact: Bool = false) -> String {
    let secs = Int(max(0, seconds))
    if compact {
        if secs >= 86400 {
            return String(format: "%02dd%02dh", secs / 86400, (secs % 86400) / 3600)
        } else if secs >= 3600 {
            return String(format: "%02dh%02dm", secs / 3600, (secs % 3600) / 60)
        } else {
            return String(format: "%02dm%02ds", secs / 60, secs % 60)
        }
    } else {
        if seconds < 60 {
            return String(format: "%.1f seconds", seconds)
        } else if secs < 3600 {
            return "\(secs / 60)m \(secs % 60)s"
        } else {
            return "\(secs / 3600)h \((secs % 3600) / 60)m"
        }
    }
}

/// Truncate or pad a string to an exact display width
func formatTruncate(_ text: String, maxWidth: Int, pad: Bool = false) -> String {
    guard maxWidth > 0 else { return "" }

    if text.count > maxWidth {
        if maxWidth > 3 {
            return "..." + text.suffix(maxWidth - 3)
        }
        return String(text.prefix(maxWidth))
    } else if pad {
        return text + String(repeating: " ", count: maxWidth - text.count)
    }
    return text
}

/// Terminal dimension utilities
enum Terminal {
    static var width: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }
}
```

- [ ] **Step 2: Replace CopyResult.formatDuration with shared version**

In `CopyResult.swift`, delete the `formatDuration` method (lines ~140-152). Update the call site in `summary`:

```swift
        lines.append(row("Duration", formatDuration(duration)))
```

This matches the existing output because the non-compact format is the default.

- [ ] **Step 3: Replace ProgressReporter.formatTime with shared version**

In `ProgressReporter.swift`, delete the `formatTime` method (lines ~411-426). Replace all calls to `formatTime(...)` with `formatDuration(..., compact: true)`:

- In `formatCompletedLine`: `formatTime(completed.duration)` → `formatDuration(completed.duration, compact: true)`
- In `formatActiveLine`: `formatTime(progress.eta(at: now))` → `formatDuration(progress.eta(at: now), compact: true)`
- In `formatTotalLine`: `formatTime(remaining)` → `formatDuration(remaining, compact: true)` and the `"00m00s"` default stays the same.

- [ ] **Step 4: Replace ProgressReporter.truncateOrPad with shared version**

In `ProgressReporter.swift`, delete the `truncateOrPad` method (lines ~454-475). Replace all calls to `truncateOrPad(text, width: w)` with `formatTruncate(text, maxWidth: w, pad: true)`.

Note: `ProgressReporter.truncateOrPad` pads shorter strings with spaces and truncates with `...` at the end (prefix-based). The shared `formatTruncate` uses `...` at the start (suffix-based, showing the end of the string). Update `formatTruncate` to match ProgressReporter's behavior by adding an `ellipsisPosition` parameter, OR change ProgressReporter to use end-of-string truncation. Since filenames are more useful when you see the end (extension + name), the suffix-based truncation from `formatTruncate` is actually better. Keep the shared version as-is.

- [ ] **Step 5: Replace Logger truncate methods with shared version**

In `Logger.swift`, delete `truncate` and `truncatePath` methods (lines ~188-198). Replace calls:

- `truncate(fileName, max: 30)` → `formatTruncate(fileName, maxWidth: 30)`
- `truncate(source.lastPathComponent, max: 35)` → `formatTruncate(source.lastPathComponent, maxWidth: 35)`
- `truncatePath(path.path, max: 50)` → `formatTruncate(path.path, maxWidth: 50)`

- [ ] **Step 6: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 7: Add tests for new formatting functions**

Add to `Tests/macroboTests/FormattingTests.swift`:

```swift
    // MARK: - formatDuration

    func testFormatDurationSeconds() {
        XCTAssertEqual(formatDuration(5.3), "5.3 seconds")
        XCTAssertEqual(formatDuration(59.9), "59.9 seconds")
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
```

- [ ] **Step 8: Run all tests**

Run: `swift test`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add Sources/macrobo/Formatting.swift Sources/macrobo/Models/CopyResult.swift Sources/macrobo/ProgressReporter.swift Sources/macrobo/Logger.swift Tests/macroboTests/FormattingTests.swift
git commit -m "refactor: extract shared formatting utilities (formatDuration, formatTruncate, Terminal)"
```

---

### Task 13: Make CopyResult Mutation Consistent

**Files:**
- Modify: `Sources/macrobo/Models/CopyResult.swift`
- Modify: `Sources/macrobo/CopyEngine.swift`

- [ ] **Step 1: Add directory deletion to FileOperationResult**

In `Models/CopyResult.swift`, add a new case to `FileOperationResult`:

```swift
    case directoryDeleted(path: URL)
```

- [ ] **Step 2: Handle the new case in CopyResult.record**

In the `record` method, add:

```swift
        case .directoryDeleted(_):
            directoriesDeleted += 1
```

- [ ] **Step 3: Handle the new case in Logger.logOperation**

In `Logger.swift`, in the `logOperation` method's switch statement, add:

```swift
        case .directoryDeleted(let path):
            let msg = "RMDIR: \(formatTruncate(path.lastPathComponent, maxWidth: 50))"
            debug(msg)
```

- [ ] **Step 4: Update CopyEngine.purgeExtraFiles to use record()**

In `CopyEngine.swift`, in `purgeExtraFiles()`, replace the direct mutations:

For file deletion (replace `result.filesDeleted += 1`):
```swift
                result.record(.deleted(path: file))
```

For directory deletion (replace `result.directoriesDeleted += 1`):
```swift
                result.record(.directoryDeleted(path: dir))
```

- [ ] **Step 5: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/macrobo/Models/CopyResult.swift Sources/macrobo/CopyEngine.swift Sources/macrobo/Logger.swift
git commit -m "refactor: route all CopyResult mutations through record()"
```

---

## Chunk 5: Phase 4 — Features

### Task 14: Bandwidth Limiting

**Files:**
- Create: `Sources/macrobo/RateLimiter.swift`
- Modify: `Sources/macrobo/FileOperations.swift`
- Modify: `Sources/macrobo/Models/CopyOptions.swift`
- Modify: `Sources/macrobo/MacroboCommand.swift`

- [ ] **Step 1: Add bandwidthLimit to CopyOptions**

In `Models/CopyOptions.swift`, add after the `resumePartial` property:

```swift
    var bandwidthLimit: UInt64 = 0  // 0 = unlimited, bytes per second
```

- [ ] **Step 2: Create RateLimiter actor**

Create `Sources/macrobo/RateLimiter.swift`:

```swift
import Foundation

/// Token-bucket rate limiter for bandwidth throttling across multiple threads
actor RateLimiter {
    private let bytesPerSecond: UInt64
    private var tokens: Double
    private var lastRefill: Date
    private let maxBurst: Double

    /// Creates a rate limiter. Pass 0 for unlimited.
    init(bytesPerSecond: UInt64) {
        self.bytesPerSecond = bytesPerSecond
        let burst = Double(bytesPerSecond)
        self.maxBurst = burst
        self.tokens = burst
        self.lastRefill = Date()
    }

    nonisolated var isUnlimited: Bool { bytesPerSecond == 0 }

    /// Request permission to write `bytes` bytes. Sleeps if necessary to stay within rate.
    func acquire(_ bytes: Int) async {
        guard bytesPerSecond > 0 else { return }

        let needed = Double(bytes)

        // Refill tokens based on elapsed time
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        tokens = min(maxBurst, tokens + elapsed * Double(bytesPerSecond))
        lastRefill = now

        if tokens >= needed {
            tokens -= needed
            return
        }

        // Not enough tokens — calculate sleep time
        let deficit = needed - tokens
        let sleepSeconds = deficit / Double(bytesPerSecond)
        tokens = 0
        lastRefill = Date()

        try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
    }
}
```

- [ ] **Step 3: Add rateLimiter parameter to FileOperations.streamingCopy**

In `FileOperations.swift`, update the `streamingCopy` method signature to accept an optional rate limiter:

```swift
    private static func streamingCopy(
        from source: URL,
        to partialDest: URL,
        finalDestination: URL,
        sourceSize: UInt64,
        resumeOffset: UInt64,
        syncBeforeRename: Bool,
        rateLimiter: RateLimiter? = nil,
        progressHandler: ((UInt64, UInt64) async -> Void)?,
        syncHandler: (() async -> Void)?
    ) async throws {
```

Inside the copy loop, after `try destHandle.write(contentsOf: chunk)`, add:

```swift
                if let limiter = rateLimiter, !limiter.isUnlimited {
                    await limiter.acquire(chunk.count)
                }
```

- [ ] **Step 4: Thread rateLimiter through copyFile**

Update `FileOperations.copyFile()` signature to accept the rate limiter:

```swift
    static func copyFile(
        from source: URL,
        to destination: URL,
        options: CopyOptions,
        rateLimiter: RateLimiter? = nil,
        progressHandler: ((UInt64, UInt64) async -> Void)? = nil,
        syncHandler: (() async -> Void)? = nil
    ) async throws -> UInt64 {
```

Pass it through to `streamingCopy`:

```swift
        try await streamingCopy(
            from: source,
            to: partialURL,
            finalDestination: destination,
            sourceSize: sourceSize,
            resumeOffset: resumeOffset,
            syncBeforeRename: needsSync,
            rateLimiter: rateLimiter,
            progressHandler: progressHandler,
            syncHandler: syncHandler
        )
```

- [ ] **Step 5: Create and pass RateLimiter in CopyEngine**

In `CopyEngine.swift`, add a stored property:

```swift
    private let rateLimiter: RateLimiter?
```

Initialize it in `init`:

```swift
        self.rateLimiter = options.bandwidthLimit > 0
            ? RateLimiter(bytesPerSecond: options.bandwidthLimit)
            : nil
```

In the `copyFile` method, pass the limiter to `FileOperations.copyFile`:

```swift
                let bytes = try await FileOperations.copyFile(
                    from: source,
                    to: destURL,
                    options: options,
                    rateLimiter: rateLimiter,
                    progressHandler: { ... },
                    syncHandler: { ... }
                )
```

- [ ] **Step 6: Add --bwlimit flag to MacroboCommand**

Extract `parseSize` from `MacroboCommand` to `Formatting.swift` so it can be reused:

Add to `Formatting.swift`:

```swift
/// Parses a human-readable size string (e.g., "100M", "1G") using macOS decimal units
func parseSize(_ sizeStr: String) -> UInt64? {
    let str = sizeStr.uppercased().trimmingCharacters(in: .whitespaces)
    guard !str.isEmpty else { return nil }

    let multipliers: [Character: UInt64] = [
        "K": 1_000,
        "M": 1_000_000,
        "G": 1_000_000_000,
        "T": 1_000_000_000_000
    ]

    if let lastChar = str.last, let multiplier = multipliers[lastChar] {
        let numStr = String(str.dropLast())
        guard let num = UInt64(numStr) else { return nil }
        return num * multiplier
    } else {
        return UInt64(str)
    }
}
```

In `MacroboCommand.swift`, delete the private `parseSize` method and add the `--bwlimit` option:

```swift
    @Option(name: .customLong("bwlimit"),
            help: "Bandwidth limit (e.g., 50M for 50 MB/s, 0 for unlimited)")
    var bwlimit: String?
```

In the `run()` method, add after the performance options section:

```swift
        if let bwlimit = bwlimit {
            options.bandwidthLimit = parseSize(bwlimit) ?? 0
        }
```

- [ ] **Step 7: Add parseSize tests**

Add to `Tests/macroboTests/FormattingTests.swift`:

```swift
    // MARK: - parseSize

    func testParseSizeBytes() {
        XCTAssertEqual(parseSize("1024"), 1024)
    }

    func testParseSizeKilobytes() {
        XCTAssertEqual(parseSize("100K"), 100_000)
    }

    func testParseSizeMegabytes() {
        XCTAssertEqual(parseSize("50M"), 50_000_000)
    }

    func testParseSizeGigabytes() {
        XCTAssertEqual(parseSize("2G"), 2_000_000_000)
    }

    func testParseSizeCaseInsensitive() {
        XCTAssertEqual(parseSize("100m"), 100_000_000)
    }

    func testParseSizeInvalid() {
        XCTAssertNil(parseSize(""))
        XCTAssertNil(parseSize("abc"))
    }
```

- [ ] **Step 8: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 9: Commit**

```bash
git add Sources/macrobo/RateLimiter.swift Sources/macrobo/FileOperations.swift Sources/macrobo/Models/CopyOptions.swift Sources/macrobo/MacroboCommand.swift Sources/macrobo/CopyEngine.swift Sources/macrobo/Formatting.swift Tests/macroboTests/FormattingTests.swift
git commit -m "feat: add --bwlimit flag for bandwidth throttling"
```

---

### Task 15: Config File Support

**Files:**
- Create: `Sources/macrobo/ConfigFile.swift`
- Modify: `Sources/macrobo/MacroboCommand.swift`

- [ ] **Step 1: Create ConfigFile parser**

Create `Sources/macrobo/ConfigFile.swift`:

```swift
import Foundation

/// Parses macrobo config files (flat key: value format)
struct ConfigFile {
    let values: [String: String]

    /// Loads and parses a config file
    static func load(from path: String) throws -> ConfigFile {
        let expandedPath = (path as NSString).expandingTildeInPath
        let content = try String(contentsOfFile: expandedPath, encoding: .utf8)
        return parse(content)
    }

    /// Loads a named job from ~/.config/macrobo/<name>.conf
    static func loadJob(named name: String) throws -> ConfigFile {
        let configDir = ("~/.config/macrobo" as NSString).expandingTildeInPath
        let path = (configDir as NSString).appendingPathComponent("\(name).conf")
        return try load(from: path)
    }

    /// Parses config file content
    static func parse(_ content: String) -> ConfigFile {
        var values: [String: String] = [:]

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split on first colon
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

            if !key.isEmpty {
                values[key] = value
            }
        }

        return ConfigFile(values: values)
    }

    /// Applies config values to CopyOptions, without overriding values already set by CLI flags
    func apply(to options: inout CopyOptions, warnings: inout [String]) {
        for (key, value) in values {
            switch key {
            case "source":
                // Only apply if not already set by CLI — caller handles this
                break
            case "destination":
                break
            case "mirror":
                if value.lowercased() == "true" { options.mirror = true }
            case "purge":
                if value.lowercased() == "true" { options.purge = true }
            case "threads":
                if let n = Int(value) { options.threadCount = n }
            case "retry":
                if let n = Int(value) { options.retryCount = n }
            case "wait":
                if let n = Int(value) { options.retryWaitSeconds = n }
            case "exclude-files":
                options.excludeFiles = value.components(separatedBy: " ").filter { !$0.isEmpty }
            case "exclude-dirs":
                options.excludeDirectories = value.components(separatedBy: " ").filter { !$0.isEmpty }
            case "include-files":
                options.includeFiles = value.components(separatedBy: " ").filter { !$0.isEmpty }
            case "exclude-older":
                if value.lowercased() == "true" { options.excludeOlder = true }
            case "exclude-extra":
                if value.lowercased() == "true" { options.excludeExtra = true }
            case "include-same":
                if value.lowercased() == "true" { options.includeSame = true }
            case "checksum":
                if value.lowercased() == "true" { options.checksum = true }
            case "max-size":
                if let s = parseSize(value) { options.maxFileSize = s }
            case "min-size":
                if let s = parseSize(value) { options.minFileSize = s }
            case "bwlimit":
                if let s = parseSize(value) { options.bandwidthLimit = s }
            case "verbose":
                if value.lowercased() == "true" { options.verbose = true }
            case "quiet":
                if value.lowercased() == "true" { options.quiet = true }
            default:
                warnings.append("Unknown config key: \(key)")
            }
        }
    }
}
```

- [ ] **Step 2: Add --job and --config flags to MacroboCommand**

In `MacroboCommand.swift`, add after the dry-run section:

```swift
    // MARK: - Config File

    @Option(name: .customLong("config"),
            help: "Path to a config file")
    var configFile: String?

    @Option(name: .customLong("job"),
            help: "Named job from ~/.config/macrobo/<name>.conf")
    var job: String?
```

Make source and destination optional to support config-file-only invocations:

```swift
    @Argument(help: "Source directory to copy from")
    var source: String?

    @Argument(help: "Destination directory to copy to")
    var destination: String?
```

In the `run()` method, add config loading before options construction. Parse once and reuse:

```swift
        // Load config file if specified (parse once, reuse)
        var configWarnings: [String] = []
        var loadedConfig: ConfigFile? = nil

        if let jobName = job {
            do {
                loadedConfig = try ConfigFile.loadJob(named: jobName)
            } catch {
                fputs("Error loading job '\(jobName)': \(error.localizedDescription)\n", stderr)
                throw ExitCode(1)
            }
        } else if let configPath = configFile {
            do {
                loadedConfig = try ConfigFile.load(from: configPath)
            } catch {
                fputs("Error loading config: \(error.localizedDescription)\n", stderr)
                throw ExitCode(1)
            }
        }

        // Resolve source and destination (CLI overrides config)
        let configSource = loadedConfig?.values["source"]
        let configDest = loadedConfig?.values["destination"]

        guard let resolvedSource = source ?? configSource else {
            fputs("Error: source directory is required\n", stderr)
            throw ExitCode(1)
        }
        guard let resolvedDest = destination ?? configDest else {
            fputs("Error: destination directory is required\n", stderr)
            throw ExitCode(1)
        }

        let sourceURL = URL(fileURLWithPath: (resolvedSource as NSString).expandingTildeInPath)
        let destURL = URL(fileURLWithPath: (resolvedDest as NSString).expandingTildeInPath)
```

Apply config values after constructing options but before CLI overrides:

```swift
        var options = CopyOptions(source: sourceURL, destination: destURL)

        // Apply config file values first (CLI flags override below)
        if let config = loadedConfig {
            config.apply(to: &options, warnings: &configWarnings)
        }

        // Print config warnings
        for warning in configWarnings {
            fputs("Warning: \(warning)\n", stderr)
        }

        // CLI overrides follow (existing code)...
```

- [ ] **Step 3: Add config file tests**

Create `Tests/macroboTests/ConfigFileTests.swift`:

```swift
import XCTest
@testable import MacroboLib

final class ConfigFileTests: XCTestCase {
    func testParseBasicConfig() {
        let content = """
        source: ~/Photos
        destination: /Volumes/NAS/Photos
        mirror: true
        threads: 4
        """
        let config = ConfigFile.parse(content)
        XCTAssertEqual(config.values["source"], "~/Photos")
        XCTAssertEqual(config.values["destination"], "/Volumes/NAS/Photos")
        XCTAssertEqual(config.values["mirror"], "true")
        XCTAssertEqual(config.values["threads"], "4")
    }

    func testSkipsCommentsAndEmptyLines() {
        let content = """
        # This is a comment
        source: /src

        # Another comment
        destination: /dst
        """
        let config = ConfigFile.parse(content)
        XCTAssertEqual(config.values.count, 2)
    }

    func testMultiValueKeys() {
        let content = "exclude-dirs: .git node_modules .build"
        let config = ConfigFile.parse(content)
        XCTAssertEqual(config.values["exclude-dirs"], ".git node_modules .build")
    }

    func testApplyToOptions() {
        let content = """
        mirror: true
        threads: 16
        exclude-dirs: .git node_modules
        bwlimit: 50M
        """
        let config = ConfigFile.parse(content)
        var options = CopyOptions(
            source: URL(fileURLWithPath: "/src"),
            destination: URL(fileURLWithPath: "/dst")
        )
        var warnings: [String] = []
        config.apply(to: &options, warnings: &warnings)

        XCTAssertTrue(options.mirror)
        XCTAssertEqual(options.threadCount, 16)
        XCTAssertEqual(options.excludeDirectories, [".git", "node_modules"])
        XCTAssertEqual(options.bandwidthLimit, 50_000_000)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testUnknownKeyWarning() {
        let content = "future-flag: value"
        let config = ConfigFile.parse(content)
        var options = CopyOptions(
            source: URL(fileURLWithPath: "/src"),
            destination: URL(fileURLWithPath: "/dst")
        )
        var warnings: [String] = []
        config.apply(to: &options, warnings: &warnings)

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("future-flag"))
    }
}
```

- [ ] **Step 4: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/macrobo/ConfigFile.swift Sources/macrobo/MacroboCommand.swift Tests/macroboTests/ConfigFileTests.swift
git commit -m "feat: add --job and --config flags for config file support"
```

---

### Task 16: JSON Progress Output Mode

**Files:**
- Modify: `Sources/macrobo/ProgressReporter.swift`
- Modify: `Sources/macrobo/MacroboCommand.swift`
- Modify: `Sources/macrobo/Models/CopyOptions.swift`

- [ ] **Step 1: Add ProgressMode enum and option**

In `Models/CopyOptions.swift`, add:

```swift
    /// Progress display mode
    enum ProgressMode: String {
        case bar
        case json
        case none
    }

    var progressMode: ProgressMode = .bar
```

- [ ] **Step 2: Add JSON output to ProgressReporter**

In `ProgressReporter.swift`, add a `mode` property and JSON methods:

Add to stored properties:

```swift
    private let mode: CopyOptions.ProgressMode
```

Update init:

```swift
    init(quiet: Bool = false, mode: CopyOptions.ProgressMode = .bar) {
        self.quiet = quiet
        self.mode = mode
    }
```

Add JSON output helper:

```swift
    private func writeJSON(_ dict: [String: Any]) {
        // Build JSON string manually to avoid Foundation's JSONSerialization import overhead
        var parts: [String] = []
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            switch value {
            case let s as String:
                parts.append("\"\(key)\":\"\(s)\"")
            case let n as Int:
                parts.append("\"\(key)\":\(n)")
            case let n as UInt64:
                parts.append("\"\(key)\":\(n)")
            case let n as Double:
                parts.append("\"\(key)\":\(String(format: "%.2f", n))")
            default:
                parts.append("\"\(key)\":\"\(value)\"")
            }
        }
        let json = "{\(parts.joined(separator: ","))}\n"
        json.utf8CString.withUnsafeBufferPointer { ptr in
            _ = Darwin.write(STDOUT_FILENO, ptr.baseAddress, json.utf8.count)
        }
    }
```

In `fileStarted`, add JSON branch at the top:

```swift
        if mode == .json {
            writeJSON([
                "event": "file_start",
                "path": key,
                "name": displayName,
                "size": bytes
            ])
            return
        }
```

In `fileCompleted`, add JSON branch at the top:

```swift
        if mode == .json {
            let now = Date()
            let duration = activeFiles[key].map { now.timeIntervalSince($0.startTime) } ?? 0
            let speed = duration > 0.001 ? Double(bytes) / duration : 0
            writeJSON([
                "event": "file_done",
                "path": key,
                "name": displayName,
                "bytes": bytes,
                "speed": speed,
                "duration": duration
            ])
            // Still track counts for summary
            activeFiles.removeValue(forKey: key)
            completedFiles += 1
            completedBytes += bytes
            return
        }
```

In `finish`, add JSON branch:

```swift
        if mode == .json {
            let elapsed = Date().timeIntervalSince(startTime)
            writeJSON([
                "event": "summary",
                "files": completedFiles,
                "bytes": completedBytes,
                "duration": elapsed
            ])
            return
        }
```

- [ ] **Step 3: Add --progress flag to MacroboCommand**

In `MacroboCommand.swift`, add:

```swift
    @Option(name: .customLong("progress"),
            help: "Progress display mode: bar (default), json, or none")
    var progressMode: String?
```

In `run()`, resolve the progress mode considering flag interactions:

```swift
        // Resolve progress mode
        let resolvedProgressMode: CopyOptions.ProgressMode
        if let modeStr = progressMode, let mode = CopyOptions.ProgressMode(rawValue: modeStr) {
            resolvedProgressMode = mode
        } else {
            resolvedProgressMode = .bar
        }
        options.progressMode = resolvedProgressMode

        // Flag interactions:
        // --progress=json overrides --verbose
        // --progress=bar + --verbose: verbose wins (no progress bar)
        // --progress=none: equivalent to --quiet for progress
```

Update ProgressReporter construction:

```swift
        let suppressProgress = options.quiet || options.verbose || resolvedProgressMode == .none
        let progress = ProgressReporter(
            quiet: suppressProgress && resolvedProgressMode != .json,
            mode: resolvedProgressMode
        )

        // Suppress text banner in JSON mode to keep stdout clean for machine parsing
        let suppressBanner = options.quiet || resolvedProgressMode == .json
```

Also update the existing header-printing block to use `suppressBanner`:

```swift
        if !suppressBanner {
            let title = "macrobo - Multi-threaded File Copy for macOS (v\(BuildInfo.fullVersion))"
            // ... existing banner code ...
        }
```

- [ ] **Step 4: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 5: Manual smoke test**

```bash
mkdir -p /tmp/macrobo_json_test/src
echo "test" > /tmp/macrobo_json_test/src/file.txt
.build/debug/macrobo /tmp/macrobo_json_test/src /tmp/macrobo_json_test/dst --progress json
rm -rf /tmp/macrobo_json_test
```
Expected: JSON lines printed to stdout (file_start, file_done, summary events)

- [ ] **Step 6: Commit**

```bash
git add Sources/macrobo/ProgressReporter.swift Sources/macrobo/MacroboCommand.swift Sources/macrobo/Models/CopyOptions.swift
git commit -m "feat: add --progress=json for machine-readable progress output"
```

---

### Task 17: Verify Mode

**Files:**
- Modify: `Sources/macrobo/FileOperations.swift`
- Modify: `Sources/macrobo/CopyEngine.swift`
- Modify: `Sources/macrobo/Models/CopyOptions.swift`
- Modify: `Sources/macrobo/MacroboCommand.swift`

- [ ] **Step 1: Add verify option**

In `Models/CopyOptions.swift`, add:

```swift
    var verify: Bool = false  // Re-read and verify checksums after copy
```

- [ ] **Step 2: Add full-file checksum to FileOperations**

In `FileOperations.swift`, add:

```swift
    /// Computes a full SHA256 checksum of the entire file (for verification mode)
    static func fullChecksumFile(at url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }
```

- [ ] **Step 3: Add verification pass to CopyEngine**

In `CopyEngine.swift`, add a method and call it after copying completes:

```swift
    /// Verifies copied files by comparing full SHA256 checksums
    private func verifyFiles(_ copiedFiles: [(source: URL, destination: URL)]) async {
        guard options.verify && !copiedFiles.isEmpty else { return }

        if !options.quiet {
            print("Verifying \(copiedFiles.count) copied files...")
        }

        for (source, destination) in copiedFiles {
            do {
                let srcHash = try FileOperations.fullChecksumFile(at: source)
                let dstHash = try FileOperations.fullChecksumFile(at: destination)
                if srcHash != dstHash {
                    result.record(.failed(
                        path: destination,
                        error: MacroboError.copyFailed(
                            destination.lastPathComponent,
                            NSError(domain: "macrobo", code: 10,
                                    userInfo: [NSLocalizedDescriptionKey: "Verification failed: checksum mismatch"])
                        )
                    ))
                    await logger.error("VERIFY FAILED: \(destination.lastPathComponent)")
                }
            } catch {
                await logger.error("VERIFY ERROR: \(destination.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
```

To track which files were copied, modify `copyFiles` to return the list. Update its signature:

```swift
    private func copyFiles(_ files: [FileInfo]) async -> [(source: URL, destination: URL)] {
        var copiedFiles: [(source: URL, destination: URL)] = []
```

Inside the `for await` loop, capture successful copies:

```swift
                case .copied(let source, let dest, _):
                    await progress.fileCompleted(key: progressKey, displayName: source.lastPathComponent, bytes: bytes)
                    copiedFiles.append((source: source, destination: dest))
```

At the end of the method: `return copiedFiles`

In `run()`, update the call and add verification:

```swift
            let copiedFiles = await copyFiles(filesToCopy)

            // End progress display
            await progress.finish()
            await logger.endProgressDisplay()

            // Verify copied files if requested
            await verifyFiles(copiedFiles)
```

- [ ] **Step 4: Add --verify flag to MacroboCommand**

In `MacroboCommand.swift`, add:

```swift
    @Flag(name: .customLong("verify"),
          help: "Verify copied files by comparing full SHA256 checksums after copy")
    var verify = false
```

In `run()`, add:

```swift
        options.verify = verify
```

- [ ] **Step 5: Add verification test**

Add to `Tests/macroboTests/CopyEngineTests.swift`:

```swift
    func testVerifyMode() async throws {
        // Create a file with known content
        createFile("verified.txt", in: srcDir, content: "verify me please")

        var options = CopyOptions(source: srcDir, destination: dstDir)
        options.verify = true
        let result = try await runCopy(options: options)

        // File should be copied and verified successfully
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.filesFailed, 0)
    }
```

- [ ] **Step 6: Verify build and tests pass**

Run: `./build.sh --debug && swift test`
Expected: Build succeeds, all tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/macrobo/FileOperations.swift Sources/macrobo/CopyEngine.swift Sources/macrobo/Models/CopyOptions.swift Sources/macrobo/MacroboCommand.swift Tests/macroboTests/CopyEngineTests.swift
git commit -m "feat: add --verify flag for post-copy SHA256 verification"
```

---

## Chunk 6: Final Verification

### Task 18: Full Build and Test Verification

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass

- [ ] **Step 2: Build release binary**

Run: `./build.sh`
Expected: `Build complete: macrobo 2.0.XX`

- [ ] **Step 3: Verify help output includes new flags**

Run: `.build/release/macrobo --help`
Expected: Output includes `--bwlimit`, `--config`, `--job`, `--progress`, `--verify` flags

- [ ] **Step 4: Smoke test core functionality**

```bash
mkdir -p /tmp/macrobo_final_test/src/subdir
echo "file1" > /tmp/macrobo_final_test/src/a.txt
echo "file2" > /tmp/macrobo_final_test/src/subdir/b.txt
dd if=/dev/urandom of=/tmp/macrobo_final_test/src/large.bin bs=1M count=20 2>/dev/null

# Basic copy
.build/release/macrobo /tmp/macrobo_final_test/src /tmp/macrobo_final_test/dst

# Mirror (should skip identical files)
.build/release/macrobo /tmp/macrobo_final_test/src /tmp/macrobo_final_test/dst --mirror

# Verify mode
.build/release/macrobo /tmp/macrobo_final_test/src /tmp/macrobo_final_test/dst2 --verify

# JSON progress
.build/release/macrobo /tmp/macrobo_final_test/src /tmp/macrobo_final_test/dst3 --progress json

# Cleanup
rm -rf /tmp/macrobo_final_test
```

- [ ] **Step 5: Commit any final fixes**

If any issues are found, fix and commit them individually.
