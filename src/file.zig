const std = @import("std");
const mem = std.mem;
const Terminal = std.Io.Terminal;
const builtin = @import("builtin");

const opts = @import("opts.zig");

const size_units = [_][]const u8{ "B", "K", "M", "G", "T" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

// Date calculation algorithm developed by Neri/Schneider (2021): https://arxiv.org/abs/2102.06959v1
// Originally written in C++ version (https://github.com/cassioneri/calendar) of the
// mentioned paper.
// The Zig version is a port from the C++ version by FOberstein and can be
// found here: https://codeberg.org/FObersteiner/zdt/src/commit/e03e31e0754cd246428a2b83ff1ecfdc576e675e/benchmark/src/bmarks_zbench_calendar.zig#L100-L138

const Date = struct {
    year: i32 = 0,
    month: u32 = 0,
    day: u32 = 0,
};

const S: u32 = 82;
const K: u32 = 719468 + 146097 * S;
const L: u32 = 400 * S;

fn rdToDateCpp(N_U: i32) Date {
    // Rata die shift
    const N: u32 = @as(u32, @bitCast(N_U)) +% K;

    // Century
    const N_1: u32 = 4 * N + 3;
    const C: u32 = N_1 / 146097;
    const N_C: u32 = (N_1 % 146097) / 4;

    // Year
    const N_2: u32 = 4 * N_C + 3;
    const P_2: u64 = @as(u64, 2939745) * N_2;
    const Z: u32 = @intCast(P_2 / 4294967296);
    const N_Y: u32 = @intCast((P_2 % 4294967296) / 2939745 / 4);
    const Y: u32 = 100 * C + Z;

    // Month and day
    const N_3: u32 = 2141 * N_Y + 197913;
    const M: u32 = N_3 / 65536;
    const D: u32 = (N_3 % 65536) / 2141;

    // Map. (Notice the year correction, including type change.)
    const J: u32 = @intFromBool(N_Y >= 306);
    const Y_G: i32 = @intCast(@as(i32, @bitCast(Y -% L)) + @as(i32, @intCast(J)));
    const M_G: u32 = if (J != 0) M - 12 else M;
    const D_G: u32 = D + 1;

    return .{ .year = Y_G, .month = M_G, .day = D_G };
}

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
const S_ISUID = 0o4000;
const S_ISGID = 0o2000;
const S_ISVTX = 0o1000;

inline fn formatExecPermission(mode: u32, exec_bit: u16, special_bit: u16, special_char: u8, no_exec_special_char: u8) u8 {
    const has_exec = mode & exec_bit != 0;
    if (mode & special_bit != 0) {
        return if (has_exec) special_char else no_exec_special_char;
    }
    return if (has_exec) 'x' else '-';
}

pub const File = struct {
    const Self = @This();
    is_dir: bool,
    is_exec: bool,
    is_hidden: bool,
    name: []const u8,

    stat_t: ?Stat,
    recursive_size: ?u64,
    username: []const u8,
    groupname: []const u8,

    /// Initialize a File from a directory entry.
    /// Return null if the file should be skipped (e.g., hidden files when not showing hidden).
    pub inline fn init(
        allocator: std.mem.Allocator,
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
        if (!is_dir) {
            if (opt.exts) |exts| {
                if (shouldFilterByExt(entry.name, exts)) {
                    return null;
                }
            }
        }
        if (opt.matches) |matches| {
            if (is_dir and opt.keep_dirs_for_match) {
                // keep directories so recursive traversal can continue
            } else if (!shouldIncludeByName(entry.name, matches)) {
                return null;
            }
        }

        var file: Self = .{
            .is_hidden = is_hidden,
            .is_dir = is_dir,
            .is_exec = false,
            .name = entry.name,
            .stat_t = null,
            .recursive_size = null,
            .username = "",
            .groupname = "",
        };

        if (opt.load_stat) {
            // read more file details
            file.stat_t = file.getStat(dir);

            if (shouldFilterByChangedWithin(file.stat_t, is_dir, opt)) {
                return null;
            }

            if (shouldFilterBySize(file.stat_t, is_dir, opt)) {
                return null;
            }

            if (opt.load_owner and builtin.os.tag != .windows) {
                file.username = file.getName(.User, allocator, username_inventory, groupname_inventory) orelse "UNKNOWN";
                file.groupname = file.getName(.Group, allocator, username_inventory, groupname_inventory) orelse "UNKNOWN";
            }
        }

        return file;
    }

    inline fn shouldFilterByExt(name: []const u8, exts: []const []const u8) bool {
        const file_ext = std.fs.path.extension(name);
        const file_ext_no_dot = if (file_ext.len > 0) file_ext[1..] else "";

        for (exts) |ext| {
            const ext_no_dot = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
            if (std.ascii.eqlIgnoreCase(file_ext_no_dot, ext_no_dot)) {
                return true;
            }
        }

        return false;
    }

    inline fn shouldIncludeByName(name: []const u8, matches: []const []const u8) bool {
        for (matches) |m| {
            // check if name contains m as a substring, ignoring case
            if (std.ascii.findIgnoreCase(name, m) != null) {
                return true;
            }
        }
        return false;
    }

    inline fn shouldFilterByChangedWithin(stat_t: ?Stat, is_dir: bool, opt: opts.FileOptions) bool {
        const max_age = opt.changed_within orelse return false;
        if (is_dir and opt.keep_dirs_for_changed_within) {
            return false;
        }

        const stat = stat_t orelse return true;
        const now = opt.changed_within_now orelse return false;
        const age = stat.mtime.durationTo(now);
        return age.nanoseconds > max_age.nanoseconds;
    }

    inline fn shouldFilterBySize(stat_t: ?Stat, is_dir: bool, opt: opts.FileOptions) bool {
        const size_range = opt.size_range orelse return false;
        if (is_dir) {
            return !opt.keep_dirs_for_size;
        }

        const stat = stat_t orelse return true;

        if (size_range.min_bytes) |min_bytes| {
            if (size_range.min_inclusive) {
                if (stat.size < min_bytes) {
                    return true;
                }
            } else if (stat.size <= min_bytes) {
                return true;
            }
        }

        if (size_range.max_bytes) |max_bytes| {
            if (size_range.max_inclusive) {
                if (stat.size > max_bytes) {
                    return true;
                }
            } else if (stat.size >= max_bytes) {
                return true;
            }
        }

        return false;
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

    pub fn mtimeMoreThan(_: void, lhs: Self, rhs: Self) bool {
        if (lhs.stat_t == null or rhs.stat_t == null) {
            return false;
        }

        // sort by modification time, newest first
        return lhs.stat_t.?.mtime.toMilliseconds() > rhs.stat_t.?.mtime.toMilliseconds();
    }

    pub fn sizeMoreThan(_: void, lhs: Self, rhs: Self) bool {
        const lhs_size = lhs.effectiveSize() orelse return false;
        const rhs_size = rhs.effectiveSize() orelse return false;

        // sort by size, largest first
        return lhs_size > rhs_size;
    }

    /// get effective size for display and sorting.
    /// for directories, use recursive_size if available, otherwise fallback to stat size;
    /// for files, use stat size. Return null if no size information is available.
    pub inline fn effectiveSize(self: Self) ?u64 {
        if (self.is_dir) {
            if (self.recursive_size) |size| {
                return size;
            }
        }

        if (self.stat_t) |stat| {
            return stat.size;
        }

        return null;
    }

    pub inline fn setRecursiveSize(self: *Self, size: u64) void {
        self.recursive_size = size;
    }

    pub inline fn statForName(name: []const u8, dir: *const std.Io.Dir) ?Stat {
        const temp_file = Self{
            .is_dir = false,
            .is_exec = false,
            .is_hidden = false,
            .name = name,
            .stat_t = null,
            .recursive_size = null,
            .username = "",
            .groupname = "",
        };

        return temp_file.getStat(dir);
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
            // User
            buf[1] = if (m & S_IRUSR != 0) 'r' else '-';
            buf[2] = if (m & S_IWUSR != 0) 'w' else '-';
            buf[3] = formatExecPermission(m, S_IXUSR, S_ISUID, 's', 'S');
            // Group
            buf[4] = if (m & S_IRGRP != 0) 'r' else '-';
            buf[5] = if (m & S_IWGRP != 0) 'w' else '-';
            buf[6] = formatExecPermission(m, S_IXGRP, S_ISGID, 's', 'S');
            // Other
            buf[7] = if (m & S_IROTH != 0) 'r' else '-';
            buf[8] = if (m & S_IWOTH != 0) 'w' else '-';
            buf[9] = formatExecPermission(m, S_IXOTH, S_ISVTX, 't', 'T');
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
        allocator: std.mem.Allocator,
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
                const owned_str = allocator.dupe(u8, str) catch return null;
                ui.put(uid, owned_str) catch return null;

                return owned_str;
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
                const owned_str = allocator.dupe(u8, str) catch return null;
                gi.put(gid, owned_str) catch return null;

                return owned_str;
            },
        }
    }

    /// convert size in bytes to human-readable format
    pub inline fn humanSize(self: Self, buf: []u8) ![]u8 {
        var size = self.effectiveSize() orelse {
            return std.fmt.bufPrint(buf, "?B", .{});
        };
        var i: usize = 0;
        while (i < size_units.len - 1 and size >= 1024) : (i += 1) {
            size = size >> 10; // divide by 1024
        }

        return std.fmt.bufPrint(buf, "{d}{s}", .{ size, size_units[i] });
    }

    /// format modification time to string
    pub inline fn formatTime(self: Self, buf: []u8) ![]u8 {
        const epoch_seconds: u64 = @as(u64, @bitCast(self.stat_t.?.mtime.toSeconds()));
        const epoch_day = epoch_seconds / 86_400;
        // Date calculated by the Neri/Schneider algorithm
        const date = rdToDateCpp(@intCast(epoch_day));

        // Leftover seconds used to calculate the day-time
        const day_leftover_sec = epoch_seconds % 86_400;
        const hour = day_leftover_sec / 3600;
        const hour_leftover_sec = day_leftover_sec % 3600;
        const min = hour_leftover_sec / 60;
        const sec = hour_leftover_sec % 60;

        //  %b %d %H:%M:%S %Y in C Language
        return std.fmt.bufPrint(buf, "{s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC {d}", .{
            month_names[date.month - 1],
            date.day,
            hour,
            min,
            sec,
            date.year,
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
