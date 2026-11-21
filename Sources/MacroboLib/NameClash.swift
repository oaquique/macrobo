import Foundation

/// How a destination compares file names. Two source names that differ only in a way the
/// destination ignores can't both exist there: the second would land on the first.
public enum NameMatching: Sendable, Equatable {
    /// Every distinct name is a distinct file (case-sensitive, and no Unicode normalization)
    case exact
    /// Case-sensitive, but accented letters stored two ways (NFC/NFD) are one name (APFS, HFS+)
    case ignoresNormalization
    /// Capital letters don't matter, nor do ß and ss or NFC/NFD (most Mac disks, SMB shares)
    case ignoresCase

    /// The name as the destination sees it: equal keys mean the same file there
    public func key(_ path: String) -> String {
        switch self {
        case .exact:
            return path
        case .ignoresNormalization:
            return path.precomposedStringWithCanonicalMapping
        case .ignoresCase:
            // Full case folding: "Die großen" and "Die Grossen" both become "die grossen"
            return path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        }
    }

    /// Why two such names clash, for the summary
    var reason: String {
        switch self {
        case .ignoresCase: return "the destination ignores capital letters, so only one fits"
        case .exact, .ignoresNormalization: return "the destination treats these names as the same, so only one fits"
        }
    }

    /// Asks the volume holding `path` (or its nearest existing parent, for a destination
    /// that doesn't exist yet) how it compares names
    public static func of(_ path: String) -> NameMatching {
        var dir = (path as NSString).standardizingPath
        while !dir.isEmpty, dir != "/", !FileManager.default.fileExists(atPath: dir) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        if dir.isEmpty { dir = "/" }
        // 0: case-insensitive; 1: case-sensitive; -1: unknown (treated as case-sensitive)
        if pathconf(dir, _PC_CASE_SENSITIVE) == 0 {
            return .ignoresCase
        }
        let type = VolumeInfo.fileSystemType(of: dir)
        return type == "apfs" || type == "hfs" ? .ignoresNormalization : .exact
    }
}

/// A source file left out because another source file has the same name at the destination
public struct NameClash: Sendable, Equatable {
    /// Relative path of the file not copied ("/a/b.m4a")
    public let path: String
    /// Relative path of the file copied in its place
    public let sameAs: String
}

public enum NameClashes {
    /// Splits the source files into those to copy and those left out. For each group of names
    /// the destination sees as one, the first in alphabetical order of the full path is kept,
    /// so every run picks the same file. Folders whose names clash simply merge: only files
    /// whose full paths clash are left out.
    public static func resolve(_ files: [FileInfo], matching: NameMatching) -> (keep: [FileInfo], clashes: [NameClash]) {
        guard matching != .exact else { return (files, []) }
        var groups: [String: [Int]] = [:]
        for (i, file) in files.enumerated() {
            groups[matching.key(file.relativePath), default: []].append(i)
        }
        var left = Set<Int>()
        var clashes: [NameClash] = []
        for indices in groups.values where indices.count > 1 {
            let sorted = indices.sorted { files[$0].relativePath < files[$1].relativePath }
            let kept = files[sorted[0]].relativePath
            for i in sorted.dropFirst() {
                left.insert(i)
                clashes.append(NameClash(path: files[i].relativePath, sameAs: kept))
            }
        }
        guard !left.isEmpty else { return (files, []) }
        let keep = files.indices.filter { !left.contains($0) }.map { files[$0] }
        return (keep, clashes.sorted { $0.path < $1.path })
    }

    /// For each group of source folders the destination sees as one, the spelling to create
    /// first (alphabetical order), so the merged folder's name doesn't depend on which copy
    /// thread gets there first
    public static func folderSpellings(_ folders: Set<String>, matching: NameMatching) -> [String] {
        guard matching != .exact else { return [] }
        var groups: [String: [String]] = [:]
        for folder in folders {
            groups[matching.key(folder), default: []].append(folder)
        }
        return groups.values.filter { $0.count > 1 }.map { $0.min()! }.sorted()
    }
}
