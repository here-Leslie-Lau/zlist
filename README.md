# zlist ⚡️

> A simple, colorful alternative to `ls` built with **Zig**.

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)](https://github.com/here-Leslie-Lau/zlist)
[![Zig Version](https://img.shields.io/badge/zig-0.16.0_dev-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

**Note**: This is my **first CLI tool written in Zig**! 🚀

I built this project to learn the language, understand manual memory management, and explore the standard library. It may not be the fastest or smallest `ls` clone out there (yet!), but it's a functional experiment and a work in progress.

## ✨ Features

While it's a learning project, it still packs some handy features:

*   **Smart Grid Layout**: Dynamically adjusts column widths to keep the output compact and readable, saving screen space.
*   **Visual Context**:
    *   **Nerd Fonts** support out of the box.
    *   Specific icons for your code (`Zig`, `Rust`, `Go`, `Python`, `JS/TS`, `C/C++`, etc.).
    *   Highlights directories and Markdown files so you spot them instantly.
*   **Smart Details**: Permissions, user/group, sizes, and timestamps formatted to be actually readable.
*   **Unique Default Sorting**: Defaults to sorting by **filename length** (because finding that one short file in a sea of long names is always a pain). Standard A-Z sorting is also available.
*   **Dig Deeper**: A basic `-r` flag to peek into subdirectories, Or `-L` to control how deep you want to go.
*   **Filters**: Quickly isolate just directories (`-d`) or just files (`-D`).

## 📸 Preview

![Preview1](pics/screenshot.png)
![Preview2](pics/screenshot2.png)

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

Simple and intuitive.

```bash
zl [OPTIONS] [PATH]
```

| Flag | Description |
| :--- | :--- |
| `-l`, `--long` | Enable detailed view (permissions, size, date, user). |
| `-a`, `--a` | Show hidden files (starting with `.`). |
| `-s`, `--sort <mode>` | `length` (Shortest first) [Default]<br>`name` (A-Z) |
| `-r`, `--recursive` | Recursively list subdirectories encountered. |
| `-L`, `--level <INT>` | Limit the depth of recursion (use `0` for infinite depth). |
| `-p`, `--pure` | Clean output without colors or icons (useful for pipes). |
| `-d`, `--dir` | Only show directories. |
| `-D`, `--no_dir` | Only show files (exclude directories). |
| `-h`, `--help` | Print help message. |

### Examples

**Standard list:**
```bash
zl
```

**Show everything with details (Sorted by name):**
```bash
zl -la -s name
```

**Dig deep (Recursive listing):**
```bash
# Basic recursive (infinite)
zl -r

# Limit recursion to 2 levels deep
zl -L 2
```

**Clean output (No colors/icons):**
```bash
zl -p
```

**Filter by file type (Directories only / Files only):**
```bash
zl -d
zl -D
```

## 🛣 Roadmap

*   [x] Basic file listing & recursion
*   [x] Color output & Nerd Font icons
*   [x] Detailed file stats
*   [x] Sorting by name length
*   [x] Recursive directory traversal (`-r`)
*   [x] Depth control for recursion (`-L`)
*   [x] Clean output mode (`-p`)
*   [x] Filter by files or directories (`-d`, `-D`)
*   [x] Smart dynamic grid layout
*   [ ] Multi-threading for faster `stat` calls
*   [ ] Custom color/icon configurations (Maybe, if you need it)

## 🤝 Contributing

Got an idea? Found a bug? Feel free to open an issue or drop a PR. This is a fun side project, and all contributions are welcome.

1.  Fork it
2.  Create your feature branch (`git checkout -b feature/cool-thing`)
3.  Commit your changes
4.  Push to the branch
5.  Open a Pull Request

---

*Crafted with ❤️ in Zig.*
