import Foundation

/// Tracks progress for a single file being copied
struct FileProgress: Sendable {
    let index: Int
    let fileName: String
    let totalBytes: UInt64
    var copiedBytes: UInt64 = 0
    var isSyncing: Bool = false
    let startTime: Date

    var percent: Int {
        guard totalBytes > 0 else { return 100 }
        return min(100, Int(Double(copiedBytes) / Double(totalBytes) * 100))
    }

    func currentSpeed(at now: Date = Date()) -> Double {
        let elapsed = now.timeIntervalSince(startTime)
        guard elapsed > 0.001 else { return 0 }  // At least 1ms
        return Double(copiedBytes) / elapsed
    }

    func eta(at now: Date = Date()) -> TimeInterval {
        let speed = currentSpeed(at: now)
        guard speed > 0 && copiedBytes < totalBytes else { return 0 }
        return Double(totalBytes - copiedBytes) / speed
    }
}

/// Completed file info
struct CompletedFile: Sendable {
    let index: Int
    let name: String
    let bytes: UInt64
    let speed: Double
    let duration: TimeInterval
}

/// Reports progress to the console with DNF-style multi-line display
public actor ProgressReporter {
    private let quiet: Bool
    private let mode: CopyOptions.ProgressMode
    private var totalFiles: Int = 0
    private var totalBytes: UInt64 = 0
    private var completedFiles: Int = 0
    private var completedBytes: UInt64 = 0
    private var startTime: Date = Date()
    private var cachedTerminalWidth: Int = 0
    private var lastWidthCheck: Date = .distantPast

    private var terminalWidth: Int {
        let now = Date()
        if now.timeIntervalSince(lastWidthCheck) >= 1.0 {
            var ws = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
                cachedTerminalWidth = Int(ws.ws_col)
            } else if cachedTerminalWidth == 0 {
                cachedTerminalWidth = 80
            }
            lastWidthCheck = now
        }
        return cachedTerminalWidth
    }

    private var spinnerIndex: Int = 0
    private static let spinnerChars: [Character] = ["|", "/", "-", "\\"]

    // Track active files being copied
    private var activeFiles: [String: FileProgress] = [:]
    private var completedList: [CompletedFile] = []
    private var nextFileIndex: Int = 0

    // Display state
    private var displayLines: Int = 0
    private var lastDisplayTime: Date = Date()

    // Maximum number of completed files to show
    private let maxCompletedToShow = 20

    /// Whether finished steps and other static lines print (bar and none modes, unless --quiet)
    private let showSteps: Bool

    /// Live lines (spinners, the copy frame) need a terminal. When the output goes to a file or
    /// a pipe, only finished lines are written, as the screen shows them once the run ends.
    private let isTerminal = isatty(STDOUT_FILENO) != 0
    private var live: Bool { !quiet && isTerminal }

    /// - Parameters:
    ///   - quiet: suppresses the live display (spinner lines, copy bars)
    ///   - showSteps: prints the finished-step checklist and static lines such as dry-run lists
    public init(quiet: Bool = false, mode: CopyOptions.ProgressMode = .bar, showSteps: Bool = false) {
        self.quiet = quiet
        self.mode = mode
        self.showSteps = showSteps && mode != .json
    }

    /// Escapes a string for a JSON string literal
    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private func writeJSON(_ dict: [String: Any]) {
        var parts: [String] = []
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let k = Self.jsonEscape(key)
            switch value {
            case let s as String: parts.append("\"\(k)\":\"\(Self.jsonEscape(s))\"")
            case let n as Int: parts.append("\"\(k)\":\(n)")
            case let n as UInt64: parts.append("\"\(k)\":\(n)")
            case let n as Double: parts.append("\"\(k)\":\(String(format: "%.2f", n))")
            case let b as Bool: parts.append("\"\(k)\":\(b)")
            default: parts.append("\"\(k)\":\"\(Self.jsonEscape("\(value)"))\"")
            }
        }
        let json = "{\(parts.joined(separator: ","))}\n"
        fflush(stdout)
        json.utf8CString.withUnsafeBufferPointer { ptr in
            _ = Darwin.write(STDOUT_FILENO, ptr.baseAddress, json.utf8.count)
        }
    }

    /// Sets the total counts for progress calculation
    func setTotals(files: Int, bytes: UInt64) {
        self.totalFiles = files
        self.totalBytes = bytes
        self.startTime = Date()
        self.completedFiles = 0
        self.completedBytes = 0
        self.activeFiles = [:]
        self.completedList = []
        self.nextFileIndex = 0
        self.displayLines = 0
    }

    /// Called when starting to copy a file
    func fileStarted(key: String, displayName: String, bytes: UInt64) {
        nextFileIndex += 1
        activeFiles[key] = FileProgress(
            index: nextFileIndex,
            fileName: displayName,
            totalBytes: bytes,
            copiedBytes: 0,
            startTime: Date()
        )
        if mode == .json {
            writeJSON([
                "event": "file_start" as String,
                "file": displayName as String,
                "bytes": bytes
            ])
            return
        }
        updateDisplay()
    }

    /// Updates progress during a file copy
    func bytesProgress(current: UInt64, total: UInt64, key: String) {
        guard var progress = activeFiles[key] else { return }

        progress.copiedBytes = current
        activeFiles[key] = progress

        // Throttle display updates to every 100ms
        let now = Date()
        if now.timeIntervalSince(lastDisplayTime) >= 0.1 {
            lastDisplayTime = now
            updateDisplay()
        }
    }

    /// Updates progress with a completed file
    func fileCompleted(key: String, displayName: String, bytes: UInt64) {
        let now = Date()

        var speed: Double = 0
        var duration: TimeInterval = 0
        if let progress = activeFiles[key] {
            duration = now.timeIntervalSince(progress.startTime)
            speed = duration > 0.001 ? Double(bytes) / duration : Double(bytes) / 0.001

            completedList.append(CompletedFile(
                index: progress.index,
                name: displayName,
                bytes: bytes,
                speed: speed,
                duration: duration
            ))
            activeFiles.removeValue(forKey: key)
        } else {
            // File wasn't tracked, still record completion
            nextFileIndex += 1
            completedList.append(CompletedFile(
                index: nextFileIndex,
                name: displayName,
                bytes: bytes,
                speed: 0,
                duration: 0
            ))
        }

        completedFiles += 1
        completedBytes += bytes

        if mode == .json {
            writeJSON([
                "event": "file_done" as String,
                "file": displayName as String,
                "bytes": bytes,
                "speed": speed,
                "completed_files": completedFiles as Int,
                "total_files": totalFiles as Int
            ])
            return
        }

        // Prune old entries to prevent unbounded memory growth
        if completedList.count > maxCompletedToShow {
            completedList.removeFirst(completedList.count - maxCompletedToShow)
        }

        updateDisplay()
    }

    /// Marks an active file as syncing to disk
    func fileSyncing(key: String) {
        guard var progress = activeFiles[key] else { return }
        progress.isSyncing = true
        activeFiles[key] = progress
        updateDisplay()
    }

    /// Removes a failed/skipped file from active display
    func fileFailed(key: String) {
        // Just remove from active files - don't add to completed list
        // The file count will be tracked by CopyResult
        activeFiles.removeValue(forKey: key)
        completedFiles += 1  // Count as processed for progress purposes
        updateDisplay()
    }

    // MARK: - Steps

    /// Shows the live line of a running step, e.g. "/ Listing source         4,212 files, 803 folders".
    /// In JSON mode emits a "step" event with the counts instead.
    func stepRunning(id: String, name: String, detail: String, counts: [String: Int]) {
        if mode == .json {
            var event: [String: Any] = ["event": "step", "step": id, "state": "running"]
            for (k, v) in counts { event[k] = v }
            writeJSON(event)
            return
        }
        guard live else { return }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerChars.count
        let line = formatStepLine(mark: String(Self.spinnerChars[spinnerIndex]), name: name, detail: detail)
        let fitted = String(line.prefix(max(1, terminalWidth - 1)))
        let buf = "\r\u{1B}[K" + fitted
        fflush(stdout)
        buf.utf8CString.withUnsafeBufferPointer { ptr in
            _ = Darwin.write(STDOUT_FILENO, ptr.baseAddress, buf.utf8.count)
        }
    }

    /// Replaces the live line with the finished step: "✓ Listed source   6,779 files, 1,337 folders   0.6 s"
    func stepDone(id: String, name: String, detail: String, seconds: TimeInterval, counts: [String: Int]) {
        if mode == .json {
            var event: [String: Any] = ["event": "step", "step": id, "state": "done", "seconds": seconds]
            for (k, v) in counts { event[k] = v }
            writeJSON(event)
            return
        }
        let clear = live ? "\r\u{1B}[K" : ""
        guard showSteps else {
            if !clear.isEmpty { print(clear, terminator: ""); fflush(stdout) }
            return
        }
        print(clear + formatStepLine(mark: "✓", name: name, detail: detail, seconds: seconds))
        fflush(stdout)
    }

    /// Prints a static line (a dry-run entry, a blank separator) in bar and none modes
    func line(_ text: String) {
        guard showSteps else { return }
        print(text)
        fflush(stdout)
    }

    /// A dry-run entry. JSON mode gets a "would_copy" / "would_delete" event instead of text.
    func wouldChange(_ action: String, path: String, bytes: UInt64? = nil, folder: Bool = false) {
        if mode == .json {
            var event: [String: Any] = ["event": "would_\(action)", "path": path]
            if let bytes { event["bytes"] = bytes }
            if folder { event["folder"] = true }
            writeJSON(event)
            return
        }
        let suffix = folder ? "/ (folder)" : bytes.map { " (\(formatBytes($0)))" } ?? ""
        line("  WOULD \(action.uppercased()): \(path)\(suffix)")
    }

    /// Clears the progress display
    func clear() {
        guard live else { return }
        if displayLines > 0 {
            for _ in 0..<displayLines {
                print("\u{1B}[A\u{1B}[2K", terminator: "")
            }
            displayLines = 0
        }
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
    }

    /// Finishes progress display - clears multi-line display and shows clean final total.
    /// Returns the time spent copying, which the total line's speed is based on.
    @discardableResult
    func finish() -> TimeInterval {
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        if mode == .json {
            let overallSpeed = elapsed > 0.001 ? Double(completedBytes) / elapsed : 0
            writeJSON([
                "event": "summary" as String,
                "completed_files": completedFiles as Int,
                "total_files": totalFiles as Int,
                "completed_bytes": completedBytes,
                "total_bytes": totalBytes,
                "speed": overallSpeed,
                "elapsed": elapsed
            ])
            return elapsed
        }
        guard !quiet else { return elapsed }
        guard isTerminal else {
            // No live frame was drawn: just the final total, as the screen ends up showing it
            print(formatTotalLine(now: now))
            print("")
            fflush(stdout)
            return elapsed
        }

        // Clear the entire multi-line progress display
        if displayLines > 0 {
            print("\u{1B}[\(displayLines)A", terminator: "")
            for _ in 0..<displayLines {
                print("\u{1B}[2K")
            }
            print("\u{1B}[\(displayLines)A", terminator: "")
        }

        // Print just the separator and final total line
        let separator = String(repeating: "-", count: min(terminalWidth - 1, 80))
        print("\u{1B}[2K\(separator)")
        print("\u{1B}[2K\(formatTotalLine(now: now))")
        print("")
        fflush(stdout)
        displayLines = 0
        return elapsed
    }

    // MARK: - Display Rendering

    private func updateDisplay() {
        guard live, totalFiles > 0 else { return }

        let now = Date()

        // Build content lines (completed + active)
        var contentLines: [String] = []
        let recentCompleted = completedList.suffix(maxCompletedToShow)
        for completed in recentCompleted {
            contentLines.append(formatCompletedLine(completed))
        }
        let sortedActive = activeFiles.values.sorted { $0.index < $1.index }
        for progress in sortedActive {
            contentLines.append(formatActiveLine(progress, now: now))
        }

        // Footer is always 2 lines: separator + total
        let separator = String(repeating: "-", count: min(terminalWidth - 1, 80))
        let totalLine = formatTotalLine(now: now)

        // Frame height never shrinks — pad between content and footer
        // so the total line stays pinned to the bottom
        let footerLines = 2
        let minContentLines = max(contentLines.count, displayLines - footerLines)
        let frameSize = minContentLines + footerLines

        // Build the entire frame in one buffer for atomic write
        var buf = ""
        buf += "\u{1B}[?25l"  // hide cursor
        if displayLines > 0 {
            buf += "\u{1B}[\(displayLines)A"  // move to top of previous frame
        }
        // Content lines
        for line in contentLines {
            let truncated = String(line.prefix(terminalWidth - 1))
            buf += "\u{1B}[2K\(truncated)\n"
        }
        // Blank padding between content and footer
        for _ in contentLines.count..<minContentLines {
            buf += "\u{1B}[2K\n"
        }
        // Footer (separator + total) — always at the bottom of the frame
        buf += "\u{1B}[2K\(separator)\n"
        buf += "\u{1B}[2K\(String(totalLine.prefix(terminalWidth - 1)))\n"
        buf += "\u{1B}[?25h"  // show cursor

        displayLines = frameSize

        // Write atomically via file descriptor to bypass Swift print buffering
        fflush(stdout)
        buf.utf8CString.withUnsafeBufferPointer { ptr in
            _ = Darwin.write(STDOUT_FILENO, ptr.baseAddress, buf.utf8.count)
        }
    }

    /// Tests: lay lines out for this terminal width
    func useTerminalWidth(_ width: Int) {
        cachedTerminalWidth = width
        lastWidthCheck = .distantFuture
    }

    /// Tests: a copy in progress, as the display would show it
    func simulate(totalFiles: Int, completed: Int, bytes: UInt64) {
        self.totalFiles = totalFiles
        self.totalBytes = bytes * 2
        self.completedFiles = completed
        self.completedBytes = bytes
    }

    /// Cells in the progress bars: 20 when there's room. On a narrow terminal (or with 1,000+
    /// files, whose counters are wider) the bar narrows, down to 5, so every line keeps its
    /// size and time left within width - 1 columns. The copying and total lines share it.
    private var barCells: Int {
        let full = 20
        let sample = String(format: "%@ %@ | %@ | %@ | %@", "100%", brailleBar(percent: 0, width: full),
                            formatSpeed(0), formatSize(0), "00m00s")
        let overflow = counterWidth + 1 + 10 + 1 + sample.count - (terminalWidth - 1)
        return overflow > 0 ? max(5, full - overflow) : full
    }

    /// Returns the width needed for the counter based on total files
    private var counterWidth: Int {
        // Format: [XXX/YYY] - digits for current + digits for total + 3 for brackets and slash
        let digits = String(totalFiles).count
        return digits * 2 + 3
    }

    private func formatCounter(_ current: Int) -> String {
        let digits = String(totalFiles).count
        return String(format: "[%\(digits)d/%d]", current, totalFiles)
    }

    private func formatCompletedLine(_ completed: CompletedFile) -> String {
        // Format: [XXX/YYY] filename                    100% |  XX.X MiB/s |  XX.X MiB | 00m00s
        let counter = formatCounter(completed.index)
        let speedStr = formatSpeed(completed.speed)
        let sizeStr = formatSize(completed.bytes)
        let timeStr = formatDuration(completed.duration, compact: true)

        // Fixed-width stats section (no progress bar for completed)
        let stats = String(format: "100%% | %@ | %@ | %@", speedStr, sizeStr, timeStr)

        // Calculate space for filename (counter + space + name + space + stats)
        let usedWidth = counterWidth + 1 + stats.count + 1
        let nameWidth = max(10, terminalWidth - 1 - usedWidth)
        let truncatedName = formatTruncate(completed.name, maxWidth: nameWidth, pad: true)

        return "\(counter) \(truncatedName) \(stats)"
    }

    func formatActiveLine(_ progress: FileProgress, now: Date) -> String {
        let counter = formatCounter(progress.index)

        if progress.isSyncing {
            // Show syncing status instead of progress bar
            let stats = "Syncing to disk..."
            let usedWidth = counterWidth + 1 + stats.count + 1
            let nameWidth = max(10, terminalWidth - 1 - usedWidth)
            let truncatedName = formatTruncate(progress.fileName, maxWidth: nameWidth, pad: true)
            return "\(counter) \(truncatedName) \(stats)"
        }

        // Format: [XXX/YYY] filename    XX% [========        ] |  XX.X MiB/s |  XX.X MiB | 00m00s
        let pct = String(format: "%3d%%", progress.percent)
        let speed = progress.currentSpeed(at: now)
        let speedStr = formatSpeed(speed)
        let sizeStr = formatSize(progress.copiedBytes)
        let etaStr = formatDuration(progress.eta(at: now), compact: true)

        let bar = brailleBar(percent: progress.percent, width: barCells)

        // Fixed-width stats section
        let stats = String(format: "%@ %@ | %@ | %@ | %@", pct, bar, speedStr, sizeStr, etaStr)

        // Calculate space for filename
        let usedWidth = counterWidth + 1 + stats.count + 1
        let nameWidth = max(10, terminalWidth - 1 - usedWidth)
        let truncatedName = formatTruncate(progress.fileName, maxWidth: nameWidth, pad: true)

        return "\(counter) \(truncatedName) \(stats)"
    }

    func formatTotalLine(now: Date) -> String {
        let counter = formatCounter(completedFiles)
        let totalPercent = totalFiles > 0 ? Int(Double(completedFiles) / Double(totalFiles) * 100) : 0
        let pct = String(format: "%3d%%", totalPercent)

        let elapsed = now.timeIntervalSince(startTime)
        let overallSpeed = elapsed > 0.001 ? Double(completedBytes) / elapsed : 0
        let speedStr = formatSpeed(overallSpeed)
        let sizeStr = formatSize(completedBytes)

        // Calculate ETA for remaining
        var etaStr = formatDuration(0, compact: true)
        if overallSpeed > 0 && completedBytes < totalBytes {
            let remaining = Double(totalBytes - completedBytes) / overallSpeed
            etaStr = formatDuration(remaining, compact: true)
        }

        let bar = brailleBar(percent: totalPercent, width: barCells)

        // Fixed-width stats section
        let stats = String(format: "%@ %@ | %@ | %@ | %@", pct, bar, speedStr, sizeStr, etaStr)

        // Calculate space for label
        let usedWidth = counterWidth + 1 + stats.count + 1
        let nameWidth = max(10, terminalWidth - 1 - usedWidth)
        let paddedLabel = formatTruncate("Total", maxWidth: nameWidth, pad: true)

        return "\(counter) \(paddedLabel) \(stats)"
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        // Use macOS decimal units (1000-based)
        if bytesPerSec >= 1_000_000_000 {
            return String(format: "%6.1f GB/s", bytesPerSec / 1_000_000_000)
        } else if bytesPerSec >= 1_000_000 {
            return String(format: "%6.1f MB/s", bytesPerSec / 1_000_000)
        } else if bytesPerSec >= 1_000 {
            return String(format: "%6.1f KB/s", bytesPerSec / 1_000)
        } else {
            return String(format: "%6.0f  B/s", bytesPerSec)
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        // Use macOS decimal units (1000-based)
        if bytes >= 1_000_000_000 {
            return String(format: "%6.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%6.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%6.1f KB", Double(bytes) / 1_000)
        } else {
            return String(format: "%6d  B", bytes)
        }
    }

    /// Builds a braille-dot progress bar that fills vertically like docker/git pull
    private func brailleBar(percent: Int, width: Int = 20) -> String {
        // Braille levels filling bottom-to-top: ⡀ → ⣀ → ⣤ → ⣶ → ⣿
        let levels: [Character] = ["⡀", "⣀", "⣤", "⣶", "⣿"]
        let maxLevel = levels.count - 1  // 4

        // Exact fractional position within the bar
        let progress = Double(percent) / 100.0 * Double(width)
        let fullCount = Int(progress)
        let fraction = progress - Double(fullCount)

        var bar = ""
        for i in 0..<width {
            if i < fullCount {
                bar.append(levels[maxLevel])  // ⣿ fully filled
            } else if i == fullCount {
                // Transition character based on fraction
                let level = Int(fraction * Double(maxLevel))
                bar.append(levels[level])
            } else {
                bar.append(levels[0])  // ⡀ empty
            }
        }
        return "[" + bar + "]"
    }

}
