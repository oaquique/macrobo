import Foundation

/// File info with size and relative path captured during enumeration
public struct FileInfo: Sendable {
    public let url: URL
    public let size: UInt64
    public let relativePath: String  // Path relative to source root
    /// Modification date captured during enumeration (nil if it could not be read)
    public let modificationDate: Date?

    public init(url: URL, size: UInt64, relativePath: String, modificationDate: Date? = nil) {
        self.url = url
        self.size = size
        self.relativePath = relativePath
        self.modificationDate = modificationDate
    }
}

/// Result of a source enumeration: the files that passed the filters, plus the
/// relative paths of every directory walked (used by mirror/purge to avoid a
/// per-entry existence check on the source).
public struct SourceEnumeration: Sendable {
    public let files: [FileInfo]
    public let directoryRelativePaths: Set<String>
    /// Directories that couldn't be listed, with the reason. Their contents are unknown,
    /// so a purge must not delete anything under them.
    public var unreadableDirectories: [(relativePath: String, reason: String)] = []
}

/// Enumerates source files with filtering support
public struct FileEnumerator {

    /// Compiles a glob pattern (*, ?) into a pre-compiled NSRegularExpression
    public static func compileGlobPattern(_ pattern: String) -> NSRegularExpression? {
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
        return try? NSRegularExpression(pattern: "^\(regexPattern)$", options: .caseInsensitive)
    }

    /// Checks if a name matches a pre-compiled regex, with fallback to case-insensitive string comparison
    public static func matches(_ name: String, regex: NSRegularExpression?, fallbackPattern: String) -> Bool {
        guard let regex = regex else {
            return name.lowercased() == fallbackPattern.lowercased()
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Slots in the live counts passed to `enumerateSource`
    public static let filesSlot = 0
    public static let foldersSlot = 1

    /// Lists the source on several threads with filtering, also returning walked directories.
    /// Blocks until done; `counts` (slots `filesSlot`, `foldersSlot`) updates as it goes.
    public static func enumerateSource(
        source: URL,
        skipHidden: Bool,
        excludeDirs: [String],
        excludeFiles: [String],
        includeFiles: [String],
        minSize: UInt64?,
        maxSize: UInt64?,
        counts: LiveCounts = LiveCounts(slots: 2),
        workers: Int = 16
    ) throws -> SourceEnumeration {
        // Pre-compile all glob patterns once (instead of per-file)
        let excludeDirRegexes = excludeDirs.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let excludeFileRegexes = excludeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let includeFileRegexes = includeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }

        let lock = NSLock()
        var files: [FileInfo] = []
        var directoryRelativePaths: Set<String> = []
        var unreadable: [(relativePath: String, reason: String)] = []

        // Symlinked directories are never followed (they list as symlinks, not directories),
        // so the walk can't loop.
        try ParallelWalker.walk(
            root: source,
            rootContext: (),
            keys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            skipHidden: skipHidden,
            workers: workers,
            unreadable: { dir, error in
                lock.lock()
                unreadable.append((dir.relativePath, (error as NSError).localizedFailureReason ?? error.localizedDescription))
                lock.unlock()
            },
            visit: { _, entries in
                var subdirs: [ParallelWalker.Directory<Void>] = []
                var batch: [FileInfo] = []
                for entry in entries {
                    if entry.isDirectory {
                        let excluded = excludeDirRegexes.contains { matches(entry.name, regex: $0.regex, fallbackPattern: $0.pattern) }
                        if excluded { continue }
                        subdirs.append(.init(url: entry.url, relativePath: entry.relativePath, context: ()))
                        continue
                    }

                    // Skip non-regular files (symlinks, sockets, ...)
                    guard entry.isRegularFile else { continue }

                    if excludeFileRegexes.contains(where: { matches(entry.name, regex: $0.regex, fallbackPattern: $0.pattern) }) { continue }
                    if !includeFileRegexes.isEmpty
                        && !includeFileRegexes.contains(where: { matches(entry.name, regex: $0.regex, fallbackPattern: $0.pattern) }) { continue }

                    // Size from the prefetched values (fall back to a stat only if missing)
                    let size: UInt64
                    if let prefetched = entry.values?.fileSize {
                        size = UInt64(prefetched)
                    } else {
                        size = FileOperations.fileSize(at: entry.url) ?? 0
                    }
                    if let min = minSize, size < min { continue }
                    if let max = maxSize, size > max { continue }

                    batch.append(FileInfo(
                        url: entry.url,
                        size: size,
                        relativePath: entry.relativePath,
                        modificationDate: entry.values?.contentModificationDate
                    ))
                }
                lock.lock()
                files.append(contentsOf: batch)
                for dir in subdirs { directoryRelativePaths.insert(dir.relativePath) }
                lock.unlock()
                counts.add(filesSlot, batch.count)
                counts.add(foldersSlot, subdirs.count)
                return subdirs
            }
        )

        // Directories finish in any order; a stable order keeps runs and logs predictable
        files.sort { $0.relativePath < $1.relativePath }
        return SourceEnumeration(
            files: files,
            directoryRelativePaths: directoryRelativePaths,
            unreadableDirectories: unreadable.sorted { $0.relativePath < $1.relativePath }
        )
    }
}
