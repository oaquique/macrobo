# macrobo v2.0 — Comprehensive Improvements Design

## Overview

A four-phase improvement roadmap for macrobo covering performance, reliability, code quality, and new features. The major version bumps from 1.0 to 2.0 to reflect the scope of changes.

### Version Scheme Change

- **Before:** `1.0.<git commit count>`
- **After:** `2.0.<git commit count>`
- Update `build.sh` to generate `BuildInfo.version = "2.0"` instead of `"1.0"`

---

## Phase 1 — Quick Wins

### 1.1 APFS Clonefile for Same-Volume Copies

When source and destination are on the same APFS volume, use `clonefile()` for instant copy-on-write clones instead of streaming bytes.

**Implementation:**
- Before copying, check if source and destination share the same mount point via `statfs()`
- If same APFS volume, call `clonefile(src, dst, CLONE_NOFOLLOW)`
- Fall back to normal streaming copy if clonefile fails (cross-volume, non-APFS, etc.)
- Skip resume logic entirely for clones — they're atomic

**Location:** `FileOperations.copyFile()` — add a fast path before the streaming logic. CopyEngine doesn't change.

**Impact:** Same-volume copies go from minutes to seconds.

### 1.2 F_NOCACHE for Large Sequential Reads

Streaming copies pollute the OS page cache with data that won't be re-read. For large files on network volumes, this pushes useful cached data out of RAM.

**Implementation:**
- After opening source/destination FileHandles, call `fcntl(fd, F_NOCACHE, 1)`
- Only apply to files above 10MB — small files benefit from caching
- Access file descriptor via `FileHandle.fileDescriptor`

**Location:** `FileOperations.streamingCopy()` — two lines after opening each FileHandle.

**Impact:** Better system memory behavior during large copies; slight throughput improvement on NAS.

### 1.3 Deduplicate formatBytes

`formatBytes` is implemented 3 times with minor variations across `CopyEngine`, `Logger`, and `CopyResult`.

**Implementation:**
- Extract to a free function in a new `Formatting.swift`
- Signature: `func formatBytes(_ bytes: UInt64, precision: Int = 2) -> String`
- Replace all three call sites

---

## Phase 2 — Reliability & Correctness

### 2.1 Test Suite

macrobo has zero automated tests. Bugs have been caught through manual testing and code audits.

**Structure:**
- Add `Tests/macroboTests/` target to `Package.swift`
- **Unit tests:** `checksumFile`, `areFilesIdentical`, `areFileContentsIdentical`, `copyAttributes`, extended attributes, `deleteFile` retry, all formatting functions, `parseSize`
- **Integration tests:** Create temp directories with known file trees, run copy operations, verify results. Cover: basic copy, mirror/purge, resume from partial, checksum skip, exclude/include patterns, size filtering, symlink cycle detection
- **Edge cases:** Unicode filenames, empty files (0 bytes), very long paths, files that disappear mid-copy, read-only destinations

**Not tested:** ProgressReporter ANSI rendering (fragile, low value). Logger file writing (simple wrapper).

### 2.2 Streaming/Lazy File Enumeration

Currently `enumerateSourceFilesSync()` loads all candidate files into a `[FileInfo]` array before copying begins. For directories with millions of files, this delays copy start and consumes memory.

**Implementation:**
- `gatherSourceFiles()` returns `AsyncStream<FileInfo>` instead of `[FileInfo]`
- A producer task runs `FileManager.enumerator`, yielding files into the stream
- `copyFiles()` consumes the stream, feeding its task group
- Total counts become estimates until enumeration completes (prefix with `~`)
- Checksum filtering integrates into the stream pipeline rather than being a separate loop

**Trade-off:** Progress display shows approximate totals during enumeration (e.g., `[3/~1,204]`). Same approach as rsync/rclone.

### 2.3 Edge Case Fixes

**a) Relative path fallback (CopyEngine:344):**
When the standardized URL path doesn't share the expected source prefix, the fallback uses just the filename — losing directory structure and risking file collisions. Fix: normalize both paths through `realpath()` before comparing. Log a warning when the fallback triggers.

**b) gatherFilesToPurge nonisolated safety (CopyEngine:510):**
Marked `nonisolated` but reads actor properties. Safe today because they're `let`, but fragile. Fix: pass needed values as explicit parameters.

**c) Terminal width caching:**
Both `ProgressReporter` and `Logger` cache terminal width at init and never update. Fix: query `ioctl(TIOCGWINSZ)` on each display refresh (or on `SIGWINCH`).

---

## Phase 3 — Code Quality & Maintainability

### 3.1 Split CopyEngine.swift

CopyEngine (564 lines) handles four distinct responsibilities. Extract enumeration into a dedicated `FileEnumerator`:

- `FileEnumerator.enumerate(source:options:) -> [FileInfo]` (or `AsyncStream` after Phase 2.2)
- Contains `enumerateSourceFilesSync`, `compileGlobPattern`, `matches`, symlink cycle detection
- CopyEngine drops to ~250 lines focused on orchestration and retry

### 3.2 Extract Shared Formatting Utilities

Create `Formatting.swift` (~80 lines) containing:

