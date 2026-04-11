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

    if (res.args.du != 0) {
        opt.recursive_dir_size = true;
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
    opt.size_range = try parseSizeArgs(res.args.size);

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

const ParseSizeError = error{
    InvalidSize,
    ConflictingSizeRange,
};

const SizeOperator = enum {
    gt,
    gte,
    lt,
    lte,
    eq,
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

inline fn parseSizeArgs(values: []const []const u8) ParseSizeError!?opts.SizeRange {
    if (values.len == 0) {
        return null;
    }

    var size_range = opts.SizeRange{};
    for (values) |value| {
        try applySizeClause(&size_range, value);
    }

    try validateSizeRange(size_range);
    return size_range;
}

inline fn applySizeClause(size_range: *opts.SizeRange, value: []const u8) ParseSizeError!void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const colon_index = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidSize;
    const op_text = std.mem.trim(u8, trimmed[0..colon_index], " \t\r\n");
    const size_text = std.mem.trim(u8, trimmed[colon_index + 1 ..], " \t\r\n");

    if (op_text.len == 0 or size_text.len == 0) {
        return error.InvalidSize;
    }

    const op = std.meta.stringToEnum(SizeOperator, op_text) orelse return error.InvalidSize;
    const size_bytes = try parseSizeBytes(size_text);

    switch (op) {
        .gt => try applyMinBound(size_range, size_bytes, false),
        .gte => try applyMinBound(size_range, size_bytes, true),
        .lt => try applyMaxBound(size_range, size_bytes, false),
        .lte => try applyMaxBound(size_range, size_bytes, true),
        .eq => {
            try applyMinBound(size_range, size_bytes, true);
            try applyMaxBound(size_range, size_bytes, true);
        },
    }
}

inline fn applyMinBound(size_range: *opts.SizeRange, size_bytes: u64, inclusive: bool) ParseSizeError!void {
    if (size_range.min_bytes) |curr| {
        if (size_bytes > curr) {
            size_range.min_bytes = size_bytes;
            size_range.min_inclusive = inclusive;
            return;
        }

        if (size_bytes == curr) {
            size_range.min_inclusive = size_range.min_inclusive and inclusive;
        }

        return;
    }

    size_range.min_bytes = size_bytes;
    size_range.min_inclusive = inclusive;
}

inline fn applyMaxBound(size_range: *opts.SizeRange, size_bytes: u64, inclusive: bool) ParseSizeError!void {
    if (size_range.max_bytes) |curr| {
        if (size_bytes < curr) {
            size_range.max_bytes = size_bytes;
            size_range.max_inclusive = inclusive;
            return;
        }

        if (size_bytes == curr) {
            size_range.max_inclusive = size_range.max_inclusive and inclusive;
        }

        return;
    }

    size_range.max_bytes = size_bytes;
    size_range.max_inclusive = inclusive;
}

inline fn validateSizeRange(size_range: opts.SizeRange) ParseSizeError!void {
    const min_bytes = size_range.min_bytes orelse return;
    const max_bytes = size_range.max_bytes orelse return;

    if (min_bytes > max_bytes) {
        return error.ConflictingSizeRange;
    }

    if (min_bytes == max_bytes and (!size_range.min_inclusive or !size_range.max_inclusive)) {
        return error.ConflictingSizeRange;
    }
}

inline fn parseSizeBytes(value: []const u8) ParseSizeError!u64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2) {
        return error.InvalidSize;
    }

    const unit = std.ascii.toUpper(trimmed[trimmed.len - 1]);
    const number_text = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    if (number_text.len == 0) {
        return error.InvalidSize;
    }

    const amount = std.fmt.parseInt(u64, number_text, 10) catch return error.InvalidSize;
    const multiplier: u64 = switch (unit) {
        'B' => 1,
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        'T' => 1024 * 1024 * 1024 * 1024,
        else => return error.InvalidSize,
    };

    return std.math.mul(u64, amount, multiplier) catch return error.InvalidSize;
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
