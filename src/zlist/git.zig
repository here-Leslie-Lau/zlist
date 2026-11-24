const std = @import("std");
const process = std.process;

/// Checks if the given path is a Git repository by running `git rev-parse --is-inside-work-tree`.
pub inline fn isGitRepo(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const argv = [_][]const u8{
        "git",
        "-C",
        path,
        "rev-parse",
        "--is-inside-work-tree",
    };

    const result = process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .inherit,
    }) catch return false;

    // free the process resources (stdout and stderr)
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return std.mem.startsWith(u8, result.stdout, "true");
}

test "isGitRepo" {
    const testing = std.testing;

    const ok = isGitRepo(testing.allocator, testing.io, ".");

    try testing.expect(ok);
}

/// Represents the status of a file in a Git repository.
pub const GitStatus = enum {
    none,
    modified,
    added,
    deleted,
    renamed,
    untracked,
    unmerged,
};

inline fn parseStatusCode(x: u8, y: u8) GitStatus {
    // Priority: unmerged > deleted > renamed > modified > added > untracked
    if (x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D')) {
        return .unmerged;
    }

    if (x == 'D' or y == 'D') return .deleted;
    if (x == 'R' or y == 'R') return .renamed;
    if (x == 'M' or y == 'M') return .modified;
    if (x == 'A' or y == 'A') return .added;
    if (x == '?' and y == '?') return .untracked;
    return .none;
}

pub inline fn getFileStatuses(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.StringHashMap(GitStatus) {
    var m = std.StringHashMap(GitStatus).init(allocator);
    errdefer deinitFileStatuses(allocator, &m);

    const argv = [_][]const u8{
        "git",
        "-C",
        path,
        "status",
        "--porcelain=v1",
    };

    const result = process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .inherit,
    }) catch return m;
    // free the process resources (stdout and stderr)
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 3) {
            continue;
        }

        const x = line[0];
        const y = line[1];
        const filename = std.mem.trim(u8, line[3..], " \t");
        const basename = std.fs.path.basename(filename);

        const status = parseStatusCode(x, y);
        if (status != .none) {
            if (m.getPtr(basename)) |existing| {
                // Avoid allocating a duplicate key when two changed files share the same basename.
                existing.* = status;
                continue;
            }

            const name_cp = try allocator.dupe(u8, basename);
            errdefer allocator.free(name_cp);
            try m.put(name_cp, status);
        }
    }

    return m;
}

/// Free duplicated git status keys and destroy the map.
fn deinitFileStatuses(allocator: std.mem.Allocator, m: *std.StringHashMap(GitStatus)) void {
    var keys = m.keyIterator();
    while (keys.next()) |key| {
        allocator.free(key.*);
    }
    m.deinit();
}

/// Cap each stdin batch below OS pipe capacity
const max_check_ignore_bytes = 8 * 1024;

/// Names matched by `git check-ignore`, backed by a single buffer of stdout bytes.
pub const IgnoredNames = struct {
    buf: []u8 = &.{},
    set: std.StringHashMapUnmanaged(void) = .{},

    pub fn isEmpty(self: IgnoredNames) bool {
        return self.set.count() == 0;
    }

    pub fn contains(self: IgnoredNames, name: []const u8) bool {
        return self.set.contains(name);
    }

    pub fn deinit(self: *IgnoredNames, allocator: std.mem.Allocator) void {
        self.set.deinit(allocator);
        if (self.buf.len > 0) allocator.free(self.buf);
        self.* = .{};
    }
};

const CheckIgnoreResult = enum {
    matched,
    none,
    unavailable,
};

/// Return the subset of `names` ignored by git inside `dir`.
/// Silently returns an empty set if `git` is unavailable or `dir` is not in a repo.
pub fn ignoredNames(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    names: []const []const u8,
) !IgnoredNames {
    if (names.len == 0) return .{};

    var raw_out: std.ArrayList(u8) = .empty;
    defer raw_out.deinit(allocator);

    var start: usize = 0;
    while (start < names.len) {
        const chunk = nextChunk(names, start);
        start += chunk.len;

        const prev_len = raw_out.items.len;
        switch (try runCheckIgnoreChunk(allocator, io, dir, chunk, &raw_out)) {
            .matched => {},
            .none => raw_out.items.len = prev_len,
            .unavailable => return .{},
        }
    }

    if (raw_out.items.len == 0) return .{};

    const buf = try raw_out.toOwnedSlice(allocator);
    errdefer allocator.free(buf);

    var set: std.StringHashMapUnmanaged(void) = .{};
    errdefer set.deinit(allocator);

    var it = std.mem.splitScalar(u8, buf, 0);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try set.put(allocator, name, {});
    }

    return .{
        .buf = buf,
        .set = set,
    };
}

fn nextChunk(names: []const []const u8, start: usize) []const []const u8 {
    var end = start;
    var bytes: usize = 0;
    while (end < names.len) : (end += 1) {
        const entry_bytes = names[end].len + 1;
        if (end > start and bytes + entry_bytes > max_check_ignore_bytes) break;
        bytes += entry_bytes;
    }
    return names[start..end];
}

fn runCheckIgnoreChunk(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    chunk: []const []const u8,
    raw_out: *std.ArrayList(u8),
) !CheckIgnoreResult {
    const argv = [_][]const u8{
        "git",
        "check-ignore",
        "--stdin",
        "-z",
    };

    var child = process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .dir = dir },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return .unavailable;
    defer child.kill(io);

    // Feed candidate names NUL-separated, then close stdin so git flushes and exits.
    var write_buf: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writerStreaming(io, &write_buf);
    var write_ok = true;
    for (chunk) |name| {
        stdin_writer.interface.writeAll(name) catch {
            write_ok = false;
            break;
        };
        stdin_writer.interface.writeByte(0) catch {
            write_ok = false;
            break;
        };
    }
    if (write_ok) {
        stdin_writer.interface.flush() catch {
            write_ok = false;
        };
    }
    child.stdin.?.close(io);
    child.stdin = null;

    if (write_ok) {
        var read_buf: [4096]u8 = undefined;
        var stdout_reader = child.stdout.?.readerStreaming(io, &read_buf);
        stdout_reader.interface.appendRemainingUnlimited(allocator, raw_out) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return .unavailable,
        };
    }

    const term = child.wait(io) catch return .unavailable;
    return switch (term) {
        .exited => |code| switch (code) {
            0 => if (write_ok) .matched else .unavailable,
            1 => .none,
            else => .unavailable,
        },
        else => .unavailable,
    };
}

fn runGitInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !void {
    const res = try process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try std.testing.expectEqual(process.Child.Term.success, res.term);
}

test "getFileStatuses" {
    const testing = std.testing;

    const allocator = testing.allocator;
    var m = try getFileStatuses(allocator, testing.io, ".");

    // Just check that we can get the status of this file (which should be untracked or modified)
    const status = m.get("src/git.zig") orelse .none;
    std.debug.print("Status of src/git.zig: {}\n", .{status});

    var it = m.keyIterator();
    while (it.next()) |filename| {
        // f**k, forgot it...
        allocator.free(filename.*);
    }
    m.deinit();
}
