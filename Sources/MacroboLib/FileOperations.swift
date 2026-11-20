import CryptoKit
import Foundation

/// Low-level file operations with support for resumable copies and attribute preservation
public struct FileOperations {
    private static let chunkSize: Int = 1024 * 1024  // 1MB chunks for streaming
    public static let partialSuffix = ".macrobo-partial"
    private static let nocacheThreshold: UInt64 = 10 * 1024 * 1024  // 10MB

    /// Checks if two paths are on the same APFS volume. Runs once per copied file, so it uses
    /// statfs (one system call) rather than URL volume resource values, which query IOKit for
    /// the volume's format and encryption state and dominated the time to copy small files.
    /// The destination's folder may not exist yet: its nearest existing ancestor decides.
    public static func isSameAPFSVolume(source: String, destination: String) -> Bool {
        var src = statfs()
        guard statfs(source, &src) == 0, fsTypeName(src) == "apfs" else { return false }

        var dir = (destination as NSString).deletingLastPathComponent
        var dst = statfs()
        while statfs(dir, &dst) != 0 {
            guard errno == ENOENT, dir != "/", !dir.isEmpty else { return false }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return fsTypeName(dst) == "apfs"
            && src.f_fsid.val.0 == dst.f_fsid.val.0
            && src.f_fsid.val.1 == dst.f_fsid.val.1
    }

    private static func fsTypeName(_ info: statfs) -> String {
        var copy = info
        return withUnsafeBytes(of: &copy.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// A partial file untouched this long is left over from an interrupted copy; a copy in
    /// progress writes to its partial file all the time
    static let leftoverPartialAge: TimeInterval = 600

    /// The leftover partial file next to a destination file, or nil if there is none. Called
    /// only for files found complete, so the partial is no longer needed.
    static func leftoverPartial(forDestination path: String) -> String? {
        let partial = path + partialSuffix
        guard let attrs = DestinationComparator.destinationAttributes(atPath: partial),
              Date().timeIntervalSince(attrs.modificationDate) > leftoverPartialAge else { return nil }
        return partial
    }

    /// Where to resume an interrupted copy, or nil to start over. Only a partial file shorter
    /// than the source and written after the source last changed is resumed: one started
    /// before the source was edited holds old bytes, and appending to it would mix two versions.
    static func resumableOffset(
        partialSize: UInt64?, partialModified: Date?, sourceSize: UInt64, sourceModified: Date?
    ) -> UInt64? {
        guard let partialSize, partialSize > 0, partialSize < sourceSize,
              let partialModified, let sourceModified, partialModified >= sourceModified else { return nil }
        return partialSize
    }

    /// Attempts an APFS clone. Returns true if successful, false if fallback needed.
    public static func tryCloneFile(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        let result = source.path.withCString { srcPath in
            destination.path.withCString { dstPath in
                Darwin.clonefile(srcPath, dstPath, UInt32(CLONE_NOFOLLOW))
            }
        }
        if result == 0 { return true }
        return false
    }

    /// Copies a file with support for resume and progress reporting
    public static func copyFile(
        from source: URL,
        to destination: URL,
        options: CopyOptions,
        rateLimiter: RateLimiter? = nil,
        progressHandler: ((UInt64, UInt64) async -> Void)? = nil,
        syncHandler: (() async -> Void)? = nil
    ) async throws -> UInt64 {
        let fm = FileManager.default

        // Get source file attributes
        let sourceAttrs = try fm.attributesOfItem(atPath: source.path)
        guard let sourceSize = sourceAttrs[.size] as? UInt64 else {
            throw MacroboError.copyFailed(source.path, NSError(domain: "macrobo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot determine file size"]))
        }

        // APFS clone fast path: instant copy-on-write for same-volume copies
        if isSameAPFSVolume(source: source.path, destination: destination.path) {
            let parentDir = destination.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if tryCloneFile(from: source, to: destination) {
                // A partial file from an interrupted earlier copy is no longer needed
                try? fm.removeItem(atPath: destination.path + partialSuffix)
                removeOmittedMetadata(at: destination, options: options)
                await progressHandler?(sourceSize, sourceSize)
                return sourceSize
            }
        }

        // Check for partial file and resume capability
        let partialPath = destination.path + partialSuffix
        let partialURL = URL(fileURLWithPath: partialPath)
        var resumeOffset: UInt64 = 0

        if fm.fileExists(atPath: partialPath) {
            let partialAttrs = try? fm.attributesOfItem(atPath: partialPath)
            if options.resumePartial, let offset = resumableOffset(
                partialSize: partialAttrs?[.size] as? UInt64,
                partialModified: partialAttrs?[.modificationDate] as? Date,
                sourceSize: sourceSize,
                sourceModified: sourceAttrs[.modificationDate] as? Date
            ) {
                resumeOffset = offset
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
        // Only fsync before rename when in move mode (source will be deleted after copy)
        let needsSync = options.moveFiles || options.moveAll
        try await streamingCopy(
            from: source,
            to: partialURL,
            finalDestination: destination,
            sourceSize: sourceSize,
            resumeOffset: resumeOffset,
            syncBeforeRename: needsSync,
            rateLimiter: rateLimiter,
            progressHandler: progressHandler,
            syncHandler: syncHandler
        )

        // Copy attributes
        if options.keepsTimestamps || options.keepsPermissions {
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

        // Copy file (FileManager carries timestamps, permissions and extended attributes over)
        try fm.copyItem(at: source, to: destination)
        removeOmittedMetadata(at: destination, options: options)
    }

    /// Streaming copy with progress and resume support
    private static func streamingCopy(
        from source: URL,
        to partialDest: URL,
        finalDestination: URL,
        sourceSize: UInt64,
        resumeOffset: UInt64,
        syncBeforeRename: Bool,
        rateLimiter: RateLimiter? = nil,
        progressHandler: ((UInt64, UInt64) async -> Void)?,
        syncHandler: (() async -> Void)?
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

        if sourceSize >= nocacheThreshold {
            _ = fcntl(sourceHandle.fileDescriptor, F_NOCACHE, 1)
        }

        // Open or create destination
        let destHandle: FileHandle
        if resumeOffset > 0 && fm.fileExists(atPath: partialDest.path) {
            do {
                let handle = try FileHandle(forWritingTo: partialDest)
                do {
                    try handle.seek(toOffset: resumeOffset)
                    try sourceHandle.seek(toOffset: resumeOffset)
                } catch {
                    try? handle.close()
                    throw MacroboError.copyFailed(partialDest.lastPathComponent, error)
                }
                destHandle = handle
            } catch let error as MacroboError {
                throw error
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

        if sourceSize >= nocacheThreshold {
            _ = fcntl(destHandle.fileDescriptor, F_NOCACHE, 1)
        }

        // Copy in chunks using modern Swift-throwing APIs
        // Note: The legacy readData(ofLength:) and write(_:) throw NSExceptions
        // which Swift cannot catch. Using read(upToCount:) and write(contentsOf:)
        // throws Swift errors that we can properly handle.
        var totalWritten = resumeOffset
        while true {
            do {
                guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }
                try destHandle.write(contentsOf: chunk)
                if let limiter = rateLimiter {
                    await limiter.acquire(chunk.count)
                }
                totalWritten += UInt64(chunk.count)
            } catch {
                throw MacroboError.copyFailed(source.lastPathComponent, error)
            }

            await progressHandler?(totalWritten, sourceSize)

            if totalWritten >= sourceSize {
                break
            }
        }

        // Flush the destination to durable storage before renaming and stamping
        // attributes. Required for network filesystems (SMB/NFS) with delayed
        // write-back: if buffered data is committed by the server AFTER copyFile()
        // sets the mtime via copyAttributes(), the server bumps the mtime to
        // commit-time, so the file fails the size+mtime "identical" check on the
        // next run and is needlessly re-copied. fsync here forces the commit to
        // happen now, making the later mtime stamp final.
        try destHandle.synchronize()
        if syncBeforeRename {
            await syncHandler?()
        }

        // Rename partial to final destination
        if fm.fileExists(atPath: finalDestination.path) {
            try fm.removeItem(at: finalDestination)
        }
        try fm.moveItem(at: partialDest, to: finalDestination)
    }

    /// Copies file attributes (timestamps, permissions)
    public static func copyAttributes(from source: URL, to destination: URL, options: CopyOptions) throws {
        let fm = FileManager.default
        let sourceAttrs = try fm.attributesOfItem(atPath: source.path)
        var destAttrs: [FileAttributeKey: Any] = [:]

        if options.keepsTimestamps {
            if let modDate = sourceAttrs[.modificationDate] {
                destAttrs[.modificationDate] = modDate
            }
            if let createDate = sourceAttrs[.creationDate] {
                destAttrs[.creationDate] = createDate
            }
        }

        if options.keepsPermissions {
            if let posixPerms = sourceAttrs[.posixPermissions] {
                destAttrs[.posixPermissions] = posixPerms
            }
        }

        if !destAttrs.isEmpty {
            try fm.setAttributes(destAttrs, ofItemAtPath: destination.path)
        }
    }

    /// Permissions a newly created file gets under this process's umask (0644 with the usual
    /// 022). Read once at startup: umask() can only be read by setting it, which isn't
    /// safe while other threads create files.
    public static let defaultFileMode: Int = {
        let mask = umask(0)
        umask(mask)
        return 0o666 & ~Int(mask)
    }()

    /// clonefile and FileManager.copyItem carry every piece of metadata over. Takes off what the
    /// options leave out (--no-timestamps, --no-permissions, --no-attributes, --no-xattr), so
    /// every copy path follows the same options. Best effort: the contents are already copied.
    static func removeOmittedMetadata(at destination: URL, options: CopyOptions) {
        if !options.copyExtendedAttributes, let names = try? listExtendedAttributes(at: destination) {
            for name in names {
                _ = removexattr(destination.path, name, XATTR_NOFOLLOW)
            }
        }
        var attributes: [FileAttributeKey: Any] = [:]
        if !options.keepsTimestamps {
            let now = Date()
            attributes[.modificationDate] = now
            attributes[.creationDate] = now
        }
        if !options.keepsPermissions {
            attributes[.posixPermissions] = defaultFileMode
        }
        if !attributes.isEmpty {
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: destination.path)
        }
    }

    /// Copies extended attributes (macOS-specific)
    public static func copyExtendedAttributes(from source: URL, to destination: URL) throws {
        // List extended attributes on source
        let names = try listExtendedAttributes(at: source)

        for name in names {
            if let value = try getExtendedAttribute(name: name, at: source) {
                try setExtendedAttribute(name: name, value: value, at: destination)
            }
        }
    }

    /// Lists extended attribute names
    public static func listExtendedAttributes(at url: URL) throws -> [String] {
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
    public static func getExtendedAttribute(name: String, at url: URL) throws -> Data? {
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
    public static func setExtendedAttribute(name: String, value: Data, at url: URL) throws {
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
    public static func fileSize(at url: URL) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? UInt64
    }

    /// Gets modification date
    public static func modificationDate(at url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private static let sampleSize = 4096  // 4KB samples for lightweight checksum

    /// Computes a lightweight SHA256 checksum by reading small samples from the first, middle,
    /// and last 4KB of a file. Total I/O per file is ~12KB regardless of file size, making this
    /// safe for network volumes. For files smaller than 12KB, reads the entire file.
    public static func checksumFile(at url: URL, fileSize: UInt64? = nil) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = fileSize ?? (self.fileSize(at: url) ?? 0)
        let sample = UInt64(sampleSize)

        var hasher = SHA256()

        // For small files (< 3 samples), just read the whole thing
        if size <= sample * 3 {
            while let data = try handle.read(upToCount: sampleSize), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize()
        }

        // Read first 4KB
        if let data = try handle.read(upToCount: sampleSize), !data.isEmpty {
            hasher.update(data: data)
        }

        // Seek to middle and read 4KB
        let middleOffset = (size - sample) / 2
        try handle.seek(toOffset: middleOffset)
        if let data = try handle.read(upToCount: sampleSize), !data.isEmpty {
            hasher.update(data: data)
        }

        // Seek to end and read last 4KB
        let endOffset = size - sample
        try handle.seek(toOffset: endOffset)
        if let data = try handle.read(upToCount: sampleSize), !data.isEmpty {
            hasher.update(data: data)
        }

        return hasher.finalize()
    }

    /// Computes a full SHA256 checksum of the entire file contents
    public static func fullChecksumFile(at url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    /// Checks whether two same-sized files have identical contents. Compares the first, middle
    /// and last 4KB of each (~24KB of reads, so a network volume costs round trips, not bandwidth).
    /// With `full`, files whose samples match are then compared byte for byte, stopping at the
    /// first difference. A file that can't be read counts as different (it gets copied).
    public static func areFileContentsIdentical(source: URL, destination: URL, sourceSize: UInt64? = nil, full: Bool = false) -> Bool {
        let size = sourceSize ?? fileSize(at: source)
        guard let srcHash = try? checksumFile(at: source, fileSize: size),
              let dstHash = try? checksumFile(at: destination, fileSize: size) else {
            return false
        }
        guard srcHash == dstHash else { return false }
        // Small files were read whole by the sample pass
        guard full, let size, size > UInt64(sampleSize * 3) else { return true }
        return (try? fullContentsEqual(source, destination)) ?? false
    }

    /// Streams both files side by side and compares every byte, stopping at the first difference.
    /// Large files bypass the page cache so a big pass doesn't evict everything else.
    static func fullContentsEqual(_ a: URL, _ b: URL) throws -> Bool {
        let fdA = open(a.path, O_RDONLY)
        guard fdA >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fdA) }
        let fdB = open(b.path, O_RDONLY)
        guard fdB >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fdB) }
        if (fileSize(at: a) ?? 0) >= nocacheThreshold {
            _ = fcntl(fdA, F_NOCACHE, 1)
            _ = fcntl(fdB, F_NOCACHE, 1)
        }

        let bufferSize = chunkSize * 4
        let bufA = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        let bufB = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { bufA.deallocate(); bufB.deallocate() }

        while true {
            let readA = readFully(fdA, bufA, bufferSize)
            let readB = readFully(fdB, bufB, bufferSize)
            guard readA >= 0, readB >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if readA != readB { return false }
            if readA == 0 { return true }
            if memcmp(bufA, bufB, readA) != 0 { return false }
        }
    }

    /// Reads up to `count` bytes, retrying short reads (common on network volumes). -1 on error.
    private static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if n == 0 { break }
            total += n
        }
        return total
    }

    /// Deletes a file with retry
    public static func deleteFile(at url: URL, retryCount: Int = 3, retryWait: Int = 1) async throws {
        var lastError: Error?
        let totalAttempts = 1 + retryCount  // 1 initial + N retries

        for attempt in 0..<max(1, totalAttempts) {
            do {
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                lastError = error
                if attempt < totalAttempts - 1 {
                    try await Task.sleep(nanoseconds: UInt64(retryWait) * 1_000_000_000)
                }
            }
        }

        throw MacroboError.deleteFailed(url.path, lastError ?? NSError(domain: "macrobo", code: 5))
    }
}
