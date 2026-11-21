import Foundation

/// Result of a single file operation
public enum FileOperationResult {
    case copied(source: URL, destination: URL, bytes: UInt64)
    case skipped(source: URL, reason: SkipReason, bytes: UInt64)
    case deleted(path: URL)
    case failed(path: URL, error: Error)
    case directoryCreated(path: URL)
    case directoryDeleted(path: URL)

    public enum SkipReason: CustomStringConvertible {
        case alreadyExists
        case newerAtDestination
        case excludedByPattern
        case sizeOutOfRange
        case dryRun

        public var description: String {
            switch self {
            case .alreadyExists: return "already exists"
            case .newerAtDestination: return "destination is newer"
            case .excludedByPattern: return "excluded by pattern"
            case .sizeOutOfRange: return "size out of range"
            case .dryRun: return "dry run"
            }
        }
    }
}

/// Aggregate result of the entire copy operation
public struct CopyResult {
    public var filesCopied: Int = 0
    public var filesSkipped: Int = 0
    public var filesFailed: Int = 0
    public var filesDeleted: Int = 0
    public var directoriesCreated: Int = 0
    public var directoriesDeleted: Int = 0
    public var bytesCopied: UInt64 = 0
    public var bytesSkipped: UInt64 = 0
    public var errors: [(path: String, error: Error)] = []
    /// Source files not copied because another one has the same name at the destination
    public var nameClashes: [NameClash] = []
    /// Why those names clash ("the destination ignores capital letters, so only one fits")
    public var nameClashReason = ""
    public var startTime: Date = Date()
    public var endTime: Date?

    // Dry run: what a real run would do
    public var isDryRun = false
    public var showsCopies = true
    public var showsDeletes = false
    public var wouldCopyFiles = 0
    public var wouldCopyBytes: UInt64 = 0
    public var wouldCopyFolders = 0
    public var wouldDeleteFiles = 0
    public var wouldDeleteFolders = 0
    public var unchangedFiles = 0
    /// Leftover partial files from interrupted copies a run would remove
    public var wouldRemoveLeftovers = 0

    /// Time spent copying, for the speed; nil when nothing was copied
    public var copyDuration: TimeInterval?

    public init() {}

    /// Total files processed
    public var totalFiles: Int {
        filesCopied + filesSkipped + filesFailed
    }

    /// Duration of the operation
    public var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    /// Copy speed in bytes per second, over the copying alone (not listing or checksumming),
    /// so it matches the speed on the copy progress line
    public var bytesPerSecond: Double {
        guard let copyDuration, copyDuration > 0 else { return 0 }
        return Double(bytesCopied) / copyDuration
    }

