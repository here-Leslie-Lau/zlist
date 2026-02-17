const std = @import("std");
const mem = std.mem;
const Terminal = std.Io.Terminal;
const testing = std.testing;

const file = @import("file.zig");
const PrintMode = @import("print_mode.zig").PrintMode;

pub const SortType = enum {
    /// sort by name(asc)
    name,
    /// sort by name length(asc)
    length,
};

pub const Files = struct {
    const Self = @This();

    pub const Options = struct {
        /// show detail mode
        show_detail: bool = false,
        /// show hidden files
        show_hidden: bool = false,
        /// show recursive
        recursive: bool = false,
        /// sort type
        sort_type: SortType = .name,
    };

    allocator: mem.Allocator,
    io: std.Io,
    items: std.ArrayList(file.File),
    opt: Options,

    icon_inventory: std.StaticStringMap([]const u8) = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".zig", " " },
        .{ ".go", " " },
        .{ ".rs", " " },
        .{ ".c", " " },
        .{ ".cpp", " " },
        .{ ".h", " " },
        .{ ".js", " " },
        .{ ".ts", " " },
        .{ ".py", " " },
        .{ ".java", " " },
        .{ ".md", " " },
        .{ ".txt", " " },
        .{ ".png", " " },
        .{ ".jpg", " " },
        .{ ".jpeg", " " },
        .{ ".gif", " " },
        // default file icon
        .{ "", " " },
    }),

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

        switch (opt.sort_type) {
            .length => {
                // sort by name length
                mem.sortUnstable(file.File, files.items, {}, file.File.nameLenLessThan);
            },
            else => {
                // sort by name ascending
                mem.sortUnstable(file.File, files.items, {}, file.File.nameLessThan);
            },
        }

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
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(self.io, &stdout_buf);

        const stdout = &stdout_writer.interface;
        // get term
        const term = try self.getTerminal(stdout, stdout_file);

        const max_display_len = self.getMaxDisplayLen();
        const term_width = self.getTerminalWidth(stdout_file.handle);
        const col_width = max_display_len + 2; // 2 spaces padding
        var cols = term_width / col_width;
        if (cols < 1) {
            cols = 1;
        }

        for (self.items.items, 0..) |val, i| {
            const icon = self.getIcon(val.is_dir, val.name);

            // set color
            try term.setColor(val.getColor());
            // print item
            try term.writer.print(PrintMode.Normal.toString(), .{
                icon,
                val.name,
                max_display_len - icon.len + 1,
            });
            // reset color
            try term.setColor(Terminal.Color.reset);

            // make sure to print newline after each row
            if ((i + 1) % cols == 0) {
                try term.writer.print("\n", .{});
            }
        }

        try term.writer.print("\n", .{});
        try term.writer.flush();
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

    inline fn getIcon(self: Self, is_dir: bool, name: []const u8) []const u8 {
        if (is_dir) {
            return " ";
        }

        const ext = std.fs.path.extension(name);
        if (self.icon_inventory.get(ext)) |icon| {
            return icon;
        }

        // return default icons based on extension
        return " ";
    }

    /// list files in detail mode
    pub fn listDetail(self: Self) !void {
        // stdout
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(self.io, &stdout_buf);

        const stdout = &stdout_writer.interface;
        // get term
        const term = try self.getTerminal(stdout, stdout_file);

        var perm_buf: [10]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;

        for (self.items.items) |val| {
            // first, set color
            try term.setColor(val.getColor());
            try term.writer.print(PrintMode.Detail.toString(), .{
                val.getPermissions(&perm_buf),
                val.username,
                val.groupname,
                try val.humanSize(&size_buf),
                try val.formatTime(&time_buf),
                self.getIcon(val.is_dir, val.name),
                val.name,
            });

            // reset color
            try term.setColor(Terminal.Color.reset);
            try term.writer.print("\n", .{});
        }

        try term.writer.flush();
    }

    /// list files recursively
    pub fn listRecursive(
        self: Self,
        term: Terminal,
        prefix: []const u8,
        first: bool,
        dir: std.Io.Dir,
    ) !void {
        if (first) {
            try term.writer.print(".\n", .{});
        }

        const total = self.items.items.len;

        for (self.items.items, 0..) |val, i| {
            const is_last = (i == total - 1);
            const connector = if (is_last) "└──" else "├──";

            // set color for prefix and connector
            try term.setColor(Terminal.Color.bright_blue);
            try term.writer.print(PrintMode.RecursivePrefix.toString(), .{
                prefix,
                connector,
            });
            // reset color
            try term.setColor(Terminal.Color.reset);

            // print file/directory name
            try term.setColor(val.getColor());
            try term.writer.print(PrintMode.RecursiveWithFileMeta.toString(), .{
                self.getIcon(val.is_dir, val.name),
                val.name,
            });
            try term.setColor(Terminal.Color.reset);

            if (val.is_dir) {
                const sub_dir = try dir.openDir(self.io, val.name, .{ .iterate = true });
                defer sub_dir.close(self.io);

                var sub_files = try Files.init(
                    self.allocator,
                    self.io,
                    sub_dir,
                    self.opt,
                );
                defer sub_files.deinit();

                // recursive itself
                const child_connector = if (is_last) "    " else "│   ";
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, child_connector });

                try sub_files.listRecursive(term, new_prefix, false, sub_dir);

                self.allocator.free(new_prefix);
            }
        }
    }

    /// get terminal info
    pub inline fn getTerminal(self: Self, writer: anytype, f: std.Io.File) !Terminal {
        const term_mode = try Terminal.Mode.detect(self.io, f, false, false);
        return Terminal{
            .mode = term_mode,
            .writer = writer,
        };
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

test "recursive" {
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test1.txt", .data = "hello 1" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test2.txt", .data = "hello 2" });

    try tmp_dir.dir.createDirPath(io, "sub_dir");
    var tmp_sub_dir = try tmp_dir.dir.openDir(io, "sub_dir", .{ .iterate = true });
    defer tmp_sub_dir.close(io);
    _ = try tmp_sub_dir.createFile(io, "sub_test1.txt", .{});

    const allocator = testing.allocator;

    // stdout
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    var files = try Files.init(
        allocator,
        io,
        tmp_dir.dir,
        .{},
    );
    defer files.deinit();

    const term = try files.getTerminal(&stdout_writer.interface, stdout_file);

    try files.listRecursive(term, "", true, tmp_dir.dir);
    try stdout_writer.interface.flush();
}
