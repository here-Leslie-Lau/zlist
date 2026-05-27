const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // link libc to get access to the C standard library
        .link_libc = true,
        // set single threaded mode
        .single_threaded = true,
    });

    // import zlist as a module
    const zlist_mod = b.createModule(.{
        .root_source_file = b.path("src/zlist.zig"),
        .target = target,
        .optimize = optimize,
        // link libc to get access to the C standard library
        .link_libc = true,
        // set single threaded mode
        .single_threaded = true,
    });

    mod.addImport("zlist", zlist_mod);

    {
        // setup exe
        const exe = b.addExecutable(.{
            .name = "zl",
            .root_module = mod,
        });

        // add clap as a dependency
        const clap = b.dependency("clap", .{
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("clap", clap.module("clap"));

        b.installArtifact(exe);
    }
}
