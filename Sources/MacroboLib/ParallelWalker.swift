import Foundation

/// Thread-safe set of named counters, written by worker threads and read by the progress ticker.
public final class LiveCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int]

    public init(slots: Int) {
        values = Array(repeating: 0, count: slots)
    }

    public func add(_ slot: Int, _ amount: Int = 1) {
        lock.lock(); values[slot] += amount; lock.unlock()
    }

    public func get(_ slot: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return values[slot]
    }

    public var all: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Runs `body` on a dedicated thread and resumes when it returns. Used for blocking file
/// system work (network round trips) that must not tie up Swift's cooperative thread pool.
func runOnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.start()
    }
}

/// Carries one file's progress from its copy thread to the display and log: at most 10 updates
/// a second (plus the last one), delivered in order.
final class ProgressRelay: @unchecked Sendable {
    private let progress: ProgressReporter
    private let logger: Logger
    private let key: String
    private let name: String
    private let lock = NSLock()
    private var lastSent = Date.distantPast
    /// Each update waits for the one before it, so they arrive in order
    private var tail: Task<Void, Never>?

    init(progress: ProgressReporter, logger: Logger, key: String, name: String) {
        self.progress = progress
        self.logger = logger
        self.key = key
        self.name = name
    }

    private func send(_ update: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        tail = Task {
            await previous?.value
            await update()
        }
    }

    func bytes(_ current: UInt64, of total: UInt64) {
        let now = Date()
        lock.lock()
        let due = current >= total || now.timeIntervalSince(lastSent) >= 0.1
        if due { lastSent = now }
        lock.unlock()
        guard due else { return }
        let (progress, logger, key, name) = (self.progress, self.logger, self.key, self.name)
        send {
            await progress.bytesProgress(current: current, total: total, key: key)
            await logger.logFileProgress(fileName: name, currentBytes: current, totalBytes: total)
        }
    }

    func syncing() {
        let (progress, key) = (self.progress, self.key)
        send { await progress.fileSyncing(key: key) }
    }

    /// Waits until every update sent so far has been delivered
    func delivered() async {
        await lastUpdate()?.value
    }

    private func lastUpdate() -> Task<Void, Never>? {
        lock.withLock { tail }
    }
}

/// Runs `body(i)` for every i in 0..<count on `workers` threads and blocks until all are done.
/// Call it from `runOnThread`, never on the cooperative pool.
func parallelForEach(count: Int, workers: Int, _ body: @escaping @Sendable (Int) -> Void) {
    guard count > 0 else { return }
    let lock = NSLock()
    var next = 0
    let group = DispatchGroup()
    for _ in 0..<max(1, min(workers, count)) {
        group.enter()
        let thread = Thread {
            while true {
                lock.lock()
                let i = next
                next += 1
                lock.unlock()
                guard i < count else { break }
                body(i)
            }
            group.leave()
        }
        thread.start()
    }
    group.wait()
}

/// Fixed-size results written by worker threads at distinct indices
final class ResultSlots<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T?]

    init(count: Int) { values = Array(repeating: nil, count: count) }

    subscript(i: Int) -> T? {
        get { lock.lock(); defer { lock.unlock() }; return values[i] }
        set { lock.lock(); values[i] = newValue; lock.unlock() }
    }

    var all: [T?] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Walks a directory tree breadth-first on several threads. Each listed directory costs a
/// network round trip on NFS/SMB, so listing many directories at once hides that latency.
enum ParallelWalker {
    /// A directory waiting to be listed, with caller-defined context passed down the tree
    struct Directory<Context> {
        let url: URL
        /// Relative path from the walk root ("" for the root itself, else "/a/b")
        let relativePath: String
        let context: Context
    }

    /// One entry of a listed directory, with its prefetched resource values
    struct Entry {
        let url: URL
        let name: String
        let relativePath: String
        let values: URLResourceValues?

        var isDirectory: Bool { values?.isDirectory == true }
        var isRegularFile: Bool { values?.isRegularFile == true }
    }

    /// Lists `root` and every directory `visit` returns, using `workers` threads, and blocks
    /// until the whole tree is done. `visit` runs concurrently on worker threads: it must be
    /// thread-safe. Directories that can't be listed are passed to `unreadable`; the root
    /// failing to list throws.
    static func walk<Context>(
        root: URL,
        rootContext: Context,
        keys: [URLResourceKey],
        skipHidden: Bool,
        workers: Int = 16,
        unreadable: @escaping (Directory<Context>, Error) -> Void = { _, _ in },
        visit: @escaping (Directory<Context>, [Entry]) -> [Directory<Context>]
    ) throws {
        var options: FileManager.DirectoryEnumerationOptions = []
        if skipHidden { options.insert(.skipsHiddenFiles) }
        let keySet = Set(keys)

        func list(_ dir: Directory<Context>) throws -> [Entry] {
            let urls = try FileManager.default.contentsOfDirectory(
                at: dir.url, includingPropertiesForKeys: keys, options: options
            )
            return urls.map { url in
                let name = url.lastPathComponent
                return Entry(
                    url: url,
                    name: name,
                    relativePath: dir.relativePath + "/" + name,
                    values: try? url.resourceValues(forKeys: keySet)
                )
            }
        }

        // The root is listed up front so that an unreadable root is an error, not a skip
        let rootDir = Directory(url: root, relativePath: "", context: rootContext)
        let rootEntries = try list(rootDir)
        let queue = WorkQueue<Directory<Context>>()
        queue.push(visit(rootDir, rootEntries))

        let group = DispatchGroup()
        for _ in 0..<max(1, workers) {
            group.enter()
            let thread = Thread {
                while let dir = queue.pop() {
                    do {
                        queue.push(visit(dir, try list(dir)))
                    } catch {
                        unreadable(dir, error)
                    }
                    queue.finishOne()
                }
                group.leave()
            }
            thread.start()
        }
        group.wait()
    }
}

/// Work queue that knows when no more work can arrive: it is empty and nothing is in progress.
private final class WorkQueue<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [T] = []
    /// Items queued or being processed
    private var outstanding = 0

    func push(_ newItems: [T]) {
        guard !newItems.isEmpty else { return }
        condition.lock()
        items.append(contentsOf: newItems)
        outstanding += newItems.count
        condition.broadcast()
        condition.unlock()
    }

    /// Next item, or nil once the walk is complete
    func pop() -> T? {
        condition.lock(); defer { condition.unlock() }
        while items.isEmpty && outstanding > 0 { condition.wait() }
        return items.isEmpty ? nil : items.removeLast()
    }

    func finishOne() {
        condition.lock()
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }
}
