import Foundation

/// Logger for file and console output
public actor Logger {
    private let logFile: URL?
    private let appendMode: Bool
    private let verbose: Bool
    private let quiet: Bool
    private var fileHandle: FileHandle?
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

    private var totalFiles: Int = 0
    private var processedFiles: Int = 0
    private var suppressConsoleErrors: Bool = false
    private var bufferedErrors: [String] = []

    public init(logFile: URL? = nil, append: Bool = false, verbose: Bool = false, quiet: Bool = false) {
        self.logFile = logFile
        self.appendMode = append
        self.verbose = verbose
        self.quiet = quiet
    }

    /// Sets the total file count for progress display
    func setTotalFiles(_ total: Int) {
        self.totalFiles = total
        self.processedFiles = 0
    }

    /// Opens the log file for writing
    func open() throws {
        guard let logFile = logFile else { return }

        let fm = FileManager.default

        if appendMode && fm.fileExists(atPath: logFile.path) {
            fileHandle = try FileHandle(forWritingTo: logFile)
            fileHandle?.seekToEndOfFile()
        } else {
            fm.createFile(atPath: logFile.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: logFile)
        }

        // Write header
        let header = """
            ----------------------------------------------------------------
            macrobo - Started at \(ISO8601DateFormatter().string(from: Date()))
            ----------------------------------------------------------------

            """
        writeToFile(header)
    }

    /// Closes the log file
    func close() {
        if let handle = fileHandle {
            let footer = """

                ----------------------------------------------------------------
                macrobo - Finished at \(ISO8601DateFormatter().string(from: Date()))
                ----------------------------------------------------------------
                """
            writeToFile(footer)
            try? handle.close()
            fileHandle = nil
        }
    }

    /// Logs an info message
    func info(_ message: String) {
        if !quiet {
            print(message)
        }
        writeToFile(message)
    }

    /// Logs a verbose message (only if verbose mode is enabled)
    func debug(_ message: String) {
        if verbose {
            print("  \(message)")
        }
        writeToFile("  \(message)")
    }

    /// Logs an error message
    func error(_ message: String) {
        let errorMessage = "ERROR: \(message)"
        if suppressConsoleErrors {
            bufferedErrors.append(errorMessage)
        } else {
            fputs("\(errorMessage)\n", stderr)
        }
        writeToFile(errorMessage)
    }

    /// Suppresses console error output (buffers them for later)
    func beginProgressDisplay() {
        suppressConsoleErrors = true
        bufferedErrors.removeAll()
    }

    /// Re-enables console error output and flushes buffered errors
    func endProgressDisplay() {
        suppressConsoleErrors = false
        for error in bufferedErrors {
            fputs("\(error)\n", stderr)
        }
        bufferedErrors.removeAll()
    }

    /// Logs a warning message
    func warning(_ message: String) {
        let warningMessage = "WARNING: \(message)"
        if !quiet {
            print(warningMessage)
        }
        writeToFile(warningMessage)
    }

    /// Logs progress during a file copy (updates in place)
    func logFileProgress(fileName: String, currentBytes: UInt64, totalBytes: UInt64) {
        guard verbose && !quiet else { return }

        let percent = totalBytes > 0 ? Int(Double(currentBytes) / Double(totalBytes) * 100) : 0
        let currentStr = formatBytes(currentBytes)
        let totalStr = formatBytes(totalBytes)
        let displayName = formatTruncate(fileName, maxWidth: 30)

        // Build mini progress bar (15 chars)
        let barWidth = 15
        let filled = Int(Double(barWidth) * Double(percent) / 100.0)
        let bar = String(repeating: "=", count: filled) + ">" + String(repeating: " ", count: max(0, barWidth - filled - 1))

        // Format: "  COPY: [======>        ] 45% filename (1.2/4.5 MB)"
        // Fixed-width elements first for alignment
        let line = String(format: "  COPY: [%@] %3d%% %@ (%@/%@)", bar, percent, displayName, currentStr, totalStr)

        // Overwrite current line
        print("\r" + line.padding(toLength: terminalWidth - 1, withPad: " ", startingAt: 0), terminator: "")
        fflush(stdout)
    }

    /// Clears the current progress line (call before printing final result)
    func clearProgressLine() {
        guard verbose && !quiet else { return }
        print("\r" + String(repeating: " ", count: terminalWidth - 1) + "\r", terminator: "")
        fflush(stdout)
    }

    /// Logs a file operation result
    func logOperation(_ result: FileOperationResult) {
        switch result {
        case .copied(let source, let dest, let bytes):
            processedFiles += 1
            clearProgressLine()
            let sizeStr = formatBytes(bytes)
            let fileName = source.lastPathComponent
            // Format: "  COPY: filename (size) [n/total]"
            let progress = totalFiles > 0 ? " [\(processedFiles)/\(totalFiles)]" : ""
            let msg = "COPY: \(formatTruncate(fileName, maxWidth: 35)) (\(sizeStr))\(progress)"
            debug(msg)
            // Write full path to log file only
            writeToFile("  COPY: \(source.lastPathComponent) -> \(dest.path) (\(sizeStr))")
        case .skipped(let source, let reason, _):
            processedFiles += 1
            let progress = totalFiles > 0 ? " [\(processedFiles)/\(totalFiles)]" : ""
            let msg = "SKIP: \(formatTruncate(source.lastPathComponent, maxWidth: 35)) (\(reason))\(progress)"
            debug(msg)
        case .deleted(let path):
            let msg = "DEL: \(formatTruncate(path.lastPathComponent, maxWidth: 50))"
            debug(msg)
        case .failed(let path, let error):
            processedFiles += 1
            clearProgressLine()
            self.error("\(formatTruncate(path.lastPathComponent, maxWidth: 30)): \(error.localizedDescription)")
        case .directoryCreated(let path):
            let msg = "MKDIR: \(formatTruncate(path.path, maxWidth: 50))"
            debug(msg)
        case .directoryDeleted(let path):
            let msg = "RMDIR: \(formatTruncate(path.lastPathComponent, maxWidth: 50))"
            debug(msg)
        }
    }

    /// Logs the final summary
    func logSummary(_ result: CopyResult) {
        let summary = result.summary
        if !quiet {
            print(summary)
        }
        writeToFile(summary)
    }

    private func writeToFile(_ message: String) {
        guard let handle = fileHandle,
              let data = "\(message)\n".data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

}