    /// Formatted summary string
    public var summary: String {
        let separator = String(repeating: "─", count: 60)

        // Helper to right-align label and add colon (aligns colons at column 25)
        func row(_ label: String, _ value: String) -> String {
            let width = 23
            let padding = String(repeating: " ", count: max(0, width - label.count))
            return " \(padding)\(label): \(value)"
        }

        var lines: [String] = []
        lines.append("")
        lines.append(separator)
        lines.append("                    macrobo Summary")
        lines.append(separator)
        lines.append("")

        if isDryRun {
            if showsCopies {
                var copy = "\(formatCount(wouldCopyFiles, "file")) (\(formatBytes(wouldCopyBytes, precision: 1)))"
                if wouldCopyFolders > 0 { copy += ", \(formatCount(wouldCopyFolders, "empty folder"))" }
                lines.append(row("Would copy", copy))
            }
            if showsDeletes {
                lines.append(row("Would delete", "\(formatCount(wouldDeleteFiles, "file")), \(formatCount(wouldDeleteFolders, "folder"))"))
            }
            if showsCopies {
                lines.append(row("Unchanged", formatCount(unchangedFiles, "file")))
            }
            if !nameClashes.isEmpty {
                lines.append(row("Name clashes", "\(formatCount(nameClashes.count)) (would not be copied)"))
            }
            if wouldRemoveLeftovers > 0 {
                lines.append(row("Would remove", formatCount(wouldRemoveLeftovers, "leftover partial file")))
            }
            lines.append("")
        } else if !showsCopies {
            // Delete only (--purge): nothing is copied, so copy rows would only show zeros
            if directoriesCreated > 0 {
                lines.append(row("Directories created", formatCount(directoriesCreated)))
            }
            lines.append(row("Directories deleted", formatCount(directoriesDeleted)))
            lines.append(row("Files deleted", formatCount(filesDeleted)))
            if filesFailed > 0 {
                lines.append(row("Files failed", formatCount(filesFailed)))
            }
            lines.append("")
            lines.append(row("Duration", formatDuration(duration)))
            lines.append("")
        } else {
            // Directories section
            lines.append(row("Directories created", formatCount(directoriesCreated)))
            if directoriesDeleted > 0 {
                lines.append(row("Directories deleted", formatCount(directoriesDeleted)))
            }
            lines.append("")

            // Files section
            lines.append(row("Files copied", formatCount(filesCopied)))
            lines.append(row("Files skipped", formatCount(filesSkipped)))
            if !nameClashes.isEmpty {
                lines.append(row("Name clashes", "\(formatCount(nameClashes.count)) (not copied)"))
            }
            if filesFailed > 0 {
                lines.append(row("Files failed", formatCount(filesFailed)))
            }
            if filesDeleted > 0 {
                lines.append(row("Files deleted", formatCount(filesDeleted)))
            }
            lines.append("")

            // Stats section
            lines.append(row("Bytes copied", formatBytes(bytesCopied)))
            if bytesSkipped > 0 {
                lines.append(row("Bytes skipped", formatBytes(bytesSkipped)))
            }
            if bytesCopied > 0 {
                lines.append(row("Speed", "\(formatBytes(UInt64(bytesPerSecond)))/s"))
            }
            lines.append(row("Duration", formatDuration(duration)))
            lines.append("")
        }

        // Name clashes: the file left out and the one copied in its place
        if !nameClashes.isEmpty {
            lines.append(" Name clashes (\(nameClashReason)):")
            for clash in nameClashes.prefix(10) {
                lines.append("   Not copied:   " + String(clash.path.dropFirst()))
                lines.append("   Same name as: " + String(clash.sameAs.dropFirst()))
            }
            if nameClashes.count > 10 {
                lines.append("   ... and \(formatCount(nameClashes.count - 10, "more name clash", "more name clashes"))")
            }
            lines.append("")
        }

        // Errors section
        if !errors.isEmpty {
            lines.append(" Errors:")
            for (path, error) in errors.prefix(10) {
                lines.append("   " + Self.failureText(path: path, error: error))
            }
            if errors.count > 10 {
                lines.append("   ... and \(formatCount(errors.count - 10, "more error"))")
            }
            lines.append("")
        }

        lines.append(separator)
        return lines.joined(separator: "\n")
    }

    /// One failure for the screen and the log. macrobo's own errors already name their full
    /// path ("Can't copy to /a/b: Permission denied"); anything else gets the path in front.
    public static func failureText(path: String, error: Error) -> String {
        error is MacroboError ? error.localizedDescription : "\(path): \(error.localizedDescription)"
    }

    /// Records a file operation result
    public mutating func record(_ result: FileOperationResult) {
        switch result {
        case .copied(_, _, let bytes):
            filesCopied += 1
            bytesCopied += bytes
        case .skipped(_, _, let bytes):
            filesSkipped += 1
            bytesSkipped += bytes
        case .deleted(_):
            filesDeleted += 1
        case .failed(let path, let error):
            filesFailed += 1
            errors.append((path.path, error))
        case .directoryCreated(_):
            directoriesCreated += 1
        case .directoryDeleted(_):
            directoriesDeleted += 1
        }
    }

    /// Marks the operation as complete
    public mutating func finish() {
        endTime = Date()
    }
}
