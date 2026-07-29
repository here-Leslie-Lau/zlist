const std = @import("std");
const mem = std.mem;

const testing = std.testing;

// Slab size. Names longer than this error out.
const chunk_size: usize = 16 * 1024;

/// Packs filename bytes into a few slabs instead of alloc-per-name.
/// Slices from `store` live until `deinit`; don't free them yourself.
pub const NamePool = struct {
    const Self = @This();

    allocator: mem.Allocator,

    chunks: std.ArrayList([]u8),
    last_chunk_used: usize = 0,

    pub fn init(allocator: mem.Allocator) !Self {
        var chunks = try std.ArrayList([]u8).initCapacity(allocator, 1);
        errdefer chunks.deinit(allocator);

        const first = try allocator.alloc(u8, chunk_size);
        errdefer allocator.free(first);

        try chunks.append(allocator, first);

        return Self{
            .allocator = allocator,
            .chunks = chunks,
        };
    }

    /// Copies `name` into the pool. Caller must not free the returned slice.
    pub fn store(self: *Self, name: []const u8) ![]const u8 {
        if (name.len == 0) return "";
        if (name.len > chunk_size) return error.NameTooLong;

        if (self.last_chunk_used + name.len > chunk_size) {
            try self.appendChunk();
        }

        const last_chunk = self.chunks.items[self.chunks.items.len - 1];
        const start = self.last_chunk_used;
        const end = start + name.len;

        @memcpy(last_chunk[start..end], name);
        self.last_chunk_used += name.len;

        return last_chunk[start..end];
    }

    fn appendChunk(self: *Self) !void {
        const new = try self.allocator.alloc(u8, chunk_size);
        errdefer self.allocator.free(new);

        try self.chunks.append(self.allocator, new);
        self.last_chunk_used = 0;
    }

    /// Frees all slabs. Everything `store` ever returned is invalid after this.
    pub fn deinit(self: *Self) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.deinit(self.allocator);
    }
};

test "store basic names" {
    var pool = try NamePool.init(testing.allocator);
    defer pool.deinit();

    const a = try pool.store("main.zig");
    const b = try pool.store("render.zig");

    try testing.expectEqualStrings("main.zig", a);
    try testing.expectEqualStrings("render.zig", b);
}

test "empty name" {
    var pool = try NamePool.init(testing.allocator);
    defer pool.deinit();

    try testing.expectEqualStrings("", try pool.store(""));
}

test "earlier slices stay valid after a new chunk" {
    var pool = try NamePool.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.store("first-name");

    // ~32KiB of payload forces at least one extra slab.
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var buf: [16]u8 = undefined;
        @memset(&buf, 'a');
        _ = try pool.store(&buf);
    }

    try testing.expect(pool.chunks.items.len > 1);
    try testing.expectEqualStrings("first-name", first);
}

test "name longer than chunk" {
    var pool = try NamePool.init(testing.allocator);
    defer pool.deinit();

    const big = try testing.allocator.alloc(u8, chunk_size + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    try testing.expectError(error.NameTooLong, pool.store(big));
}
