import Foundation

/// Configuration options for the copy operation
public struct CopyOptions {
    // Source and destination
    public let source: URL
    public let destination: URL

    // Directory options
    public var includeEmptyDirectories: Bool = true
    public var mirror: Bool = false  // /MIR - copy + purge
    public var purge: Bool = false   // /PURGE - delete dest files not in source

    // File comparison
    public var excludeOlder: Bool = false      // /XO - only copy if source is newer
    public var excludeExtra: Bool = false      // /XX - don't delete extra files in dest
    public var includeSame: Bool = false       // /IS - include same files (force copy even if identical)
    public var checksum: Bool = false          // Compare checksums when size matches but timestamps differ

    // Retry options
    public var retryCount: Int = 3          // /R:n
    public var retryWaitSeconds: Int = 5    // /W:n

    // Performance
    public var threadCount: Int = 8         // /MT:n
    public var resumePartial: Bool = true   // Resume interrupted copies

    // Filtering
    public var excludeFiles: [String] = []      // /XF patterns
    public var excludeDirectories: [String] = [] // /XD patterns
    public var includeFiles: [String] = []       // /IF patterns
    public var maxFileSize: UInt64?              // /MAXSIZE:n bytes
    public var minFileSize: UInt64?              // /MINSIZE:n bytes

    // Logging
    public var logFile: URL? = nil           // /LOG:file
    public var appendLog: Bool = false       // /LOG+:file
    public var verbose: Bool = false         // /V
    public var quiet: Bool = false           // /NP - no progress

    // What to copy
    public var copyAttributes: Bool = true   // Copy file attributes
    public var copyTimestamps: Bool = true   // Copy timestamps
    public var copyPermissions: Bool = true  // Copy POSIX permissions
    public var copyExtendedAttributes: Bool = true  // macOS extended attributes

    // Move mode
    public var moveFiles: Bool = false       // /MOV - move files
    public var moveAll: Bool = false         // /MOVE - move files and dirs

    // Bandwidth
    public var bandwidthLimit: UInt64 = 0  // 0 = unlimited, bytes per second

    // Progress display
    public enum ProgressMode: String {
        case bar, json, none
    }
    public var progressMode: ProgressMode = .bar

    // Dry run
    public var dryRun: Bool = false          // /L - list only

    /// Creates options from source and destination paths
    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    /// Validates the options
    public func validate() throws {
        let fm = FileManager.default

        // Source must exist
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw MacroboError.sourceNotFound(source.path)
        }
        guard isDir.boolValue else {
            throw MacroboError.sourceNotDirectory(source.path)
        }

        // Thread count must be positive
        guard threadCount > 0 else {
            throw MacroboError.invalidThreadCount(threadCount)
        }

        // Retry count must be non-negative
        guard retryCount >= 0 else {
            throw MacroboError.invalidRetryCount(retryCount)
        }
    }
}

/// Errors that can occur during macrobo operations
public enum MacroboError: Error, LocalizedError {
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case destinationCreationFailed(String)
    case copyFailed(String, Error)
    case deleteFailed(String, Error)
    case invalidThreadCount(Int)
    case invalidRetryCount(Int)
    case permissionDenied(String)
    case fileLocked(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Source not found: \(path)"
        case .sourceNotDirectory(let path):
            return "Source is not a directory: \(path)"
        case .destinationCreationFailed(let path):
            return "Failed to create destination: \(path)"
        case .copyFailed(let path, let error):
            return "Failed to copy \(path): \(error.localizedDescription)"
        case .deleteFailed(let path, let error):
            return "Failed to delete \(path): \(error.localizedDescription)"
        case .invalidThreadCount(let count):
            return "Invalid thread count: \(count). Must be greater than 0."
        case .invalidRetryCount(let count):
            return "Invalid retry count: \(count). Must be non-negative."
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .fileLocked(let path):
            return "File is locked: \(path)"
        }
    }
}
