const std = @import("std");

/// Runtime config loaded from a `.zon` file.
pub const Config = struct {
    // icons, colors, etc.
};

/// Returns defaults when `path` is null; otherwise reads and parses the file.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Config {
    const file_path = path orelse return .{};

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    // Allow newer config keys without breaking older builds.
    return std.zon.parse.fromSlice(Config, allocator, source, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    });
}

test "load without path returns defaults" {
    const testing = std.testing;
    const config = try load(testing.allocator, testing.io, null);
    std.debug.print("load(null) => {any}\n", .{config});
    try testing.expectEqual(Config{}, config);
}

test "load with path reads zon file" {
    const testing = std.testing;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "zlist.zon",
        .data = ".{}",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "zlist.zon", &path_buf);
    const abs_path = path_buf[0..path_len];

    const config = try load(testing.allocator, io, abs_path);
    std.debug.print("load({s}) => {any}\n", .{ abs_path, config });
    try testing.expectEqual(Config{}, config);
}
