import Foundation

/// Shared formatting utilities used across macrobo components
/// Format bytes for human-readable display (macOS decimal units, base 1000)
func formatBytes(_ bytes: UInt64, precision: Int = 2) -> String {
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
