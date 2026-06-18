//! Public API for zlist.
//!
//! Import this module with `@import("zlist")`.

const opts = @import("zlist/opts.zig");

/// Metadata for a single file or directory.
pub const File = @import("zlist/file.zig").File;
/// A collection of files returned by zlist.
pub const Files = @import("zlist/files.zig").Files;

pub const FilesOptions = opts.FilesOptions;
pub const FileOptions = opts.FileOptions;
pub const ModeOptionsComptime = opts.ModeOptionsComptime;
pub const PrintMode = opts.PrintMode;

pub const SortType = opts.SortType;
pub const SizeRange = opts.SizeRange;
pub const GitStatus = @import("zlist/git.zig").GitStatus;
