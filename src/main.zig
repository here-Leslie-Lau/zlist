const std = @import("std");

const clap = @import("clap");
const fs = @import("files.zig");

var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

const params_desc: []const u8 = blk: {
    break :blk 
    \\-h, --help    Display this help and exit.
    \\-l, --l       List files in the long format.
    \\
    ;
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    // parse command line arguments
    const params = comptime clap.parseParamsComptime(params_desc);
    var res = try clap.parse(
        clap.Help,
        &params,
        clap.parsers.default,
        init.minimal.args,
        .{
            .allocator = allocator,
        },
    );

    if (res.args.help != 0) {
        // show hellp msg
        std.debug.print("{s}\n", .{params_desc});
        return;
    }
    // TODO leslie: get command line options

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(io, ".", .{ .iterate = true });

    var files = try fs.Files.init(allocator, io, dir, .{});
    defer files.deinit();

    try files.list();
}

test {
    _ = @import("files.zig");

    std.testing.refAllDecls(@This());
}
