import Foundation

/// Result of a single file operation
public enum FileOperationResult {
    case copied(source: URL, destination: URL, bytes: UInt64)
    case skipped(source: URL, reason: SkipReason, bytes: UInt64)
    case deleted(path: URL)
    case failed(path: URL, error: Error)
    case directoryCreated(path: URL)

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
    public var startTime: Date = Date()
    public var endTime: Date?

    public init() {}

    /// Total files processed
    public var totalFiles: Int {
        filesCopied + filesSkipped + filesFailed
    }

    /// Duration of the operation
    public var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    /// Copy speed in bytes per second
    public var bytesPerSecond: Double {
        guard duration > 0 else { return 0 }
        return Double(bytesCopied) / duration
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

        // Directories section
        lines.append(row("Directories created", "\(directoriesCreated)"))
        if directoriesDeleted > 0 {
            lines.append(row("Directories deleted", "\(directoriesDeleted)"))
        }
        lines.append("")

        // Files section
        lines.append(row("Files copied", "\(filesCopied)"))
        lines.append(row("Files skipped", "\(filesSkipped)"))
        if filesFailed > 0 {
            lines.append(row("Files failed", "\(filesFailed)"))
        }
        if filesDeleted > 0 {
            lines.append(row("Files deleted", "\(filesDeleted)"))
        }
        lines.append("")

        // Stats section
        lines.append(row("Bytes copied", formatBytes(bytesCopied)))
        if bytesSkipped > 0 {
            lines.append(row("Bytes skipped", formatBytes(bytesSkipped)))
        }
        lines.append(row("Speed", "\(formatBytes(UInt64(bytesPerSecond)))/s"))
        lines.append(row("Duration", formatDuration(duration)))
        lines.append("")

        // Errors section
        if !errors.isEmpty {
            lines.append(" Errors:")
            for (path, error) in errors.prefix(10) {
                lines.append("   \(path): \(error.localizedDescription)")
            }
            if errors.count > 10 {
                lines.append("   ... and \(errors.count - 10) more errors")
            }
            lines.append("")
        }

        lines.append(separator)
        return lines.joined(separator: "\n")
    }

    /// Format duration for display
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1f seconds", seconds)
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return "\(hours)h \(mins)m"
        }
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
        }
    }

    /// Marks the operation as complete
    public mutating func finish() {
        endTime = Date()
    }
}
