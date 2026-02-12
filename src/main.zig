const std = @import("std");

const clap = @import("clap");
const fs = @import("files.zig");

var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

const params_desc: []const u8 = blk: {
    break :blk 
    \\-h, --help                Usage: ls [OPTIONS: -l -a -s=length ...] [Directory]
    \\-l, --long                List files in the long format.
    \\-a, --a                   Include directory entries whose names begin with a dot (‘.’).
    \\-s, --sort <SORTTYPE>     Sort results. Default: name(asc). OPTIONS: name(asc), length(name length asc)
    \\-r, --recursive           Recursively list subdirectories encountered.
    \\<str>...
    \\
    ;
};

pub fn main(init: std.process.Init.Minimal) !void {
    // get allocator
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const allocator = arena_impl.allocator();

    // parsers
    const parsers = comptime .{
        .str = clap.parsers.string,
        .SORTTYPE = clap.parsers.enumeration(fs.SortType),
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
    var recursive: bool = false;
    var sort_type: fs.SortType = .name;
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
    if (res.args.recursive != 0) {
        // set recursive mode
        recursive = true;
        // no necessity to show detail in recursive mode
        show_detail = false;
    }

    // get file path from args
    if (res.positionals[0].len > 0) {
        path = res.positionals[0][0];
    }

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var files = try fs.Files.init(allocator, io, dir, .{ .show_detail = show_detail, .show_hidden = show_hidden, .sort_type = sort_type, .recursive = recursive });
    defer files.deinit();

    if (files.items.items.len == 0) {
        // no files to show
        // stdout
        var stdout_buf: [1024]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(io, &stdout_buf);

        try stdout_writer.interface.print("\n\x1b[93m No files to show.\x1b[0m\n", .{});
        try stdout_writer.interface.flush();

        return;
    }

    if (show_detail) {
        // ls -l
        try files.listDetail();
    } else if (recursive) {
        // ls -r
        // stdout
        var stdout_buf: [1024]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(io, &stdout_buf);

        try files.listRecursive(&stdout_writer.interface, "", true, dir);
        try stdout_writer.interface.flush();
    } else {
        // just ls command
        try files.list();
    }
}

test {
    _ = @import("files.zig");

    std.testing.refAllDecls(@This());
}
