# macrobo - Build Instructions

## Building

**Always use `build.sh` to build macrobo.** Do NOT use `swift build` directly.

```bash
./build.sh          # Release build (default)
./build.sh --debug  # Debug build
```

`build.sh` auto-generates `BuildInfo.swift` with the version number derived from the git commit count. Running `swift build` directly skips this step and produces a binary with a stale version number.

## Installing

After building, copy the release binary to `/usr/local/bin`:

```bash
sudo cp .build/release/macrobo /usr/local/bin/macrobo
```

## Version Scheme

- Format: `1.0.<build>` where `<build>` is the git commit count (`git rev-list --count HEAD`)
- The build number only increments after a commit, so commit changes before building a release
