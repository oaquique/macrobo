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

    /// Builds a relative path ("/a/b/file") from the last `level` components of a URL
    /// returned by a directory enumerator. Pure string work: no file system calls.
    static func relativePath(of url: URL, level: Int) -> String {
        let components = url.pathComponents
        guard level > 0, components.count > level else { return "/" + url.lastPathComponent }
        return "/" + components.suffix(level).joined(separator: "/")
    }

    /// Enumerates source files synchronously with filtering, also returning walked directories
    public static func enumerateSource(
        source: URL,
        skipHidden: Bool,
        excludeDirs: [String],
        excludeFiles: [String],
        includeFiles: [String],
        minSize: UInt64?,
        maxSize: UInt64?
    ) throws -> SourceEnumeration {
        let fm = FileManager.default
        var files: [FileInfo] = []
        var directoryRelativePaths: Set<String> = []

        // Pre-compile all glob patterns once (instead of per-file)
        let excludeDirRegexes = excludeDirs.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let excludeFileRegexes = excludeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }
        let includeFileRegexes = includeFiles.map { (pattern: $0, regex: compileGlobPattern($0)) }

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
            // Served from the values the enumerator prefetched: no extra file system call
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])

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
                directoryRelativePaths.insert(relativePath(of: url, level: enumerator.level))
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

            // Check size constraints (fall back to a stat only if the prefetched size is missing)
            let actualSize: UInt64
            if let prefetched = resourceValues?.fileSize {
                actualSize = UInt64(prefetched)
            } else {
                actualSize = FileOperations.fileSize(at: url) ?? 0
            }

            if let min = minSize, actualSize < min { continue }
            if let max = maxSize, actualSize > max { continue }

            // Relative path from the enumerator depth. The enumerator never descends into
            // symlinked directories, so this equals the old "resolved path minus resolved
            // source root" result without resolving symlinks for every file.
            files.append(FileInfo(
                url: url,
                size: actualSize,
                relativePath: relativePath(of: url, level: enumerator.level),
                modificationDate: resourceValues?.contentModificationDate
            ))
        }

        return SourceEnumeration(files: files, directoryRelativePaths: directoryRelativePaths)
    }
}