- `formatBytes(_:precision:)` — replaces 3 implementations
- `formatDuration(_:compact:)` — unifies `CopyResult.formatDuration()` and `ProgressReporter.formatTime()`
- `truncate(_:maxWidth:ellipsis:pad:)` — replaces `Logger.truncate()`, `Logger.truncatePath()`, `ProgressReporter.truncateOrPad()`
- `Terminal.width` — static computed property replacing duplicated `ioctl` calls in Logger and ProgressReporter

### 3.3 Make CopyResult Mutation Consistent

`purgeExtraFiles()` directly mutates `result.filesDeleted += 1` and `result.directoriesDeleted += 1` instead of going through `record()`. Fix: add `FileOperationResult` coverage for directory deletion, or add dedicated `recordDeletion()` / `recordDirectoryDeletion()` methods so all mutations go through one path.

### 3.4 Reduce FileManager.default Calls

Capture `FileManager.default` once per function scope instead of calling it repeatedly. Minor style improvement, not a priority.

---

## Phase 4 — Features

### 4.1 Bandwidth Limiting

`--bwlimit <rate>` caps total copy throughput (e.g., `--bwlimit 50M` for 50 MB/s).

**Implementation:**
- Token-bucket rate limiter actor
- Each chunk write requests tokens before proceeding
- Limiter tracks bytes across all threads, introduces `Task.sleep` delays when rate exceeds target
- Integrates into `streamingCopy()` after each chunk write
- Value of `0` means unlimited (default)
- Reuses existing `parseSize()` for parsing the rate value

### 4.2 Config File Support

Save and reuse configurations for repeated sync jobs.

**Format:**
```
# ~/.config/macrobo/photos-backup.conf
source: ~/Photos
destination: /Volumes/NAS/Photos
mirror: true
threads: 4
exclude-dirs: .Trash Thumbnails
exclude-files: *.tmp .DS_Store
bwlimit: 30M
```

**Invocation:** `macrobo --job <name>` or `macrobo --config <path>`

**Rules:**
- CLI flags override config file values
- Search order: explicit `--config` path, then `~/.config/macrobo/<name>.conf`
- No new dependencies — parse flat `key: value` format manually

### 4.3 Progress Output Modes

`--progress=none|bar|json`

- `bar` (default): current multi-line braille display
- `none`: equivalent to `--quiet`
- `json`: newline-delimited JSON events for programmatic consumption:
  ```json
  {"event":"file_start","path":"/src/a.txt","size":1048576}
  {"event":"file_done","path":"/src/a.txt","bytes":1048576,"speed":52428800,"duration":0.02}
  {"event":"summary","copied":150,"failed":0,"bytes":1073741824,"duration":12.3}
  ```

**Location:** `ProgressReporter` gets a `mode` enum. In JSON mode, writes NDJSON to stdout instead of ANSI escape codes.

### 4.4 Verify Mode

`--verify` re-reads destination files after copy and compares full SHA256 checksums against source.

**Implementation:**
- After all copies complete, run a verification pass over copied files
- Compute full SHA256 (not the 3-sample lightweight checksum) of both source and destination
- Report mismatches as errors
- Can combine with `--checksum` (lightweight scan, full verification post-copy)

**Trade-off:** Doubles I/O for the copy operation. Opt-in only.

---

## Phase Ordering and Dependencies

```
Phase 1 (Quick Wins) ──→ Phase 2 (Reliability) ──→ Phase 3 (Code Quality) ──→ Phase 4 (Features)
                              │
                              └── 2.1 Test Suite should land before Phase 3 refactoring
                                  2.2 Streaming enum is independent of tests
```

- Phase 1 items are independent of each other
- Phase 2.1 (tests) should land before Phase 3 refactoring to provide a safety net
- Phase 2.2 (streaming enum) affects Phase 3.1 (CopyEngine split) — if both land, FileEnumerator uses AsyncStream
- Phase 4 items are independent of each other and can be prioritized individually
- Version bump (`1.0` → `2.0`) happens in Phase 1 alongside the first changes

## Files Changed

| File | Changes |
|------|---------|
| `build.sh` | Version `1.0` → `2.0` |
| `Sources/macrobo/Formatting.swift` | **New** — shared formatting utilities |
| `Sources/macrobo/FileEnumerator.swift` | **New** — extracted from CopyEngine |
| `Sources/macrobo/FileOperations.swift` | APFS clonefile fast path, F_NOCACHE, verify mode |
| `Sources/macrobo/CopyEngine.swift` | Streaming enum, edge case fixes, extract enumeration |
| `Sources/macrobo/ProgressReporter.swift` | Terminal width refresh, JSON mode, approximate totals |
| `Sources/macrobo/Logger.swift` | Use shared formatting, terminal width from utility |
| `Sources/macrobo/MacroboCommand.swift` | New flags: `--bwlimit`, `--job`/`--config`, `--progress`, `--verify` |
| `Sources/macrobo/Models/CopyOptions.swift` | New option fields for added features |
| `Sources/macrobo/Models/CopyResult.swift` | Use shared formatting, consistent mutation |
| `Package.swift` | Add test target |
| `Tests/macroboTests/` | **New** — test suite |
