const std = @import("std");
const fs = @import("files.zig");

var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

pub fn main() !void {
    const allocator = std.heap.page_allocator;

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
