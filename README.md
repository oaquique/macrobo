# macrobo

Fast, multi-threaded file replication tool for macOS.

macrobo copies files in parallel using multiple threads, supports mirroring, retry on failure, APFS clonefile acceleration, and resumable transfers.

## Install

```bash
brew tap oaquique/tap
brew install macrobo
```

## Usage

```bash
macrobo <source> <destination> [options]
```

### Examples

```bash
# Basic copy
macrobo ~/Documents ~/Backup/Documents

# Mirror (copy + delete extras at destination)
macrobo /source /dest --mirror

# Multi-threaded with exclusions
macrobo /source /dest --threads 16 --exclude-dirs .git node_modules

# Only delete destination files that aren't in the source (copies nothing)
macrobo /source /dest --purge

# Dry run: list every file a mirror would copy and delete, changing nothing
macrobo /source /dest --mirror --dry-run

# Move files instead of copying
macrobo /source /dest --move
```

### Options

| Option | Description |
|---|---|
| `--mirror` | Copy files and delete extras at destination |
| `--purge` | Only delete destination files that aren't in the source; copies nothing |
| `--allow-mass-delete` | Let `--mirror` or `--purge` run from an empty source or delete more than half the destination |
| `--skip-hidden` | Skip hidden files and folders (names starting with a dot); they're copied by default |
| `--exclude-older` | Only copy if source is newer |
| `--exclude-extra` | Don't delete extra files at destination |
| `--include-same` | Copy files even if identical at destination |
| `-c, --checksum` | When size matches but dates differ, compare samples of the contents (start, middle, end) instead of copying; identical files get the source's date, so they're checked only once |
| `--checksum-full` | Like `--checksum`, but compare every byte (slower, certain) |
| `--verify` | Verify copied files by comparing full SHA256 checksums |
| `-t, --threads N` | Parallel copy threads (default: 8) |
| `--bwlimit` | Bandwidth limit (e.g., `50M` for 50 MB/s, `0` for unlimited) |
| `-r, --retry N` | Retries on failure (default: 3) |
| `-w, --wait N` | Wait between retries in seconds (default: 5) |
| `--exclude-files` | File patterns to exclude (e.g., `*.tmp *.log`) |
| `--exclude-dirs` | Directory names to exclude (e.g., `.git node_modules`) |
| `--include-files` | Only include matching file patterns |
| `--max-size` | Maximum file size (e.g., `100M`, `1G`) |
| `--min-size` | Minimum file size (e.g., `1K`, `1M`) |
| `--move` | Move files (delete source after copy) |
| `--move-all` | Move files and directories (source folders are removed once empty) |
| `-l, --list, --dry-run` | List what would be copied and deleted, without changing anything |
| `--log PATH` | Log to file (overwrite) |
| `--log-append PATH` | Log to file (append) |
| `-v, --verbose` | Verbose output |
| `-q, --quiet` | Minimal output |
| `--progress MODE` | `bar` (default), `json`, or `none`. When the output goes to a file or a pipe, `bar` writes only finished lines, with no live display |
| `-s, --no-empty` | Skip empty directories |
| `-e, --include-empty` | Include empty directories (default) |
| `--config PATH` | Read options from a config file |
| `--job NAME` | Run a named job from `~/.config/macrobo/<name>.conf` |
| `--no-resume` | Disable resume for interrupted copies |
| `--no-attributes` | Don't copy file attributes (timestamps and permissions) |
| `--no-timestamps` | Don't preserve timestamps |
| `--no-permissions` | Don't preserve POSIX permissions |
| `--no-xattr` | Don't copy extended attributes |

## Safety

macrobo stops before listing anything when it can't write to the destination, for example the leftover folder of a share that isn't mounted, instead of failing on every file.

`--mirror` and `--purge` stop before deleting anything when the source is empty (for example, a disk that isn't mounted) or when they would delete more than half of the destination. Add `--allow-mass-delete` to go ahead. If a source folder can't be read, nothing under it is deleted at the destination.

An interrupted copy leaves a `.macrobo-partial` file beside the destination file, and the next run resumes it, unless the source changed after the partial file was written. Then the copy starts over, so old and new bytes are never mixed. When a later run finds the destination file already complete, it removes the leftover partial file. A partial file written to in the last 10 minutes is left alone, in case another copy is still writing it.

## License

[MIT](LICENSE)
