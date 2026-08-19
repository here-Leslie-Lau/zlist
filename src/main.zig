const std = @import("std");

const clap = @import("clap");
const zlist = @import("zlist");

const cfg = @import("cfg.zig");
const cli_args = @import("cli_args.zig");
const render = @import("render.zig");

var threaded: std.Io.Threaded = undefined;

const params_desc: []const u8 = blk: {
    break :blk
    \\-h, --help                       Usage: zl [OPTIONS] [PATH]...
    \\-l, --long                       Show the long view.
    \\-H, --header                     Show header in the long view.
    \\    --no-permissions             Hide permissions from the long view.
    \\    --no-user                    Hide user from the long view.
    \\    --no-group                   Hide group from the long view.
    \\    --no-size                    Hide size from the long view.
    \\    --no-time                    Hide time from the long view.
    \\    --no-icon                    Hide icon from the long view.
    \\-a, --a                          Include hidden entries.
    \\    --du                         Show recursive directory size in long view and size sort. This is the sum of file sizes, not the same as `du` disk usage.
    \\-G, --dir-grouping <DIRGROUPING> Group directories before or after files. Default: none. OPTIONS: none, before, after.
    \\-s, --sort <SORTTYPE>            Sort results. Default: name. OPTIONS: name, length, mtime, size.
    \\-R, --reverse                    Reverse sort
    \\    --size <str>...              Filter files by size range (e.g. --size gt:10K --size lte:2M).
    \\    --changed-within <str>       Only show entries changed within a time range (e.g. --changed-within 7d).
    \\-r, --recursive                  Recurse into subdirectories. Same as -L 0.
    \\-L, --level <INT>                Limit recursion depth. 0 means no limit.
    \\    --root-display <ROOTDISPLAY> Changes how root dir is displayed in recursive view. Default: dot. OPTIONS: dot, name, none.
    \\-p, --pure                       Show names only, without colors or icons.
    \\    --color <COLORUSE>           When to use terminal colors. Default: auto. OPTIONS: auto, always, never.
    \\    --report                     Show a short summary of files and folders.
    \\-d, --dir                        Only show directories. If used with -D, both are ignored.
    \\-D, --no_dir                     Only show files. If used with -d, both are ignored.
    \\-g, --git                        Show git status in long view.
    \\-e, --ext <str>...               Filter by extension (e.g. --ext zig,md,ts).
    \\-m, --match <str>...             Filter names by substring (e.g. --match main,readme).
    \\-C, --config <str>               Load config from a .zon file.
    \\<str>...
    \\
    ;
};

pub fn main(init: std.process.Init.Minimal) !void {
    // get allocator (c_allocator and arena allocator)
    const c_allocator = std.heap.c_allocator;
    var arena_impl = std.heap.ArenaAllocator.init(c_allocator);
    defer arena_impl.deinit();
    const allocator = arena_impl.allocator();

    // get io
    threaded = std.Io.Threaded.init(c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // parsers
    const parsers = comptime .{
        .str = clap.parsers.string,
        .DIRGROUPING = clap.parsers.enumeration(zlist.DirGrouping),
        .SORTTYPE = clap.parsers.enumeration(zlist.SortType),
        .INT = clap.parsers.int(i8, 10),
        .ROOTDISPLAY = clap.parsers.enumeration(render.RootDisplay),
        .COLORUSE = clap.parsers.enumeration(render.ColorUse),
    };

    // parse command line arguments
    var diag = clap.Diagnostic{};
    const params = comptime clap.parseParamsComptime(params_desc);
    const res = clap.parse(
        clap.Help,
        &params,
        parsers,
        init.args,
        .{
            .allocator = allocator,
            .diagnostic = &diag,
        },
    ) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        std.debug.print("\nRun --help for usage information.\n", .{});
        return;
    };

    if (res.args.help != 0) {
        // show help msg
        return clap.helpToFile(io, .stderr(), clap.Help, &params, .{});
    }

    const cli = cli_args.parseCliConfig(allocator, res) catch |err| switch (err) {
        error.InvalidChangedWithin => {
            printInvalidChangedWithin();
            return;
        },
        error.InvalidSize => {
            printInvalidSize();
            return;
        },
        error.ConflictingSizeRange => {
            printConflictingSizeRange();
            return;
        },
        else => return err,
    };

    const config = cfg.load(allocator, io, cli.config_path) catch |err| {
        if (cli.config_path) |config_path| {
            std.debug.print("zl: failed to load config '{s}': {s}\n", .{ config_path, @errorName(err) });
        } else {
            std.debug.print("zl: failed to load config: {s}\n", .{@errorName(err)});
        }
        return;
    };

    for (cli.paths, 0..) |path, index| {
        var opt = cli.opt;
        opt.path = path;

        // Reuse parsed rendering options for every requested path.
        runForPath(allocator, io, opt, cli.long_view_opt, cli.root_display, path, cli.pure, cli.color_use, config, cli.paths.len > 1, index) catch |err| switch (err) {
            error.FileNotFound => std.debug.print("zl: path not found: {s}\n", .{path}),
            error.NotDir => std.debug.print("zl: not a directory: {s}\n", .{path}),
            else => return err,
        };
    }
}

