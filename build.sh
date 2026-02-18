#!/bin/bash
# Build script for macrobo - auto-increments build number

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_INFO="$SCRIPT_DIR/Sources/macrobo/BuildInfo.swift"

# Get build number from git commit count
BUILD_NUMBER=$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo "0")

# Update BuildInfo.swift
cat > "$BUILD_INFO" << EOF
import Foundation

/// Build information - auto-generated, do not edit manually
enum BuildInfo {
    static let version = "1.0"
    static let build = $BUILD_NUMBER
    static var fullVersion: String { "\(version).\(build)" }
}
EOF

echo "Building macrobo version 1.0.$BUILD_NUMBER"

# Build release by default, debug with --debug, or universal with --universal
if [[ "$1" == "--debug" ]]; then
    swift build
elif [[ "$1" == "--universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
else
    swift build -c release
fi

echo "Build complete: macrobo 1.0.$BUILD_NUMBER"
