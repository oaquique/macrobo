import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared formatting utilities used across macrobo components
/// Format bytes for human-readable display (macOS decimal units, base 1000)
public func formatBytes(_ bytes: UInt64, precision: Int = 2) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0

    while value >= 1000 && unitIndex < units.count - 1 {
        value /= 1000
        unitIndex += 1
    }

    if unitIndex == 0 {
        return "\(bytes) \(units[unitIndex])"
    } else {
        return String(format: "%.\(precision)f %@", value, units[unitIndex])
    }
}

/// Format a time duration for display
/// - Parameter compact: If true, uses compact format (02m35s). If false, uses readable format (2m 35s).
public func formatDuration(_ seconds: TimeInterval, compact: Bool = false) -> String {
    let secs = Int(max(0, seconds))
    if compact {
        if secs >= 86400 {
            return String(format: "%02dd%02dh", secs / 86400, (secs % 86400) / 3600)
        } else if secs >= 3600 {
            return String(format: "%02dh%02dm", secs / 3600, (secs % 3600) / 60)
        } else {
            return String(format: "%02dm%02ds", secs / 60, secs % 60)
        }
    } else {
        if seconds < 60 {
            return String(format: "%.1f seconds", seconds)
        } else if secs < 3600 {
            return "\(secs / 60)m \(secs % 60)s"
        } else {
            return "\(secs / 3600)h \((secs % 3600) / 60)m"
        }
    }
}

/// Truncate a string to a max display width, showing end with ellipsis prefix
public func formatTruncate(_ text: String, maxWidth: Int, pad: Bool = false) -> String {
    guard maxWidth > 0 else { return "" }
    if text.count > maxWidth {
        if maxWidth > 3 {
            return "..." + text.suffix(maxWidth - 3)
        }
        return String(text.prefix(maxWidth))
    } else if pad {
        return text + String(repeating: " ", count: maxWidth - text.count)
    }
    return text
}

/// Parses a human-readable size string (e.g., "100M", "1G") using macOS decimal units
public func parseSize(_ sizeStr: String) -> UInt64? {
    let str = sizeStr.uppercased().trimmingCharacters(in: .whitespaces)
    guard !str.isEmpty else { return nil }

    // Use decimal (base 1000) to match macOS conventions
    let multipliers: [Character: UInt64] = [
        "K": 1_000,
        "M": 1_000_000,
        "G": 1_000_000_000,
        "T": 1_000_000_000_000
    ]

    if let lastChar = str.last, let multiplier = multipliers[lastChar] {
        let numStr = String(str.dropLast())
        guard let num = UInt64(numStr) else { return nil }
        return num * multiplier
    } else {
        return UInt64(str)
    }
}

/// Formats a count with thousands separators ("6,779"), independent of the user's locale
public func formatCount(_ n: Int) -> String {
    let digits = String(abs(n))
    var grouped = ""
    for (i, ch) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { grouped.append(",") }
        grouped.append(ch)
    }
    return n < 0 ? "-" + grouped : grouped
}

/// "1 file", "6,779 files"
public func formatCount(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(formatCount(n)) \(n == 1 ? singular : (plural ?? singular + "s"))"
}

/// Seconds for a finished step: "0.6 s", "42.0 s", or "02m13s" from 100 seconds up
public func formatStepSeconds(_ seconds: TimeInterval) -> String {
    seconds < 100 ? String(format: "%.1f s", seconds) : formatDuration(seconds, compact: true)
}

/// One line of the step checklist:
/// "✓ Listed source        6,779 files, 1,337 folders                       0.6 s"
/// The name takes 21 columns; the time is right-aligned to end at column 79 (77 without a mark),
/// so every finished step's time lines up. Text too long for that is followed by two spaces.
public func formatStepLine(mark: String, name: String, detail: String, seconds: TimeInterval? = nil) -> String {
    let paddedName = name.count < 21 ? name + String(repeating: " ", count: 21 - name.count) : name + " "
    let head = (mark.isEmpty ? "" : mark + " ") + paddedName + detail
    guard let seconds else { return head }
    let time = formatStepSeconds(seconds)
    let lineEnd = mark.isEmpty ? 77 : 79
    let gap = lineEnd - head.count - time.count
    return head + String(repeating: " ", count: max(2, gap)) + time
}

/// "about 14 min left" for a step with a known total, once it has run for 5 seconds and made
/// progress (earlier estimates jump around). Nil while there is no estimate yet.
public func formatTimeLeft(elapsed: TimeInterval, done: Double, total: Double) -> String? {
    guard elapsed >= 5, done > 0, total > done else { return nil }
    let left = elapsed / done * (total - done)
    if left < 60 { return "under a minute left" }
    let minutes = Int((left / 60).rounded(.up))
    if minutes < 60 { return "about \(minutes) min left" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
}

/// Terminal dimension utilities
public enum Terminal {
    public static var width: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }
}
