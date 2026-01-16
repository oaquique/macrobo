import Foundation

/// Tracks progress for a single file being copied
struct FileProgress: Sendable {
    let index: Int
    let fileName: String
    let totalBytes: UInt64
    var copiedBytes: UInt64 = 0
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
actor ProgressReporter {
    private let quiet: Bool
    private var totalFiles: Int = 0
    private var totalBytes: UInt64 = 0
    private var completedFiles: Int = 0
    private var completedBytes: UInt64 = 0
    private var startTime: Date = Date()
    private let terminalWidth: Int
    private var spinnerIndex: Int = 0
    private static let spinnerChars: [Character] = ["|", "/", "-", "\\"]

    // Track active files being copied
    private var activeFiles: [String: FileProgress] = [:]
    private var completedList: [CompletedFile] = []
    private var nextFileIndex: Int = 0

    // Display state
    private var displayLines: Int = 0
    private var lastDisplayTime: Date = Date()

    // Fixed widths for alignment
    private let statsWidth = 55  // Fixed width for stats section on the right

    // Maximum number of completed files to show
    private let maxCompletedToShow = 20

    init(quiet: Bool = false) {
        self.quiet = quiet
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            self.terminalWidth = Int(ws.ws_col)
        } else {
            self.terminalWidth = 120
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
    func fileStarted(name: String, bytes: UInt64) {
        nextFileIndex += 1
        activeFiles[name] = FileProgress(
            index: nextFileIndex,
            fileName: name,
            totalBytes: bytes,
            copiedBytes: 0,
            startTime: Date()
        )
        updateDisplay()
    }

    /// Updates progress during a file copy
    func bytesProgress(current: UInt64, total: UInt64, fileName: String) {
        guard var progress = activeFiles[fileName] else { return }

        progress.copiedBytes = current
        activeFiles[fileName] = progress

        // Throttle display updates to every 100ms
        let now = Date()
        if now.timeIntervalSince(lastDisplayTime) >= 0.1 {
            lastDisplayTime = now
            updateDisplay()
        }
    }

    /// Updates progress with a completed file
    func fileCompleted(name: String, bytes: UInt64) {
        let now = Date()

        if let progress = activeFiles[name] {
            let duration = now.timeIntervalSince(progress.startTime)
            let speed = duration > 0.001 ? Double(bytes) / duration : Double(bytes) / 0.001

            completedList.append(CompletedFile(
                index: progress.index,
                name: name,
                bytes: bytes,
                speed: speed,
                duration: duration
            ))
            activeFiles.removeValue(forKey: name)
        } else {
            // File wasn't tracked, still record completion
            nextFileIndex += 1
            completedList.append(CompletedFile(
                index: nextFileIndex,
                name: name,
                bytes: bytes,
                speed: 0,
                duration: 0
            ))
        }

        completedFiles += 1
        completedBytes += bytes
        updateDisplay()
    }

    /// Removes a failed/skipped file from active display
    func fileFailed(name: String) {
        // Just remove from active files - don't add to completed list
        // The file count will be tracked by CopyResult
        activeFiles.removeValue(forKey: name)
        completedFiles += 1  // Count as processed for progress purposes
        updateDisplay()
    }

    /// Shows a status message with spinner (for scanning phase)
    func showStatus(_ message: String) {
        guard !quiet else { return }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerChars.count
        let spinner = Self.spinnerChars[spinnerIndex]
        let fullMessage = "\(spinner) \(message)"
        let padded = fullMessage.padding(toLength: terminalWidth - 1, withPad: " ", startingAt: 0)
        print("\r\(padded)", terminator: "")
        fflush(stdout)
    }

    /// Updates scanning progress
    func updateScanProgress(scanned: Int, found: Int) {
        guard !quiet else { return }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerChars.count
        let spinner = Self.spinnerChars[spinnerIndex]
        let message = "\(spinner) Scanning: \(scanned) files checked, \(found) to copy..."
        let padded = message.padding(toLength: terminalWidth - 1, withPad: " ", startingAt: 0)
        print("\r\(padded)", terminator: "")
        fflush(stdout)
    }

    /// Clears the progress display
    func clear() {
        guard !quiet else { return }
        if displayLines > 0 {
            for _ in 0..<displayLines {
                print("\u{1B}[A\u{1B}[2K", terminator: "")
            }
            displayLines = 0
        }
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
    }

    /// Finishes progress display - shows final state
    func finish() {
        guard !quiet else { return }
        updateDisplay()
        print("")  // Move past the display
        fflush(stdout)
        displayLines = 0
    }

    // MARK: - Display Rendering

    private func updateDisplay() {
        guard !quiet, totalFiles > 0 else { return }

        let now = Date()
        var lines: [String] = []

        // Show recent completed files (last N)
        let recentCompleted = completedList.suffix(maxCompletedToShow)
        for completed in recentCompleted {
            lines.append(formatCompletedLine(completed))
        }

        // Show active files with progress bars
        let sortedActive = activeFiles.values.sorted { $0.index < $1.index }
        for progress in sortedActive {
            lines.append(formatActiveLine(progress, now: now))
        }

        // Separator and total line
        lines.append(String(repeating: "-", count: min(terminalWidth - 1, 80)))
        lines.append(formatTotalLine(now: now))

        // Clear previous display by moving cursor up
        if displayLines > 0 {
            print("\u{1B}[\(displayLines)A", terminator: "")
        }

        // Print all lines
        for line in lines {
            // Truncate to terminal width and clear rest of line
            let truncated = String(line.prefix(terminalWidth - 1))
            print("\u{1B}[2K\(truncated)")
        }

        displayLines = lines.count
        fflush(stdout)
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
        let timeStr = formatTime(completed.duration)

        // Fixed-width stats section (no progress bar for completed)
        let stats = String(format: "100%% | %@ | %@ | %@", speedStr, sizeStr, timeStr)

        // Calculate space for filename (counter + space + name + space + stats)
        let usedWidth = counterWidth + 1 + stats.count + 1
        let nameWidth = max(10, terminalWidth - usedWidth)
        let truncatedName = truncateOrPad(completed.name, width: nameWidth)

        return "\(counter) \(truncatedName) \(stats)"
    }

    private func formatActiveLine(_ progress: FileProgress, now: Date) -> String {
        // Format: [XXX/YYY] filename    XX% [========        ] |  XX.X MiB/s |  XX.X MiB | 00m00s
        let counter = formatCounter(progress.index)
        let pct = String(format: "%3d%%", progress.percent)
        let speed = progress.currentSpeed(at: now)
        let speedStr = formatSpeed(speed)
        let sizeStr = formatSize(progress.copiedBytes)
        let etaStr = formatTime(progress.eta(at: now))

        // Build progress bar (using # to avoid font ligature issues with ==)
        let barWidth = 15
        let filled = Int(Double(barWidth) * Double(progress.percent) / 100.0)
        let empty = barWidth - filled
        let bar = "[" + String(repeating: "#", count: filled) + String(repeating: " ", count: empty) + "]"

        // Fixed-width stats section
        let stats = String(format: "%@ %@ | %@ | %@ | %@", pct, bar, speedStr, sizeStr, etaStr)

        // Calculate space for filename
        let usedWidth = counterWidth + 1 + stats.count + 1
        let nameWidth = max(10, terminalWidth - usedWidth)
        let truncatedName = truncateOrPad(progress.fileName, width: nameWidth)

        return "\(counter) \(truncatedName) \(stats)"
    }

    private func formatTotalLine(now: Date) -> String {
        let counter = formatCounter(completedFiles)
        let totalPercent = totalFiles > 0 ? Int(Double(completedFiles) / Double(totalFiles) * 100) : 0
        let pct = String(format: "%3d%%", totalPercent)

        let elapsed = now.timeIntervalSince(startTime)
        let overallSpeed = elapsed > 0.001 ? Double(completedBytes) / elapsed : 0
        let speedStr = formatSpeed(overallSpeed)
        let sizeStr = formatSize(completedBytes)

        // Calculate ETA for remaining
        var etaStr = "00m00s"
        if overallSpeed > 0 && completedBytes < totalBytes {
            let remaining = Double(totalBytes - completedBytes) / overallSpeed
            etaStr = formatTime(remaining)
        }

        // Build progress bar (using # to avoid font ligature issues)
        let barWidth = 15
        let filled = Int(Double(barWidth) * Double(totalPercent) / 100.0)
        let empty = barWidth - filled
        let bar = "[" + String(repeating: "#", count: filled) + String(repeating: " ", count: empty) + "]"

        // Fixed-width stats section
        let stats = String(format: "%@ %@ | %@ | %@ | %@", pct, bar, speedStr, sizeStr, etaStr)

        // Calculate space for label
        let usedWidth = counterWidth + 1 + stats.count + 1
        let nameWidth = max(10, terminalWidth - usedWidth)
        let paddedLabel = truncateOrPad("Total", width: nameWidth)

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

    private func formatTime(_ seconds: TimeInterval) -> String {
        let secs = Int(max(0, seconds))
        if secs >= 86400 {
            let days = secs / 86400
            let hours = (secs % 86400) / 3600
            return String(format: "%02dd%02dh", days, hours)
        } else if secs >= 3600 {
            let hours = secs / 3600
            let mins = (secs % 3600) / 60
            return String(format: "%02dh%02dm", hours, mins)
        } else {
            let mins = secs / 60
            let s = secs % 60
            return String(format: "%02dm%02ds", mins, s)
        }
    }

    /// Truncate or pad text to exact display width
    /// Uses character count which works for most Unicode, then pads with spaces
    private func truncateOrPad(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }

        // Count actual characters (not bytes)
        let charCount = text.count

        if charCount > width {
            // Truncate with ellipsis
            if width > 3 {
                let truncated = String(text.prefix(width - 3))
                return truncated + "..."
            } else {
                return String(text.prefix(width))
            }
        } else {
            // Pad with spaces
            let padding = String(repeating: " ", count: width - charCount)
            return text + padding
        }
    }
}
