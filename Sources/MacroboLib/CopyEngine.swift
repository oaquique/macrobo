import Foundation

/// One file or folder at the destination that isn't in the source, with everything under it
struct ExtraItem: Sendable {
    let url: URL
    /// Relative path from the destination root ("/a/b")
    let relativePath: String
    let isDirectory: Bool
    /// Files inside (folders only), relative paths, for counting and logging
    var innerFiles: [String] = []
    /// Folders inside (folders only), relative paths, deepest first
    var innerFolders: [String] = []

    var fileCount: Int { isDirectory ? innerFiles.count : 1 }
    var folderCount: Int { isDirectory ? innerFolders.count + 1 : 0 }
}

/// Collects extras found by the destination walk's worker threads
private final class ExtraCollector: @unchecked Sendable {
    private let lock = NSLock()
    /// Extra items whose parent is kept, by relative path
    private(set) var tops: [String: ExtraItem] = [:]
    /// Everything inside an extra folder, with the extra folder it belongs to
    private(set) var inner: [(top: String, path: String, isDir: Bool)] = []

    func add(tops newTops: [ExtraItem], inner newInner: [(top: String, path: String, isDir: Bool)]) {
        lock.lock(); defer { lock.unlock() }
        for item in newTops { tops[item.relativePath] = item }
        inner.append(contentsOf: newInner)
    }
}

