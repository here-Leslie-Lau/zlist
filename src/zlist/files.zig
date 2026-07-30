const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const file = @import("file.zig");
const git = @import("git.zig");
const opts = @import("opts.zig");

pub const Files = struct {
    const Self = @This();

    max_display_len: usize = 0,
    curr_recursion_level: i8 = 1,
    allocator: mem.Allocator,
    io: std.Io,
    items: std.ArrayList(file.File),
    opt: opts.FilesOptions,
    total_folders: usize = 0,
    total_files: usize = 0,

    /// for caching username and groupname, key is uid/gid, value is username/groupname.
    /// since getting username from uid is a costly operation, we can cache it to improve performance.
    username_inventory: std.AutoHashMap(std.c.uid_t, []const u8),
    groupname_inventory: std.AutoHashMap(std.c.gid_t, []const u8),

    loaded_git: bool = false,
    /// for caching git status, key is filename, value is git status.
    git_inventory: std.StringHashMap(git.GitStatus),

    /// init a Files from a directory
    pub fn init(
        allocator: mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        opt: opts.FilesOptions,
    ) !Self {
        var files = try std.ArrayList(file.File).initCapacity(allocator, 32);
        errdefer {
            deinitItems(allocator, files.items);
            files.deinit(allocator);
        }

        var max_len: usize = 0;
        var total_folders: usize = 0;
        var total_files: usize = 0;

        // determine if we need to calculate recursive directory size. it is needed when recursive_dir_size is enabled, and either show_detail is true or sort by size.
        const needs_recursive_dir_size = opt.recursive_dir_size and (opt.show_detail or opt.sort_type == .size);

        // we need to load stat
        // if show_detail is true, sort by mtime/size, or changed-within is enabled.
        // otherwise we can skip loading stat to improve performance.
        const load_stat = shouldLoadStat(opt, needs_recursive_dir_size);
        const changed_within_now = if (opt.changed_within != null)
            std.Io.Timestamp.now(io, .real)
        else
            null;

        var username_inventory = std.AutoHashMap(std.c.uid_t, []const u8).init(allocator);
        errdefer deinitCachedNames(std.c.uid_t, allocator, &username_inventory);

        var groupname_inventory = std.AutoHashMap(std.c.gid_t, []const u8).init(allocator);
        errdefer deinitCachedNames(std.c.gid_t, allocator, &groupname_inventory);

        var loaded_git = false;
        var git_inventory = std.StringHashMap(git.GitStatus).init(allocator);
        errdefer deinitGitInventory(allocator, &git_inventory);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            var fs = (try file.File.init(
                allocator,
                io,
                &entry,
                &dir,
                .{
                    .load_stat = load_stat,
                    .load_symlink_target = opt.show_detail,
                    .load_owner = opt.show_detail,
                    .show_hidden = opt.show_hidden,
                    .only_dir = opt.only_dir,
                    .only_file = opt.only_file,
                    .keep_dirs_for_match = opt.recursive,
                    .keep_dirs_for_changed_within = opt.recursive,
                    .keep_dirs_for_size = opt.recursive,
                    .exts = opt.exts,
                    .matches = opt.matches,
                    .changed_within = opt.changed_within,
                    .size_range = opt.size_range,
                    .changed_within_now = changed_within_now,
                },
                &username_inventory,
                &groupname_inventory,
            )) orelse continue;
            errdefer if (fs.symlink_target) |target| allocator.free(target);

            // copy name
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            fs.name = name;

            if (!opt.show_detail and !opt.recursive) {
                // get display length of the name, including icon(len is 2), just in normal mode
                const curr_len = fs.name.len + 2;
                if (curr_len > max_len) {
                    max_len = curr_len;
                }
            }

            if (opt.report) {
                if (fs.is_dir) {
                    total_folders += 1;
                } else {
                    total_files += 1;
                }
            }

            try files.append(allocator, fs);
        }

        if (needs_recursive_dir_size) {
            for (files.items) |*item| {
                if (!item.is_dir) continue;

                const sub_dir = dir.openDir(io, item.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close(io);

                const recursive_size = calculateDirectorySize(io, sub_dir) catch continue;
                item.setRecursiveSize(recursive_size);
            }
        }

        // git integration is enabled, and current directory is a git repository
        if (opt.show_git and git.isGitRepo(allocator, io, opt.path)) {
            // load git status inventory
            git_inventory = try git.getFileStatuses(allocator, io, opt.path);
            loaded_git = true;
        }

        sort(files.items, opt.dir_grouping, opt.sort_type, opt.reverse);

        return .{
            .max_display_len = max_len,
            .total_folders = total_folders,
            .total_files = total_files,
            .allocator = allocator,
            .io = io,
            .items = files,
            .opt = opt,
            .username_inventory = username_inventory,
            .groupname_inventory = groupname_inventory,
            .loaded_git = loaded_git,
            .git_inventory = git_inventory,
        };
    }

    pub fn initSingle(
        allocator: mem.Allocator,
        io: std.Io,
        path: []const u8,
        opt: opts.FilesOptions,
    ) !Self {
        const parent_path = std.fs.path.dirname(path) orelse ".";
        const base_name = std.fs.path.basename(path);

        const cwd = std.Io.Dir.cwd();
        const parent_dir = try cwd.openDir(io, parent_path, .{});
        defer parent_dir.close(io);

        const stat = try parent_dir.statFile(io, base_name, .{});
        const entry: std.Io.Dir.Entry = .{
            .name = base_name,
            .kind = stat.kind,
            .inode = 0,
        };

        var files = try std.ArrayList(file.File).initCapacity(allocator, 1);
        errdefer {
            deinitItems(allocator, files.items);
            files.deinit(allocator);
        }

        var max_len: usize = 0;
        var total_folders: usize = 0;
        var total_files: usize = 0;

        const needs_recursive_dir_size = opt.recursive_dir_size and (opt.show_detail or opt.sort_type == .size);
        const load_stat = shouldLoadStat(opt, needs_recursive_dir_size);
        const changed_within_now = if (opt.changed_within != null)
            std.Io.Timestamp.now(io, .real)
        else
            null;

        var username_inventory = std.AutoHashMap(std.c.uid_t, []const u8).init(allocator);
        errdefer deinitCachedNames(std.c.uid_t, allocator, &username_inventory);

        var groupname_inventory = std.AutoHashMap(std.c.gid_t, []const u8).init(allocator);
        errdefer deinitCachedNames(std.c.gid_t, allocator, &groupname_inventory);

        var loaded_git = false;
        var git_inventory = std.StringHashMap(git.GitStatus).init(allocator);
        errdefer deinitGitInventory(allocator, &git_inventory);

        if (try file.File.init(
            allocator,
            io,
            &entry,
            &parent_dir,
            .{
                .load_stat = load_stat,
                .load_symlink_target = opt.show_detail,
                .load_owner = opt.show_detail,
                .show_hidden = opt.show_hidden,
                .only_dir = opt.only_dir,
                .only_file = opt.only_file,
                .keep_dirs_for_match = opt.recursive,
                .keep_dirs_for_changed_within = opt.recursive,
                .keep_dirs_for_size = opt.recursive,
                .exts = opt.exts,
                .matches = opt.matches,
                .changed_within = opt.changed_within,
                .size_range = opt.size_range,
                .changed_within_now = changed_within_now,
            },
            &username_inventory,
            &groupname_inventory,
        )) |single_file| {
            var item = single_file;
            errdefer if (item.symlink_target) |target| allocator.free(target);

            const name = try allocator.dupe(u8, base_name);
            errdefer allocator.free(name);
            item.name = name;

            if (!opt.show_detail and !opt.recursive) {
                max_len = item.name.len + 2;
            }

            if (opt.report) {
                if (item.is_dir) {
                    total_folders = 1;
                } else {
                    total_files = 1;
                }
            }

            try files.append(allocator, item);
        }

        if (opt.show_git and git.isGitRepo(allocator, io, parent_path)) {
            git_inventory = try git.getFileStatuses(allocator, io, parent_path);
            loaded_git = true;
        }

        return .{
            .max_display_len = max_len,
            .total_folders = total_folders,
            .total_files = total_files,
            .allocator = allocator,
            .io = io,
            .items = files,
            .opt = opt,
            .username_inventory = username_inventory,
            .groupname_inventory = groupname_inventory,
            .loaded_git = loaded_git,
            .git_inventory = git_inventory,
        };
    }

    inline fn shouldLoadStat(opt: opts.FilesOptions, needs_recursive_dir_size: bool) bool {
        return opt.show_detail or
            opt.sort_type == .mtime or
            opt.sort_type == .size or
            opt.changed_within != null or
            opt.size_range != null or
            needs_recursive_dir_size;
    }

    pub fn deinit(self: *Self) void {
        deinitItems(self.allocator, self.items.items);
        self.items.deinit(self.allocator);

        deinitCachedNames(std.c.uid_t, self.allocator, &self.username_inventory);
        deinitCachedNames(std.c.gid_t, self.allocator, &self.groupname_inventory);
        deinitGitInventory(self.allocator, &self.git_inventory);
    }

    /// Free owned data stored by each File entry.
    inline fn deinitItems(allocator: mem.Allocator, items: []file.File) void {
        // Each File owns its copied name and optional symlink target.
        for (items) |item| {
            allocator.free(item.name);
            if (item.symlink_target) |target| {
                allocator.free(target);
            }
        }
    }

    /// Free cached owner/group names and destroy the cache.
    inline fn deinitCachedNames(comptime Key: type, allocator: mem.Allocator, inventory: *std.AutoHashMap(Key, []const u8)) void {
        // Owner names are shared through caches, so free each cached value once.
        var names = inventory.valueIterator();
        while (names.next()) |name| {
            allocator.free(name.*);
        }
        inventory.deinit();
    }

    /// Free cached git status keys and destroy the map.
    inline fn deinitGitInventory(allocator: mem.Allocator, inventory: *std.StringHashMap(git.GitStatus)) void {
        // Git status keys are duplicated when the inventory is loaded.
        var names = inventory.keyIterator();
        while (names.next()) |name| {
            allocator.free(name.*);
        }
        inventory.deinit();
    }

    /// Return the collected file entries as a read-only slice.
    pub inline fn entries(self: Self) []const file.File {
        return self.items.items;
    }

    /// Return the longest display width used by simple listing output.
    pub inline fn maxDisplayLen(self: Self) usize {
        return self.max_display_len;
    }

    /// Return whether git status data was loaded for this listing.
    pub inline fn hasGitStatus(self: Self) bool {
        return self.loaded_git;
    }

    /// Return the git status for a file name, if one was loaded.
    pub inline fn gitStatus(self: Self, name: []const u8) ?git.GitStatus {
        if (!self.loaded_git) return null;
        return self.git_inventory.get(name);
    }

    /// Return the options used to create this listing.
    pub inline fn options(self: Self) opts.FilesOptions {
        return self.opt;
    }

    /// Return whether recursive listing should stop at the current level.
    pub inline fn recursionLimitReached(self: Self) bool {
        return self.opt.recursion_level > 0 and self.curr_recursion_level > self.opt.recursion_level;
    }

    /// Return the recursion level to use for a child listing.
    pub inline fn nextRecursionLevel(self: Self) i8 {
        return self.curr_recursion_level + 1;
    }

    /// Set the recursion level for this listing.
    pub inline fn setRecursionLevel(self: *Self, level: i8) void {
        self.curr_recursion_level = level;
    }

    /// Add a child listing's report totals to this listing.
    pub inline fn addReportTotals(self: *Self, child: Self) void {
        self.total_folders += child.total_folders;
        self.total_files += child.total_files;
    }

    const SortCtx = struct {
        sort_type: opts.SortType,
        dir_grouping: opts.DirGrouping,
        reverse: bool,

        fn lessThan(ctx: SortCtx, a: file.File, b: file.File) bool {
            if (ctx.dir_grouping != .none) {
                const a_is_dir = a.is_dir or a.is_symlink_to_dir;
                const b_is_dir = b.is_dir or b.is_symlink_to_dir;
                if (a_is_dir != b_is_dir) return a_is_dir == (ctx.dir_grouping == .before);
            }

            const res = switch (ctx.sort_type) {
                .length => file.File.nameLenLessThan({}, a, b),
                .mtime => file.File.mtimeMoreThan({}, a, b),
                .size => file.File.sizeMoreThan({}, a, b),
                else => file.File.nameLessThan({}, a, b),
            };

            return if (ctx.reverse) !res else res;
        }

        fn isDir(path: []const u8, io: std.Io, dir: std.Io.Dir) bool {
            const stat = dir.statFile(io, path, .{}) catch return false;
            return stat.kind == .directory;
        }
    };

    fn sort(items: []file.File, dir_grouping: opts.DirGrouping, sort_type: opts.SortType, reverse: bool) void {
        mem.sortUnstable(
            file.File,
            items,
            SortCtx{
                .dir_grouping = dir_grouping,
                .sort_type = sort_type,
                .reverse = reverse,
            },
            SortCtx.lessThan,
        );
    }

    /// recursively calculate directory size by summing up sizes of all descendant files.
    pub fn calculateDirectorySize(io: std.Io, dir: std.Io.Dir) anyerror!u64 {
        var total_size: u64 = 0;
        var it = dir.iterate();

        while (try it.next(io)) |entry| {
            const stat = file.File.statForName(entry.name, &dir) orelse continue;

            if (entry.kind == .directory) {
                // recursively calculate size for subdirectory
                const child_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child_dir.close(io);

                const child_size = calculateDirectorySize(io, child_dir) catch continue;
                total_size = std.math.add(u64, total_size, child_size) catch return error.Overflow;
                continue;
            }

            total_size = std.math.add(u64, total_size, stat.size) catch return error.Overflow;
        }

        return total_size;
    }
};

