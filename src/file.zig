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
    username: []const u8,
    groupname: []const u8,

    pub const Options = struct {
        /// show detail mode
        show_detail: bool = false,
        /// show hidden files
        show_hidden: bool = false,
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
            .username = "",
            .groupname = "",
        };

        if (opt.show_detail) {
            // read more file details
            const stat = try dir.statFile(io, file.name, .{});
            file.stat = stat;

            const f = try dir.openFile(io, file.name, .{});
            defer f.close(io);

            var c_stat: std.c.Stat = undefined;
            if (std.c.fstat(f.handle, &c_stat) == 0 and builtin.os.tag != .windows) {
                file.username = file.getNameByID(.User, c_stat.uid) orelse "UNKNOWN";
                file.groupname = file.getNameByID(.Group, c_stat.gid) orelse "UNKNOWN";
            }
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
        if (self.stat == null) {
            // unknown permissions
            @memset(buf, '-');
            return buf[0..10];
        }

        buf[0] = switch (self.stat.?.kind) {
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

    pub const NameByID = enum {
        User,
        Group,
    };

    /// get user name by user ID (uid or gid)
    pub inline fn getNameByID(_: Self, name: NameByID, id: u32) ?[]const u8 {
        switch (name) {
            .User => {
                const uid: std.c.uid_t = @intCast(id);
                const passwd_ptr = std.c.getpwuid(uid);
                if (passwd_ptr == null) {
                    return null;
                }
                return std.mem.span(passwd_ptr.?.*.name);
            },
            .Group => {
                const gid: std.c.gid_t = @intCast(id);
                const group_ptr = std.c.getgrgid(gid);
                if (group_ptr == null) {
                    return null;
                }
                return std.mem.span(group_ptr.?.*.name);
            },
        }
    }

    /// convert size in bytes to human-readable format
    pub inline fn humanSize(self: Self, buf: []u8) ![]u8 {
        const units = [_][]const u8{ "B", "K", "M", "G", "T" };

        var sz: f64 = @floatFromInt(self.stat.?.size);
        var i: usize = 0;
        while (sz >= 1024.0 and i < units.len - 1) : (i += 1) {
            sz /= 1024.0;
        }

        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ sz, units[i] });
    }

    /// format modification time to string
    pub inline fn formatTime(self: Self, buf: []u8) ![]u8 {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(self.stat.?.mtime.toSeconds()) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year = year_day.year;
        // month_day.month.numeric() 返回 1-12，数组索引需要 0-11
        const month_index = @as(usize, month_day.month.numeric()) - 1;
        const day = month_day.day_index + 1; // day_index 是从 0 开始的
        const hour = day_seconds.getHoursIntoDay();
        const min = day_seconds.getMinutesIntoHour();
        const sec = day_seconds.getSecondsIntoMinute();
        const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        //  %b %d %H:%M:%S %Y in C Language
        return std.fmt.bufPrint(buf, "{s} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC {d}", .{
            month_names[month_index],
            day,
            hour,
            min,
            sec,
            year,
        });
    }
};
