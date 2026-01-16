import Foundation

/// File info with size and relative path captured during enumeration
struct FileInfo: Sendable {
    let url: URL
    let size: UInt64
    let relativePath: String  // Path relative to source root
}

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

        // Gather files to copy (with sizes captured during enumeration)
        let filesToCopy = try await gatherSourceFiles()
        await progress.clear()
        let totalBytes = filesToCopy.reduce(UInt64(0)) { $0 + $1.size }

        // Print summary line after scanning
        if !options.quiet {
            print("Copying \(filesToCopy.count) files (\(formatBytes(totalBytes)))...")
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
        let candidates = try await Task.detached {
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

        spinnerTask.cancel()

        // Second pass: filter files that need copying (with progress updates)
        var files: [FileInfo] = []
        var lastUpdateTime = Date()
        let fm = FileManager.default
        let destBase = options.destination.path

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
                // Skip identical files (same size and modification time) - mirrors robocopy's default behavior
                // Unless includeSame (/IS) is set, which forces copying even identical files
                if !options.includeSame && FileOperations.areFilesIdentical(source: fileInfo.url, destination: destURL) {
                    continue
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

        // Standardize source path for consistent relative path calculation
        let sourcePathStandardized = source.standardizedFileURL.path

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if skipHidden {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: enumeratorOptions
        )

        guard let enumerator = enumerator else {
            throw MacroboError.sourceNotFound(source.path)
        }

        for case let url as URL in enumerator {
            // Get resource values including size
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])

            if resourceValues?.isDirectory == true {
                // Skip excluded directories
                let dirName = url.lastPathComponent
                let shouldSkip = excludeDirs.contains { pattern in
                    matchesPatternStatic(dirName, pattern: pattern)
                }
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
            let shouldExclude = excludeFiles.contains { pattern in
                matchesPatternStatic(fileName, pattern: pattern)
            }
            if shouldExclude { continue }

            // Check include patterns (if specified)
            if !includeFiles.isEmpty {
                let shouldInclude = includeFiles.contains { pattern in
                    matchesPatternStatic(fileName, pattern: pattern)
                }
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

    /// Static pattern matching for use in detached tasks
    private static func matchesPatternStatic(_ name: String, pattern: String) -> Bool {
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$", options: .caseInsensitive) else {
            return name.lowercased() == pattern.lowercased()
        }

        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
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
    private func copyFiles(_ files: [FileInfo]) async {
        await withTaskGroup(of: FileOperationResult.self) { group in
            var pendingFiles = files[...]
            var activeTasks = 0

            // Start initial batch
            while activeTasks < options.threadCount && !pendingFiles.isEmpty {
                let fileInfo = pendingFiles.removeFirst()
                activeTasks += 1
                group.addTask {
                    await self.copyFile(fileInfo)
                }
            }

            // Process results and add more tasks
            for await opResult in group {
                result.record(opResult)
                await logger.logOperation(opResult)

                // Update progress for both successful and failed files
                switch opResult {
                case .copied(let source, _, let bytes):
                    await progress.fileCompleted(name: source.lastPathComponent, bytes: bytes)
                case .failed(let path, _):
                    await progress.fileFailed(name: path.lastPathComponent)
                case .skipped(let source, _):
                    await progress.fileFailed(name: source.lastPathComponent)
                default:
                    break
                }

                // Add next file if available
                if !pendingFiles.isEmpty {
                    let fileInfo = pendingFiles.removeFirst()
                    group.addTask {
                        await self.copyFile(fileInfo)
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

        // Notify progress that we're starting this file (use captured size)
        await progress.fileStarted(name: source.lastPathComponent, bytes: fileSize)

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

    /// Format bytes for human-readable display (macOS decimal units)
    private nonisolated func formatBytes(_ bytes: UInt64) -> String {
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
            return String(format: "%.1f %@", value, units[unitIndex])
        }
    }
}
