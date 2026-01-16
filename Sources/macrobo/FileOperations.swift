import Foundation

/// Low-level file operations with support for resumable copies and attribute preservation
struct FileOperations {
    private static let chunkSize: Int = 1024 * 1024  // 1MB chunks for streaming
    private static let partialSuffix = ".macrobo-partial"

    /// Copies a file with support for resume and progress reporting
    static func copyFile(
        from source: URL,
        to destination: URL,
        options: CopyOptions,
        progressHandler: ((UInt64, UInt64) async -> Void)? = nil
    ) async throws -> UInt64 {
        let fm = FileManager.default

        // Get source file attributes
        let sourceAttrs = try fm.attributesOfItem(atPath: source.path)
        guard let sourceSize = sourceAttrs[.size] as? UInt64 else {
            throw MacroboError.copyFailed(source.path, NSError(domain: "macrobo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot determine file size"]))
        }

        // Check for partial file and resume capability
        let partialPath = destination.path + partialSuffix
        let partialURL = URL(fileURLWithPath: partialPath)
        var resumeOffset: UInt64 = 0

        if options.resumePartial && fm.fileExists(atPath: partialPath) {
            let partialAttrs = try? fm.attributesOfItem(atPath: partialPath)
            if let partialSize = partialAttrs?[.size] as? UInt64, partialSize < sourceSize {
                resumeOffset = partialSize
            } else {
                try? fm.removeItem(atPath: partialPath)
            }
        }

        // For small files or no resume needed, use simple copy
        if resumeOffset == 0 && sourceSize < UInt64(chunkSize * 2) {
            try await simpleFileCopy(from: source, to: destination, options: options)
            // Report 100% progress for small files
            await progressHandler?(sourceSize, sourceSize)
            return sourceSize
        }

        // Streaming copy with resume support
        try await streamingCopy(
            from: source,
            to: partialURL,
            finalDestination: destination,
            sourceSize: sourceSize,
            resumeOffset: resumeOffset,
            progressHandler: progressHandler
        )

        // Copy attributes
        if options.copyAttributes || options.copyTimestamps || options.copyPermissions {
            try copyAttributes(from: source, to: destination, options: options)
        }

        // Copy extended attributes
        if options.copyExtendedAttributes {
            try copyExtendedAttributes(from: source, to: destination)
        }

