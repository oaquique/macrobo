import Foundation

/// Core copy engine with multi-threaded file operations
public actor CopyEngine {
    private let options: CopyOptions
    private let logger: Logger
    private let progress: ProgressReporter
    private let rateLimiter: RateLimiter?
    private var result = CopyResult()
    private let resolvedSourcePath: String
    private let resolvedDestPath: String
    /// Relative paths of every source file and directory the scan saw (for mirror/purge)
    private var knownSourcePaths: Set<String> = []
    /// Phase timings, written to the log file
    private var scanTimings: (enumerate: TimeInterval, compare: TimeInterval, files: Int)?

    public init(options: CopyOptions, logger: Logger, progress: ProgressReporter) {
        self.options = options
        self.logger = logger
        self.progress = progress
        self.rateLimiter = options.bandwidthLimit > 0 ? RateLimiter(bytesPerSecond: options.bandwidthLimit) : nil
        // Resolve symlinks using realpath for consistent path handling
        // The file enumerator returns resolved paths (e.g., /private/tmp/...) so we must match
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

    /// Runs the copy operation
    public func run() async throws -> CopyResult {
        // Validate options
        try options.validate()

        // Open logger - ensure it's always closed, even on error
        try await logger.open()

        do {
            // Log start
            await logger.info("Source: \(options.source.path)")
            await logger.info("Destination: \(options.destination.path)")
            if options.mirror {
                await logger.info("Mode: Mirror (copy + purge)")
            }
            await logger.info("")

            // Create destination if needed
            try ensureDestinationExists()

            // Gather files to copy (with sizes captured during enumeration)
            let filesToCopy = try await gatherSourceFiles()
            await progress.clear()
            if let timings = scanTimings {
                await logger.writeLogOnly(String(
                    format: "Scan: %d files in %.1fs (enumerate %.1fs, compare %.1fs)",
                    timings.files, timings.enumerate + timings.compare, timings.enumerate, timings.compare
                ))
            }
            let totalBytes = filesToCopy.reduce(UInt64(0)) { $0 + $1.size }

            // Print summary line after scanning
            if !options.quiet {
                print("Copying \(filesToCopy.count) files (\(formatBytes(totalBytes, precision: 1)))...")
            }

            await progress.setTotals(files: filesToCopy.count, bytes: totalBytes)
            await logger.setTotalFiles(filesToCopy.count)

            // Begin progress display phase - suppress inline errors
            await logger.beginProgressDisplay()

            // Copy files using thread pool
            let copiedPairs = await copyFiles(filesToCopy)

            // End progress display - flush any buffered errors
            await progress.finish()
            await logger.endProgressDisplay()

            // Verify copied files if requested
            if options.verify && !copiedPairs.isEmpty {
                await verifyFiles(copiedPairs)
            }

            // Handle purge/mirror - delete extra files in destination
            if options.mirror || options.purge {
                let purgeStart = Date()
                await purgeExtraFiles()
                await logger.writeLogOnly(String(format: "Purge scan and delete: %.1fs", Date().timeIntervalSince(purgeStart)))
            }

            // Finish up
            result.finish()
            await logger.logSummary(result)
            await logger.close()

            return result
        } catch {
            await logger.close()
            throw error
        }
    }

    /// Ensures the destination directory exists
    private func ensureDestinationExists() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: options.destination.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw MacroboError.destinationCreationFailed("\(options.destination.path) exists but is not a directory")
            }
        } else {
            if options.dryRun {
                return
            }
            do {
                try fm.createDirectory(at: options.destination, withIntermediateDirectories: true)
                result.record(.directoryCreated(path: options.destination))
            } catch {
                throw MacroboError.destinationCreationFailed(options.destination.path)
            }
        }
    }

    /// Gathers all source files to be copied (with sizes)
    private func gatherSourceFiles() async throws -> [FileInfo] {
        // First pass: enumerate all candidate files
        // Run enumeration in background thread so spinner can update
        let sourceURL = options.source
        let skipHidden = true
        let excludeDirs = options.excludeDirectories
        let excludeFilesPatterns = options.excludeFiles
        let includeFilesPatterns = options.includeFiles
        let minSize = options.minFileSize
        let maxSize = options.maxFileSize

        // Start spinner task
        let spinnerTask = Task {
            while !Task.isCancelled {
                await progress.showStatus("Scanning source files...")
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        // Run enumeration in detached task to allow spinner to run
        let enumerateStart = Date()
        let enumeration: SourceEnumeration
        do {
            enumeration = try await Task.detached {
                try FileEnumerator.enumerateSource(
                    source: sourceURL,
                    skipHidden: skipHidden,
                    excludeDirs: excludeDirs,
                    excludeFiles: excludeFilesPatterns,
                    includeFiles: includeFilesPatterns,
                    minSize: minSize,
                    maxSize: maxSize
                )
            }.value
        } catch {
            spinnerTask.cancel()
            throw error
        }

        spinnerTask.cancel()
        let candidates = enumeration.files
        let enumerateDuration = Date().timeIntervalSince(enumerateStart)

        if options.mirror || options.purge {
            knownSourcePaths = enumeration.directoryRelativePaths
            for file in candidates { knownSourcePaths.insert(file.relativePath) }
        }

        // Second pass: compare against the destination in parallel (one metadata call per file)
        let compareStart = Date()
        let settings = CompareSettings(
            includeSame: options.includeSame,
            checksum: options.checksum,
            excludeOlder: options.excludeOlder
        )
        let counter = ScanCounter()
        let compareProgressTask = Task {
            while !Task.isCancelled {
                let snapshot = counter.snapshot
                await progress.updateScanProgress(scanned: snapshot.completed, found: snapshot.toCopy)
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        let verdicts = await DestinationComparator.compareAll(
            candidates,
            destinationBase: options.destination.path,
            settings: settings,
            counter: counter
        )
        compareProgressTask.cancel()

        // Third pass: content checksums, sequential and throttled to protect NAS/network volumes
        var files: [FileInfo] = []
        let destBase = options.destination.path
        var checksumCount = 0
        let checksumBatchSize = 100
        let checksumPauseNs: UInt64 = 500_000_000 // 500ms pause every batch
        let scanned = candidates.count
        var found = counter.snapshot.toCopy

        for (fileInfo, verdict) in zip(candidates, verdicts) {
            switch verdict {
            case .skip:
                continue
            case .copy:
                files.append(fileInfo)
            case .checksum(let skipIfDifferent):
                let destURL = URL(fileURLWithPath: destBase + fileInfo.relativePath)
                // Show which file is being checksummed and keep spinner alive
                let fileName = fileInfo.url.lastPathComponent
                let currentFound = found
                await progress.updateScanProgress(scanned: scanned, found: currentFound, checksumming: fileName)
                let spinnerTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await self.progress.updateScanProgress(scanned: scanned, found: currentFound, checksumming: fileName)
                    }
                }
                let size = fileInfo.size
                let identical = await Task.detached {
                    FileOperations.areFileContentsIdentical(source: fileInfo.url, destination: destURL, sourceSize: size)
                }.value
                spinnerTask.cancel()
                checksumCount += 1
                // Pause periodically to avoid overwhelming NAS/network volumes
                if checksumCount % checksumBatchSize == 0 {
                    try? await Task.sleep(nanoseconds: checksumPauseNs)
                }
                if identical || skipIfDifferent {
                    continue
                }
                found += 1
                files.append(fileInfo)
            }
        }

        // Final progress update
        await progress.updateScanProgress(scanned: scanned, found: files.count)
        scanTimings = (enumerateDuration, Date().timeIntervalSince(compareStart), candidates.count)

        return files
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

    /// Verifies copied files by comparing full SHA256 checksums
    private func verifyFiles(_ pairs: [(source: URL, destination: URL)]) async {
        if !options.quiet {
            print("Verifying \(pairs.count) copied files...")
        }
        await logger.info("Verifying \(pairs.count) copied files...")

        var verified = 0
        var failed = 0

        for (source, destination) in pairs {
            do {
                let srcHash = try FileOperations.fullChecksumFile(at: source)
                let dstHash = try FileOperations.fullChecksumFile(at: destination)
                if srcHash == dstHash {
                    verified += 1
                } else {
                    failed += 1
                    result.record(.failed(path: destination, error: MacroboError.copyFailed(
                        destination.lastPathComponent,
                        NSError(domain: "macrobo", code: 10,
                                userInfo: [NSLocalizedDescriptionKey: "Verification failed: checksum mismatch"])
                    )))
                    await logger.warning("Verification FAILED: \(destination.lastPathComponent)")
                }
            } catch {
                failed += 1
                await logger.warning("Verification error for \(destination.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !options.quiet {
            print("Verification complete: \(verified) OK, \(failed) failed")
        }
        await logger.info("Verification complete: \(verified) OK, \(failed) failed")
    }

    /// Purges extra files from destination that don't exist in source
    private func purgeExtraFiles() async {
        guard !options.excludeExtra else { return }

        let fm = FileManager.default

        // Gather files to delete (synchronous to avoid Swift 6 warning)
        let (filesToDelete, dirsToDelete) = gatherFilesToPurge(
            destination: options.destination,
            resolvedDestPath: resolvedDestPath,
            resolvedSourcePath: resolvedSourcePath,
            knownSourcePaths: knownSourcePaths
        )

        // Delete files
        for file in filesToDelete {
            if options.dryRun {
                result.record(.skipped(source: file, reason: .dryRun, bytes: FileOperations.fileSize(at: file) ?? 0))
                continue
            }
            do {
                try await FileOperations.deleteFile(at: file)
                result.record(.deleted(path: file))
                await logger.logOperation(.deleted(path: file))
            } catch {
                result.record(.failed(path: file, error: error))
            }
        }

        // Delete directories (in reverse order to handle nested dirs)
        for dir in dirsToDelete.reversed() {
            if options.dryRun {
                continue
            }
            do {
                try fm.removeItem(at: dir)
                result.record(.directoryDeleted(path: dir))
                await logger.logOperation(.directoryDeleted(path: dir))
            } catch {
                await logger.warning("Failed to delete directory \(dir.path): \(error.localizedDescription)")
            }
        }
    }

    /// Gathers files and directories to purge (synchronous helper to avoid Swift 6 warning)
    private nonisolated func gatherFilesToPurge(
        destination: URL,
        resolvedDestPath: String,
        resolvedSourcePath: String,
        knownSourcePaths: Set<String>
    ) -> (files: [URL], dirs: [URL]) {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )

        guard let enumerator = enumerator else { return ([], []) }

        var filesToDelete: [URL] = []
        var dirsToDelete: [URL] = []

        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let relativePath: String
            if url.path.hasPrefix(resolvedDestPath) {
                relativePath = String(url.path.dropFirst(resolvedDestPath.count))
            } else {
                relativePath = "/" + url.lastPathComponent
            }
            // Paths the scan already saw exist in the source: no network round trip.
            // Anything else (hidden, excluded, filtered, or spelled differently) falls
            // back to an existence check on the source, as before.
            if knownSourcePaths.contains(relativePath) { continue }
            let sourcePath = resolvedSourcePath + relativePath

            if !fm.fileExists(atPath: sourcePath) {
                if resourceValues?.isDirectory == true {
                    dirsToDelete.append(url)
                    enumerator.skipDescendants()
                } else if resourceValues?.isRegularFile == true {
                    filesToDelete.append(url)
                }
            }
        }

        return (filesToDelete, dirsToDelete)
    }

}
