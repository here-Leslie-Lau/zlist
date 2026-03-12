const std = @import("std");
const mem = std.mem;
const Terminal = std.Io.Terminal;
const builtin = @import("builtin");

const opts = @import("opts.zig");

const size_units = [_][]const u8{ "B", "K", "M", "G", "T" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub const File = struct {
    const Self = @This();
    is_dir: bool,
    is_exec: bool,
    is_hidden: bool,
    name: []const u8,

    stat_t: ?Stat,
    username: []const u8,
    groupname: []const u8,

    /// Initialize a File from a directory entry.
    /// Return null if the file should be skipped (e.g., hidden files when not showing hidden).
    pub inline fn init(
        entry: *const std.Io.Dir.Entry,
        dir: *const std.Io.Dir,
        opt: opts.FileOptions,
        username_inventory: *std.AutoHashMap(std.c.uid_t, []const u8),
        groupname_inventory: *std.AutoHashMap(std.c.gid_t, []const u8),
    ) !?Self {
        const is_dir: bool = (entry.kind == .directory);
        const is_hidden: bool = (entry.name[0] == '.');

        if (!opt.show_hidden and is_hidden) {
            return null;
        }
        if (opt.only_dir and !is_dir) {
            return null;
        }
        if (opt.only_file and is_dir) {
            return null;
        }

        var file: Self = .{
            .is_hidden = is_hidden,
            .is_dir = is_dir,
            .is_exec = false,
            .name = entry.name,
            .stat_t = null,
            .username = "",
            .groupname = "",
        };

        if (opt.show_detail) {
            // read more file details
            file.stat_t = file.getStat(dir);

            if (builtin.os.tag != .windows) {
                file.username = file.getName(.User, username_inventory, groupname_inventory) orelse "UNKNOWN";
                file.groupname = file.getName(.Group, username_inventory, groupname_inventory) orelse "UNKNOWN";
            }
        }

        return file;
    }

    pub fn nameLessThan(_: void, lhs: Self, rhs: Self) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name) == .lt;
    }

    pub fn nameLenLessThan(_: void, lhs: Self, rhs: Self) bool {
        return lhs.name.len < rhs.name.len;
    }

    pub fn dirMoreThan(_: void, lhs: Self, rhs: Self) bool {
        // directories first, then files
        if (lhs.is_dir != rhs.is_dir) {
            // true if lhs is dir and rhs is not
            return lhs.is_dir;
        }
        // otherwise, consider them equal for sorting
        return false;
    }

    pub inline fn getStat(self: Self, dir: *const std.Io.Dir) ?Stat {
        switch (builtin.os.tag) {
            .windows => {
                // does not support
                return null;
            },
            .linux => {
                const linux = std.os.linux;

                // Ensure the path is null-terminated for the C API
                var name_z: [std.fs.max_path_bytes]u8 = undefined;
                @memcpy(name_z[0..self.name.len], self.name);
                name_z[self.name.len] = 0;

                var statx: linux.Statx = undefined;
                // Use dir.handle to perform fstatat/statx without opening the file
                const errno = linux.errno(linux.statx(dir.handle, @ptrCast(&name_z), linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &statx));

                switch (errno) {
                    .SUCCESS => {},
                    else => return null,
                }

                // convert statx mode to permissions and kind
                const m = statx.mode;
                const kind = switch (m & linux.S.IFMT) {
                    linux.S.IFDIR => std.Io.File.Kind.directory,
                    linux.S.IFLNK => std.Io.File.Kind.sym_link,
                    linux.S.IFSOCK => std.Io.File.Kind.unix_domain_socket,
                    linux.S.IFCHR => std.Io.File.Kind.character_device,
                    linux.S.IFBLK => std.Io.File.Kind.block_device,
                    linux.S.IFIFO => std.Io.File.Kind.named_pipe,
                    else => std.Io.File.Kind.file, // IFREG
                };

                // std.Io.File.Permissions representation (same as unix mode bits)
                const permissions: std.Io.File.Permissions = @enumFromInt(m & 0o7777);

                return .{
                    .size = statx.size,
                    .kind = kind,
                    .permissions = permissions,
                    .mtime = .{ .nanoseconds = @as(i96, @intCast(statx.mtime.sec)) * std.time.ns_per_s + @as(i96, @intCast(statx.mtime.nsec)) },

                    // TODO leslie: cache these values in File struct to avoid extra syscalls
                    .uid = statx.uid,
                    .gid = statx.gid,
                };
            },
            else => {
                // posix-like (macOS, FreeBSD, etc)
                var buf: std.c.Stat = undefined;

                // Ensure the path is null-terminated for the C API
                var name_z: [std.fs.max_path_bytes]u8 = undefined;
                @memcpy(name_z[0..self.name.len], self.name);
                name_z[self.name.len] = 0;

                // Use std.c.fstatat to avoid opening the file, providing AT_SYMLINK_NOFOLLOW
                const result = std.c.fstatat(dir.handle, @ptrCast(&name_z), &buf, std.posix.AT.SYMLINK_NOFOLLOW);
                if (result != 0) {
                    return null;
                }

                const m = buf.mode;
                const kind = switch (m & std.posix.S.IFMT) {
                    std.posix.S.IFDIR => std.Io.File.Kind.directory,
                    std.posix.S.IFLNK => std.Io.File.Kind.sym_link,
                    std.posix.S.IFSOCK => std.Io.File.Kind.unix_domain_socket,
                    std.posix.S.IFCHR => std.Io.File.Kind.character_device,
                    std.posix.S.IFBLK => std.Io.File.Kind.block_device,
                    std.posix.S.IFIFO => std.Io.File.Kind.named_pipe,
                    else => std.Io.File.Kind.file,
                };

                const permissions: std.Io.File.Permissions = @enumFromInt(m & 0o7777);

                return .{
                    .size = @intCast(buf.size),
                    .kind = kind,
                    .permissions = permissions,
                    .mtime = .{ .nanoseconds = @as(i96, @intCast(buf.mtimespec.sec)) * std.time.ns_per_s + @as(i96, @intCast(buf.mtimespec.nsec)) },

                    // TODO leslie: cache these values in File struct to avoid extra syscalls
                    .uid = buf.uid,
                    .gid = buf.gid,
                };
            },
        }

        return null;
    }

    pub inline fn getPermissions(self: Self, buf: *[10]u8) []const u8 {
        if (self.stat_t == null) {
            // unknown permissions
            @memset(buf, '-');
            return buf[0..10];
        }

        buf[0] = switch (self.stat_t.?.kind) {
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
            const m = @intFromEnum(self.stat_t.?.permissions);
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

    /// get user name (enum User or Group)
    pub inline fn getName(
        self: Self,
        name: NameByID,
        ui: *std.AutoHashMap(std.c.uid_t, []const u8),
        gi: *std.AutoHashMap(std.c.gid_t, []const u8),
    ) ?[]const u8 {
        if (self.stat_t == null) {
            return null;
        }

        switch (name) {
            .User => {
                const uid = self.stat_t.?.uid;
                // first check the cache to avoid extra syscalls
                if (ui.get(uid)) |str| {
                    return str;
                }

                const passwd = std.c.getpwuid(uid);
                if (passwd == null) {
                    return null;
                }

                const str = std.mem.span(passwd.?.*.name) orelse return null;
                ui.put(uid, str) catch return null;

                return str;
            },
            .Group => {
                const gid = self.stat_t.?.gid;
                if (gi.get(gid)) |str| {
                    return str;
                }

                const group = std.c.getgrgid(gid);
                if (group == null) {
                    return null;
                }

                const str = std.mem.span(group.?.*.name) orelse return null;
                gi.put(gid, str) catch return null;

                return str;
            },
        }
    }

    /// convert size in bytes to human-readable format
    pub inline fn humanSize(self: Self, buf: []u8) ![]u8 {
        if (self.stat_t == null) {
            return std.fmt.bufPrint(buf, "?B", .{});
        }

        var size = self.stat_t.?.size;
        var i: usize = 0;
        while (i < size_units.len - 1 and size >= 1024) : (i += 1) {
            size = size >> 10; // divide by 1024
        }

        return std.fmt.bufPrint(buf, "{d}{s}", .{ size, size_units[i] });
    }

    /// format modification time to string
    pub inline fn formatTime(self: Self, buf: []u8) ![]u8 {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(self.stat_t.?.mtime.toSeconds()) };
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

        //  %b %d %H:%M:%S %Y in C Language
        return std.fmt.bufPrint(buf, "{s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC {d}", .{
            month_names[month_index],
            day,
            hour,
            min,
            sec,
            year,
        });
    }
};

/// Wrapper around std.Io.Dir.Stat to store only necessary fields for display.
/// Cross-platform.
const Stat = struct {
    size: u64,
    kind: std.Io.File.Kind,
    permissions: std.Io.File.Permissions,
    mtime: std.Io.Timestamp,

    uid: std.c.uid_t,
    gid: std.c.gid_t,
};
