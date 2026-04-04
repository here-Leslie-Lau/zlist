# zlist ⚡️

> A simple, colorful alternative to `ls` built with **Zig**.

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)](https://github.com/here-Leslie-Lau/zlist)
[![Zig Version](https://img.shields.io/badge/zig-0.16.0_dev-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

**Note**: This is my **first CLI tool in Zig**! 🚀

I built this project to learn Zig, get comfortable with manual memory management, and explore the standard library. It might not be the fastest or smallest `ls` clone (yet), but it's usable today and still getting better.

## ✨ Features

Even as a learning project, it already has some pretty handy features:

*   **Smart Grid Layout**: Automatically adjusts column widths so things stay compact and easy to scan.
*   **Visual Context**:
    *   **Nerd Fonts** support out of the box.
    *   Specific icons for your code (`Zig`, `Rust`, `Go`, `Python`, `JS/TS`, `C/C++`, etc.).
    *   Highlights directories and Markdown files so you spot them instantly.
*   **Smart Details**: Permissions, user/group, sizes, and timestamps in a format that's actually readable.
*   **Sorting**: Default is A-Z by name, plus options for **filename length**, **directories first**, **modification time** (newest first), and **file size** (largest first).
*   **Dig Deeper**: Use `-r` to recurse into subdirectories, or `-L` to cap the depth.
*   **Filters**: Quickly isolate just directories (`-d`) or just files (`-D`).
*   **Extension Filter**: Hide extensions you don't want to see with `-e` / `--ext` (for example: `--ext zig,md,ts`).
*   **Name Match Filter**: Only show entries whose names contain specific text with `-m` / `--match` (for example: `--match test`).
*   **Size Filter**: Filter files by size range with `--size` (for example: `--size gt:10K --size lte:2M`).
*   **Modified Time Filter**: Show only recently changed entries with `--changed-within` (for example: `--changed-within 7d`).
*   **Summary Report**: Use `-R` to see a quick count of files and folders after listing.
*   **Git Integration**: Use `-g` with `-l` to show Git status indicators in detailed view (`M` modified, `A` added, `D` deleted, `R` renamed, `?` untracked). Note: this only works in detailed mode (`-l`), not in grid mode.

## 📸 Preview

![Preview1](pics/screenshot.png)
![Preview2](pics/screenshot2.png)
![Preview3](pics/screenshot3.png)

*(Make sure you have a [Nerd Font](https://www.nerdfonts.com/) installed in your terminal to see the icons!)*

## 🚀 Installation

### Precompiled Binaries

Download the latest binary for your system from the [Releases](https://github.com/here-Leslie-Lau/zlist/releases) page.

> **Note**: Windows is currently **not supported** due to differences in file system APIs. Support may be added in future versions.

### From Source

Requirements: `zig` (master/0.16.0-dev recommended).

```bash
# 1. Clone the repo
git clone --recursive https://github.com/here-Leslie-Lau/zlist.git
cd zlist

# 2. Build in release mode [ReleaseFast, ReleaseSafe, ReleaseSmall]
zig build -Doptimize=ReleaseFast

# 3. Run it. (Optional: add to PATH, it's up to you.)
./zig-out/bin/zl
```

## 🛠 Usage

Just run:

```bash
zl [OPTIONS] [PATH]
```

| Flag | Description |
| :--- | :--- |
| `-l`, `--long` | Show detailed view (permissions, size, date, user). |
| `-a`, `--a` | Show hidden files (starting with `.`). |
| `-s`, `--sort <mode>` | `name` (A-Z) [Default]<br>`length` (Shortest first)<br>`dir_first` (Dirs first)<br>`mtime` (Newest first)<br>`size` (Largest first) |
| `-r`, `--recursive` | Recurse into subdirectories. |
| `-L`, `--level <INT>` | Limit the depth of recursion (use `0` for infinite depth). |
| `-p`, `--pure` | Clean output without colors or icons (useful for pipes). |
| `-d`, `--dir` | Only show directories. |
| `-D`, `--no_dir` | Only show files (hide directories). |
| `-e`, `--ext <str>...` | Hide files by extension, e.g. `--ext zig,go,ts`. |
| `-m`, `--match <str>...` | Only show names that contain the given text, e.g. `--match test`. |
| `--size <str>...` | Only show files in a size range, e.g. `--size gt:10K --size lte:2M`. Supports `gt`, `gte`, `lt`, `lte`, `eq` and units `B`, `K`, `M`, `G`, `T`. |
| `--changed-within <str>` | Only show entries changed within a time range, e.g. `--changed-within 7d`. Supports `s`, `m`, `h`, `d`, `w`. |
| `-R`, `--report` | Show a brief summary of file and folder counts. |
| `-g`, `--git` | Show Git status indicators (requires `-l` to work). |
| `-h`, `--help` | Print help message. |

### Examples

**Standard list:**
```bash
zl
```

**Show all files with details (sorted by filename length):**
```bash
zl -la -s length
```

**Dig deep (recursive listing):**
```bash
# Basic recursive (infinite)
zl -r

# Limit recursion to 2 levels deep
zl -L 2
```

**Clean output (no colors/icons):**
```bash
zl -p
```

**Filter by file type (directories only / files only):**
```bash
zl -d
zl -D
```

**Exclude some extensions:**
```bash
zl --ext zig,go,ts
```

**Match by name:**
```bash
zl --match test
```

**Filter files by size:**
```bash
zl --size lt:10K
zl --size gt:10K --size lte:2M
```

**Show files changed recently:**
```bash
zl --changed-within 7d
```

**Show summary report:**
```bash
zl -R
```

**Show Git status (must be used with `-l`):**
```bash
zl -lg
```

## 🛣 Roadmap

*   [x] Basic file listing & recursion
*   [x] Color output & Nerd Font icons
*   [x] Detailed file stats
*   [x] Sorting by name (default), length, and modification time
*   [x] Recursive directory traversal (`-r`)
*   [x] Depth control for recursion (`-L`)
*   [x] Clean output mode (`-p`)
*   [x] Filter by files or directories (`-d`, `-D`)
*   [x] Extension filter (`-e`, `--ext`)
*   [x] Name match filter (`-m`, `--match`)
*   [x] Smart dynamic grid layout
*   [x] Summary report (`-R`)
*   [x] Git status integration (`-g`)
*   [ ] Multi-threading for faster `stat` calls
*   [ ] Custom color/icon configurations (Maybe, if you need it)

## 🤝 Contributing

Got an idea? Found a bug? Open an issue or send a PR. This is a fun side project, and contributions are always welcome.

1.  Fork it
2.  Create your feature branch (`git checkout -b feature/cool-thing`)
3.  Commit your changes
4.  Push to the branch
5.  Open a Pull Request

---

*Crafted with ❤️ in Zig.*
