const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");

pub const File = struct {
    const Self = @This();
    is_dir: bool,
    is_exec: bool,
    is_hidden: bool,
    name: []const u8,

    stat: ?std.Io.Dir.Stat,

    pub const Options = struct {
        /// show detail mode
        show_detail: bool = false,
        /// show hidden files
        show_hidden: bool = false,
        sub_path: []const u8 = ".",
    };

    /// Initialize a File from a directory entry.
    /// Return null if the file should be skipped (e.g., hidden files when not showing hidden).
    pub inline fn init(
        io: std.Io,
        entry: *const std.Io.Dir.Entry,
        dir: *const std.Io.Dir,
        opt: Options,
    ) !?Self {
        const is_dir: bool = (entry.kind == .directory);
        const is_hidden: bool = (entry.name[0] == '.');

        if (!opt.show_hidden and is_hidden) {
            return null;
        }

        var file: Self = .{
            .is_hidden = is_hidden,
            .is_dir = is_dir,
            .is_exec = false,
            .name = entry.name,
            .stat = null,
        };

        if (opt.show_detail) {
            // read more file details
            const stat = try dir.statFile(io, opt.sub_path, .{});
            file.stat = stat;
        }

        return file;
    }

    pub fn nameLessThan(_: void, lhs: Self, rhs: Self) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name) == .lt;
    }

    const Color = struct {
        const reset = "\x1b[0m";
        const light_blue = "\x1b[94m";
        const light_green = "\x1b[92m";
        const cyan = "\x1b[36m";
        const light_magenta = "\x1b[95m";
        const light_yellow = "\x1b[93m";
        const red = "\x1b[31m";
        const white = "\x1b[37m";
    };

    pub inline fn getColor(self: Self) []const u8 {
        // TODO: add more colors based on file type
        if (self.is_dir) {
            // blue (directory)
            return Color.light_blue;
        } else {
            // default file color
            return Color.light_yellow;
        }
    }

    pub inline fn getPermissions(self: Self, buf: *[10]u8) []const u8 {
        if (!self.stat) {
            // unknown permissions
            @memset(buf, '-');
            return buf[0..10];
        }

        buf[0] = switch (self.stat.?.kind) {
            // block_device,
            .directory => 'd',
            .sym_link => 'l',
            .unix_domain_socket => 's',
            .character_device => 'c',
            else => '-', // regular file
        };

        if (builtin.os.tag == .windows) {
            // TODO leslie: todo
        } else {
            // posix permissions
            const m = @intFromEnum(self.stat.?.permissions);
            // Permission bits from posix standard
            const S_IRUSR = 0o400;
            const S_IWUSR = 0o200;
            const S_IXUSR = 0o100;
            const S_IRGRP = 0o040;
            const S_IWGRP = 0o020;
            const S_IXGRP = 0o010;
            const S_IROTH = 0o004;
            const S_IWOTH = 0o002;
            const S_IXOTH = 0o001;
            // User
            buf[1] = if (m & S_IRUSR != 0) 'r' else '-';
            buf[2] = if (m & S_IWUSR != 0) 'w' else '-';
            buf[3] = if (m & S_IXUSR != 0) 'x' else '-';
            // Group
            buf[4] = if (m & S_IRGRP != 0) 'r' else '-';
            buf[5] = if (m & S_IWGRP != 0) 'w' else '-';
            buf[6] = if (m & S_IXGRP != 0) 'x' else '-';
            // Other
            buf[7] = if (m & S_IROTH != 0) 'r' else '-';
            buf[8] = if (m & S_IWOTH != 0) 'w' else '-';
            buf[9] = if (m & S_IXOTH != 0) 'x' else '-';
        }
        return buf;
    }
};
