const std = @import("std");
const process = std.process;

/// Checks if the given path is a Git repository by running `git rev-parse --is-inside-work-tree`.
pub fn isGitRepo(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
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
