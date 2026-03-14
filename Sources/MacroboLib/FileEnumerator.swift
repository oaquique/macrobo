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

    /// Enumerates source files synchronously with filtering
    public static func enumerateSourceFiles(
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
