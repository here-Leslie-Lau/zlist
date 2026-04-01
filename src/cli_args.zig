const std = @import("std");

const opts = @import("opts.zig");

pub const CliConfig = struct {
    opt: opts.FilesOptions,
    path: []const u8,
};

pub inline fn parseCliConfig(allocator: std.mem.Allocator, res: anytype) !CliConfig {
    var opt = opts.FilesOptions{ .recursion_level = 0 };
    var path: []const u8 = ".";

    if (res.args.long != 0) {
        opt.show_detail = true;
        if (res.args.git != 0) {
            opt.show_git = true;
        }
    }

    if (res.args.a != 0) {
        opt.show_hidden = true;
    }

    if (res.args.sort) |sort| {
        opt.sort_type = sort;
    }

    if (res.args.pure != 0) {
        opt.pure = true;
    }

    if (res.args.report != 0) {
        opt.report = true;
    }

    if (res.args.dir != 0) {
        opt.only_dir = true;
    }

    if (res.args.no_dir != 0) {
        opt.only_file = true;
    }

    if (opt.only_dir and opt.only_file) {
        opt.only_dir = false;
        opt.only_file = false;
    }

    if (res.args.recursive != 0) {
        opt.recursive = true;
        opt.show_detail = false;
        opt.show_git = false;
    }

    if (res.args.level) |level| {
        opt.recursive = true;
        opt.recursion_level = level;
        opt.show_detail = false;
        opt.show_git = false;
    }

    opt.exts = try parseCsvArgs(allocator, res.args.ext);
    opt.matches = try parseCsvArgs(allocator, res.args.match);

    if (res.args.@"changed-within") |value| {
        opt.changed_within = try parseChangedWithin(value);
    }

    if (res.positionals[0].len > 0) {
        path = res.positionals[0][0];
    }
    opt.path = path;

    return .{
        .opt = opt,
        .path = path,
    };
}

const ParseChangedWithinError = error{
    InvalidChangedWithin,
};

inline fn parseChangedWithin(value: []const u8) ParseChangedWithinError!std.Io.Duration {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2) {
        return error.InvalidChangedWithin;
    }

    const unit = trimmed[trimmed.len - 1];
    const number_text = trimmed[0 .. trimmed.len - 1];
    const amount = std.fmt.parseInt(i64, number_text, 10) catch {
        return error.InvalidChangedWithin;
    };

    if (amount < 0) {
        return error.InvalidChangedWithin;
    }

    return switch (unit) {
        's' => std.Io.Duration.fromSeconds(amount),
        'm' => std.Io.Duration.fromSeconds(std.math.mul(i64, amount, 60) catch return error.InvalidChangedWithin),
        'h' => std.Io.Duration.fromSeconds(std.math.mul(i64, amount, 60 * 60) catch return error.InvalidChangedWithin),
        'd' => std.Io.Duration.fromSeconds(std.math.mul(i64, amount, 24 * 60 * 60) catch return error.InvalidChangedWithin),
        'w' => std.Io.Duration.fromSeconds(std.math.mul(i64, amount, 7 * 24 * 60 * 60) catch return error.InvalidChangedWithin),
        else => error.InvalidChangedWithin,
    };
}

inline fn parseCsvArgs(allocator: std.mem.Allocator, values: []const []const u8) !?[]const []const u8 {
    if (values.len == 0) {
        return null;
    }

    var items = try std.ArrayList([]const u8).initCapacity(allocator, values.len);
    errdefer items.deinit(allocator);

    for (values) |value| {
        var token_it = std.mem.splitScalar(u8, value, ',');
        while (token_it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t\r\n");
            if (trimmed.len == 0) continue;
            try items.append(allocator, trimmed);
        }
    }

    if (items.items.len == 0) {
        items.deinit(allocator);
        return null;
    }

    return items.items;
}
