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
    if (x == 'U' or y == 'U' or x == 'A' and y == 'A' or x == 'D' and y == 'D') {
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

        const status = parseStatusCode(x, y);
        if (status != .none) {
            const name_cp = try allocator.dupe(u8, filename);
            try m.put(name_cp, status);
        }
    }

    return m;
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
