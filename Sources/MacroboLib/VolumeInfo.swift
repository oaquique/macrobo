import Foundation

/// Facts about where a path lives, read from the mount table so they work even when the
/// path itself can't be opened (a share that denies access is still listed as mounted).
enum VolumeInfo {
    /// File system types that are network shares
    private static let networkTypes: Set<String> = ["nfs", "smbfs", "afpfs", "webdav", "cifs"]

    /// The network file system type ("nfs", "smbfs", ...) of the mount holding `path`,
    /// or nil when it's a local disk or can't be determined
    static func networkFileSystemType(of path: String) -> String? {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return nil }

        let standardized = (path as NSString).standardizingPath
        var bestMatch: (length: Int, type: String)?
        for i in 0..<Int(count) {
            var entry = mounts[i]
            let mountPoint = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let isUnder = mountPoint == "/" || standardized == mountPoint || standardized.hasPrefix(mountPoint + "/")
            if isUnder && mountPoint.count > (bestMatch?.length ?? -1) {
                bestMatch = (mountPoint.count, type)
            }
        }
        guard let bestMatch, networkTypes.contains(bestMatch.type) else { return nil }
        return bestMatch.type
    }

    enum DirectoryProblem: Equatable {
        case missing
        case notDirectory
        /// Exists but can't be opened; the reason is the system's ("Permission denied")
        case unreadable(String)
    }

    /// Checks that `path` can be opened as a directory. Returns nil when it can.
    static func directoryProblem(at path: String) -> DirectoryProblem? {
        var st = stat()
        let found = URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { fsPath -> Int32 in
            guard let fsPath else { return -1 }
            return fstatat(AT_FDCWD, fsPath, &st, 0)
        }
        if found != 0 {
            let code = errno
            return code == ENOENT ? .missing : .unreadable(String(cString: strerror(code)))
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .notDirectory }
        // Listing needs read and search permission
        if access(path, R_OK | X_OK) != 0 {
            return .unreadable(String(cString: strerror(errno)))
        }
        return nil
    }
}
