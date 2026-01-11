import ArgumentParser
import Foundation

@main
struct MacroboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macrobo",
        abstract: "Robust file copy utility for macOS (robocopy clone)",
        discussion: """
            macrobo is a powerful file copying tool inspired by Windows' robocopy.
            It supports mirroring, multi-threaded copying, retry on failure, and more.

            Examples:
              macrobo ~/Documents ~/Backup/Documents
              macrobo /source /dest --mirror
              macrobo /source /dest --mirror --threads 16 --exclude-dirs .git node_modules
            """,
        version: BuildInfo.fullVersion
    )

    // MARK: - Positional Arguments

    @Argument(help: "Source directory to copy from")
    var source: String

    @Argument(help: "Destination directory to copy to")
    var destination: String

    // MARK: - Directory Options

    @Flag(name: [.customShort("s"), .customLong("no-empty")],
          help: "Skip empty directories (like robocopy /S)")
    var skipEmptyDirs = false

    @Flag(name: [.customShort("e"), .customLong("include-empty")],
          help: "Include empty directories (like robocopy /E, default)")
    var includeEmptyDirs = false

    @Flag(name: .customLong("mirror"),
          help: "Mirror mode: copy files and delete extras at destination (like robocopy /MIR)")
    var mirror = false

    @Flag(name: .customLong("purge"),
          help: "Delete destination files that no longer exist in source (like robocopy /PURGE)")
    var purge = false

    // MARK: - File Comparison Options

    @Flag(name: .customLong("exclude-older"),
          help: "Only copy files if source is newer than destination (like robocopy /XO)")
    var excludeOlder = false

    @Flag(name: .customLong("exclude-extra"),
          help: "Don't delete extra files at destination (like robocopy /XX)")
    var excludeExtra = false

    @Flag(name: .customLong("include-same"),
          help: "Copy files even if identical at destination (like robocopy /IS)")
    var includeSame = false

    // MARK: - Retry Options

    @Option(name: [.customShort("r"), .customLong("retry")],
            help: "Number of retries on failed copies (default: 3)")
    var retryCount: Int = 3

    @Option(name: [.customShort("w"), .customLong("wait")],
            help: "Wait time between retries in seconds (default: 5)")
    var retryWait: Int = 5

    // MARK: - Performance Options

    @Option(name: [.customShort("t"), .customLong("threads")],
            help: "Number of parallel copy threads (default: 8)")
    var threadCount: Int = 8

    @Flag(name: .customLong("no-resume"),
          help: "Disable resume for interrupted copies")
    var noResume = false

    // MARK: - Filtering Options

    @Option(name: .customLong("exclude-files"),
            parsing: .upToNextOption,
            help: "File patterns to exclude (e.g., *.tmp *.log)")
    var excludeFiles: [String] = []

    @Option(name: .customLong("exclude-dirs"),
            parsing: .upToNextOption,
            help: "Directory names to exclude (e.g., .git node_modules)")
    var excludeDirs: [String] = []

    @Option(name: .customLong("include-files"),
            parsing: .upToNextOption,
            help: "Only include files matching these patterns")
    var includeFiles: [String] = []

    @Option(name: .customLong("max-size"),
            help: "Maximum file size to copy (e.g., 100M, 1G)")
    var maxSize: String?

    @Option(name: .customLong("min-size"),
            help: "Minimum file size to copy (e.g., 1K, 1M)")
    var minSize: String?

    // MARK: - Logging Options

    @Option(name: .customLong("log"),
            help: "Log file path (overwrites existing)")
    var logFile: String?

    @Option(name: .customLong("log-append"),
            help: "Log file path (appends to existing)")
    var logAppendFile: String?

    @Flag(name: [.customShort("v"), .customLong("verbose")],
          help: "Verbose output")
    var verbose = false

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Quiet mode - minimal output")
    var quiet = false

    // MARK: - Copy Options

    @Flag(name: .customLong("no-attributes"),
          help: "Don't copy file attributes")
    var noAttributes = false

    @Flag(name: .customLong("no-timestamps"),
          help: "Don't preserve timestamps")
    var noTimestamps = false

    @Flag(name: .customLong("no-permissions"),
          help: "Don't preserve POSIX permissions")
    var noPermissions = false

    @Flag(name: .customLong("no-xattr"),
          help: "Don't copy extended attributes")
    var noXattr = false

    // MARK: - Move Options

    @Flag(name: .customLong("move"),
          help: "Move files (delete source after copy)")
    var moveFiles = false

    @Flag(name: .customLong("move-all"),
          help: "Move files and directories")
    var moveAll = false

    // MARK: - Dry Run

    @Flag(name: [.customShort("l"), .customLong("list"), .customLong("dry-run")],
          help: "List only - don't actually copy (dry run)")
    var dryRun = false

    // MARK: - Run

    func run() async throws {
        let sourceURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)

        var options = CopyOptions(source: sourceURL, destination: destURL)

        // Directory options
        options.includeEmptyDirectories = !skipEmptyDirs
        options.mirror = mirror
        options.purge = purge

        // Comparison options
        options.excludeOlder = excludeOlder
        options.excludeExtra = excludeExtra
        options.includeSame = includeSame

        // Retry options
        options.retryCount = retryCount
        options.retryWaitSeconds = retryWait

        // Performance options
        options.threadCount = threadCount
        options.resumePartial = !noResume

        // Filtering options
        options.excludeFiles = excludeFiles
        options.excludeDirectories = excludeDirs
        options.includeFiles = includeFiles
        if let maxSize = maxSize {
            options.maxFileSize = parseSize(maxSize)
        }
        if let minSize = minSize {
            options.minFileSize = parseSize(minSize)
        }

        // Logging options
        if let logAppend = logAppendFile {
            options.logFile = URL(fileURLWithPath: (logAppend as NSString).expandingTildeInPath)
            options.appendLog = true
        } else if let log = logFile {
            options.logFile = URL(fileURLWithPath: (log as NSString).expandingTildeInPath)
            options.appendLog = false
        }
        options.verbose = verbose
        options.quiet = quiet

        // Copy options
        options.copyAttributes = !noAttributes
        options.copyTimestamps = !noTimestamps
        options.copyPermissions = !noPermissions
        options.copyExtendedAttributes = !noXattr

        // Move options
        options.moveFiles = moveFiles
        options.moveAll = moveAll

        // Dry run
        options.dryRun = dryRun

        // Create components
        let logger = Logger(
            logFile: options.logFile,
            append: options.appendLog,
            verbose: options.verbose,
            quiet: options.quiet
        )
        // In verbose mode, suppress progress bar (file-by-file output is shown instead)
        let progress = ProgressReporter(quiet: options.quiet || options.verbose)
        let engine = CopyEngine(options: options, logger: logger, progress: progress)

        // Print header
        if !quiet {
            print("")
            print("  macrobo - Robust File Copy for macOS")
            print("  =====================================")
            print("")
        }

        // Run copy
        do {
            let result = try await engine.run()

            // Exit with error code if there were failures
            if result.filesFailed > 0 {
                throw ExitCode(1)
            }
        } catch let error as MacroboError {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
    }

    /// Parses a human-readable size string (e.g., "100M", "1G") to bytes
    private func parseSize(_ sizeStr: String) -> UInt64? {
        let str = sizeStr.uppercased().trimmingCharacters(in: .whitespaces)
        guard !str.isEmpty else { return nil }

        let multipliers: [Character: UInt64] = [
            "K": 1024,
            "M": 1024 * 1024,
            "G": 1024 * 1024 * 1024,
            "T": 1024 * 1024 * 1024 * 1024
        ]

        if let lastChar = str.last, let multiplier = multipliers[lastChar] {
            let numStr = String(str.dropLast())
            guard let num = UInt64(numStr) else { return nil }
            return num * multiplier
        } else {
            return UInt64(str)
        }
    }
}
