const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the library module to package consumers.
    const zlist_mod = b.addModule("zlist", .{
        .root_source_file = b.path("src/zlist.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
    });

    // Dependencies should not pull in CLI-only code or packages.
    if (b.pkg_hash.len != 0) return;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
    });

    mod.addImport("zlist", zlist_mod);

    {
        const exe = b.addExecutable(.{
            .name = "zl",
            .root_module = mod,
        });

        // clap is only needed by the CLI.
        const clap = b.lazyDependency("clap", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;

        exe.root_module.addImport("clap", clap.module("clap"));

        b.installArtifact(exe);
    }
}
