const std = @import("std");

const Color = std.Io.Terminal.Color;

pub const ExtIcon = struct {
    ext: []const u8,
    icon: []const u8,
};

pub const ExtColor = struct {
    ext: []const u8,
    color: Color,
};

/// Runtime config loaded from a `.zon` file.
/// Defaults match the built-in render appearance.
pub const Config = struct {
    dir_icon: []const u8 = " ",
    file_icon: []const u8 = " ",
    icon_by_ext: []const ExtIcon = &.{},

    dir_color: Color = .bright_blue,
    file_color: Color = .bright_yellow,
    color_by_ext: []const ExtColor = &.{},
};

/// ZON wire format. Every field is optional so partial files keep defaults.
const File = struct {
    icons: ?Icons = null,
    colors: ?Colors = null,

    const Icons = struct {
        dir: ?[]const u8 = null,
        file: ?[]const u8 = null,
        by_ext: ?[]const ExtIcon = null,
    };

    const Colors = struct {
        dir: ?[]const u8 = null,
        file: ?[]const u8 = null,
        by_ext: ?[]const RawExtColor = null,
    };

    const RawExtColor = struct {
        ext: []const u8,
        color: []const u8,
    };
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

    const file = try std.zon.parse.fromSliceAlloc(File, allocator, source, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    });
    return try configFromFile(allocator, file);
}

fn configFromFile(allocator: std.mem.Allocator, file: File) !Config {
    var config: Config = .{};

    if (file.icons) |icons| {
        if (icons.dir) |dir| config.dir_icon = dir;
        if (icons.file) |file_icon| config.file_icon = file_icon;
        if (icons.by_ext) |by_ext| config.icon_by_ext = by_ext;
    }

    if (file.colors) |colors| {
        if (colors.dir) |name| config.dir_color = try parseColor(name);
        if (colors.file) |name| config.file_color = try parseColor(name);
        if (colors.by_ext) |entries| {
            const by_ext = try allocator.alloc(ExtColor, entries.len);
            for (entries, 0..) |entry, i| {
                by_ext[i] = .{
                    .ext = entry.ext,
                    .color = try parseColor(entry.color),
                };
            }
            config.color_by_ext = by_ext;
        }
    }

    return config;
}

fn parseColor(name: []const u8) !Color {
    return std.meta.stringToEnum(Color, name) orelse error.InvalidColor;
}

test "load without path returns defaults" {
    const testing = std.testing;
    const config = try load(testing.allocator, testing.io, null);
    std.debug.print("load(null) => {any}\n", .{config});
    try expectDefaultConfig(config);
}

test "load empty zon keeps defaults" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const config = try loadFromData(arena.allocator(), testing.io, ".{}");
    std.debug.print("load(.{{}}) => {any}\n", .{config});
    try expectDefaultConfig(config);
}

test "load applies partial overrides" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const zon =
        \\.{
        \\    .icons = .{
        \\        .dir = "D ",
        \\        .by_ext = .{
        \\            .{ .ext = ".zig", .icon = "Z " },
        \\        },
        \\    },
        \\    .colors = .{
        \\        .file = "bright_green",
        \\        .by_ext = .{
        \\            .{ .ext = ".md", .color = "bright_magenta" },
        \\        },
        \\    },
        \\}
    ;

    const config = try loadFromData(arena.allocator(), testing.io, zon);
    std.debug.print("load(partial) => {any}\n", .{config});

    try testing.expectEqualStrings("D ", config.dir_icon);
    try testing.expectEqualStrings(" ", config.file_icon);
    try testing.expectEqual(@as(usize, 1), config.icon_by_ext.len);
    try testing.expectEqualStrings(".zig", config.icon_by_ext[0].ext);
    try testing.expectEqualStrings("Z ", config.icon_by_ext[0].icon);

    try testing.expectEqual(Color.bright_blue, config.dir_color);
    try testing.expectEqual(Color.bright_green, config.file_color);
    try testing.expectEqual(@as(usize, 1), config.color_by_ext.len);
    try testing.expectEqualStrings(".md", config.color_by_ext[0].ext);
    try testing.expectEqual(Color.bright_magenta, config.color_by_ext[0].color);
}

test "load rejects unknown color names" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const zon =
        \\.{
        \\    .colors = .{
        \\        .dir = "not_a_color",
        \\    },
        \\}
    ;

    try testing.expectError(error.InvalidColor, loadFromData(arena.allocator(), testing.io, zon));
}

fn expectDefaultConfig(config: Config) !void {
    const testing = std.testing;
    try testing.expectEqualStrings(" ", config.dir_icon);
    try testing.expectEqualStrings(" ", config.file_icon);
    try testing.expectEqual(@as(usize, 0), config.icon_by_ext.len);
    try testing.expectEqual(Color.bright_blue, config.dir_color);
    try testing.expectEqual(Color.bright_yellow, config.file_color);
    try testing.expectEqual(@as(usize, 0), config.color_by_ext.len);
}

fn loadFromData(allocator: std.mem.Allocator, io: std.Io, data: []const u8) !Config {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "zlist.zon",
        .data = data,
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "zlist.zon", &path_buf);
    return load(allocator, io, path_buf[0..path_len]);
}
