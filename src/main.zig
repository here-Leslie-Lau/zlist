const std = @import("std");

const clap = @import("clap");
const fs = @import("files.zig");
const opts = @import("opts.zig");

var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

const params_desc: []const u8 = blk: {
    break :blk
    \\-h, --help                Usage: zl [OPTIONS: -l -a -s=length ...] [Directory]
    \\-l, --long                List files in the long format.
    \\-a, --a                   Include directory entries whose names begin with a dot (‘.’).
    \\-s, --sort <SORTTYPE>     Sort results. Default: name(asc). OPTIONS: name(asc), length(name length asc), dir_first(directories first)
    \\-r, --recursive           Recursively list subdirectories encountered. Equivalent to -L 0.
    \\-L, --level <INT>         Limit the depth of recursion. 0 means infinite.
    \\-p, --pure                Only show file names, without colors or other formatting.
    \\-R, --report              Shows brief report about number of files and folders shown.
    \\-d, --dir                 Only show directories, not files. When used in conjunction with -D, neither is effective.
    \\-D, --no_dir              Only show files, not directories. When used in conjunction with -d, neither is effective.
    \\<str>...
    \\
    ;
};

pub fn main(init: std.process.Init.Minimal) !void {
    // get allocator (c_allocator and arena allocator)
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_impl.deinit();
    const allocator = arena_impl.allocator();

    // parsers
    const parsers = comptime .{
        .str = clap.parsers.string,
        .SORTTYPE = clap.parsers.enumeration(opts.SortType),
        .INT = clap.parsers.int(i8, 10),
    };

    // parse command line arguments
    const params = comptime clap.parseParamsComptime(params_desc);
    var res = try clap.parse(
        clap.Help,
        &params,
        parsers,
        init.args,
        .{
            .allocator = allocator,
        },
    );

    var show_hidden: bool = false;
    var show_detail: bool = false;
    var pure: bool = false;
    var report: bool = false;
    var sort_type: opts.SortType = .name;
    var only_dir: bool = false;
    var only_file: bool = false;
    var recursive: bool = false;
    var recursion_level: i8 = 0; // 0 means infinite

    var path: []const u8 = ".";

    // process parsed args
    if (res.args.help != 0) {
        // show hellp msg
        std.debug.print("{s}\n", .{params_desc});
        return;
    }
    if (res.args.long != 0) {
        // set long listing mode
        show_detail = true;
    }
    if (res.args.a != 0) {
        // show hidden files
        show_hidden = true;
    }
    // set sort type
    if (res.args.sort) |sort| {
        sort_type = sort;
    }
    // set pure mode
    if (res.args.pure != 0) {
        pure = true;
    }
    if (res.args.report != 0) {
        report = true;
    }
    // only show directories or files
    if (res.args.dir != 0) {
        only_dir = true;
    }
    if (res.args.no_dir != 0) {
        only_file = true;
    }
    if (only_dir and only_file) {
        // if both -d and -D are set, neither is effective
        only_dir = false;
        only_file = false;
    }
    if (res.args.recursive != 0) {
        // set recursive mode
        recursive = true;
        // no necessity to show detail in recursive mode
        show_detail = false;
    }
    if (res.args.level) |level| {
        // set recursive mode and recursion level
        recursive = true;
        recursion_level = level;
    }

    // get file path from args
    if (res.positionals[0].len > 0) {
        path = res.positionals[0][0];
    }

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var files = try fs.Files.init(
        allocator,
        io,
        dir,
        .{ .show_detail = show_detail, .show_hidden = show_hidden, .sort_type = sort_type, .recursive = recursive, .pure = pure, .only_dir = only_dir, .only_file = only_file, .recursion_level = recursion_level, .report = report },
    );
    defer files.deinit();

    if (files.items.items.len == 0) {
        // no files to show
        // stdout
        var stdout_buf: [256]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(io, &stdout_buf);

        try stdout_writer.interface.print(comptime "\n\x1b[93m No files to show.\x1b[0m\n", .{});
        try stdout_writer.interface.flush();

        return;
    }

    // stdout
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    // get term
    const term = try files.getTerminal(&stdout_writer.interface, stdout_file);

    if (show_detail) {
        // zl -l
        switch (pure) {
            // pure mode
            true => try files.listDetail(term, .{ .pure = true }),
            false => try files.listDetail(term, .{ .pure = false }),
        }
    } else if (recursive) {
        // zl -r
        switch (pure) {
            // pure mode
            true => try files.listRecursive(term, "", true, dir, .{ .pure = true }),
            false => try files.listRecursive(term, "", true, dir, .{ .pure = false }),
        }
    } else {
        // just ls command
        switch (pure) {
            // pure mode
            true => try files.list(term, stdout_file.handle, .{ .pure = true }),
            false => try files.list(term, stdout_file.handle, .{ .pure = false }),
        }
    }

    if (report) {
        try files.printReport(&stdout_writer.interface);
    }

    try stdout_writer.interface.flush();
}

test {
    _ = @import("files.zig");

    std.testing.refAllDecls(@This());
}