inline fn runForPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    opt: zlist.FilesOptions,
    long_view_opt: render.LongViewOptions,
    root_display: render.RootDisplay,
    path: []const u8,
    pure: bool,
    color_use: render.ColorUse,
    config: cfg.Config,
    show_header: bool,
    index: usize,
) !void {
    const stdout_file = std.Io.File.stdout();

    if (show_header) {
        var header_buf: [512]u8 = undefined;
        var header_writer = stdout_file.writer(io, &header_buf);

        if (index > 0) {
            try header_writer.interface.writeAll("\n");
        }

        try header_writer.interface.print("{s}:\n", .{path});
        try header_writer.interface.flush();
    }

    const cwd = std.Io.Dir.cwd();
    const dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return runForSingleFile(allocator, io, stdout_file, opt, long_view_opt, root_display, pure, color_use, config, path),
        error.FileNotFound => {
            std.debug.print("zl: path not found: {s}\n", .{path});
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    return runForDirectory(allocator, io, stdout_file, opt, long_view_opt, root_display, pure, color_use, config, dir);
}

inline fn runForDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    opt: zlist.FilesOptions,
    long_view_opt: render.LongViewOptions,
    root_display: render.RootDisplay,
    pure: bool,
    color_use: render.ColorUse,
    config: cfg.Config,
    dir: std.Io.Dir,
) !void {
    var files = try zlist.Files.init(allocator, io, dir, opt);
    defer files.deinit();

    try printFiles(io, stdout_file, opt, long_view_opt, root_display, pure, color_use, config, &files, dir);
}

inline fn runForSingleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    opt: zlist.FilesOptions,
    long_view_opt: render.LongViewOptions,
    root_display: render.RootDisplay,
    pure: bool,
    color_use: render.ColorUse,
    config: cfg.Config,
    path: []const u8,
) !void {
    var files = try zlist.Files.initSingle(allocator, io, path, opt);
    defer files.deinit();

    try printFiles(io, stdout_file, opt, long_view_opt, root_display, pure, color_use, config, &files, null);
}

fn printFiles(
    io: std.Io,
    stdout_file: std.Io.File,
    opt: zlist.FilesOptions,
    long_view_opt: render.LongViewOptions,
    root_display: render.RootDisplay,
    pure: bool,
    color_use: render.ColorUse,
    config: cfg.Config,
    files: *zlist.Files,
    dir: ?std.Io.Dir,
) !void {
    if (files.entries().len == 0) {
        return printNoFiles(io, stdout_file);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const term = try render.getTerminal(io, &stdout_writer.interface, stdout_file, color_use);

    if (opt.show_detail) {
        // long format
        switch (pure) {
            true => try render.listDetail(files.*, term, .{ .pure = true }, long_view_opt, config),
            false => try render.listDetail(files.*, term, .{ .pure = false }, long_view_opt, config),
        }
    } else if (opt.recursive) {
        // recursive
        if (dir) |opened_dir| {
            var root_dir: []const u8 = undefined;
            if (root_display == .name) {
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const len = try std.Io.Dir.cwd().realPathFile(io, opt.path, &buf);
                root_dir = std.fs.path.basename(buf[0..len]);
            }

            switch (pure) {
                true => try render.listRecursive(root_dir, files, term, "", true, opened_dir, .{ .pure = true }, root_display, config),
                false => try render.listRecursive(root_dir, files, term, "", true, opened_dir, .{ .pure = false }, root_display, config),
            }
        } else {
            switch (pure) {
                true => try render.list(files.*, term, stdout_file.handle, .{ .pure = true }, config),
                false => try render.list(files.*, term, stdout_file.handle, .{ .pure = false }, config),
            }
        }
    } else {
        // normal format
        switch (pure) {
            true => try render.list(files.*, term, stdout_file.handle, .{ .pure = true }, config),
            false => try render.list(files.*, term, stdout_file.handle, .{ .pure = false }, config),
        }
    }

    if (opt.report) {
        // print report
        try render.printReport(files.*, &stdout_writer.interface);
    }

    try stdout_writer.interface.flush();
}

fn printNoFiles(io: std.Io, stdout_file: std.Io.File) !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);

    try stdout_writer.interface.print(comptime "\n\x1b[93m No files to show.\x1b[0m\n", .{});
    try stdout_writer.interface.flush();
}

fn printInvalidChangedWithin() void {
    std.debug.print(
        "zl: invalid value for --changed-within\nexpected format: 30s, 15m, 12h, 7d, 2w\nsupported units: s, m, h, d, w\n",
        .{},
    );
}

fn printInvalidSize() void {
    std.debug.print(
        "zl: invalid value for --size\nexpected format: gt:10K, lte:2M, eq:512B\nsupported operators: gt, gte, lt, lte, eq\nsupported units: B, K, M, G, T\n",
        .{},
    );
}

fn printConflictingSizeRange() void {
    std.debug.print(
        "zl: conflicting --size filters\nminimum size cannot be greater than maximum size\n",
        .{},
    );
}

test {
    _ = @import("zlist");
    _ = @import("render.zig");
    _ = @import("cfg.zig");

    std.testing.refAllDecls(@This());
}
