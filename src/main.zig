const std = @import("std");

const clap = @import("clap");
const cli_args = @import("cli_args.zig");
const render = @import("render.zig");
const zlist = @import("zlist");

var threaded: std.Io.Threaded = undefined;

const params_desc: []const u8 = blk: {
    break :blk
    \\-h, --help                 Usage: zl [OPTIONS] [PATH]...
    \\-l, --long                 Show the long view.
    \\-a, --a                    Include hidden entries.
    \\    --du                   Show recursive directory size in long view and size sort. This is the sum of file sizes, not the same as `du` disk usage.
    \\-s, --sort <SORTTYPE>      Sort results. Default: name. OPTIONS: name, length, dir_first, mtime, size.
    \\    --size <str>...        Filter files by size range (e.g. --size gt:10K --size lte:2M).
    \\    --changed-within <str> Only show entries changed within a time range (e.g. --changed-within 7d).
    \\-r, --recursive            Recurse into subdirectories. Same as -L 0.
    \\-L, --level <INT>          Limit recursion depth. 0 means no limit.
    \\-p, --pure                 Show names only, without colors or icons.
    \\-R, --report               Show a short summary of files and folders.
    \\-d, --dir                  Only show directories. If used with -D, both are ignored.
    \\-D, --no_dir               Only show files. If used with -d, both are ignored.
    \\-g, --git                  Show git status in long view.
    \\-e, --ext <str>...         Filter by extension (e.g. --ext zig,md,ts).
    \\-m, --match <str>...       Filter names by substring (e.g. --match main,readme).
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
        .SORTTYPE = clap.parsers.enumeration(zlist.SortType),
        .INT = clap.parsers.int(i8, 10),
    };

    // parse command line arguments
    const params = comptime clap.parseParamsComptime(params_desc);
    const res = try clap.parse(
        clap.Help,
        &params,
        parsers,
        init.args,
        .{
            .allocator = allocator,
        },
    );

    if (res.args.help != 0) {
        // show hellp msg
        std.debug.print("{s}\n", .{params_desc});
        return;
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

    for (cli.paths, 0..) |path, index| {
        var opt = cli.opt;
        opt.path = path;

        runForPath(allocator, io, opt, path, cli.paths.len > 1, index) catch |err| switch (err) {
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
    path: []const u8,
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
        error.NotDir => return runForSingleFile(allocator, io, stdout_file, opt, path),
        error.FileNotFound => {
            std.debug.print("zl: path not found: {s}\n", .{path});
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    return runForDirectory(allocator, io, stdout_file, opt, dir);
}

inline fn runForDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    opt: zlist.FilesOptions,
    dir: std.Io.Dir,
) !void {
    var files = try zlist.Files.init(allocator, io, dir, opt);
    defer files.deinit();

    try printFiles(io, stdout_file, opt, &files, dir);
}

inline fn runForSingleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    opt: zlist.FilesOptions,
    path: []const u8,
) !void {
    var files = try zlist.Files.initSingle(allocator, io, path, opt);
    defer files.deinit();

    try printFiles(io, stdout_file, opt, &files, null);
}

fn printFiles(
    io: std.Io,
    stdout_file: std.Io.File,
    opt: zlist.FilesOptions,
    files: *zlist.Files,
    dir: ?std.Io.Dir,
) !void {
    if (files.entries().len == 0) {
        return printNoFiles(io, stdout_file);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const term = try render.getTerminal(io, &stdout_writer.interface, stdout_file);

    if (opt.show_detail) {
        // long format
        switch (opt.pure) {
            true => try render.listDetail(files.*, term, .{ .pure = true }),
            false => try render.listDetail(files.*, term, .{ .pure = false }),
        }
    } else if (opt.recursive) {
        // recursive
        if (dir) |opened_dir| {
            switch (opt.pure) {
                true => try render.listRecursive(files, term, "", true, opened_dir, .{ .pure = true }),
                false => try render.listRecursive(files, term, "", true, opened_dir, .{ .pure = false }),
            }
        } else {
            switch (opt.pure) {
                true => try render.list(files.*, term, stdout_file.handle, .{ .pure = true }),
                false => try render.list(files.*, term, stdout_file.handle, .{ .pure = false }),
            }
        }
    } else {
        // normal format
        switch (opt.pure) {
            true => try render.list(files.*, term, stdout_file.handle, .{ .pure = true }),
            false => try render.list(files.*, term, stdout_file.handle, .{ .pure = false }),
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

    std.testing.refAllDecls(@This());
}
