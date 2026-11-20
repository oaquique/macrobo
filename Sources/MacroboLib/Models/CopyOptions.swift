import Foundation

/// Configuration options for the copy operation
public struct CopyOptions {
    // Source and destination
    public let source: URL
    public let destination: URL

    // Directory options
    public var includeEmptyDirectories: Bool = true
    public var mirror: Bool = false  // copy + delete extras
    public var purge: Bool = false   // delete dest files not in source, without copying
    public var allowMassDelete: Bool = false  // allow deleting from an empty source or more than half the destination
    public var skipHidden: Bool = false       // skip names starting with a dot

    // File comparison
    public var excludeOlder: Bool = false      // only copy if source is newer
    public var excludeExtra: Bool = false      // don't delete extra files in dest
    public var includeSame: Bool = false       // copy even if identical
    public var checksum: Bool = false          // Compare checksums when size matches but timestamps differ
    public var checksumFull: Bool = false      // Like checksum, but compare every byte instead of samples

    // Retry options
    public var retryCount: Int = 3          // retries after a failed copy
    public var retryWaitSeconds: Int = 5    // seconds between retries

    // Performance
    public var threadCount: Int = 8         // parallel copies
    public var resumePartial: Bool = true   // Resume interrupted copies

    // Filtering
    public var excludeFiles: [String] = []      // file name patterns to skip
    public var excludeDirectories: [String] = [] // folder name patterns to skip
    public var includeFiles: [String] = []       // only file names matching these
    public var maxFileSize: UInt64?              // bytes
    public var minFileSize: UInt64?              // bytes

    // Logging
    public var logFile: URL? = nil           // log file
    public var appendLog: Bool = false       // append to the log file
    public var verbose: Bool = false         // file-by-file output
    public var quiet: Bool = false           // no progress display

    // What to copy
    public var copyAttributes: Bool = true   // Copy file attributes
    public var copyTimestamps: Bool = true   // Copy timestamps
    public var copyPermissions: Bool = true  // Copy POSIX permissions
    public var copyExtendedAttributes: Bool = true  // macOS extended attributes

    // Move mode
    public var moveFiles: Bool = false       // delete each source file after copying it
    public var moveAll: Bool = false         // also remove source folders

    // Bandwidth
    public var bandwidthLimit: UInt64 = 0  // 0 = unlimited, bytes per second

    // Progress display
    public enum ProgressMode: String {
        case bar, json, none
    }
    public var progressMode: ProgressMode = .bar

    // Verification
    public var verify: Bool = false

    // Dry run
    public var dryRun: Bool = false          // list changes without making them

    /// Timestamps are kept unless --no-timestamps or --no-attributes ("attributes" means
    /// timestamps and permissions together)
    public var keepsTimestamps: Bool { copyAttributes && copyTimestamps }
    /// POSIX permissions are kept unless --no-permissions or --no-attributes
    public var keepsPermissions: Bool { copyAttributes && copyPermissions }

    /// Creates options from source and destination paths
    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    /// Validates the options
    public func validate() throws {
        // Source must exist and be readable. stat() tells "missing" apart from "can't open"
        // (a network share that denies access), which FileManager.fileExists does not.
        switch VolumeInfo.directoryProblem(at: source.path) {
        case nil: break
        case .missing: throw MacroboError.sourceNotFound(source.path)
        case .notDirectory: throw MacroboError.sourceNotDirectory(source.path)
        case .unreadable(let reason):
            throw MacroboError.cannotOpen(
                role: "source", path: source.path, reason: reason,
                networkType: VolumeInfo.networkFileSystemType(of: source.path)
            )
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
    /// The source or destination exists but can't be opened (e.g. a share that denies access)
    case cannotOpen(role: String, path: String, reason: String, networkType: String?)
    /// The destination couldn't be created
    case cannotCreateDestination(path: String, reason: String, unmountedVolume: Bool)
    /// The destination exists, but files can't be created in it
    case cannotWriteDestination(path: String, reason: String, unmountedVolume: Bool)
    /// One file couldn't be written at the destination, or read at the source
    case cannotCopyTo(path: String, reason: String)
    case cannotRead(path: String, reason: String)
    /// A folder couldn't be created at the destination
    case cannotCreateFolder(path: String, reason: String)
    /// A mirror or purge would delete too much; nothing was deleted
    case massDeleteBlocked(String)
    case copyFailed(String, Error)
    case deleteFailed(String, Error)
    case invalidThreadCount(Int)
    case invalidRetryCount(Int)
    case permissionDenied(String)
    case fileLocked(String)

    private static let unmountedHint = "\nIt's a folder on this Mac, not a mounted drive or share. Mount it and try again."

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Source not found: \(path)"
        case .sourceNotDirectory(let path):
            return "Source is not a directory: \(path)"
        case .cannotOpen(let role, let path, let reason, let networkType):
            var message = "Can't open the \(role) \(path): \(reason)"
            if let networkType {
                message += "\nIt's on a network share (\(networkType)). If the server was just updated or restarted,"
                message += "\nremount the share and try again."
            }
            return message
        case .cannotCreateDestination(let path, let reason, let unmountedVolume):
            return "Can't create the destination \(path): \(reason)" + (unmountedVolume ? Self.unmountedHint : "")
        case .cannotWriteDestination(let path, let reason, let unmountedVolume):
            return "Can't write to the destination \(path): \(reason)" + (unmountedVolume ? Self.unmountedHint : "")
        case .cannotCopyTo(let path, let reason):
            return "Can't copy to \(path): \(reason)"
        case .cannotRead(let path, let reason):
            return "Can't read \(path): \(reason)"
        case .cannotCreateFolder(let path, let reason):
            return "Can't create the folder \(path): \(reason)"
        case .massDeleteBlocked(let message):
            return message
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
