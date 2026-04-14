const std = @import("std");
const mem = std.mem;
const Terminal = std.Io.Terminal;
const testing = std.testing;

const file = @import("file.zig");
const opts = @import("opts.zig");
const git = @import("git.zig");

pub const Files = struct {
    const Self = @This();

    max_display_len: usize = 0,
    curr_recursion_level: i8 = 1,
    allocator: mem.Allocator,
    io: std.Io,
    items: std.ArrayList(file.File),
    opt: opts.FilesOptions,
    total_folders: usize = 0,
    total_files: usize = 0,

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
        .{ ".sh", " " },
        // default file icon
        .{ "", " " },
    }),

    color_inventory: std.StaticStringMap(Terminal.Color) = std.StaticStringMap(Terminal.Color).initComptime(.{
        .{ ".md", Terminal.Color.bright_magenta },
        .{ ".png", Terminal.Color.bright_cyan },
        .{ ".jpg", Terminal.Color.bright_cyan },
        .{ ".jpeg", Terminal.Color.bright_cyan },
        .{ ".gif", Terminal.Color.bright_cyan },
        .{ ".sh", Terminal.Color.bright_green },
        .{ "", Terminal.Color.bright_yellow },
    }),

    /// for caching username and groupname, key is uid/gid, value is username/groupname.
    /// since getting username from uid is a costly operation, we can cache it to improve performance.
    username_inventory: std.AutoHashMap(std.c.uid_t, []const u8),
    groupname_inventory: std.AutoHashMap(std.c.gid_t, []const u8),

    loaded_git: bool = false,
    /// for caching git status, key is filename, value is git status.
    git_inventory: std.StringHashMap(git.GitStatus),

    /// init a Files from a directory
    pub fn init(
        allocator: mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        opt: opts.FilesOptions,
    ) !Self {
        var files = try std.ArrayList(file.File).initCapacity(allocator, 32);
        errdefer files.deinit(allocator);

        var max_len: usize = 0;
        var total_folders: usize = 0;
        var total_files: usize = 0;

        // determine if we need to calculate recursive directory size. it is needed when recursive_dir_size is enabled, and either show_detail is true or sort by size.
        const needs_recursive_dir_size = opt.recursive_dir_size and (opt.show_detail or opt.sort_type == .size);

        // we need to load stat
        // if show_detail is true, sort by mtime/size, or changed-within is enabled.
        // otherwise we can skip loading stat to improve performance.
        const load_stat = shouldLoadStat(opt, needs_recursive_dir_size);
        const changed_within_now = if (opt.changed_within != null)
            std.Io.Timestamp.now(io, .real)
        else
            null;

        // initialize inventory if show_detail is true, otherwise leave them as undefined to save memory.
        var username_inventory: std.AutoHashMap(std.c.uid_t, []const u8) = undefined;
        var groupname_inventory: std.AutoHashMap(std.c.gid_t, []const u8) = undefined;
        if (opt.show_detail) {
            username_inventory = std.AutoHashMap(std.c.uid_t, []const u8).init(allocator);
            groupname_inventory = std.AutoHashMap(std.c.gid_t, []const u8).init(allocator);
        }

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            var fs = (try file.File.init(
                &entry,
                &dir,
                .{
                    .load_stat = load_stat,
                    .load_owner = opt.show_detail,
                    .show_hidden = opt.show_hidden,
                    .only_dir = opt.only_dir,
                    .only_file = opt.only_file,
                    .keep_dirs_for_match = opt.recursive,
                    .keep_dirs_for_changed_within = opt.recursive,
                    .keep_dirs_for_size = opt.recursive,
                    .exts = opt.exts,
                    .matches = opt.matches,
                    .changed_within = opt.changed_within,
                    .size_range = opt.size_range,
                    .changed_within_now = changed_within_now,
                },
                &username_inventory,
                &groupname_inventory,
            )) orelse continue;

            // copy name
            var name: []const u8 = undefined;
            name = try allocator.dupe(u8, entry.name);
            fs.name = name;

            if (!opt.show_detail and !opt.recursive) {
                // get display length of the name, including icon(len is 2), just in normal mode
                const curr_len = fs.name.len + 2;
                if (curr_len > max_len) {
                    max_len = curr_len;
                }
            }

            if (opt.report) {
                if (fs.is_dir) {
                    total_folders += 1;
                } else {
                    total_files += 1;
                }
            }

            try files.append(allocator, fs);
        }

        if (needs_recursive_dir_size) {
            for (files.items) |*item| {
                if (!item.is_dir) continue;

                const sub_dir = dir.openDir(io, item.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close(io);

                const recursive_size = calculateDirectorySize(io, sub_dir) catch continue;
                item.setRecursiveSize(recursive_size);
            }
        }

        var loaded_git = false;
        var git_inventory: std.StringHashMap(git.GitStatus) = undefined;
        // git integration is enabled, and current directory is a git repository
        if (opt.show_git and git.isGitRepo(allocator, io, opt.path)) {
            // load git status inventory
            git_inventory = try git.getFileStatuses(allocator, io, opt.path);
            loaded_git = true;
        }

        switch (opt.sort_type) {
            .length => {
                // sort by name length
                mem.sortUnstable(file.File, files.items, {}, file.File.nameLenLessThan);
            },
            .dir_first => {
                // sort by directory first
                mem.sortUnstable(file.File, files.items, {}, file.File.dirMoreThan);
            },
            .mtime => {
                // sort by modification time desc
                mem.sortUnstable(file.File, files.items, {}, file.File.mtimeMoreThan);
            },
            .size => {
                // sort by file size desc
                mem.sortUnstable(file.File, files.items, {}, file.File.sizeMoreThan);
            },
            else => {
                // sort by name ascending
                mem.sortUnstable(file.File, files.items, {}, file.File.nameLessThan);
            },
        }

        return .{
            .max_display_len = max_len,
            .total_folders = total_folders,
            .total_files = total_files,
            .allocator = allocator,
            .io = io,
            .items = files,
            .opt = opt,
            .username_inventory = username_inventory,
            .groupname_inventory = groupname_inventory,
            .loaded_git = loaded_git,
            .git_inventory = git_inventory,
        };
    }

    pub fn initSingle(
        allocator: mem.Allocator,
        io: std.Io,
        path: []const u8,
        opt: opts.FilesOptions,
    ) !Self {
        const parent_path = std.fs.path.dirname(path) orelse ".";
        const base_name = std.fs.path.basename(path);

        const cwd = std.Io.Dir.cwd();
        const parent_dir = try cwd.openDir(io, parent_path, .{});
        defer parent_dir.close(io);

        const stat = try parent_dir.statFile(io, base_name, .{});
        const entry: std.Io.Dir.Entry = .{
            .name = base_name,
            .kind = stat.kind,
            .inode = 0,
        };

        var files = try std.ArrayList(file.File).initCapacity(allocator, 1);
        errdefer files.deinit(allocator);

        var max_len: usize = 0;
        var total_folders: usize = 0;
        var total_files: usize = 0;

        const needs_recursive_dir_size = opt.recursive_dir_size and (opt.show_detail or opt.sort_type == .size);
        const load_stat = shouldLoadStat(opt, needs_recursive_dir_size);
        const changed_within_now = if (opt.changed_within != null)
            std.Io.Timestamp.now(io, .real)
        else
            null;

        var username_inventory: std.AutoHashMap(std.c.uid_t, []const u8) = undefined;
        var groupname_inventory: std.AutoHashMap(std.c.gid_t, []const u8) = undefined;
        if (opt.show_detail) {
            username_inventory = std.AutoHashMap(std.c.uid_t, []const u8).init(allocator);
            groupname_inventory = std.AutoHashMap(std.c.gid_t, []const u8).init(allocator);
        }

        if (try file.File.init(
            &entry,
            &parent_dir,
            .{
                .load_stat = load_stat,
                .load_owner = opt.show_detail,
                .show_hidden = opt.show_hidden,
                .only_dir = opt.only_dir,
                .only_file = opt.only_file,
                .keep_dirs_for_match = opt.recursive,
                .keep_dirs_for_changed_within = opt.recursive,
                .keep_dirs_for_size = opt.recursive,
                .exts = opt.exts,
                .matches = opt.matches,
                .changed_within = opt.changed_within,
                .size_range = opt.size_range,
                .changed_within_now = changed_within_now,
            },
            &username_inventory,
            &groupname_inventory,
        )) |single_file| {
            var item = single_file;
            item.name = try allocator.dupe(u8, base_name);

            if (!opt.show_detail and !opt.recursive) {
                max_len = item.name.len + 2;
            }

            if (opt.report) {
                if (item.is_dir) {
                    total_folders = 1;
                } else {
                    total_files = 1;
                }
            }

            try files.append(allocator, item);
        }

        var loaded_git = false;
        var git_inventory: std.StringHashMap(git.GitStatus) = undefined;
        if (opt.show_git and git.isGitRepo(allocator, io, parent_path)) {
            git_inventory = try git.getFileStatuses(allocator, io, parent_path);
            loaded_git = true;
        }

        return .{
            .max_display_len = max_len,
            .total_folders = total_folders,
            .total_files = total_files,
            .allocator = allocator,
            .io = io,
            .items = files,
            .opt = opt,
            .username_inventory = username_inventory,
            .groupname_inventory = groupname_inventory,
            .loaded_git = loaded_git,
            .git_inventory = git_inventory,
        };
    }

    inline fn shouldLoadStat(opt: opts.FilesOptions, needs_recursive_dir_size: bool) bool {
        return opt.show_detail or
            opt.sort_type == .mtime or
            opt.sort_type == .size or
            opt.changed_within != null or
            opt.size_range != null or
            needs_recursive_dir_size;
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit(self.allocator);
    }

    /// recursively calculate directory size by summing up sizes of all descendant files.
    fn calculateDirectorySize(io: std.Io, dir: std.Io.Dir) anyerror!u64 {
        var total_size: u64 = 0;
        var it = dir.iterate();

        while (try it.next(io)) |entry| {
            const stat = file.File.statForName(entry.name, &dir) orelse continue;

            if (entry.kind == .directory) {
                // recursively calculate size for subdirectory
                const child_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child_dir.close(io);

                const child_size = calculateDirectorySize(io, child_dir) catch continue;
                total_size = std.math.add(u64, total_size, child_size) catch return error.Overflow;
                continue;
            }

            total_size = std.math.add(u64, total_size, stat.size) catch return error.Overflow;
        }

        return total_size;
    }

    /// list files in simple mode
    pub fn list(
        self: Self,
        term: Terminal,
        handle: std.Io.File.Handle,
        comptime mode_opt: opts.ModeOptionsComptime,
    ) !void {
        const term_width = self.getTerminalWidth(handle);
        const total_items = self.items.items.len;

        if (total_items == 0) {
            return;
        }

        // Max possible columns (assuming each item is at least 1 char + padding)
        const MAX_COLS: usize = 512;
        var max_possible_cols = term_width / 3;
        if (max_possible_cols == 0) {
            max_possible_cols = 1;
        }
        if (max_possible_cols > MAX_COLS) {
            max_possible_cols = MAX_COLS;
        }
        if (max_possible_cols > total_items) {
            max_possible_cols = total_items;
        }

        var optimal_cols: usize = 1;
        var optimal_rows: usize = total_items;
        var col_widths: [MAX_COLS]usize = undefined;
        var final_col_widths: [MAX_COLS]usize = undefined;

        var current_cols = max_possible_cols;
        while (current_cols > 1) : (current_cols -= 1) {
            // rows = cell(total_items / cols)
            const rows = (total_items + current_cols - 1) / current_cols;
            @memset(col_widths[0..current_cols], 0);

            var total_width: usize = 0;
            var valid = true;

            for (0..current_cols) |c| {
                for (0..rows) |r| {
                    const idx = c * rows + r;
                    if (idx >= total_items) continue;

                    const item = self.items.items[idx];
                    // visual length: pure mode has 2 space prefix. normal mode has 2 space + icon(2) + 1 space = 5.
                    const item_len = if (mode_opt.pure) item.name.len + 2 else item.name.len + 5;

                    if (item_len > col_widths[c]) {
                        col_widths[c] = item_len;
                    }
                }
                total_width += col_widths[c];
                if (c < current_cols - 1) {
                    total_width += 2; // 2 spaces between columns
                }

                if (total_width > term_width) {
                    valid = false;
                    break;
                }
            }

            if (valid) {
                optimal_cols = current_cols;
                optimal_rows = rows;
                @memcpy(final_col_widths[0..current_cols], col_widths[0..current_cols]);
                break;
            }
        }

        if (optimal_cols == 1) {
            optimal_rows = total_items;
            final_col_widths[0] = self.max_display_len + (if (mode_opt.pure) 2 else 5);
        }

        for (0..optimal_rows) |r| {
            for (0..optimal_cols) |c| {
                const idx = c * optimal_rows + r;
                if (idx >= total_items) continue;

                const val = self.items.items[idx];
                const item_len = if (mode_opt.pure) val.name.len + 2 else val.name.len + 5;

                // Print prefix, icon and name
                if (!mode_opt.pure) {
                    const icon = self.getIcon(val.is_dir, val.name);
                    try term.writer.print("  ", .{});

                    try term.setColor(self.getColor(val.is_dir, val.name));
                    try term.writer.print("{s} {s}", .{ icon, val.name });
                    try term.setColor(Terminal.Color.reset);
                } else {
                    try term.writer.print("  {s}", .{val.name});
                }

                // Print padding
                if (c < optimal_cols - 1) {
                    const padding = final_col_widths[c] - item_len + 2; // +2 for inter-column space
                    for (0..padding) |_| {
                        try term.writer.print(" ", .{});
                    }
                }
            }
            try term.writer.print("\n", .{});
        }
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

    inline fn getColor(self: Self, is_dir: bool, name: []const u8) Terminal.Color {
        if (is_dir) {
            return Terminal.Color.bright_blue;
        }

        const ext = std.fs.path.extension(name);
        if (self.color_inventory.get(ext)) |color| {
            return color;
        }

        // default file color
        return Terminal.Color.bright_yellow;
    }

    inline fn getGitStatusChar(self: Self, name: []const u8) ?u8 {
        const status = self.git_inventory.get(name) orelse return null;
        return switch (status) {
            .modified => 'M',
            .added => 'A',
            .deleted => 'D',
            .renamed => 'R',
            .untracked => '?',
            .unmerged => 'U',
            .none => null,
        };
    }

    inline fn getGitStatusColor(self: Self, name: []const u8) Terminal.Color {
        const status = self.git_inventory.get(name) orelse return Terminal.Color.reset;
        return switch (status) {
            .modified => Terminal.Color.bright_yellow,
            .added => Terminal.Color.bright_green,
            .deleted => Terminal.Color.bright_red,
            .renamed => Terminal.Color.bright_blue,
            .untracked => Terminal.Color.bright_black,
            .unmerged => Terminal.Color.bright_red,
            .none => Terminal.Color.reset,
        };
    }

    /// list files in detail mode
    pub fn listDetail(self: Self, term: Terminal, comptime mode_opt: opts.ModeOptionsComptime) !void {
        var perm_buf: [10]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;

        const show_git = self.loaded_git and !mode_opt.pure;

        for (self.items.items) |val| {
            if (!mode_opt.pure) {
                try term.setColor(self.getColor(val.is_dir, val.name));
            }

            if (show_git) {
                const git_char = self.getGitStatusChar(val.name) orelse ' ';
                const git_color = self.getGitStatusColor(val.name);

                try term.setColor(git_color);
                const icon = self.getIcon(val.is_dir, val.name);
                try term.writer.print(comptime opts.PrintMode.DetailWithGit.toString(), .{
                    git_char,
                    val.getPermissions(&perm_buf),
                    val.username,
                    val.groupname,
                    try val.humanSize(&size_buf),
                    try val.formatTime(&time_buf),
                    icon,
                    val.name,
                });
            } else {
                if (mode_opt.pure) {
                    try term.writer.print(comptime opts.PrintMode.DetailPure.toString(), .{
                        val.getPermissions(&perm_buf),
                        val.username,
                        val.groupname,
                        try val.humanSize(&size_buf),
                        try val.formatTime(&time_buf),
                        val.name,
                    });
                } else {
                    const icon = self.getIcon(val.is_dir, val.name);
                    try term.writer.print(comptime opts.PrintMode.Detail.toString(), .{
                        val.getPermissions(&perm_buf),
                        val.username,
                        val.groupname,
                        try val.humanSize(&size_buf),
                        try val.formatTime(&time_buf),
                        icon,
                        val.name,
                    });
                }
            }

            if (!mode_opt.pure) {
                try term.setColor(Terminal.Color.reset);
            }
            try term.writer.print("\n", .{});
        }
    }

    /// list files recursively
    pub fn listRecursive(
        self: *Self,
        term: Terminal,
        prefix: []const u8,
        first: bool,
        dir: std.Io.Dir,
        comptime mode_opt: opts.ModeOptionsComptime,
    ) !void {
        if (first) {
            try term.writer.print(".\n", .{});
        }

        // Determine if the maximum number of level has been reached.
        if (self.opt.recursion_level > 0) {
            if (self.curr_recursion_level > self.opt.recursion_level) {
                // reached max recursion level
                return;
            }
        }

        const total = self.items.items.len;

        for (self.items.items, 0..) |val, i| {
            const is_last = (i == total - 1);
            const connector = if (is_last) "└──" else "├──";

            // print prefix and connector
            if (!mode_opt.pure) {
                // set color for prefix and connector
                try term.setColor(Terminal.Color.bright_blue);
            }
            try term.writer.print(comptime opts.PrintMode.RecursivePrefix.toString(), .{
                prefix,
                connector,
            });
            if (!mode_opt.pure) {
                // reset color
                try term.setColor(Terminal.Color.reset);
            }

            // print file/directory name
            if (!mode_opt.pure) {
                try term.setColor(self.getColor(val.is_dir, val.name));

                try term.writer.print(comptime opts.PrintMode.RecursiveWithFileMeta.toString(), .{
                    self.getIcon(val.is_dir, val.name),
                    val.name,
                });
            } else {
                // pure mode, no color and no icon
                try term.writer.print(comptime opts.PrintMode.RecursiveWithFileMetaPure.toString(), .{val.name});
            }
            if (!mode_opt.pure) {
                try term.setColor(Terminal.Color.reset);
            }

            if (val.is_dir) {
                const sub_dir = dir.openDir(self.io, val.name, .{ .iterate = true }) catch |err| {
                    // print error message and continue
                    try term.writer.print("\x1b[31mzl: cannot open directory '{s}': {any}\x1b[0m\n", .{ val.name, err });
                    continue;
                };
                defer sub_dir.close(self.io);

                var sub_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer sub_arena.deinit();

                var sub_files = try Files.init(
                    sub_arena.allocator(),
                    self.io,
                    sub_dir,
                    self.opt,
                );
                sub_files.curr_recursion_level = self.curr_recursion_level + 1;

                // recursive itself
                const child_connector = if (is_last) "    " else "│   ";

                // concat prefix and child connector for subdirectory
                var prefix_builder = try std.ArrayList(u8).initCapacity(self.allocator, prefix.len + child_connector.len);
                defer prefix_builder.deinit(self.allocator);

                try prefix_builder.appendSlice(self.allocator, prefix);
                try prefix_builder.appendSlice(self.allocator, child_connector);

                try sub_files.listRecursive(term, prefix_builder.items, false, sub_dir, mode_opt);

                // accumulate counts from subdirectories
                self.total_folders += sub_files.total_folders;
                self.total_files += sub_files.total_files;
            }
        }
    }

    /// print report after listing.
    /// it will not flush the writer, plz flush it by yourself after calling this function.
    pub inline fn printReport(self: Self, writer: anytype) !void {
        try writer.print(
            "\n  Found {d} contents in directory.\n  Folders: {d}\n  Files: {d}\n",
            .{
                self.total_folders + self.total_files,
                self.total_folders,
                self.total_files,
            },
        );
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // stdout
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    var files = try Files.init(
        allocator,
        io,
        tmp_dir.dir,
        .{ .show_detail = true },
    );
    defer files.deinit();

    const term = try files.getTerminal(&stdout_writer.interface, stdout_file);

    try files.listDetail(term, .{ .pure = false });
    try stdout_writer.interface.flush();
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    try files.listRecursive(term, "", true, tmp_dir.dir, .{ .pure = false });
    try stdout_writer.interface.flush();
}

test "recursive directory size uses descendant file sizes" {
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "abcd" });
    try tmp_dir.dir.createDirPath(io, "sub_dir/nested");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "sub_dir/child.txt", .data = "hello" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "sub_dir/nested/deep.txt", .data = "xyz" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var files = try Files.init(
        arena.allocator(),
        io,
        tmp_dir.dir,
        .{ .show_detail = true, .recursive_dir_size = true },
    );
    defer files.deinit();

    var found_dir = false;
    for (files.items.items) |entry| {
        if (!std.mem.eql(u8, entry.name, "sub_dir")) continue;

        found_dir = true;
        try testing.expectEqual(@as(?u64, 8), entry.effectiveSize());
    }

    try testing.expect(found_dir);
}

test "without recursive directory size directory keeps stat size" {
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "sub_dir");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "sub_dir/child.txt", .data = "hello" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var files = try Files.init(
        arena.allocator(),
        io,
        tmp_dir.dir,
        .{ .show_detail = true },
    );
    defer files.deinit();

    var found_dir = false;
    for (files.items.items) |entry| {
        if (!std.mem.eql(u8, entry.name, "sub_dir")) continue;

        found_dir = true;
        try testing.expect(entry.recursive_size == null);
        try testing.expect(entry.effectiveSize() != null);
    }

    try testing.expect(found_dir);
}
