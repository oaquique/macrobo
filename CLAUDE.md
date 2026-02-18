# macrobo - Build Instructions

## Building

**Always use `build.sh` to build macrobo.** Do NOT use `swift build` directly.

```bash
./build.sh              # Release build (default)
./build.sh --debug      # Debug build
./build.sh --universal  # Universal binary (arm64 + x86_64)
```

`build.sh` auto-generates `BuildInfo.swift` with the version number derived from the git commit count. Running `swift build` directly skips this step and produces a binary with a stale version number.

## Installing

### Via Homebrew (recommended)

```bash
brew tap oaquique/tap
brew install macrobo
```

### From source

After building, copy the release binary to `/usr/local/bin`:

```bash
sudo cp .build/release/macrobo /usr/local/bin/macrobo
```

## Version Scheme

- Format: `1.0.<build>` where `<build>` is the git commit count (`git rev-list --count HEAD`)
- The build number only increments after a commit, so commit changes before building a release

## Releasing

1. Commit all changes and push
2. `./build.sh --universal` to build the universal binary
3. `tar -czf macrobo-<version>-universal.tar.gz -C .build/apple/Products/Release macrobo`
4. `git tag v<version> && git push origin v<version>`
5. `gh release create v<version> macrobo-<version>-universal.tar.gz --title "macrobo v<version>" --generate-notes`
6. Update `sha256` and `url` in the [homebrew-tap formula](https://github.com/oaquique/homebrew-tap/blob/main/Formula/macrobo.rb)
