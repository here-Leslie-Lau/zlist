const std = @import("std");
const Terminal = std.Io.Terminal;

const zlist = @import("zlist");

const icon_inventory = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".zig", " " },
    .{ ".zon", " " },
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
});

const color_inventory = std.StaticStringMap(Terminal.Color).initComptime(.{
    .{ ".md", Terminal.Color.bright_magenta },
    .{ ".png", Terminal.Color.bright_cyan },
    .{ ".jpg", Terminal.Color.bright_cyan },
    .{ ".jpeg", Terminal.Color.bright_cyan },
    .{ ".gif", Terminal.Color.bright_cyan },
    .{ ".sh", Terminal.Color.bright_green },
    .{ "", Terminal.Color.bright_yellow },
});

/// list files in simple mode
pub fn list(
    files: zlist.Files,
    term: Terminal,
    handle: std.Io.File.Handle,
    comptime mode_opt: zlist.ModeOptionsComptime,
) !void {
    const term_width = getTerminalWidth(handle);
    const entries = files.entries();
    const total_items = entries.len;

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

                const item = entries[idx];
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
        final_col_widths[0] = files.maxDisplayLen() + (if (mode_opt.pure) 2 else 5);
    }

    for (0..optimal_rows) |r| {
        for (0..optimal_cols) |c| {
            const idx = c * optimal_rows + r;
            if (idx >= total_items) continue;

            const val = entries[idx];
            const item_len = if (mode_opt.pure) val.name.len + 2 else val.name.len + 5;

            // Print prefix, icon and name
            if (!mode_opt.pure) {
                const icon = getIcon(val.is_dir, val.name);
                try term.writer.print("  ", .{});

                try term.setColor(getColor(val.is_dir, val.name));
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

/// list files in detail mode
pub fn listDetail(files: zlist.Files, term: Terminal, comptime mode_opt: zlist.ModeOptionsComptime) !void {
    var perm_buf: [10]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    var display_name_buf: [std.fs.max_path_bytes]u8 = undefined;

    const show_git = files.hasGitStatus() and !mode_opt.pure;

    for (files.entries()) |val| {
        if (!mode_opt.pure) {
            try term.setColor(getColor(val.is_dir, val.name));
        }

        if (show_git) {
            const git_char = getGitStatusChar(files, val.name) orelse ' ';
            const git_color = getGitStatusColor(files, val.name);

            try term.setColor(git_color);
            const icon = getIcon(val.is_dir, val.name);
            try term.writer.print(comptime zlist.PrintMode.DetailWithGit.toString(), .{
                git_char,
                val.getPermissions(&perm_buf),
                val.username,
                val.groupname,
                try val.humanSize(&size_buf),
                try val.formatTime(&time_buf),
                icon,
                try val.formatLongDisplayName(&display_name_buf),
            });
        } else {
            if (mode_opt.pure) {
                try term.writer.print(comptime zlist.PrintMode.DetailPure.toString(), .{
                    val.getPermissions(&perm_buf),
                    val.username,
                    val.groupname,
                    try val.humanSize(&size_buf),
                    try val.formatTime(&time_buf),
                    try val.formatLongDisplayName(&display_name_buf),
                });
            } else {
                const icon = getIcon(val.is_dir, val.name);
                try term.writer.print(comptime zlist.PrintMode.Detail.toString(), .{
                    val.getPermissions(&perm_buf),
                    val.username,
                    val.groupname,
                    try val.humanSize(&size_buf),
                    try val.formatTime(&time_buf),
                    icon,
                    try val.formatLongDisplayName(&display_name_buf),
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
    files: *zlist.Files,
    term: Terminal,
    prefix: []const u8,
    first: bool,
    dir: std.Io.Dir,
    comptime mode_opt: zlist.ModeOptionsComptime,
) !void {
    if (first) {
        try term.writer.print(".\n", .{});
    }

    // Determine if the maximum number of level has been reached.
    if (files.opt.recursion_level > 0) {
        if (files.curr_recursion_level > files.opt.recursion_level) {
            // reached max recursion level
            return;
        }
    }

    const entries = files.entries();
    const total = entries.len;

    for (entries, 0..) |val, i| {
        const is_last = (i == total - 1);
        const connector = if (is_last) "└──" else "├──";

        // print prefix and connector
        if (!mode_opt.pure) {
            // set color for prefix and connector
            try term.setColor(Terminal.Color.bright_blue);
        }
        try term.writer.print(comptime zlist.PrintMode.RecursivePrefix.toString(), .{
            prefix,
            connector,
        });
        if (!mode_opt.pure) {
            // reset color
            try term.setColor(Terminal.Color.reset);
        }

        // print file/directory name
        if (!mode_opt.pure) {
            try term.setColor(getColor(val.is_dir, val.name));

            try term.writer.print(comptime zlist.PrintMode.RecursiveWithFileMeta.toString(), .{
                getIcon(val.is_dir, val.name),
                val.name,
            });
        } else {
            // pure mode, no color and no icon
            try term.writer.print(comptime zlist.PrintMode.RecursiveWithFileMetaPure.toString(), .{val.name});
        }
        if (!mode_opt.pure) {
            try term.setColor(Terminal.Color.reset);
        }

        if (val.is_dir) {
            const sub_dir = dir.openDir(files.io, val.name, .{ .iterate = true }) catch |err| {
                // print error message and continue
                try term.writer.print("\x1b[31mzl: cannot open directory '{s}': {any}\x1b[0m\n", .{ val.name, err });
                continue;
            };
            defer sub_dir.close(files.io);

            var sub_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer sub_arena.deinit();

            var sub_files = try zlist.Files.init(
                sub_arena.allocator(),
                files.io,
                sub_dir,
                files.opt,
            );
            sub_files.curr_recursion_level = files.curr_recursion_level + 1;

            // recursive itself
            const child_connector = if (is_last) "    " else "│   ";

            // concat prefix and child connector for subdirectory
            var prefix_builder = try std.ArrayList(u8).initCapacity(files.allocator, prefix.len + child_connector.len);
            defer prefix_builder.deinit(files.allocator);

            try prefix_builder.appendSlice(files.allocator, prefix);
            try prefix_builder.appendSlice(files.allocator, child_connector);

            try listRecursive(&sub_files, term, prefix_builder.items, false, sub_dir, mode_opt);

            // accumulate counts from subdirectories
            files.total_folders += sub_files.total_folders;
            files.total_files += sub_files.total_files;
        }
    }
}

/// print report after listing.
/// it will not flush the writer, plz flush it by yourself after calling this function.
pub inline fn printReport(files: zlist.Files, writer: anytype) !void {
    try writer.print(
        "\n  Found {d} contents in directory.\n  Folders: {d}\n  Files: {d}\n",
        .{
            files.total_folders + files.total_files,
            files.total_folders,
            files.total_files,
        },
    );
}

/// get terminal info
pub inline fn getTerminal(io: std.Io, writer: anytype, f: std.Io.File) !Terminal {
    const term_mode = try Terminal.Mode.detect(io, f, false, false);
    return Terminal{
        .mode = term_mode,
        .writer = writer,
    };
}

/// get terminal width
inline fn getTerminalWidth(handle: std.Io.File.Handle) usize {
    var winsize = std.mem.zeroes(std.posix.winsize);
    if (std.c.ioctl(handle, std.c.T.IOCGWINSZ, @intFromPtr(&winsize)) == 0) {
        return winsize.col;
    }

    // default width
    return 80;
}

inline fn getIcon(is_dir: bool, name: []const u8) []const u8 {
    if (is_dir) {
        return " ";
    }

    const ext = std.fs.path.extension(name);
    if (icon_inventory.get(ext)) |icon| {
        return icon;
    }

    // return default icons based on extension
    return " ";
}

inline fn getColor(is_dir: bool, name: []const u8) Terminal.Color {
    if (is_dir) {
        return Terminal.Color.bright_blue;
    }

    const ext = std.fs.path.extension(name);
    if (color_inventory.get(ext)) |color| {
        return color;
    }

    // default file color
    return Terminal.Color.bright_yellow;
}

inline fn getGitStatusChar(files: zlist.Files, name: []const u8) ?u8 {
    const status = files.gitStatus(name) orelse return null;
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

inline fn getGitStatusColor(files: zlist.Files, name: []const u8) Terminal.Color {
    const status = files.gitStatus(name) orelse return Terminal.Color.reset;
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

test "get_detail" {
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test1.txt", .data = "hello 1" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test2.txt", .data = "hello 2" });

    try tmp_dir.dir.createDirPath(io, "sub_dir");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // stdout
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    var files = try zlist.Files.init(
        allocator,
        io,
        tmp_dir.dir,
        .{ .show_detail = true },
    );
    defer files.deinit();

    const term = try getTerminal(io, &stdout_writer.interface, stdout_file);

    try listDetail(files, term, .{ .pure = false });
    try stdout_writer.interface.flush();
}

test "recursive" {
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test1.txt", .data = "hello 1" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test2.txt", .data = "hello 2" });

    try tmp_dir.dir.createDirPath(io, "sub_dir");
    var tmp_sub_dir = try tmp_dir.dir.openDir(io, "sub_dir", .{ .iterate = true });
    defer tmp_sub_dir.close(io);
    _ = try tmp_sub_dir.createFile(io, "sub_test1.txt", .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // stdout
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    var files = try zlist.Files.init(
        allocator,
        io,
        tmp_dir.dir,
        .{},
    );
    defer files.deinit();

    const term = try getTerminal(io, &stdout_writer.interface, stdout_file);

    try listRecursive(&files, term, "", true, tmp_dir.dir, .{ .pure = false });
    try stdout_writer.interface.flush();
}
