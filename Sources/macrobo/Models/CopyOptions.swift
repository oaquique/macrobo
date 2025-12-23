import Foundation

/// Configuration options for the copy operation
struct CopyOptions {
    // Source and destination
    let source: URL
    let destination: URL

    // Directory options
    var includeSubdirectories: Bool = true
    var includeEmptyDirectories: Bool = true
    var mirror: Bool = false  // /MIR - copy + purge
    var purge: Bool = false   // /PURGE - delete dest files not in source

    // File comparison
    var excludeOlder: Bool = false      // /XO - only copy if source is newer
    var excludeExtra: Bool = false      // /XX - don't delete extra files in dest
    var excludeChanged: Bool = false    // /XC - exclude changed files
    var excludeNewer: Bool = false      // /XN - exclude newer files

    // Retry options
    var retryCount: Int = 3          // /R:n
    var retryWaitSeconds: Int = 5    // /W:n

    // Performance
    var threadCount: Int = 8         // /MT:n
    var resumePartial: Bool = true   // Resume interrupted copies

    // Filtering
    var excludeFiles: [String] = []      // /XF patterns
    var excludeDirectories: [String] = [] // /XD patterns
    var includeFiles: [String] = []       // /IF patterns
    var maxFileSize: UInt64?              // /MAXSIZE:n bytes
    var minFileSize: UInt64?              // /MINSIZE:n bytes

    // Logging
    var logFile: URL? = nil           // /LOG:file
    var appendLog: Bool = false       // /LOG+:file
    var verbose: Bool = false         // /V
    var quiet: Bool = false           // /NP - no progress

    // What to copy
    var copyAttributes: Bool = true   // Copy file attributes
    var copyTimestamps: Bool = true   // Copy timestamps
    var copyPermissions: Bool = true  // Copy POSIX permissions
    var copyExtendedAttributes: Bool = true  // macOS extended attributes

    // Move mode
    var moveFiles: Bool = false       // /MOV - move files
    var moveAll: Bool = false         // /MOVE - move files and dirs

    // Dry run
    var dryRun: Bool = false          // /L - list only

    /// Creates options from source and destination paths
    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    /// Validates the options
    func validate() throws {
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
enum MacroboError: Error, LocalizedError {
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case destinationCreationFailed(String)
    case copyFailed(String, Error)
    case deleteFailed(String, Error)
    case invalidThreadCount(Int)
    case invalidRetryCount(Int)
    case permissionDenied(String)
    case fileLocked(String)

    var errorDescription: String? {
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
