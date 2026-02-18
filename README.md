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

# Dry run to preview what would be copied
macrobo /source /dest --list

# Move files instead of copying
macrobo /source /dest --move
```

### Options

| Option | Description |
|---|---|
| `--mirror` | Copy files and delete extras at destination |
| `--purge` | Delete destination files not in source |
| `--exclude-older` | Only copy if source is newer |
| `-t, --threads N` | Parallel copy threads (default: 8) |
| `-r, --retry N` | Retries on failure (default: 3) |
| `-w, --wait N` | Wait between retries in seconds (default: 5) |
| `--exclude-files` | File patterns to exclude (e.g., `*.tmp *.log`) |
| `--exclude-dirs` | Directory names to exclude (e.g., `.git node_modules`) |
| `--include-files` | Only include matching file patterns |
| `--max-size` | Maximum file size (e.g., `100M`, `1G`) |
| `--min-size` | Minimum file size (e.g., `1K`, `1M`) |
| `--move` | Move files (delete source after copy) |
| `--move-all` | Move files and directories |
| `-l, --list, --dry-run` | List only, don't copy |
| `--log PATH` | Log to file (overwrite) |
| `--log-append PATH` | Log to file (append) |
| `-v, --verbose` | Verbose output |
| `-q, --quiet` | Minimal output |
| `--no-resume` | Disable resume for interrupted copies |
| `--no-attributes` | Don't copy file attributes |
| `--no-timestamps` | Don't preserve timestamps |
| `--no-permissions` | Don't preserve POSIX permissions |
| `--no-xattr` | Don't copy extended attributes |

## License

[MIT](LICENSE)
