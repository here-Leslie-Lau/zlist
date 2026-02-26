const std = @import("std");

/// The print mode of `zl`.
pub const PrintMode = enum {
    /// The command is `zl` without any flag.
    Normal,
    /// The command is `zl -p` without icon. just name and max width of the name.
    NormalPure,
    /// The command is `zl -l`.
    Detail,
    /// The command is `zl -l -p`.
    DetailPure,
    /// The command is `zl -r`. just prefix and connectors, no file meta(icon and name).
    RecursivePrefix,
    /// The command is `zl -r`. just file meta, without prefix and connectors.
    RecursiveWithFileMeta,
    /// The command is `zl -r -p`.
    RecursiveWithFileMetaPure,

    pub inline fn toString(self: PrintMode) []const u8 {
        return switch (self) {
            // icon, name and max width of the name.
            .Normal => "  {s} {s:<[2]}",
            // name and max width of the name.
            .NormalPure => "  {s:<[1]}",
            // permissions, username, group name, size, mtime, icon and name.
            .Detail => "  {s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s} {s}",
            // permissions, username, group name, size, mtime and name.
            .DetailPure => "  {s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s}",
            // prefix, connectors
            .RecursivePrefix => "{s}{s}",
            // icon and name
            .RecursiveWithFileMeta => " {s} {s}\n",
            // name only
            .RecursiveWithFileMetaPure => " {s}\n",
        };
    }
};

pub const SortType = enum {
    /// sort by name(asc)
    name,
    /// sort by name length(asc)
    length,
};

pub const FilesOptions = struct {
    /// show detail mode
    show_detail: bool = false,
    /// show hidden files
    show_hidden: bool = false,
    /// show recursive
    recursive: bool = false,
    /// pure mode, only show file names without icons and colors
    pure: bool = false,
    /// sort type
    sort_type: SortType = .name,
    /// only show directories, not files
    only_dir: bool = false,
    /// only show files, not directories
    only_file: bool = false,
};

pub const FileOptions = struct {
    /// show detail mode
    show_detail: bool = false,
    /// show hidden files
    show_hidden: bool = false,
    /// only show directories, not files
    only_dir: bool = false,
    /// only show files, not directories
    only_file: bool = false,
};
