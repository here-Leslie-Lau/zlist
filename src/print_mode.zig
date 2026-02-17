const std = @import("std");

/// The print mode of `zl`.
pub const PrintMode = enum {
    /// The command is `zl` without any flag.
    Normal,
    /// The command is `zl -l`.
    Detail,
    /// The command is `zl -r`. just prefix and connectors, no file meta(icon and name).
    RecursivePrefix,
    /// The command is `zl -r`. just file meta, without prefix and connectors.
    RecursiveWithFileMeta,

    pub inline fn toString(self: PrintMode) []const u8 {
        return switch (self) {
            // icon, name and max width of the name.
            .Normal => "  {s} {s:<[2]}",
            // permissions, username, group name, size, mtime, icon and name.
            .Detail => "  {s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s} {s}",
            // prefix, connectors
            .RecursivePrefix => "{s}{s}",
            // icon and name
            .RecursiveWithFileMeta => " {s} {s}\n",
        };
    }
};
