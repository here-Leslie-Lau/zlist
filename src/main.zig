const std = @import("std");

const clap = @import("clap");
const cli_args = @import("cli_args.zig");
const fs = @import("files.zig");
const opts = @import("opts.zig");

var threaded: std.Io.Threaded = undefined;

const params_desc: []const u8 = blk: {
    break :blk
    \\-h, --help                 Usage: zl [OPTIONS: -l -a -s=length ...] [Directory]
    \\-l, --long                 List files in the long format.
    \\-a, --a                    Include directory entries whose names begin with a dot (‘.’).
    \\-s, --sort <SORTTYPE>      Sort results. Default: name(asc). OPTIONS: name(asc), length(name length asc), dir_first(directories first), mtime(modification time desc), size(file size desc).
    \\    --changed-within <str> Only show entries modified within a time range (e.g. --changed-within 7d).
    \\-r, --recursive            Recursively list subdirectories encountered. Equivalent to -L 0.
    \\-L, --level <INT>          Limit the depth of recursion. 0 means infinite.
    \\-p, --pure                 Only show file names, without colors or other formatting.
    \\-R, --report               Shows brief report about number of files and folders shown.
    \\-d, --dir                  Only show directories, not files. When used in conjunction with -D, neither is effective.
    \\-D, --no_dir               Only show files, not directories. When used in conjunction with -d, neither is effective.
    \\-g, --git                  Show git status of files. Only effective when in long format.
    \\-e, --ext <str>...         Filter by extension (e.g. --ext zig,md,ts).
    \\-m, --match <str>...       Match file names/subtring (e.g. --match main,readme).
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
        .SORTTYPE = clap.parsers.enumeration(opts.SortType),
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
    const cli = try cli_args.parseCliConfig(allocator, res);

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(io, cli.path, .{ .iterate = true });
    defer dir.close(io);

    var files = try fs.Files.init(
        allocator,
        io,
        dir,
        cli.opt,
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

    if (cli.opt.show_detail) {
        // zl -l
        switch (cli.opt.pure) {
            // pure mode
            true => try files.listDetail(term, .{ .pure = true }),
            false => try files.listDetail(term, .{ .pure = false }),
        }
    } else if (cli.opt.recursive) {
        // zl -r
        switch (cli.opt.pure) {
            // pure mode
            true => try files.listRecursive(term, "", true, dir, .{ .pure = true }),
            false => try files.listRecursive(term, "", true, dir, .{ .pure = false }),
        }
    } else {
        // just ls command
        switch (cli.opt.pure) {
            // pure mode
            true => try files.list(term, stdout_file.handle, .{ .pure = true }),
            false => try files.list(term, stdout_file.handle, .{ .pure = false }),
        }
    }

    if (cli.opt.report) {
        try files.printReport(&stdout_writer.interface);
    }

    try stdout_writer.interface.flush();
}

test {
    _ = @import("files.zig");

    std.testing.refAllDecls(@This());
}
