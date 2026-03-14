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
