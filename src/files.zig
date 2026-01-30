const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const file = @import("file.zig");

pub const Files = struct {
    const Self = @This();

    pub const Options = struct {
        /// show detail mode
        show_detail: bool = false,
        /// show hidden files
        show_hidden: bool = false,
    };

    allocator: mem.Allocator,
    io: std.Io,
    items: std.ArrayList(file.File),
    opt: Options,

    /// init a Files from a directory
    pub fn init(
        allocator: mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        opt: Options,
    ) !Self {
        var files = try std.ArrayList(file.File).initCapacity(allocator, 32);
        errdefer files.deinit(allocator);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            var fs = (try file.File.init(io, &entry, &dir, .{ .show_detail = opt.show_detail, .show_hidden = opt.show_hidden })) orelse continue;

            // copy name
            var name: []const u8 = undefined;
            name = try allocator.dupe(u8, entry.name);
            fs.name = name;

            try files.append(allocator, fs);
        }

        // sort files by name
        // mem.sortUnstable(file.File, files.items, {}, file.File.nameLessThan);

        return .{
            .allocator = allocator,
            .io = io,
            .items = files,
            .opt = opt,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.items.items) |item| {
            self.allocator.free(item.name);
        }

        self.items.deinit(self.allocator);
    }

    /// list files in simple mode
    pub fn list(self: Self) !void {
        // stdout
        var stdout_buf: [1024]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(self.io, &stdout_buf);

        const stdout = &stdout_writer.interface;

        const max_display_len = self.getMaxDisplayLen();
        const term_width = self.getTerminalWidth(stdout_file.handle);
        const col_width = max_display_len + 2; // 2 spaces padding
        var cols = term_width / col_width;
        if (cols < 1) {
            cols = 1;
        }

        for (self.items.items, 0..) |val, i| {
            const icon = self.getIcon(val.is_dir, val.name);

            // print item
            try stdout.print("  {s}{s} {s:<[3]}\x1b[0m", .{ val.getColor(), icon, val.name, max_display_len - icon.len + 1 });

            // make sure to print newline after each row
            if ((i + 1) % cols == 0) {
                try stdout.print("\n", .{});
            }
        }

        try stdout.print("\n", .{});
        try stdout.flush();
    }

    /// get terminal width
    inline fn getTerminalWidth(_: Self, handle: std.Io.File.Handle) usize {
        var winsize = std.mem.zeroes(std.posix.winsize);
        if (std.c.ioctl(handle, std.c.T.IOCGWINSZ, @intFromPtr(&winsize)) == 0) {
            return winsize.col;
        }

        // default width
        return 80;
    }

    /// get max display length of file names, including icons
    inline fn getMaxDisplayLen(self: Self) usize {
        var max_len: usize = 0;
        for (self.items.items) |val| {
            const curr_len = val.name.len + self.getIcon(val.is_dir, val.name).len;

            if (curr_len > max_len) {
                max_len = curr_len;
            }
        }

        return max_len;
    }

    inline fn getIcon(_: Self, is_dir: bool, name: []const u8) []const u8 {
        if (is_dir) {
            return " ";
        }

        const ext = std.fs.path.extension(name);
        if (std.mem.eql(u8, ext, ".zig")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".go")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".rs")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".c")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".cpp")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".h")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".js")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".ts")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".py")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".java")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".md")) {
            return " ";
        } else if (std.mem.eql(u8, ext, ".txt")) {
            return " ";
        } else {
            // default file icon
            return " ";
        }
    }

    /// list files in detail mode
    pub fn listDetail(self: Self) !void {
        // stdout
        var stdout_buf: [1024]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(self.io, &stdout_buf);

        const stdout = &stdout_writer.interface;

        var perm_buf: [10]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;

        for (self.items.items) |val| {
            try stdout.print("  {s}{s:<11} {s:<8} {s:<8} {s:<8} {s:<8}  {s} {s} \x1b[0m\n", .{
                val.getColor(),
                val.getPermissions(&perm_buf),
                val.username,
                val.groupname,
                try val.humanSize(&size_buf),
                try val.formatTime(&time_buf),
                self.getIcon(val.is_dir, val.name),
                val.name,
            });
        }

        try stdout.flush();
    }
};

test "get_detail" {
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test1.txt", .data = "hello 1" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test2.txt", .data = "hello 2" });

    try tmp_dir.dir.createDirPath(io, "sub_dir");

    const allocator = testing.allocator;

    var files = try Files.init(
        allocator,
        io,
        tmp_dir.dir,
        .{ .show_detail = true },
    );
    defer files.deinit();

    try files.listDetail();
}
