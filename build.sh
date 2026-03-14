#!/bin/bash
# Build script for macrobo - auto-increments build number

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_INFO="$SCRIPT_DIR/Sources/MacroboLib/BuildInfo.swift"
BUNDLE_ID="com.oaquique.macrobo"
ENTITLEMENTS="$SCRIPT_DIR/macrobo.entitlements"

# Get build number from git commit count
BUILD_NUMBER=$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo "0")

# Update BuildInfo.swift
cat > "$BUILD_INFO" << EOF
import Foundation

/// Build information - auto-generated, do not edit manually
public enum BuildInfo {
    public static let version = "2.0"
    public static let build = $BUILD_NUMBER
    public static var fullVersion: String { "\(version).\(build)" }
}
EOF

echo "Building macrobo version 2.0.$BUILD_NUMBER"

# Build release by default, debug with --debug, or universal with --universal
if [[ "$1" == "--debug" ]]; then
    swift build
elif [[ "$1" == "--universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
else
    swift build -c release
fi

# Locate the built binary
if [[ "$1" == "--universal" ]]; then
    BINARY="$SCRIPT_DIR/.build/apple/Products/Release/macrobo"
elif [[ "$1" == "--debug" ]]; then
    BINARY=$(swift build --show-bin-path)/macrobo
else
    BINARY=$(swift build -c release --show-bin-path)/macrobo
fi

# Code sign with a stable identity for TCC persistence
# Look for Developer ID first, then Apple Development, fall back to ad-hoc with stable identifier
SIGN_IDENTITY=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing with: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$BINARY"
else
    echo "Warning: No Developer ID or Apple Development certificate found."
    echo "Signing ad-hoc with stable identifier ($BUNDLE_ID)."
    echo "TCC will still forget permissions on each rebuild."
    echo "Install a signing certificate to fix this — see README."
    codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$BINARY"
fi

echo "Build complete: macrobo 2.0.$BUILD_NUMBER"