        return sourceSize
    }

    /// Simple file copy using FileManager
    private static func simpleFileCopy(from source: URL, to destination: URL, options: CopyOptions) async throws {
        let fm = FileManager.default

        // Remove existing file if present
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        // Create parent directory if needed
        let parentDir = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Copy file
        try fm.copyItem(at: source, to: destination)

        // Adjust attributes if needed
        if options.copyAttributes || options.copyTimestamps || options.copyPermissions {
            try copyAttributes(from: source, to: destination, options: options)
        }

        if options.copyExtendedAttributes {
            try copyExtendedAttributes(from: source, to: destination)
        }
    }

    /// Streaming copy with progress and resume support
    private static func streamingCopy(
        from source: URL,
        to partialDest: URL,
        finalDestination: URL,
        sourceSize: UInt64,
        resumeOffset: UInt64,
        progressHandler: ((UInt64, UInt64) async -> Void)?
    ) async throws {
        let fm = FileManager.default

        // Create parent directory if needed
        let parentDir = partialDest.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Open source for reading using URL (preserves Unicode encoding)
        let sourceHandle: FileHandle
        do {
            sourceHandle = try FileHandle(forReadingFrom: source)
        } catch {
            throw MacroboError.copyFailed(source.lastPathComponent, error)
        }
        defer { try? sourceHandle.close() }

        // Open or create destination
        let destHandle: FileHandle
        if resumeOffset > 0 && fm.fileExists(atPath: partialDest.path) {
            do {
                destHandle = try FileHandle(forWritingTo: partialDest)
                try destHandle.seek(toOffset: resumeOffset)
                try sourceHandle.seek(toOffset: resumeOffset)
            } catch {
                throw MacroboError.copyFailed(partialDest.lastPathComponent, error)
            }
        } else {
            // Create empty file first
            fm.createFile(atPath: partialDest.path, contents: nil)
            do {
                destHandle = try FileHandle(forWritingTo: partialDest)
            } catch {
                throw MacroboError.copyFailed(partialDest.lastPathComponent, error)
            }
        }
        defer { try? destHandle.close() }

        // Copy in chunks
        var totalWritten = resumeOffset
        while true {
            autoreleasepool {
                let chunk = sourceHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    return
                }
                destHandle.write(chunk)
                totalWritten += UInt64(chunk.count)
            }

            await progressHandler?(totalWritten, sourceSize)

            if totalWritten >= sourceSize {
                break
            }
        }

        try destHandle.synchronize()

        // Rename partial to final destination
        if fm.fileExists(atPath: finalDestination.path) {
            try fm.removeItem(at: finalDestination)
        }
        try fm.moveItem(at: partialDest, to: finalDestination)
    }

    /// Copies file attributes (timestamps, permissions)
    static func copyAttributes(from source: URL, to destination: URL, options: CopyOptions) throws {
        let fm = FileManager.default
        let sourceAttrs = try fm.attributesOfItem(atPath: source.path)
        var destAttrs: [FileAttributeKey: Any] = [:]

        if options.copyTimestamps {
            if let modDate = sourceAttrs[.modificationDate] {
                destAttrs[.modificationDate] = modDate
            }
            if let createDate = sourceAttrs[.creationDate] {
                destAttrs[.creationDate] = createDate
            }
        }

        if options.copyPermissions {
            if let posixPerms = sourceAttrs[.posixPermissions] {
                destAttrs[.posixPermissions] = posixPerms
            }
        }

        if !destAttrs.isEmpty {
            try fm.setAttributes(destAttrs, ofItemAtPath: destination.path)
        }
    }

    /// Copies extended attributes (macOS-specific)
    static func copyExtendedAttributes(from source: URL, to destination: URL) throws {
        // List extended attributes on source
        let names = try listExtendedAttributes(at: source)

        for name in names {
            if let value = try getExtendedAttribute(name: name, at: source) {
                try setExtendedAttribute(name: name, value: value, at: destination)
            }
        }
    }

    /// Lists extended attribute names
    static func listExtendedAttributes(at url: URL) throws -> [String] {
        let path = url.path
        let length = listxattr(path, nil, 0, 0)
        guard length >= 0 else {
            if errno == ENOTSUP || errno == EPERM {
                return []  // Extended attributes not supported
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard length > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: length)
        let result = listxattr(path, &buffer, length, 0)
        guard result >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Parse null-separated list
        var names: [String] = []
        var start = 0
        for i in 0..<result {
            if buffer[i] == 0 {
                let name = String(cString: Array(buffer[start..<i]) + [0])
                names.append(name)
                start = i + 1
            }
        }
        return names
    }

    /// Gets an extended attribute value
    static func getExtendedAttribute(name: String, at url: URL) throws -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length >= 0 else {
            if errno == ENOATTR || errno == ENOTSUP {
                return nil
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard length > 0 else { return Data() }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = getxattr(path, name, &buffer, length, 0, 0)
        guard result >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        return Data(buffer[0..<result])
    }

    /// Sets an extended attribute value
    static func setExtendedAttribute(name: String, value: Data, at url: URL) throws {
        let path = url.path
        try value.withUnsafeBytes { buffer in
            let result = setxattr(path, name, buffer.baseAddress, value.count, 0, 0)
            guard result == 0 else {
                if errno != ENOTSUP && errno != EPERM {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return
            }
        }
    }

    /// Gets file size
    static func fileSize(at url: URL) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? UInt64
    }

    /// Gets modification date
    static func modificationDate(at url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Checks if source is newer than destination
    static func isSourceNewer(source: URL, destination: URL) -> Bool {
        guard let sourceDate = modificationDate(at: source),
              let destDate = modificationDate(at: destination) else {
            return true  // Assume source is newer if we can't determine
        }
        return sourceDate > destDate
    }

    /// Checks if source and destination are identical (same size and modification time)
    /// This mirrors robocopy's default behavior of skipping "Same" files
    static func areFilesIdentical(source: URL, destination: URL) -> Bool {
        guard let sourceSize = fileSize(at: source),
              let destSize = fileSize(at: destination),
              let sourceDate = modificationDate(at: source),
              let destDate = modificationDate(at: destination) else {
            return false  // Assume different if we can't determine
        }
        // Compare size and modification time (within 1 second tolerance for filesystem differences)
        return sourceSize == destSize && abs(sourceDate.timeIntervalSince(destDate)) < 1.0
    }

    /// Deletes a file with retry
    static func deleteFile(at url: URL, retryCount: Int = 3, retryWait: Int = 1) async throws {
        var lastError: Error?

        for attempt in 0..<max(1, retryCount) {
            do {
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                lastError = error
                if attempt < retryCount - 1 {
                    try await Task.sleep(nanoseconds: UInt64(retryWait) * 1_000_000_000)
                }
            }
        }

        throw MacroboError.deleteFailed(url.path, lastError ?? NSError(domain: "macrobo", code: 5))
    }
}
