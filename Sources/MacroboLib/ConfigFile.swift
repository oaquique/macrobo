import Foundation

public struct ConfigFile {
    public let values: [String: String]

    public static func load(from path: String) throws -> ConfigFile {
        let expandedPath = (path as NSString).expandingTildeInPath
        let content = try String(contentsOfFile: expandedPath, encoding: .utf8)
        return parse(content)
    }

    public static func loadJob(named name: String) throws -> ConfigFile {
        let configDir = ("~/.config/macrobo" as NSString).expandingTildeInPath
        let path = (configDir as NSString).appendingPathComponent("\(name).conf")
        return try load(from: path)
    }

    public static func parse(_ content: String) -> ConfigFile {
        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { values[key] = value }
        }
        return ConfigFile(values: values)
    }

    public func apply(to options: inout CopyOptions, warnings: inout [String]) {
        for (key, value) in values {
            switch key {
            case "source", "destination": break
            case "mirror": if value.lowercased() == "true" { options.mirror = true }
            case "purge": if value.lowercased() == "true" { options.purge = true }
            case "threads": if let n = Int(value) { options.threadCount = n }
            case "retry": if let n = Int(value) { options.retryCount = n }
            case "wait": if let n = Int(value) { options.retryWaitSeconds = n }
            case "exclude-files": options.excludeFiles = value.components(separatedBy: " ").filter { !$0.isEmpty }
            case "exclude-dirs": options.excludeDirectories = value.components(separatedBy: " ").filter { !$0.isEmpty }
            case "include-files": options.includeFiles = value.components(separatedBy: " ").filter { !$0.isEmpty }
            case "exclude-older": if value.lowercased() == "true" { options.excludeOlder = true }
            case "exclude-extra": if value.lowercased() == "true" { options.excludeExtra = true }
            case "include-same": if value.lowercased() == "true" { options.includeSame = true }
            case "checksum": if value.lowercased() == "true" { options.checksum = true }
            case "max-size": if let s = parseSize(value) { options.maxFileSize = s }
            case "min-size": if let s = parseSize(value) { options.minFileSize = s }
            case "bwlimit": if let s = parseSize(value) { options.bandwidthLimit = s }
            case "verbose": if value.lowercased() == "true" { options.verbose = true }
            case "quiet": if value.lowercased() == "true" { options.quiet = true }
            default: warnings.append("Unknown config key: \(key)")
            }
        }
    }
}