test "recursive directory size uses descendant file sizes" {
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "abcd" });
    try tmp_dir.dir.createDirPath(io, "sub_dir/nested");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "sub_dir/child.txt", .data = "hello" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "sub_dir/nested/deep.txt", .data = "xyz" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var files = try Files.init(
        arena.allocator(),
        io,
        tmp_dir.dir,
        .{ .show_detail = true, .recursive_dir_size = true },
    );
    defer files.deinit();

    var found_dir = false;
    for (files.entries()) |entry| {
        if (!std.mem.eql(u8, entry.name, "sub_dir")) continue;

        found_dir = true;
        try testing.expectEqual(@as(?u64, 8), entry.effectiveSize());
    }

    try testing.expect(found_dir);
}

test "without recursive directory size directory keeps stat size" {
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "sub_dir");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "sub_dir/child.txt", .data = "hello" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var files = try Files.init(
        arena.allocator(),
        io,
        tmp_dir.dir,
        .{ .show_detail = true },
    );
    defer files.deinit();

    var found_dir = false;
    for (files.entries()) |entry| {
        if (!std.mem.eql(u8, entry.name, "sub_dir")) continue;

        found_dir = true;
        try testing.expect(entry.recursive_size == null);
        try testing.expect(entry.effectiveSize() != null);
    }

    try testing.expect(found_dir);
}
