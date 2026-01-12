import Foundation

/// Reports progress to the console with a progress bar
actor ProgressReporter {
    private let quiet: Bool
    private var totalFiles: Int = 0
    private var totalBytes: UInt64 = 0
    private var processedFiles: Int = 0
    private var processedBytes: UInt64 = 0
    private var startTime: Date = Date()
    private var lastUpdateTime: Date = Date()
    private var currentFile: String = ""
    private let terminalWidth: Int
    private var spinnerIndex: Int = 0
    private static let spinnerChars: [Character] = ["|", "/", "-", "\\"]
    private var twoLineDisplayActive: Bool = false

    // ANSI escape codes
    private static let moveUp = "\u{1B}[A"
    private static let moveDown = "\u{1B}[B"
    private static let clearLine = "\u{1B}[K"

    init(quiet: Bool = false) {
        self.quiet = quiet
        // Get terminal width, default to 80
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            self.terminalWidth = Int(ws.ws_col)
        } else {
            self.terminalWidth = 80
        }
    }

    /// Sets the total counts for progress calculation
    func setTotals(files: Int, bytes: UInt64) {
        self.totalFiles = files
        self.totalBytes = bytes
        self.startTime = Date()
        self.lastUpdateTime = Date()
    }

    /// Called when starting to copy a file - initializes two-line display
    func fileStarted(name: String, bytes: UInt64) {
        currentFile = name

        guard !quiet, totalFiles > 0 else { return }

        let overallLine = buildOverallProgressLine()
        let fileLine = buildSimpleFileLine(name: name, bytes: bytes)

        if !twoLineDisplayActive {
            // Initialize two-line display
            print("\r\(overallLine)\n\(fileLine)", terminator: "")
            twoLineDisplayActive = true
        } else {
            // Update both lines
            print("\(Self.moveUp)\r\(overallLine)\(Self.moveDown)\r\(fileLine)", terminator: "")
        }
        fflush(stdout)
    }

    /// Updates progress with a completed file
    func fileCompleted(name: String, bytes: UInt64) {
        processedFiles += 1
        processedBytes += bytes
        currentFile = name
        updateDisplay()
    }

    /// Updates progress during a large file copy
    func bytesProgress(current: UInt64, total: UInt64, fileName: String) {
        currentFile = fileName
        // Throttle updates to avoid console spam
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) >= 0.1 {
            lastUpdateTime = now
            updateDisplayForFile(current: current, total: total)
        }
    }

    /// Clears the progress lines
    func clear() {
        guard !quiet else { return }
        let blank = String(repeating: " ", count: terminalWidth)
        if twoLineDisplayActive {
            // Clear both lines: move up, clear, move down, clear
            print("\(Self.moveUp)\r\(blank)\r\(blank)\r", terminator: "")
            twoLineDisplayActive = false
        } else {
            print("\r\(blank)\r", terminator: "")
        }
        fflush(stdout)
    }

    /// Shows a status message with spinner (for scanning phase, etc.)
    func showStatus(_ message: String) {
        guard !quiet else { return }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerChars.count
        let spinner = Self.spinnerChars[spinnerIndex]
        let fullMessage = "\(spinner) \(message)"
        print("\r\(fullMessage)\(String(repeating: " ", count: max(0, terminalWidth - fullMessage.count - 1)))", terminator: "")
        fflush(stdout)
    }

    /// Updates scanning progress with file count and spinner
    func updateScanProgress(scanned: Int, found: Int) {
        guard !quiet else { return }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerChars.count
        let spinner = Self.spinnerChars[spinnerIndex]
        let message = "\(spinner) Scanning: \(scanned) files checked, \(found) to copy..."
        print("\r\(message)\(String(repeating: " ", count: max(0, terminalWidth - message.count - 1)))", terminator: "")
        fflush(stdout)
    }

    /// Finishes progress display
    func finish() {
        clear()
    }

    private func updateDisplay() {
        guard !quiet, totalFiles > 0 else { return }

        let overallLine = buildOverallProgressLine()

        if twoLineDisplayActive {
            // Move up to line 1, print overall, move down, clear line 2
            print("\(Self.moveUp)\r\(overallLine)\(Self.moveDown)\r\(Self.clearLine)", terminator: "")
        } else {
            // Single line mode (between files)
            print("\r\(overallLine)", terminator: "")
        }
        fflush(stdout)
    }

    private func buildOverallProgressLine() -> String {
        let percent = Double(processedFiles) / Double(totalFiles) * 100
        let elapsed = Date().timeIntervalSince(startTime)
        let bytesPerSec = elapsed > 0 ? Double(processedBytes) / elapsed : 0

        // Calculate ETA
        var eta = "--:--"
        if bytesPerSec > 0 && totalBytes > processedBytes {
            let remainingBytes = totalBytes - processedBytes
            let remainingSecs = Double(remainingBytes) / bytesPerSec
            eta = formatDuration(remainingSecs)
        }

        // Compact progress bar - fixed width of 20 chars
        let barWidth = 20
        let filled = Int(Double(barWidth) * Double(processedFiles) / Double(totalFiles))
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: barWidth - filled)

        // Format: [===========         ] 45% | 125.3MB/s | ETA 2:34 | 1234/5678 files
        let line = String(format: "[%@] %3.0f%% | %@/s | ETA %@ | %d/%d",
                          bar, percent, formatBytes(UInt64(bytesPerSec)),
                          eta, processedFiles, totalFiles)

        return String(line.prefix(terminalWidth - 1)).padding(toLength: terminalWidth - 1, withPad: " ", startingAt: 0)
    }

    private func updateDisplayForFile(current: UInt64, total: UInt64) {
        guard !quiet else { return }

        let overallLine = buildOverallProgressLine()
        let fileLine = buildFileProgressLine(current: current, total: total)

        if !twoLineDisplayActive {
            // Initialize two-line display: print line 1, newline, then line 2
            print("\r\(overallLine)\n\(fileLine)", terminator: "")
            twoLineDisplayActive = true
        } else {
            // Update both lines: move up, print line 1, move down, print line 2
            print("\(Self.moveUp)\r\(overallLine)\(Self.moveDown)\r\(fileLine)", terminator: "")
        }
        fflush(stdout)
    }

    private func buildFileProgressLine(current: UInt64, total: UInt64) -> String {
        let percent = Double(current) / Double(total) * 100

        // Compact progress bar - fixed width of 20 chars
        let barWidth = 20
        let filled = Int(Double(barWidth) * Double(current) / Double(total))
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: barWidth - filled)

        // Truncate filename
        let maxFileLen = 25
        let displayFile = currentFile.count > maxFileLen
            ? "..." + currentFile.suffix(maxFileLen - 3)
            : currentFile

        // Format: [===========         ] 45% | 12.3MB/125.0MB | filename.mp3
        let line = String(format: "[%@] %3.0f%% | %@/%@ | %@",
                          bar, percent, formatBytes(current), formatBytes(total), displayFile)

        return String(line.prefix(terminalWidth - 1)).padding(toLength: terminalWidth - 1, withPad: " ", startingAt: 0)
    }

    private func buildSimpleFileLine(name: String, bytes: UInt64) -> String {
        // Truncate filename
        let maxFileLen = 40
        let displayFile = name.count > maxFileLen
            ? "..." + name.suffix(maxFileLen - 3)
            : name

        // Format: Copying: filename.mp3 (1.2MB)
        let line = "Copying: \(displayFile) (\(formatBytes(bytes)))"

        return String(line.prefix(terminalWidth - 1)).padding(toLength: terminalWidth - 1, withPad: " ", startingAt: 0)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return String(format: "%3d%@", bytes, units[unitIndex])
        } else {
            return String(format: "%5.1f%@", value, units[unitIndex])
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs < 60 {
            return String(format: "0:%02d", secs)
        } else if secs < 3600 {
            return String(format: "%d:%02d", secs / 60, secs % 60)
        } else {
            return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        }
    }
}
