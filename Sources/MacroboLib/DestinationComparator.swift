import Foundation

/// Outcome of comparing one source file with its destination counterpart
enum CompareVerdict: Sendable, Equatable {
    /// Destination is missing or differs: copy the file
    case copy
    /// Destination is identical (or excluded by --exclude-older): skip the file
    case skip
    /// Checksum mode, same size but different mtime: the contents must be compared.
    /// `skipIfDifferent` is true when --exclude-older would skip the file anyway.
    case checksum(skipIfDifferent: Bool)
}

/// Comparison settings taken from CopyOptions
struct CompareSettings: Sendable {
    var includeSame: Bool
    var checksum: Bool
    var excludeOlder: Bool
}

/// Thread-safe work counter shared by the compare workers and the progress poller
final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var completedCount = 0
    private var copyCount = 0

    /// Claims the next chunk of indices, or nil when all work is handed out
    func claim(chunk: Int, limit: Int) -> Range<Int>? {
        lock.lock(); defer { lock.unlock() }
        guard nextIndex < limit else { return nil }
        let end = min(nextIndex + chunk, limit)
        defer { nextIndex = end }
        return nextIndex..<end
    }

    func finish(count: Int, toCopy: Int) {
        lock.lock(); defer { lock.unlock() }
        completedCount += count
        copyCount += toCopy
    }

    var snapshot: (completed: Int, toCopy: Int) {
        lock.lock(); defer { lock.unlock() }
        return (completedCount, copyCount)
    }
}

/// Fixed-size result buffer written by the workers at distinct indices
private final class VerdictBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CompareVerdict>
    let count: Int

    init(count: Int) {
        self.count = count
        pointer = UnsafeMutablePointer<CompareVerdict>.allocate(capacity: count)
        pointer.initialize(repeating: .copy, count: count)
    }

    deinit {
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }

    func toArray() -> [CompareVerdict] {
        Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

/// Decides which source files need copying, using one metadata call per destination file
/// and running the comparisons in parallel (each one is a network round trip on NFS/SMB).
enum DestinationComparator {
    /// Number of concurrent metadata lookups during the scan
    static let defaultWorkerCount = 16
    private static let chunkSize = 32

    /// Size and mtime of the destination, or nil if it doesn't exist.
    /// Matches the previous FileManager semantics: existence follows symlinks
    /// (fileExists), attributes describe the item itself (attributesOfItem).
    ///
    /// The path goes through `fileSystemRepresentation`, as FileManager does, so names are
    /// passed in decomposed (NFD) form. Byte-exact servers (NFS) store what macOS wrote,
    /// which is NFD: passing a composed (NFC) String straight to lstat misses those files.
    static func destinationAttributes(atPath path: String) -> (size: UInt64, modificationDate: Date)? {
        URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { fsPath in
            guard let fsPath else { return nil }
            var st = stat()
            guard Darwin.lstat(fsPath, &st) == 0 else { return nil }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                // access() follows the link: a dangling symlink counts as missing
                guard access(fsPath, F_OK) == 0 else { return nil }
            }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                             + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
            return (UInt64(st.st_size), mtime)
        }
    }

    /// Compares one source file with its destination
    static func verdict(for file: FileInfo, destinationPath: String, settings: CompareSettings) -> CompareVerdict {
        guard let dest = destinationAttributes(atPath: destinationPath) else { return .copy }

        let sourceDate = file.modificationDate ?? FileOperations.modificationDate(at: file.url)

        // Identical: same size and mtime within 1 second (filesystem timestamp granularity)
        if !settings.includeSame, let sourceDate,
           file.size == dest.size,
           abs(sourceDate.timeIntervalSince(dest.modificationDate)) < 1.0 {
            return .skip
        }

        // --exclude-older: skip unless the source is strictly newer (unknown date counts as newer)
        let excludedAsOlder = settings.excludeOlder && !(sourceDate.map { $0 > dest.modificationDate } ?? true)

        if !settings.includeSame && settings.checksum && file.size == dest.size {
            return .checksum(skipIfDifferent: excludedAsOlder)
        }
        return excludedAsOlder ? .skip : .copy
    }

    /// Compares every candidate on `workerCount` threads. Results keep the candidates' order.
    static func compareAll(
        _ candidates: [FileInfo],
        destinationBase: String,
        settings: CompareSettings,
        workerCount: Int = defaultWorkerCount,
        counter: ScanCounter
    ) async -> [CompareVerdict] {
        let total = candidates.count
        guard total > 0 else { return [] }

        let buffer = VerdictBuffer(count: total)
        let workers = max(1, min(workerCount, (total + chunkSize - 1) / chunkSize))

        return await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            for _ in 0..<workers {
                group.enter()
                // Dedicated threads: these calls block on network I/O, which must not
                // tie up Swift's cooperative thread pool.
                let thread = Thread {
                    while let range = counter.claim(chunk: chunkSize, limit: total) {
                        var toCopy = 0
                        for index in range {
                            let file = candidates[index]
                            let result = verdict(
                                for: file,
                                destinationPath: destinationBase + file.relativePath,
                                settings: settings
                            )
                            buffer.pointer[index] = result
                            if result == .copy { toCopy += 1 }
                        }
                        counter.finish(count: range.count, toCopy: toCopy)
                    }
                    group.leave()
                }
                thread.start()
            }
            group.notify(queue: .global()) {
                continuation.resume(returning: buffer.toArray())
            }
        }
    }
}
