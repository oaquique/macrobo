import Foundation

/// Token-bucket rate limiter for bandwidth throttling across multiple threads
public actor RateLimiter {
    private let bytesPerSecond: UInt64
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

    public nonisolated var isUnlimited: Bool { bytesPerSecond == 0 }

    public func acquire(_ bytes: Int) async {
        guard bytesPerSecond > 0 else { return }
        let needed = Double(bytes)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        tokens = min(maxBurst, tokens + elapsed * Double(bytesPerSecond))
        lastRefill = now
        if tokens >= needed {
            tokens -= needed
            return
        }
        let deficit = needed - tokens
        let sleepSeconds = deficit / Double(bytesPerSecond)
        tokens = 0
        lastRefill = Date()
        try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
    }
}
