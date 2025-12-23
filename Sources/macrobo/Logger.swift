import Foundation

/// Logger for file and console output
actor Logger {
    private let logFile: URL?
    private let appendMode: Bool
    private let verbose: Bool
    private let quiet: Bool
    private var fileHandle: FileHandle?
    private let terminalWidth: Int
    private var totalFiles: Int = 0
    private var processedFiles: Int = 0

    init(logFile: URL? = nil, append: Bool = false, verbose: Bool = false, quiet: Bool = false) {
        self.logFile = logFile
        self.appendMode = append
        self.verbose = verbose
        self.quiet = quiet
        // Get terminal width for truncation
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            self.terminalWidth = Int(ws.ws_col)
        } else {
            self.terminalWidth = 80
        }
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
        fputs("\(errorMessage)\n", stderr)
        writeToFile(errorMessage)
    }

    /// Logs a warning message
    func warning(_ message: String) {
        let warningMessage = "WARNING: \(message)"
        if !quiet {
            print(warningMessage)
        }
        writeToFile(warningMessage)
    }

    /// Logs a file operation result
    func logOperation(_ result: FileOperationResult) {
        switch result {
        case .copied(let source, let dest, let bytes):
            processedFiles += 1
            let sizeStr = formatBytes(bytes)
            let fileName = source.lastPathComponent
            // Format: "  COPY: filename (size) [n/total]"
            let progress = totalFiles > 0 ? " [\(processedFiles)/\(totalFiles)]" : ""
            let msg = "COPY: \(truncate(fileName, max: 35)) (\(sizeStr))\(progress)"
            debug(msg)
            // Write full path to log file only
            writeToFile("  COPY: \(source.lastPathComponent) -> \(dest.path) (\(sizeStr))")
        case .skipped(let source, let reason):
            processedFiles += 1
            let progress = totalFiles > 0 ? " [\(processedFiles)/\(totalFiles)]" : ""
            let msg = "SKIP: \(truncate(source.lastPathComponent, max: 35)) (\(reason))\(progress)"
            debug(msg)
        case .deleted(let path):
            let msg = "DEL: \(truncate(path.lastPathComponent, max: 50))"
            debug(msg)
        case .failed(let path, let error):
            processedFiles += 1
            self.error("\(truncate(path.lastPathComponent, max: 30)): \(error.localizedDescription)")
        case .directoryCreated(let path):
            let msg = "MKDIR: \(truncatePath(path.path, max: 50))"
            debug(msg)
        }
    }

    /// Truncates a string to max length with ellipsis
    private func truncate(_ str: String, max: Int) -> String {
        guard str.count > max else { return str }
        return "..." + str.suffix(max - 3)
    }

    /// Truncates a path, keeping the end visible
    private func truncatePath(_ path: String, max: Int) -> String {
        guard path.count > max else { return path }
        return "..." + path.suffix(max - 3)
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

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(bytes) \(units[unitIndex])"
        } else {
            return String(format: "%.2f %@", value, units[unitIndex])
        }
    }
}