/// Core copy engine with multi-threaded file operations
public actor CopyEngine {
    private let options: CopyOptions
    private let logger: Logger
    private let progress: ProgressReporter
    private let rateLimiter: RateLimiter?
    private var result = CopyResult()
    private let resolvedSourcePath: String
    private let resolvedDestPath: String
    /// Leftover partial files a dry run would remove (relative paths), so the destination
    /// check doesn't list them a second time as extras
    private var dryRunLeftovers: [String] = []

    /// Concurrent directory listings and metadata lookups (network round trips)
    private static let walkWorkers = 16
    /// Concurrent checksums. Sampled checks are bound by network round trips: measured on an
    /// SMB share, 16 at a time ran 2.4x faster than 4, and 32 barely faster than 16.
    private static let checksumWorkers = 16

    public init(options: CopyOptions, logger: Logger, progress: ProgressReporter) {
        self.options = options
        self.logger = logger
        self.progress = progress
        self.rateLimiter = options.bandwidthLimit > 0 ? RateLimiter(bytesPerSecond: options.bandwidthLimit) : nil
        // Read the umask now, before any copy threads start
        _ = FileOperations.defaultFileMode
        // Resolve symlinks using realpath for consistent path handling
        self.resolvedSourcePath = Self.realPath(options.source.path) ?? options.source.path
        // For destination, resolve the parent directory (which should exist) and append the name
        let destParent = options.destination.deletingLastPathComponent().path
        let resolvedParent = Self.realPath(destParent) ?? destParent
        self.resolvedDestPath = (resolvedParent as NSString).appendingPathComponent(options.destination.lastPathComponent)
    }

    /// Resolves a path to its real path, following all symlinks
    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// --purge on its own deletes extras without copying; --mirror copies and deletes
    private var copies: Bool { options.mirror || !options.purge }
    private var deletes: Bool { (options.mirror || options.purge) && !options.excludeExtra }
    private var deleteVerb: String { options.mirror ? "mirroring" : "purging" }

    /// Runs the copy operation
    public func run() async throws -> CopyResult {
        try options.validate()

        // Open logger - ensure it's always closed, even on error
        try await logger.open()

        do {
            await logger.info("Source: \(options.source.path)")
            await logger.info("Destination: \(options.destination.path)")
            if options.mirror {
                await logger.info("Mode: Mirror (copy + purge)")
            } else if options.purge {
                await logger.info("Mode: Delete extras only (nothing is copied)")
            }
            if options.dryRun {
                await logger.info("Dry run: nothing will be changed.")
            }
            await logger.info("")

            result.isDryRun = options.dryRun
            result.showsCopies = copies
            result.showsDeletes = deletes

            try ensureDestinationExists()

            let source = try await listSource()
            if deletes {
                try guardEmptySource(source)
            }

            if copies {
                let toCopy = await compare(source.files)
                if options.includeEmptyDirectories {
                    await createMissingFolders(source, copying: toCopy)
                }
                let unchanged = source.files.count - toCopy.count
                if options.dryRun {
                    await listWouldCopy(toCopy, unchanged: unchanged)
                } else if !toCopy.isEmpty {
                    // Nothing to copy needs no copy block: "Compared ... 0 to copy" already says so
                    result.filesSkipped += unchanged
                    let copiedPairs = await copyPhase(toCopy)
                    if options.verify && !copiedPairs.isEmpty {
                        await verifyFiles(copiedPairs)
                    }
                    if options.moveAll {
                        await removeEmptySourceFolders(source)
                    }
                } else {
                    result.filesSkipped += unchanged
                }
            }

            if deletes {
                let extras = await checkDestination(source)
                try guardMassDelete(extras)
                if options.dryRun {
                    await listWouldDelete(extras.items)
                } else if !extras.items.isEmpty {
                    // "Checked destination ... 0 extra" already says there is nothing to delete
                    await deleteExtras(extras.items)
                }
            }

            result.finish()
            await logger.logSummary(result)
            await logger.close()
            return result
        } catch {
            await logger.close()
            throw error
        }
    }

    // MARK: - Destination

    /// Ensures the destination directory exists and can be opened
    private func ensureDestinationExists() throws {
        let path = options.destination.path
        switch VolumeInfo.directoryProblem(at: path) {
        case nil:
            return
        case .notDirectory:
            throw MacroboError.cannotOpen(role: "destination", path: path, reason: "Not a directory", networkType: nil)
        case .unreadable(let reason):
            throw MacroboError.cannotOpen(
                role: "destination", path: path, reason: reason,
                networkType: VolumeInfo.networkFileSystemType(of: path)
            )
        case .missing:
            if options.dryRun { return }
            do {
                try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
                result.record(.directoryCreated(path: options.destination))
            } catch {
                throw MacroboError.cannotCreateDestination(path: path, reason: Self.reason(for: error))
            }
        }
    }

    /// The system's short reason for a file error ("Permission denied"), not Foundation's sentence
    private static func reason(for error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        if ns.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(ns.code)))
        }
        return ns.localizedDescription
    }

    // MARK: - Steps

    /// Starts the live line of a step; `detail` is read 10 times a second from worker counters
    private func startStep(
        id: String, name: String,
        _ detail: @escaping @Sendable () -> (String, [String: Int])
    ) -> Task<Void, Never> {
        let progress = self.progress
        return Task.detached {
            while !Task.isCancelled {
                let (text, counts) = detail()
                await progress.stepRunning(id: id, name: name, detail: text, counts: counts)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Stops the live line and prints the finished step on screen and in the log
    private func finishStep(
        _ ticker: Task<Void, Never>, id: String, name: String, detail: String,
        counts: [String: Int], since start: Date
    ) async {
        ticker.cancel()
        await ticker.value
        let seconds = Date().timeIntervalSince(start)
        await progress.stepDone(id: id, name: name, detail: detail, seconds: seconds, counts: counts)
        await logger.writeLogOnly(formatStepLine(mark: "", name: name, detail: detail, seconds: seconds))
    }

    // MARK: - Listing the source

    private func listSource() async throws -> SourceEnumeration {
        let counts = LiveCounts(slots: 2)
        let start = Date()
        let ticker = startStep(id: "list_source", name: "Listing source") {
            let c = counts.all
            return ("\(formatCount(c[0], "file")), \(formatCount(c[1], "folder"))", ["files": c[0], "folders": c[1]])
        }

        let sourceURL = options.source
        let skipHidden = options.skipHidden
        let excludeDirs = options.excludeDirectories
        let excludeFiles = options.excludeFiles
        let includeFiles = options.includeFiles
        let minSize = options.minFileSize
        let maxSize = options.maxFileSize
        let workers = Self.walkWorkers
        let listing: Result<SourceEnumeration, Error> = await runOnThread {
            Result {
                try FileEnumerator.enumerateSource(
                    source: sourceURL, skipHidden: skipHidden, excludeDirs: excludeDirs,
                    excludeFiles: excludeFiles, includeFiles: includeFiles,
                    minSize: minSize, maxSize: maxSize, counts: counts, workers: workers
                )
            }
        }

        let enumeration: SourceEnumeration
        switch listing {
        case .success(let value):
            enumeration = value
        case .failure(let error):
            ticker.cancel()
            await ticker.value
            throw MacroboError.cannotOpen(
                role: "source", path: options.source.path, reason: Self.reason(for: error),
                networkType: VolumeInfo.networkFileSystemType(of: options.source.path)
            )
        }

        let files = enumeration.files.count
        let folders = enumeration.directoryRelativePaths.count
        await finishStep(
            ticker, id: "list_source", name: "Listed source",
            detail: "\(formatCount(files, "file")), \(formatCount(folders, "folder"))",
            counts: ["files": files, "folders": folders], since: start
        )
        for dir in enumeration.unreadableDirectories {
            await logger.warning("Couldn't read \(options.source.path)\(dir.relativePath): \(dir.reason). Its files were skipped, and nothing under it will be deleted.")
        }
        return enumeration
    }

    // MARK: - Comparing

    /// Decides which source files need copying: a parallel metadata compare, then content
    /// checksums for same-size files when --checksum is on.
    private func compare(_ candidates: [FileInfo]) async -> [FileInfo] {
        let settings = CompareSettings(
            includeSame: options.includeSame,
            checksum: options.checksum || options.checksumFull,
            excludeOlder: options.excludeOlder
        )
        let total = candidates.count
        let counter = ScanCounter()
        let start = Date()
        let ticker = startStep(id: "compare", name: "Comparing") {
            let s = counter.snapshot
            var text = "\(formatCount(s.completed)) of \(formatCount(total, "file")), \(formatCount(s.toCopy)) to copy"
            if let left = formatTimeLeft(elapsed: Date().timeIntervalSince(start), done: Double(s.completed), total: Double(total)) {
                text += ", \(left)"
            }
            return (text, ["checked": s.completed, "total": total, "to_copy": s.toCopy])
        }
        let leftovers = PathCollector()
        let verdicts = await DestinationComparator.compareAll(
            candidates,
            destinationBase: options.destination.path,
            settings: settings,
            counter: counter,
            leftovers: leftovers
        )

        var toCopy: [FileInfo] = []
        var toChecksum: [(file: FileInfo, skipIfDifferent: Bool)] = []
        for (file, verdict) in zip(candidates, verdicts) {
            switch verdict {
            case .skip: continue
            case .copy: toCopy.append(file)
            case .checksum(let skipIfDifferent): toChecksum.append((file, skipIfDifferent))
            }
        }
        var detail = "\(formatCount(total, "file")), \(formatCount(toCopy.count)) to copy"
        if !toChecksum.isEmpty {
            detail += ", \(formatCount(toChecksum.count)) to checksum"
        }
        await finishStep(
            ticker, id: "compare", name: "Compared", detail: detail,
            counts: ["checked": total, "to_copy": toCopy.count, "to_checksum": toChecksum.count], since: start
        )

        if !toChecksum.isEmpty {
            toCopy += await checksumPass(toChecksum, leftovers: leftovers)
            // Keep the copy order stable (source order)
            toCopy.sort { $0.relativePath < $1.relativePath }
        }
        await removeLeftoverPartials(leftovers.paths.sorted())
        return toCopy
    }

    /// Removes partial files left by interrupted copies of files now complete at the
    /// destination. A file that is copied again replaces its own partial file instead.
    private func removeLeftoverPartials(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let root = options.destination.path
        if options.dryRun {
            for path in paths {
                let relative = String(path.dropFirst(root.count + 1))
                await progress.wouldChange("delete", path: relative)
                await logger.writeLogOnly("  WOULD DELETE: \(relative) (leftover partial file)")
            }
            result.wouldRemoveLeftovers = paths.count
            dryRunLeftovers = paths.map { String($0.dropFirst(root.count)) }
            return
        }

        let counts = LiveCounts(slots: 1)
        let start = Date()
        let ticker = startStep(id: "remove_leftovers", name: "Removing leftovers") {
            let done = counts.get(0)
            return ("\(formatCount(done)) of \(formatCount(paths.count, "partial file"))", ["removed": done, "total": paths.count])
        }
        let failures = ResultSlots<String>(count: paths.count)
        await runOnThread {
            parallelForEach(count: paths.count, workers: Self.walkWorkers) { i in
                do {
                    try FileManager.default.removeItem(atPath: paths[i])
                    counts.add(0)
                } catch {
                    if (error as NSError).code == NSFileNoSuchFileError { counts.add(0); return }
                    failures[i] = Self.reason(for: error)
                }
            }
        }
        var removed = 0
        for (i, reason) in failures.all.enumerated() {
            if let reason {
                await logger.warning("Couldn't remove the leftover partial file \(paths[i]): \(reason)")
            } else {
                removed += 1
                await logger.writeLogOnly("  DELETE: \(paths[i]) (leftover partial file)")
            }
        }
        var detail = "\(formatCount(removed, "partial file")) from interrupted copies"
        if removed < paths.count { detail += ", \(formatCount(paths.count - removed)) failed" }
        await finishStep(
            ticker, id: "remove_leftovers", name: "Removed leftovers", detail: detail,
            counts: ["removed": removed, "failed": paths.count - removed], since: start
        )
    }

    /// Compares contents of same-size files on several threads (samples, or every byte with
    /// --checksum-full). Returns the files whose contents changed.
    private func checksumPass(_ items: [(file: FileInfo, skipIfDifferent: Bool)], leftovers: PathCollector) async -> [FileInfo] {
        let total = items.count
        let totalBytes = items.reduce(0) { $0 + Int($1.file.size) }
        let counts = LiveCounts(slots: 3) // checked, changed, bytes checked
        let start = Date()
        let ticker = startStep(id: "checksum", name: "Checksumming") {
            let c = counts.all
            var text = "\(formatCount(c[0])) of \(formatCount(total, "file")), \(formatCount(c[1])) changed"
            // Estimated from bytes, since file sizes vary widely
            if let left = formatTimeLeft(elapsed: Date().timeIntervalSince(start), done: Double(c[2]), total: Double(totalBytes)) {
                text += ", \(left)"
            }
            return (text, ["checked": c[0], "total": total, "changed": c[1]])
        }

        // Once contents are proven identical, give the destination the source's modification
        // time, so later runs match on size and time and don't checksum the file again
        let stampTimes = options.keepsTimestamps && !options.dryRun
        let destBase = options.destination.path
        let changed = ResultSlots<Bool>(count: total)
        let full = options.checksumFull
        await runOnThread {
            parallelForEach(count: total, workers: Self.checksumWorkers) { i in
                let item = items[i]
                let destURL = URL(fileURLWithPath: destBase + item.file.relativePath)
                let identical = FileOperations.areFileContentsIdentical(
                    source: item.file.url, destination: destURL, sourceSize: item.file.size, full: full
                )
                if identical, stampTimes, let sourceDate = item.file.modificationDate {
                    try? FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: destURL.path)
                }
                if identical, let partial = FileOperations.leftoverPartial(forDestination: destURL.path) {
                    leftovers.add(partial)
                }
                let copy = !identical && !item.skipIfDifferent
                changed[i] = copy
                counts.add(0)
                counts.add(2, Int(item.file.size))
                if copy { counts.add(1) }
            }
        }

        let flags = changed.all
        let result = items.indices.filter { flags[$0] == true }.map { items[$0].file }
        await finishStep(
            ticker, id: "checksum", name: "Checksummed",
            detail: "\(formatCount(total, "file")), \(formatCount(result.count)) changed",
            counts: ["checked": total, "changed": result.count], since: start
        )
        return result
    }

    // MARK: - Copying

    /// Creates source folders missing at the destination that no copied file will create, so
    /// empty folders are copied too (a copied file creates its own folders). Checks run in
    /// parallel: each is a network round trip on NFS/SMB.
    private func createMissingFolders(_ source: SourceEnumeration, copying toCopy: [FileInfo]) async {
        // Every folder some copied file sits in, at any depth
        var createdByCopies = Set<String>()
        for file in toCopy {
            var path = (file.relativePath as NSString).deletingLastPathComponent
            while path.count > 1, createdByCopies.insert(path).inserted {
                path = (path as NSString).deletingLastPathComponent
            }
        }
        let folders = source.directoryRelativePaths.subtracting(createdByCopies).sorted()
        guard !folders.isEmpty else { return }
        let destBase = options.destination.path
        let dryRun = options.dryRun
        let missing = ResultSlots<Bool>(count: folders.count)
        let created = ResultSlots<Bool>(count: folders.count)
        await runOnThread {
            parallelForEach(count: folders.count, workers: Self.walkWorkers) { i in
                let path = destBase + folders[i]
                var isDir: ObjCBool = false
                guard !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
                missing[i] = true
                if !dryRun {
                    created[i] = (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil
                }
            }
        }
        let missingFlags = missing.all
        let createdFlags = created.all
        for (i, folder) in folders.enumerated() where missingFlags[i] == true {
            if dryRun {
                let path = String(folder.dropFirst())
                await progress.wouldChange("copy", path: path, folder: true)
                await logger.writeLogOnly("  WOULD COPY: \(path)/ (folder)")
                result.wouldCopyFolders += 1
            } else if createdFlags[i] == true {
                let url = URL(fileURLWithPath: destBase + folder)
                result.record(.directoryCreated(path: url))
                await logger.logOperation(.directoryCreated(path: url))
            }
        }
    }

    /// --move-all: after moving the files, removes source folders left empty, deepest first.
    /// A folder that still holds anything (a skipped or failed file) stays.
    private func removeEmptySourceFolders(_ source: SourceEnumeration) async {
        let root = options.source.path
        let byDepth = Dictionary(grouping: source.directoryRelativePaths) { $0.filter { $0 == "/" }.count }
        let removed = ResultSlots<Bool>(count: source.directoryRelativePaths.count)
        var order: [String] = []
        for depth in byDepth.keys.sorted(by: >) {
            let level = byDepth[depth]!.sorted()
            let offset = order.count
            order += level
            await runOnThread {
                parallelForEach(count: level.count, workers: Self.walkWorkers) { i in
                    removed[offset + i] = rmdir(root + level[i]) == 0
                }
            }
        }
        let flags = removed.all
        for (i, folder) in order.enumerated() where flags[i] == true {
            await logger.writeLogOnly("  RMDIR: \(root + folder)")
        }
    }

    private func listWouldCopy(_ files: [FileInfo], unchanged: Int) async {
        for file in files {
            let path = String(file.relativePath.dropFirst())
            await progress.wouldChange("copy", path: path, bytes: file.size)
            await logger.writeLogOnly("  WOULD COPY: \(path) (\(formatBytes(file.size)))")
        }
        result.wouldCopyFiles = files.count
        result.wouldCopyBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        result.unchangedFiles = unchanged
    }

    private func copyPhase(_ filesToCopy: [FileInfo]) async -> [(source: URL, destination: URL)] {
        let totalBytes = filesToCopy.reduce(UInt64(0)) { $0 + $1.size }
        await progress.line("")
        await progress.line("Copying \(formatCount(filesToCopy.count, "file")) (\(formatBytes(totalBytes, precision: 1)))...")

        await progress.setTotals(files: filesToCopy.count, bytes: totalBytes)
        await logger.setTotalFiles(filesToCopy.count)

        // Begin progress display phase - suppress inline errors
        await logger.beginProgressDisplay()
        let copiedPairs = await copyFiles(filesToCopy)
        // The summary's speed uses the copy line's own time, so the two always agree
        result.copyDuration = await progress.finish()
        // Flush any buffered errors
        await logger.endProgressDisplay()
        return copiedPairs
    }

    /// Copies files using a thread pool, returns list of successfully copied source/destination pairs
    private func copyFiles(_ files: [FileInfo]) async -> [(source: URL, destination: URL)] {
        var copiedPairs: [(source: URL, destination: URL)] = []
        await withTaskGroup(of: (FileOperationResult, String).self) { group in
            var pendingFiles = files[...]
            var activeTasks = 0

            // Start initial batch
            while activeTasks < options.threadCount && !pendingFiles.isEmpty {
                let fileInfo = pendingFiles.removeFirst()
                activeTasks += 1
                group.addTask {
                    let result = await self.copyFile(fileInfo)
                    return (result, fileInfo.relativePath)
                }
            }

            // Process results and add more tasks
            for await (opResult, progressKey) in group {
                result.record(opResult)
                await logger.logOperation(opResult)

                // Update progress for both successful and failed files
                switch opResult {
                case .copied(let source, let dest, let bytes):
                    copiedPairs.append((source: source, destination: dest))
                    await progress.fileCompleted(key: progressKey, displayName: source.lastPathComponent, bytes: bytes)
                case .failed:
                    await progress.fileFailed(key: progressKey)
                case .skipped:
                    await progress.fileFailed(key: progressKey)
                default:
                    break
                }

                // Add next file if available
                if !pendingFiles.isEmpty {
                    let fileInfo = pendingFiles.removeFirst()
                    group.addTask {
                        let result = await self.copyFile(fileInfo)
                        return (result, fileInfo.relativePath)
                    }
                }
            }
        }
        return copiedPairs
    }

    /// Copies a single file with retry support
    private func copyFile(_ fileInfo: FileInfo) async -> FileOperationResult {
        let source = fileInfo.url
        let fileSize = fileInfo.size
        // Use the pre-computed relative path for destination
        let destPath = options.destination.path + fileInfo.relativePath
        let destURL = URL(fileURLWithPath: destPath)

        // Dry run
        if options.dryRun {
            return .skipped(source: source, reason: .dryRun, bytes: fileSize)
        }

        // Create parent directory if needed
        let parentDir = destURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir.path) {
            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                result.record(.directoryCreated(path: parentDir))
            } catch {
                return .failed(path: source, error: error)
            }
        }

        // Notify progress that we're starting this file (use captured size)
        // Use relativePath as unique key to avoid collisions between same-named files in different directories
        let progressKey = fileInfo.relativePath
        await progress.fileStarted(key: progressKey, displayName: source.lastPathComponent, bytes: fileSize)

        // Copy with retry
        var lastError: Error?
        let totalAttempts = 1 + options.retryCount  // 1 initial + N retries
        for attempt in 0..<max(1, totalAttempts) {
            do {
                let bytes = try await FileOperations.copyFile(
                    from: source,
                    to: destURL,
                    options: options,
                    rateLimiter: rateLimiter,
                    progressHandler: { current, total in
                        await self.progress.bytesProgress(current: current, total: total, key: progressKey)
                        await self.logger.logFileProgress(fileName: source.lastPathComponent, currentBytes: current, totalBytes: total)
                    },
                    syncHandler: {
                        await self.progress.fileSyncing(key: progressKey)
                    }
                )

                // Move mode - delete source after successful copy
                if options.moveFiles || options.moveAll {
                    try await FileOperations.deleteFile(at: source)
                }

                return .copied(source: source, destination: destURL, bytes: bytes)
            } catch {
                lastError = error
                if attempt < totalAttempts - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(options.retryWaitSeconds) * 1_000_000_000)
                }
            }
        }

        // Clean up orphaned partial file after all retries exhausted
        let partialPath = destURL.path + FileOperations.partialSuffix
        if FileManager.default.fileExists(atPath: partialPath) {
            try? FileManager.default.removeItem(atPath: partialPath)
        }

        return .failed(path: source, error: lastError ?? MacroboError.copyFailed(source.path, NSError(domain: "macrobo", code: 99)))
    }

    // MARK: - Verifying

    /// Verifies copied files by comparing full SHA256 checksums, on --threads threads
    private func verifyFiles(_ pairs: [(source: URL, destination: URL)]) async {
        let total = pairs.count
        let counts = LiveCounts(slots: 2) // checked, failed
        let start = Date()
        let ticker = startStep(id: "verify", name: "Verifying") {
            let c = counts.all
            var text = "\(formatCount(c[0])) of \(formatCount(total, "file"))"
            if let left = formatTimeLeft(elapsed: Date().timeIntervalSince(start), done: Double(c[0]), total: Double(total)) {
                text += ", \(left)"
            }
            return (text, ["checked": c[0], "total": total, "failed": c[1]])
        }

        let work = pairs.map { (source: $0.source, destination: $0.destination) }
        let outcomes = ResultSlots<String>(count: total) // nil = OK, else the failure message
        let threads = options.threadCount
        await runOnThread {
            parallelForEach(count: total, workers: threads) { i in
                let pair = work[i]
                do {
                    let srcHash = try FileOperations.fullChecksumFile(at: pair.source)
                    let dstHash = try FileOperations.fullChecksumFile(at: pair.destination)
                    if srcHash != dstHash {
                        outcomes[i] = "Verification failed: checksum mismatch"
                        counts.add(1)
                    }
                } catch {
                    outcomes[i] = "Verification error: \(error.localizedDescription)"
                    counts.add(1)
                }
                counts.add(0)
            }
        }

        var failed = 0
        for (i, message) in outcomes.all.enumerated() {
            guard let message else { continue }
            failed += 1
            let destination = pairs[i].destination
            result.record(.failed(path: destination, error: MacroboError.copyFailed(
                destination.lastPathComponent,
                NSError(domain: "macrobo", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
            )))
            await logger.warning("\(message): \(destination.path)")
        }

        let detail = failed == 0
            ? "\(formatCount(total, "file")) OK"
            : "\(formatCount(total - failed, "file")) OK, \(formatCount(failed)) failed"
        await finishStep(
            ticker, id: "verify", name: "Verified", detail: detail,
            counts: ["checked": total, "failed": failed], since: start
        )
    }

    // MARK: - Checking the destination for extras

    /// What the destination walk found
    struct DestinationCheck: Sendable {
        var items: [ExtraItem]
        /// Every file and folder seen at the destination
        var totalItems: Int
        var extraFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
        var extraFolders: Int { items.reduce(0) { $0 + $1.folderCount } }
        var extraItems: Int { extraFiles + extraFolders }
    }

    /// Walks the destination on several threads and collects what isn't in the source.
    /// Everything under an extra folder is counted, so deletion totals are complete.
    private func checkDestination(_ source: SourceEnumeration) async -> DestinationCheck {
        var known = source.directoryRelativePaths
        for file in source.files { known.insert(file.relativePath) }
        known.formUnion(dryRunLeftovers)
        let knownPaths = known
        let unreadablePrefixes = source.unreadableDirectories.map { $0.relativePath + "/" }
        let sourceRoot = resolvedSourcePath
        let destination = options.destination

        let counts = LiveCounts(slots: 2) // items seen, extra items
        let start = Date()
        let ticker = startStep(id: "check_destination", name: "Checking destination") {
            let c = counts.all
            return ("\(formatCount(c[0], "item")), \(formatCount(c[1])) extra", ["items": c[0], "extra": c[1]])
        }

        // A folder's context: the extra folder it sits in, if any
        typealias Context = String?
        let found = ExtraCollector()

        let walked: Bool = await runOnThread {
            do {
                try ParallelWalker.walk(
                    root: destination,
                    rootContext: nil as Context,
                    keys: [.isDirectoryKey, .isRegularFileKey],
                    skipHidden: false,
                    workers: Self.walkWorkers,
                    visit: { dir, entries in
                        var subdirs: [ParallelWalker.Directory<Context>] = []
                        var newTops: [ExtraItem] = []
                        var newInner: [(top: String, path: String, isDir: Bool)] = []
                        var extra = 0
                        for entry in entries {
                            let isDir = entry.isDirectory
                            if let top = dir.context {
                                // Inside an extra folder: all of it goes
                                newInner.append((top, entry.relativePath, isDir))
                                extra += 1
                                if isDir { subdirs.append(.init(url: entry.url, relativePath: entry.relativePath, context: top)) }
                                continue
                            }
                            // Symlinks and other special files at the top of an extra were never
                            // copied by macrobo, so they are left alone
                            guard isDir || entry.isRegularFile else { continue }
                            if knownPaths.contains(entry.relativePath)
                                || unreadablePrefixes.contains(where: { entry.relativePath.hasPrefix($0) || entry.relativePath + "/" == $0 })
                                || FileManager.default.fileExists(atPath: sourceRoot + entry.relativePath) {
                                if isDir { subdirs.append(.init(url: entry.url, relativePath: entry.relativePath, context: nil)) }
                                continue
                            }
                            newTops.append(ExtraItem(url: entry.url, relativePath: entry.relativePath, isDirectory: isDir))
                            extra += 1
                            if isDir { subdirs.append(.init(url: entry.url, relativePath: entry.relativePath, context: entry.relativePath)) }
                        }
                        found.add(tops: newTops, inner: newInner)
                        counts.add(0, entries.count)
                        counts.add(1, extra)
                        return subdirs
                    }
                )
                return true
            } catch {
                return false // destination missing (dry run into a new folder): nothing extra
            }
        }

        var tops = found.tops
        for entry in found.inner {
            if entry.isDir {
                tops[entry.top]?.innerFolders.append(entry.path)
            } else {
                tops[entry.top]?.innerFiles.append(entry.path)
            }
        }
        var items = tops.values.sorted { $0.relativePath < $1.relativePath }
        for i in items.indices {
            items[i].innerFiles.sort()
            // Deepest first, so a folder is logged after everything in it
            items[i].innerFolders.sort { a, b in
                let depthA = a.filter { $0 == "/" }.count
                let depthB = b.filter { $0 == "/" }.count
                return depthA != depthB ? depthA > depthB : a < b
            }
        }
        let check = DestinationCheck(items: walked ? items : [], totalItems: walked ? counts.get(0) : 0)

        await finishStep(
            ticker, id: "check_destination", name: "Checked destination",
            detail: "\(formatCount(check.totalItems, "item")), \(formatCount(check.extraItems)) extra",
            counts: ["items": check.totalItems, "extra": check.extraItems], since: start
        )
        return check
    }

    // MARK: - Guards against wiping the destination

    /// An empty source would make a mirror or purge delete everything at the destination
    private func guardEmptySource(_ source: SourceEnumeration) throws {
        guard !options.allowMassDelete, source.files.isEmpty, source.directoryRelativePaths.isEmpty else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: options.destination.path)) ?? []
        guard !entries.isEmpty else { return }
        throw MacroboError.massDeleteBlocked(
            "The source has no files, so \(deleteVerb) would delete everything at the destination. "
            + "Nothing was changed. Check that the source is the right folder and is mounted, "
            + "or add --allow-mass-delete to go ahead."
        )
    }

    /// Stops before deleting more than half of the destination
    private func guardMassDelete(_ check: DestinationCheck) throws {
        guard !options.allowMassDelete, check.totalItems > 0, check.extraItems * 2 > check.totalItems else { return }
        let percent = Int((Double(check.extraItems) / Double(check.totalItems) * 100).rounded())
        let verb = deleteVerb.prefix(1).uppercased() + deleteVerb.dropFirst()
        throw MacroboError.massDeleteBlocked(
            "\(verb) would delete \(formatCount(check.extraItems)) of \(formatCount(check.totalItems, "item")) "
            + "(\(percent)%) at the destination. Nothing was deleted. Check that the source is the right folder, "
            + "or add --allow-mass-delete to go ahead."
        )
    }

    // MARK: - Deleting extras

    private func listWouldDelete(_ items: [ExtraItem]) async {
        for item in items {
            for file in item.innerFiles + (item.isDirectory ? [] : [item.relativePath]) {
                let path = String(file.dropFirst())
                await progress.wouldChange("delete", path: path)
                await logger.writeLogOnly("  WOULD DELETE: \(path)")
            }
            if item.isDirectory {
                for folder in item.innerFolders + [item.relativePath] {
                    let path = String(folder.dropFirst())
                    await progress.wouldChange("delete", path: path, folder: true)
                    await logger.writeLogOnly("  WOULD DELETE: \(path)/ (folder)")
                }
            }
            result.wouldDeleteFiles += item.fileCount
            result.wouldDeleteFolders += item.folderCount
        }
    }

    /// Deletes extras on --threads threads. A folder goes in one call with everything in it.
    private func deleteExtras(_ items: [ExtraItem]) async {
        let totalItems = items.reduce(0) { $0 + $1.fileCount + $1.folderCount }
        let counts = LiveCounts(slots: 1) // items deleted
        let start = Date()
        let ticker = startStep(id: "delete", name: "Deleting") {
            let done = counts.get(0)
            var text = "\(formatCount(done)) of \(formatCount(totalItems, "item"))"
            if let left = formatTimeLeft(elapsed: Date().timeIntervalSince(start), done: Double(done), total: Double(totalItems)) {
                text += ", \(left)"
            }
            return (text, ["deleted": done, "total": totalItems])
        }

        let work = items
        let retries = options.retryCount
        let failures = ResultSlots<String>(count: items.count)
        let threads = options.threadCount
        await runOnThread {
            parallelForEach(count: work.count, workers: threads) { i in
                let item = work[i]
                var lastError: Error?
                for attempt in 0...max(0, retries) {
                    do {
                        try FileManager.default.removeItem(at: item.url)
                        lastError = nil
                        break
                    } catch {
                        // Already gone (removed by someone else) counts as deleted
                        if (error as NSError).code == NSFileNoSuchFileError { lastError = nil; break }
                        lastError = error
                        if attempt < retries { Thread.sleep(forTimeInterval: 1) }
                    }
                }
                if let lastError {
                    failures[i] = Self.reason(for: lastError)
                } else {
                    counts.add(0, item.fileCount + item.folderCount)
                }
            }
        }

        let failed = failures.all
        var deletedFiles = 0
        var deletedFolders = 0
        var failedCount = 0
        let root = options.destination.path
        for (i, item) in items.enumerated() {
            if let reason = failed[i] {
                failedCount += 1
                let failure = FileOperationResult.failed(path: item.url, error: MacroboError.deleteFailed(
                    item.url.path, NSError(domain: "macrobo", code: 5, userInfo: [NSLocalizedDescriptionKey: reason])
                ))
                result.record(failure)
                await logger.logOperation(failure)
                continue
            }
            for file in item.innerFiles + (item.isDirectory ? [] : [item.relativePath]) {
                await logger.logOperation(.deleted(path: URL(fileURLWithPath: root + file)))
            }
            if item.isDirectory {
                for folder in item.innerFolders + [item.relativePath] {
                    await logger.logOperation(.directoryDeleted(path: URL(fileURLWithPath: root + folder)))
                }
            }
            deletedFiles += item.fileCount
            deletedFolders += item.folderCount
        }
        result.filesDeleted += deletedFiles
        result.directoriesDeleted += deletedFolders

        var detail = "\(formatCount(deletedFiles, "file")), \(formatCount(deletedFolders, "folder"))"
        if failedCount > 0 { detail += ", \(formatCount(failedCount)) failed" }
        await finishStep(
            ticker, id: "delete", name: "Deleted", detail: detail,
            counts: ["files": deletedFiles, "folders": deletedFolders, "failed": failedCount], since: start
        )
    }
}
