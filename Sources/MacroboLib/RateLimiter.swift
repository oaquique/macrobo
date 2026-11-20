import Foundation

/// Token-bucket rate limiter for bandwidth throttling, shared by the copy threads.
/// `acquire` blocks the calling thread: copies run on dedicated threads, never on the
/// cooperative pool.
public final class RateLimiter: @unchecked Sendable {
    private let bytesPerSecond: UInt64
    private let lock = NSLock()
    private var tokens: Double
    private var lastRefill: Date
    private let maxBurst: Double

    public init(bytesPerSecond: UInt64) {
        self.bytesPerSecond = bytesPerSecond
        let burst = Double(bytesPerSecond)
        self.maxBurst = burst
        self.tokens = burst
        self.lastRefill = Date()
    }

    public var isUnlimited: Bool { bytesPerSecond == 0 }

    public func acquire(_ bytes: Int) {
        guard bytesPerSecond > 0 else { return }
        let sleepSeconds: Double = {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            tokens = min(maxBurst, tokens + now.timeIntervalSince(lastRefill) * Double(bytesPerSecond))
            lastRefill = now
            // Take the bytes even when that leaves the bucket in debt. Each caller then waits
            // until the debt is paid off, so several threads together stay within the limit.
            // (Resetting to zero let every waiting thread sleep only for its own chunk, and
            // 32 threads ran at 32 times the limit.)
            tokens -= Double(bytes)
            return tokens >= 0 ? 0 : -tokens / Double(bytesPerSecond)
        }()
        if sleepSeconds > 0 { Thread.sleep(forTimeInterval: sleepSeconds) }
    }
}
