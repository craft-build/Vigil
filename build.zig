const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_dir = b.option(
        []const u8,
        "ghostty-dir",
        "Path to the vendored ghostty checkout",
    ) orelse "vendor/ghostty";

    const xcframework_path = b.pathJoin(&.{
        ghostty_dir,
        "macos",
        "GhosttyKit.xcframework",
    });

    const slice_dir = findXcframeworkSlice(b, xcframework_path) catch |err| {
        std.debug.panic(
            "could not find a macOS slice in {s}: {s}\n" ++
                "Build libghostty first: `./scripts/build-ghostty.sh`\n",
            .{ xcframework_path, @errorName(err) },
        );
    };

    const zig_objc = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("objc", zig_objc.module("objc"));

    const sdk_path = std.mem.trim(u8, b.run(&.{
        "xcrun", "--sdk", "macosx", "--show-sdk-path",
    }), " \n\r\t");
    exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
    exe_mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/include" }) });
    exe_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib" }) });

    // libghostty headers, extracted from the xcframework's native slice
    // (built by scripts/build-ghostty.sh). We link against libghostty.dylib
    // rather than the raw libghostty-internal.a static archive: several of
    // its largest C++ translation units (glslang, spirv-cross) overflow
    // Zig 0.16's self-hosted Mach-O linker when linked directly. The build
    // script pre-links the archive into that dylib with Apple's own linker,
    // which doesn't have this bug.
    exe_mod.addIncludePath(b.path(b.pathJoin(&.{ slice_dir, "Headers" })));
    exe_mod.addLibraryPath(b.path(slice_dir));
    exe_mod.linkSystemLibrary("ghostty", .{});
    exe_mod.linkSystemLibrary("objc", .{});
    exe_mod.addRPath(b.path(slice_dir));

    const exe = b.addExecutable(.{
        .name = "vigil",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Vigil");
    run_step.dependOn(&run_cmd.step);
}

/// The xcframework contains one directory per platform slice, e.g.
/// "macos-arm64" or "macos-arm64_x86_64". Find whichever one exists rather
/// than hardcoding an architecture string.
fn findXcframeworkSlice(b: *std.Build, xcframework_path: []const u8) ![]const u8 {
    const io = b.graph.io;
    var dir = try std.Io.Dir.cwd().openDir(io, xcframework_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, "macos-")) {
            return b.pathJoin(&.{ xcframework_path, b.dupe(entry.name) });
        }
    }
    return error.NoMacOSSlice;
}
