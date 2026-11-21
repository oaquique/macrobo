import ArgumentParser
import Foundation
import MacroboLib

@main
struct MacroboCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macrobo",
        abstract: "Fast, multi-threaded file replication tool for macOS",
        discussion: """
            macrobo is a fast, multi-threaded file replication tool for macOS.
            It supports mirroring, multi-threaded copying, retry on failure, and more.

            Examples:
              macrobo ~/Documents ~/Backup/Documents
              macrobo /source /dest --mirror
              macrobo /source /dest --mirror --threads 16 --exclude-dirs .git node_modules
              macrobo /source /dest --bwlimit 50M --verify
              macrobo /source /dest --progress json
              macrobo --job photos-backup
              macrobo --config ~/sync.conf --mirror

            Name clashes: when two source names are one name at the destination (a Mac disk
            ignores capital letters, so "Song.m4a" and "song.m4a" clash), the first in
            alphabetical order is copied and the other is left out and listed in the summary.

            Exit codes: 0 done; 1 a file failed or the run couldn't start; 3 done, but some
            files were left out for name clashes.
            """,
        version: BuildInfo.fullVersion
    )

    // MARK: - Positional Arguments

    @Argument(help: "Source directory to copy from")
    var source: String?

    @Argument(help: "Destination directory to copy to")
    var destination: String?

    // MARK: - Config Options

    @Option(name: .customLong("config"), help: "Path to a config file")
    var configFile: String?

    @Option(name: .customLong("job"), help: "Named job from ~/.config/macrobo/<name>.conf")
    var job: String?

    // MARK: - Directory Options

    @Flag(name: [.customShort("s"), .customLong("no-empty")],
          help: "Skip empty directories")
    var skipEmptyDirs = false

    @Flag(name: [.customShort("e"), .customLong("include-empty")],
          help: "Include empty directories (default)")
    var includeEmptyDirs = false

    @Flag(name: .customLong("mirror"),
          help: "Copy files and delete extras at destination")
    var mirror = false

    @Flag(name: .customLong("purge"),
          help: "Only delete destination files that aren't in the source; copies nothing")
    var purge = false

    @Flag(name: .customLong("allow-mass-delete"),
          help: "Let --mirror or --purge run from an empty source or delete more than half the destination")
    var allowMassDelete = false

    @Flag(name: .customLong("skip-hidden"),
          help: "Skip hidden files and folders (names starting with a dot)")
    var skipHidden = false

    // MARK: - File Comparison Options

    @Flag(name: .customLong("exclude-older"),
          help: "Only copy files if source is newer than destination")
    var excludeOlder = false

    @Flag(name: .customLong("exclude-extra"),
          help: "Don't delete extra files at destination")
    var excludeExtra = false

    @Flag(name: .customLong("include-same"),
          help: "Copy files even if identical at destination")
    var includeSame = false

    @Flag(name: [.customShort("c"), .customLong("checksum")],
          help: "When size matches but dates differ, compare samples of the contents (start, middle, end) instead of copying")
    var checksum = false

    @Flag(name: .customLong("checksum-full"),
          help: "Like --checksum, but compare every byte (slower, certain)")
    var checksumFull = false

    // MARK: - Retry Options

    @Option(name: [.customShort("r"), .customLong("retry")],
            help: "Number of retries on failed copies")
    var retryCount: Int = 3

    @Option(name: [.customShort("w"), .customLong("wait")],
            help: "Wait time between retries in seconds")
    var retryWait: Int = 5

    // MARK: - Performance Options

    @Option(name: [.customShort("t"), .customLong("threads")],
            help: "Number of parallel copy threads")
    var threadCount: Int = 8

    @Flag(name: .customLong("no-resume"),
          help: "Disable resume for interrupted copies")
    var noResume = false

    @Option(name: .customLong("bwlimit"),
            help: "Bandwidth limit (e.g., 50M for 50 MB/s, 0 for unlimited)")
    var bwlimit: String?

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

    @Option(name: .customLong("progress"), help: "Progress display mode: bar (default), json, or none")
    var progressMode: String?

    // MARK: - Copy Options

    @Flag(name: .customLong("no-attributes"),
          help: "Don't copy file attributes (timestamps and permissions)")
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

    // MARK: - Verification

    @Flag(name: .customLong("verify"), help: "Verify copied files by comparing full SHA256 checksums")
    var verify = false

    // MARK: - Dry Run

    @Flag(name: [.customShort("l"), .customLong("list"), .customLong("dry-run")],
          help: "List what would be copied and deleted, without changing anything")
    var dryRun = false

    // MARK: - Run

    func run() async throws {
        // Load config file if specified
        var loadedConfig: ConfigFile?
        if let configPath = configFile {
            loadedConfig = try ConfigFile.load(from: configPath)
        } else if let jobName = job {
            loadedConfig = try ConfigFile.loadJob(named: jobName)
        }

        // Resolve source and destination (CLI overrides config)
        let resolvedSource: String
        if let src = source {
            resolvedSource = src
        } else if let src = loadedConfig?.values["source"] {
            resolvedSource = src
        } else {
            fputs("Error: source is required (provide as argument or in config file)\n", stderr)
            throw ExitCode(1)
        }

        let resolvedDest: String
        if let dst = destination {
            resolvedDest = dst
        } else if let dst = loadedConfig?.values["destination"] {
            resolvedDest = dst
        } else {
            fputs("Error: destination is required (provide as argument or in config file)\n", stderr)
            throw ExitCode(1)
        }

        let sourceURL = URL(fileURLWithPath: (resolvedSource as NSString).expandingTildeInPath)
        let destURL = URL(fileURLWithPath: (resolvedDest as NSString).expandingTildeInPath)

        var options = CopyOptions(source: sourceURL, destination: destURL)

        // Apply config file values first (CLI flags override below)
        var configWarnings: [String] = []
        if let config = loadedConfig {
            config.apply(to: &options, warnings: &configWarnings)
        }

        // Directory options
        options.includeEmptyDirectories = !skipEmptyDirs
        if mirror { options.mirror = true }
        if purge { options.purge = true }
        if allowMassDelete { options.allowMassDelete = true }
        if skipHidden { options.skipHidden = true }

        // Comparison options
        if excludeOlder { options.excludeOlder = true }
        if excludeExtra { options.excludeExtra = true }
        if includeSame { options.includeSame = true }
        if checksum { options.checksum = true }
        if checksumFull { options.checksumFull = true }

        // Retry options
        options.retryCount = retryCount
        options.retryWaitSeconds = retryWait

        // Performance options
        options.threadCount = threadCount
        options.resumePartial = !noResume
        if let bwlimit = bwlimit {
            options.bandwidthLimit = parseSize(bwlimit) ?? 0
        }

        // Filtering options
        if !excludeFiles.isEmpty { options.excludeFiles = excludeFiles }
        if !excludeDirs.isEmpty { options.excludeDirectories = excludeDirs }
        if !includeFiles.isEmpty { options.includeFiles = includeFiles }
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
        if verbose { options.verbose = true }
        if quiet { options.quiet = true }

        // Copy options
        options.copyAttributes = !noAttributes
        options.copyTimestamps = !noTimestamps
        options.copyPermissions = !noPermissions
        options.copyExtendedAttributes = !noXattr

        // Move options
        if moveFiles { options.moveFiles = true }
        if moveAll { options.moveAll = true }

        // Dry run
        if dryRun { options.dryRun = true }
        if verify { options.verify = true }

        // Progress mode
        let resolvedProgressMode: CopyOptions.ProgressMode
        if let modeStr = progressMode {
            resolvedProgressMode = CopyOptions.ProgressMode(rawValue: modeStr) ?? .bar
        } else {
            resolvedProgressMode = options.progressMode
        }
        options.progressMode = resolvedProgressMode

        // Create components
        // JSON mode keeps stdout pure JSON: the logger's console lines are suppressed
        // (errors still go to stderr, and everything still goes to the log file)
        let logger = Logger(
            logFile: options.logFile,
            append: options.appendLog,
            verbose: options.verbose && resolvedProgressMode != .json,
            quiet: options.quiet || resolvedProgressMode == .json
        )
        // In verbose mode, suppress the live display (file-by-file output is shown instead)
        let suppressProgress = options.quiet || options.verbose || resolvedProgressMode == .none
        let progress = ProgressReporter(
            quiet: suppressProgress,
            mode: resolvedProgressMode,
            showSteps: !options.quiet
        )
        let engine = CopyEngine(options: options, logger: logger, progress: progress)

        // Print header
        let suppressBanner = options.quiet || resolvedProgressMode == .json
        if !suppressBanner {
            let title = "macrobo - Multi-threaded File Copy for macOS (v\(BuildInfo.fullVersion))"
            let separator = String(repeating: "═", count: title.count)
            print("")
            print("  \(title)")
            print("  \(separator)")
            print("")

            // Print config warnings
            for warning in configWarnings {
                print("  Warning: \(warning)")
            }
        }

        // Run copy
        do {
            let result = try await engine.run()

            // Exit codes: 1 when any file failed; 3 when the run finished but some files were
            // left out because their names clash at the destination; 0 otherwise
            if result.filesFailed > 0 {
                throw ExitCode(1)
            }
            if !result.nameClashes.isEmpty {
                throw ExitCode(3)
            }
        } catch let error as MacroboError {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
    }

}
