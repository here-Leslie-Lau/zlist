const std = @import("std");

/// The print mode of `zl`.
pub const PrintMode = enum {
    Detail,
    DetailPure,
    DetailWithGit,
    RecursivePrefix,
    RecursiveWithFileMeta,
    RecursiveWithFileMetaPure,

    pub inline fn toString(self: PrintMode) []const u8 {
        return switch (self) {
            .Detail => "  {s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s} {s}",
            .DetailPure => "  {s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s}",
            .DetailWithGit => "    {c} {s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s} {s}",
            .RecursivePrefix => "{s}{s}",
            .RecursiveWithFileMeta => " {s} {s}\n",
            .RecursiveWithFileMetaPure => " {s}\n",
        };
    }
};

pub const SortType = enum {
    /// sort by name(asc)
    name,
    /// sort by name length(asc). Default
    length,
    /// sort by group directories first
    dir_first,
    /// sort by modification time(desc)
    mtime,
    /// sort by file size(desc)
    size,
};

pub const SizeRange = struct {
    min_bytes: ?u64 = null,
    min_inclusive: bool = true,
    max_bytes: ?u64 = null,
    max_inclusive: bool = true,
};

pub const FilesOptions = struct {
    /// show detail mode
    show_detail: bool = false,
    /// show hidden files
    show_hidden: bool = false,
    /// pure mode, only show file names without icons and colors
    pure: bool = false,
    /// report mode, shows brief report about number of files and folders shown
    report: bool = false,
    /// sort type
    sort_type: SortType = .name,
    /// only show directories, not files
    only_dir: bool = false,
    /// only show files, not directories
    only_file: bool = false,
    /// show recursive
    recursive: bool = false,
    /// limit the depth of recursion. 0 means infinite.
    recursion_level: i8 = -1,
    /// git integration.
    /// if true, it will show git status of files and folders.
    /// which can be slow for large repositories. Default is false.
    show_git: bool = false,
    /// path from args
    path: []const u8 = ".",
    /// To filter files by extension, only show files with the specified extensions.
    /// Default is null, which means no filtering.
    exts: ?[]const []const u8 = null,
    /// To match files by name, only show files that match the specified patterns.
    matches: ?[]const []const u8 = null,
    /// only show entries modified within this duration.
    changed_within: ?std.Io.Duration = null,
    /// only show files whose size falls within this range.
    size_range: ?SizeRange = null,
    /// when true, directory size can be replaced with the recursive size of its contents.
    recursive_dir_size: bool = false,
};

pub const FileOptions = struct {
    /// load file stat, which is needed for showing mtime, size, permissions, etc. but can be slow for large directories. Default is false.
    load_stat: bool = false,
    /// load symbolic link target text for display in long mode only.
    load_symlink_target: bool = false,
    /// load owner/group names from uid/gid (needed by detail mode only).
    load_owner: bool = false,
    /// show hidden files
    show_hidden: bool = false,
    /// only show directories, not files
    only_dir: bool = false,
    /// only show files, not directories
    only_file: bool = false,
    /// when true, keep directories during `--match` filtering so recursion can continue.
    keep_dirs_for_match: bool = false,
    /// when true, keep directories during `--changed-within` filtering so recursion can continue.
    keep_dirs_for_changed_within: bool = false,
    /// when true, keep directories during `--size` filtering so recursion can continue.
    keep_dirs_for_size: bool = false,
    exts: ?[]const []const u8 = null,
    matches: ?[]const []const u8 = null,
    /// only show entries modified within this duration.
    changed_within: ?std.Io.Duration = null,
    /// only show files whose size falls within this range.
    size_range: ?SizeRange = null,
    /// timestamp used as the "now" reference for changed-within filtering.
    changed_within_now: ?std.Io.Timestamp = null,
};

/// The options of `zl` that are determined at compile time.
pub const ModeOptionsComptime = struct {
    const Self = @This();
    pure: bool = false,

    pub inline fn initPure() Self {
        return comptime Self{
            .pure = true,
        };
    }
};
