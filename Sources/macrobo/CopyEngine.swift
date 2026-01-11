import Foundation

/// Core copy engine with multi-threaded file operations
actor CopyEngine {
    private let options: CopyOptions
    private let logger: Logger
    private let progress: ProgressReporter
    private var result = CopyResult()
    private let resolvedSourcePath: String
    private let resolvedDestPath: String

    init(options: CopyOptions, logger: Logger, progress: ProgressReporter) {
        self.options = options
        self.logger = logger
        self.progress = progress
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
    func run() async throws -> CopyResult {
        // Validate options
        try options.validate()

        // Open logger
        try await logger.open()
        defer { Task { await logger.close() } }

        // Log start
        await logger.info("Source: \(options.source.path)")
        await logger.info("Destination: \(options.destination.path)")
        if options.mirror {
            await logger.info("Mode: Mirror (copy + purge)")
        }
        await logger.info("")

        // Create destination if needed
        try ensureDestinationExists()

        // Gather files to copy
        let filesToCopy = try await gatherSourceFiles()
        await progress.clear()
        let totalBytes = filesToCopy.reduce(0) { $0 + (FileOperations.fileSize(at: $1) ?? 0) }

        await progress.setTotals(files: filesToCopy.count, bytes: totalBytes)
        await logger.setTotalFiles(filesToCopy.count)
        await logger.info("Found \(filesToCopy.count) files to process")

        // Copy files using thread pool
        await copyFiles(filesToCopy)

        // Handle purge/mirror - delete extra files in destination
        if options.mirror || options.purge {
            await purgeExtraFiles()
        }

        // Finish up
        result.finish()
        await progress.finish()
        await logger.logSummary(result)

        return result
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

    /// Gathers all source files to be copied
    private func gatherSourceFiles() async throws -> [URL] {
        // First pass: enumerate all candidate files (synchronous)
        // Run a spinner task in the background during enumeration
        let spinnerTask = Task {
            while !Task.isCancelled {
                await progress.showStatus("Scanning source files...")
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        let candidates = try enumerateSourceFiles()
        spinnerTask.cancel()

        // Second pass: filter files that need copying (with progress updates)
        var files: [URL] = []
        var lastUpdateTime = Date()
        let fm = FileManager.default

        for (index, url) in candidates.enumerated() {
            // Update progress periodically (every 100ms)
            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= 0.1 {
                await progress.updateScanProgress(scanned: index + 1, found: files.count)
                lastUpdateTime = now
            }

            // Check if needs copying
            let relativePath = url.path.replacingOccurrences(of: resolvedSourcePath, with: "")
            let destPath = resolvedDestPath + relativePath
            let destURL = URL(fileURLWithPath: destPath)

            if fm.fileExists(atPath: destPath) {
                // Skip identical files (same size and modification time) - mirrors robocopy's default behavior
                // Unless includeSame (/IS) is set, which forces copying even identical files
                if !options.includeSame && FileOperations.areFilesIdentical(source: url, destination: destURL) {
                    continue
                }
                // Skip if destination is newer and excludeOlder is set
                if options.excludeOlder && !FileOperations.isSourceNewer(source: url, destination: destURL) {
                    continue
                }
            }

            files.append(url)
        }

        // Final progress update
        await progress.updateScanProgress(scanned: candidates.count, found: files.count)

        return files
    }

    /// Enumerates source files synchronously (first pass - no destination checks)
    private nonisolated func enumerateSourceFiles() throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []

        let enumerator = fm.enumerator(
            at: options.source,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        guard let enumerator = enumerator else {
            throw MacroboError.sourceNotFound(options.source.path)
        }

        for case let url as URL in enumerator {
            // Check if directory
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if resourceValues?.isDirectory == true {
                // Skip excluded directories
                if shouldExcludeDirectory(url) {
                    enumerator.skipDescendants()
                    continue
                }
                continue  // Don't add directories to file list
            }

            // Skip non-regular files
            guard resourceValues?.isRegularFile == true else { continue }

            // Apply filters
            if shouldExcludeFile(url) { continue }
            if !shouldIncludeFile(url) { continue }
            if !checkSizeConstraints(url) { continue }

            files.append(url)
        }

        return files
    }

    /// Checks if a directory should be excluded
    private nonisolated func shouldExcludeDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        for pattern in options.excludeDirectories {
            if matchesPattern(name, pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Checks if a file should be excluded
    private nonisolated func shouldExcludeFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        for pattern in options.excludeFiles {
            if matchesPattern(name, pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Checks if a file should be included (when include filters are specified)
    private nonisolated func shouldIncludeFile(_ url: URL) -> Bool {
        guard !options.includeFiles.isEmpty else { return true }
        let name = url.lastPathComponent
        for pattern in options.includeFiles {
            if matchesPattern(name, pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Checks if file meets size constraints
    private nonisolated func checkSizeConstraints(_ url: URL) -> Bool {
        guard options.minFileSize != nil || options.maxFileSize != nil else { return true }
        guard let size = FileOperations.fileSize(at: url) else { return true }

        if let minSize = options.minFileSize, size < minSize {
            return false
        }
        if let maxSize = options.maxFileSize, size > maxSize {
            return false
        }
        return true
    }

    /// Simple glob pattern matching
    private nonisolated func matchesPattern(_ name: String, pattern: String) -> Bool {
        // Support basic glob patterns: *, ?
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$", options: .caseInsensitive) else {
            return name == pattern  // Fallback to exact match
        }

        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Copies files using a thread pool
    private func copyFiles(_ files: [URL]) async {
        await withTaskGroup(of: FileOperationResult.self) { group in
            var pendingFiles = files[...]
            var activeTasks = 0

            // Start initial batch
            while activeTasks < options.threadCount && !pendingFiles.isEmpty {
                let file = pendingFiles.removeFirst()
                activeTasks += 1
                group.addTask {
                    await self.copyFile(file)
                }
            }

            // Process results and add more tasks
            for await opResult in group {
                result.record(opResult)
                await logger.logOperation(opResult)

                if case .copied(let source, _, let bytes) = opResult {
                    await progress.fileCompleted(name: source.lastPathComponent, bytes: bytes)
                }

                // Add next file if available
                if !pendingFiles.isEmpty {
                    let file = pendingFiles.removeFirst()
                    group.addTask {
                        await self.copyFile(file)
                    }
                }
            }
        }
    }

    /// Copies a single file with retry support
    private func copyFile(_ source: URL) async -> FileOperationResult {
        let relativePath = source.path.replacingOccurrences(of: resolvedSourcePath, with: "")
        let destPath = resolvedDestPath + relativePath
        let destURL = URL(fileURLWithPath: destPath)

        // Dry run
        if options.dryRun {
            return .skipped(source: source, reason: .dryRun)
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

        // Copy with retry
        var lastError: Error?
        for attempt in 0..<max(1, options.retryCount) {
            do {
                let bytes = try await FileOperations.copyFile(
                    from: source,
                    to: destURL,
                    options: options
                ) { current, total in
                    await self.progress.bytesProgress(current: current, total: total, fileName: source.lastPathComponent)
                    await self.logger.logFileProgress(fileName: source.lastPathComponent, currentBytes: current, totalBytes: total)
                }

                // Move mode - delete source after successful copy
                if options.moveFiles || options.moveAll {
                    try await FileOperations.deleteFile(at: source)
                }

                return .copied(source: source, destination: destURL, bytes: bytes)
            } catch {
                lastError = error
                if attempt < options.retryCount - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(options.retryWaitSeconds) * 1_000_000_000)
                }
            }
        }

        return .failed(path: source, error: lastError ?? MacroboError.copyFailed(source.path, NSError(domain: "macrobo", code: 99)))
    }

    /// Purges extra files from destination that don't exist in source
    private func purgeExtraFiles() async {
        guard !options.excludeExtra else { return }

        let fm = FileManager.default

        // Gather files to delete (synchronous to avoid Swift 6 warning)
        let (filesToDelete, dirsToDelete) = gatherFilesToPurge()

        // Delete files
        for file in filesToDelete {
            if options.dryRun {
                result.record(.skipped(source: file, reason: .dryRun))
                continue
            }
            do {
                try await FileOperations.deleteFile(at: file)
                result.filesDeleted += 1
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
                result.directoriesDeleted += 1
                await logger.logOperation(.deleted(path: dir))
            } catch {
                await logger.warning("Failed to delete directory \(dir.path): \(error.localizedDescription)")
            }
        }
    }

    /// Gathers files and directories to purge (synchronous helper to avoid Swift 6 warning)
    private nonisolated func gatherFilesToPurge() -> (files: [URL], dirs: [URL]) {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: options.destination,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )

        guard let enumerator = enumerator else { return ([], []) }

        var filesToDelete: [URL] = []
        var dirsToDelete: [URL] = []

        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let relativePath = url.path.replacingOccurrences(of: resolvedDestPath, with: "")
            let sourcePath = resolvedSourcePath + relativePath
            let sourceURL = URL(fileURLWithPath: sourcePath)

            if !fm.fileExists(atPath: sourceURL.path) {
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
