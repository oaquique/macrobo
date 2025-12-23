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

    /// Clears the progress line
    func clear() {
        guard !quiet else { return }
        print("\r\(String(repeating: " ", count: terminalWidth))\r", terminator: "")
        fflush(stdout)
    }

    /// Finishes progress display
    func finish() {
        clear()
    }

    private func updateDisplay() {
        guard !quiet, totalFiles > 0 else { return }

        let percent = Double(processedFiles) / Double(totalFiles) * 100
        let elapsed = Date().timeIntervalSince(startTime)
        let bytesPerSec = elapsed > 0 ? Double(processedBytes) / elapsed : 0

        // Calculate ETA
        var eta = ""
        if bytesPerSec > 0 && totalBytes > processedBytes {
            let remainingBytes = totalBytes - processedBytes
            let remainingSecs = Double(remainingBytes) / bytesPerSec
            eta = formatDuration(remainingSecs)
        }

        // Build progress bar
        let barWidth = max(20, terminalWidth - 50)
        let filled = Int(Double(barWidth) * Double(processedFiles) / Double(totalFiles))
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: barWidth - filled)

        // Truncate filename if needed
        let maxFileLen = 20
        let displayFile = currentFile.count > maxFileLen
            ? "..." + currentFile.suffix(maxFileLen - 3)
            : currentFile

        let line = String(format: "\r[%@] %3.0f%% %@/s ETA:%@ %@",
                          bar, percent, formatBytes(UInt64(bytesPerSec)),
                          eta.isEmpty ? "--:--" : eta, displayFile)

        print(line.prefix(terminalWidth), terminator: "")
        fflush(stdout)
    }

    private func updateDisplayForFile(current: UInt64, total: UInt64) {
        guard !quiet else { return }

        let percent = Double(current) / Double(total) * 100

        // Build progress bar for current file
        let barWidth = max(20, terminalWidth - 50)
        let filled = Int(Double(barWidth) * Double(current) / Double(total))
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: barWidth - filled)

        let maxFileLen = 20
        let displayFile = currentFile.count > maxFileLen
            ? "..." + currentFile.suffix(maxFileLen - 3)
            : currentFile

        let line = String(format: "\r[%@] %3.0f%% %@/%@ %@",
                          bar, percent, formatBytes(current), formatBytes(total), displayFile)

        print(line.prefix(terminalWidth), terminator: "")
        fflush(stdout)
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
