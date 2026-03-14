import Foundation

/// File info with size and relative path captured during enumeration
public struct FileInfo: Sendable {
    public let url: URL
    public let size: UInt64
    public let relativePath: String  // Path relative to source root

    public init(url: URL, size: UInt64, relativePath: String) {
        self.url = url
        self.size = size
        self.relativePath = relativePath
    }
}

/// Core copy engine with multi-threaded file operations
public actor CopyEngine {
    private let options: CopyOptions
    private let logger: Logger
    private let progress: ProgressReporter
    private var result = CopyResult()
    private let resolvedSourcePath: String
    private let resolvedDestPath: String

    public init(options: CopyOptions, logger: Logger, progress: ProgressReporter) {
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
            await copyFiles(filesToCopy)

            // End progress display - flush any buffered errors
            await progress.finish()
            await logger.endProgressDisplay()

            // Handle purge/mirror - delete extra files in destination
            if options.mirror || options.purge {
                await purgeExtraFiles()
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
        let candidates: [FileInfo]
        do {
            candidates = try await Task.detached {
                try Self.enumerateSourceFilesSync(
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

        // Second pass: filter files that need copying (with progress updates)
        var files: [FileInfo] = []
        var lastUpdateTime = Date()
        let fm = FileManager.default
        let destBase = options.destination.path
        var checksumCount = 0
        let checksumBatchSize = 100
        let checksumPauseNs: UInt64 = 500_000_000 // 500ms pause every batch

        for (index, fileInfo) in candidates.enumerated() {
            // Update progress periodically (every 100ms)
            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= 0.1 {
                await progress.updateScanProgress(scanned: index + 1, found: files.count)
                lastUpdateTime = now
            }

            // Build destination path using the captured relative path
            let destPath = destBase + fileInfo.relativePath
            let destURL = URL(fileURLWithPath: destPath)

            if fm.fileExists(atPath: destPath) {
                // Skip identical files (same size and modification time)
                // Unless --include-same is set, which forces copying even identical files
                if !options.includeSame && FileOperations.areFilesIdentical(source: fileInfo.url, destination: destURL) {
                    continue
                }
                // Checksum mode: if size matches but mtime differs, compare file contents
                if !options.includeSame && options.checksum {
                    if let srcSize = FileOperations.fileSize(at: fileInfo.url),
                       let dstSize = FileOperations.fileSize(at: destURL),
                       srcSize == dstSize {
                        // Show which file is being checksummed and keep spinner alive
                        await progress.updateScanProgress(scanned: index + 1, found: files.count, checksumming: fileInfo.url.lastPathComponent)
                        let scanned = index + 1
                        let currentFound = files.count
                        let fileName = fileInfo.url.lastPathComponent
                        let spinnerTask = Task {
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                await self.progress.updateScanProgress(scanned: scanned, found: currentFound, checksumming: fileName)
                            }
                        }
                        let identical = await Task.detached {
                            FileOperations.areFileContentsIdentical(source: fileInfo.url, destination: destURL)
                        }.value
                        spinnerTask.cancel()
                        lastUpdateTime = Date()
                        checksumCount += 1
                        // Pause periodically to avoid overwhelming NAS/network volumes
                        if checksumCount % checksumBatchSize == 0 {
                            try? await Task.sleep(nanoseconds: checksumPauseNs)
                        }
                        if identical {
                            continue
                        }
                    }
                }
                // Skip if destination is newer and excludeOlder is set
                if options.excludeOlder && !FileOperations.isSourceNewer(source: fileInfo.url, destination: destURL) {
                    continue
                }
            }

            files.append(fileInfo)
        }

        // Final progress update
        await progress.updateScanProgress(scanned: candidates.count, found: files.count)

        return files
    }

    /// Compiles a glob pattern (*, ?) into a pre-compiled NSRegularExpression
    private static func compileGlobPattern(_ pattern: String) -> NSRegularExpression? {
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        return try? NSRegularExpression(pattern: "^\(regexPattern)$", options: .caseInsensitive)
    }

    /// Checks if a name matches a pre-compiled regex, with fallback to case-insensitive string comparison
    private static func matches(_ name: String, regex: NSRegularExpression?, fallbackPattern: String) -> Bool {
        guard let regex = regex else {
            return name.lowercased() == fallbackPattern.lowercased()
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Enumerates source files synchronously (static version for background execution)
    private static func enumerateSourceFilesSync(
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

        // Pre-compile all glob patterns once (instead of per-file)
        let excludeDirRegexes = excludeDirs.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let excludeFileRegexes = excludeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let includeFileRegexes = includeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }

        // Standardize source path for consistent relative path calculation
        let sourcePathStandardized = source.standardizedFileURL.path

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if skipHidden {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        // Resolve symlinks in source to detect cycles
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
            // Get resource values including size
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])

            if resourceValues?.isDirectory == true {
                // Detect symlink cycles by resolving the real path
                let resolvedDir = url.resolvingSymlinksInPath().path
                if visitedDirs.contains(resolvedDir) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedDirs.insert(resolvedDir)

                // Skip excluded directories
                let dirName = url.lastPathComponent
                let shouldSkip = excludeDirRegexes.contains { matches(dirName, regex: $0.regex, fallbackPattern: $0.pattern) }
                if shouldSkip {
                    enumerator.skipDescendants()
                    continue
                }
                continue  // Don't add directories to file list
            }

            // Skip non-regular files
            guard resourceValues?.isRegularFile == true else { continue }

            let fileName = url.lastPathComponent

            // Check exclude patterns
            let shouldExclude = excludeFileRegexes.contains { matches(fileName, regex: $0.regex, fallbackPattern: $0.pattern) }
            if shouldExclude { continue }

            // Check include patterns (if specified)
            if !includeFileRegexes.isEmpty {
                let shouldInclude = includeFileRegexes.contains { matches(fileName, regex: $0.regex, fallbackPattern: $0.pattern) }
                if !shouldInclude { continue }
            }

            // Check size constraints
            let fileSize = UInt64(resourceValues?.fileSize ?? 0)
            let actualSize = fileSize > 0 ? fileSize : (FileOperations.fileSize(at: url) ?? 0)

            if let min = minSize, actualSize < min { continue }
            if let max = maxSize, actualSize > max { continue }

            // Calculate relative path by removing source prefix
            let urlPathStandardized = url.standardizedFileURL.path
            let relativePath: String
            if urlPathStandardized.hasPrefix(sourcePathStandardized) {
                relativePath = String(urlPathStandardized.dropFirst(sourcePathStandardized.count))
            } else {
                // Fallback: just use the last path component
                relativePath = "/" + url.lastPathComponent
            }

            files.append(FileInfo(url: url, size: actualSize, relativePath: relativePath))
        }

        return files
    }

    /// Copies files using a thread pool
    private func copyFiles(_ files: [FileInfo]) async {
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
                case .copied(let source, _, let bytes):
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

    /// Purges extra files from destination that don't exist in source
    private func purgeExtraFiles() async {
        guard !options.excludeExtra else { return }

        let fm = FileManager.default

        // Gather files to delete (synchronous to avoid Swift 6 warning)
        let (filesToDelete, dirsToDelete) = gatherFilesToPurge()

        // Delete files
        for file in filesToDelete {
            if options.dryRun {
                result.record(.skipped(source: file, reason: .dryRun, bytes: FileOperations.fileSize(at: file) ?? 0))
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
            let relativePath: String
            if url.path.hasPrefix(resolvedDestPath) {
                relativePath = String(url.path.dropFirst(resolvedDestPath.count))
            } else {
                relativePath = "/" + url.lastPathComponent
            }
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
