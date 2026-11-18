const std = @import("std");

const Lang = enum { lua51, lua52, lua53, lua54, lua55, luajit };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const lang = b.option(Lang, "lang", "Lua flavor to embed (default luajit)") orelse .luajit;

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = @as([]const u8, @tagName(lang)),
    });
    const zigimg_dep = b.dependency("zigimg", .{ .target = target, .optimize = optimize });

    const core_mod = b.addModule("genpuin", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("zigimg", zigimg_dep.module("zigimg"));

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("genpuin", core_mod);
    exe_mod.addImport("zlua", zlua_dep.module("zlua"));
    const lua_sources = luaSources(b);
    exe_mod.addImport("lua_sources", lua_sources);

    const exe = b.addExecutable(.{ .name = "genpuin", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run genpuin with the given arguments").dependOn(&run.step);

    const test_step = b.step("test", "Run the Zig unit tests, the Lua tests and the math guard");
    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const runner_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_mod.addImport("genpuin", core_mod);
    runner_mod.addImport("zlua", zlua_dep.module("zlua"));
    runner_mod.addImport("lua_sources", lua_sources);
    const runner = b.addExecutable(.{ .name = "test_runner", .root_module = runner_mod });
    const lua_tests = b.addRunArtifact(runner);
    lua_tests.addArg("test");
    lua_tests.setCwd(b.path("."));
    lua_tests.has_side_effects = true;
    test_step.dependOn(&lua_tests.step);

    const guard_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/math_guard.zig"),
        .target = b.graph.host,
    });
    const guard = b.addExecutable(.{ .name = "math_guard", .root_module = guard_mod });
    for ([_]*std.Build.Step.Compile{ exe, runner }) |checked| {
        const guard_run = b.addRunArtifact(guard);
        guard_run.addArtifactArg(checked);
        test_step.dependOn(&guard_run.step);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = guard_mod })).step);

    const examples_step = b.step("examples", "Render every examples/*.lua to out/");
    const ext = b.option([]const u8, "ext", "Output format for the examples step (png, ppm, svg)") orelse "png";
    b.dependOnDirectoryContents(b.path("examples"));
    const render = b.addRunArtifact(exe);
    render.setCwd(b.path("."));
    render.has_side_effects = true;
    var dir = b.root.openDir(b.graph.io, "examples", .{ .iterate = true }) catch
        @panic("examples/ missing");
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch @panic("examples/ unreadable")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        render.addArg(b.fmt("examples/{s}", .{entry.name}));
    }
    render.addArgs(&.{ "--format", ext, "-o", b.fmt("out/{s}/", .{ext}) });
    examples_step.dependOn(&render.step);
}

/// A module embedding every src/lua/prelude/*.lua, so the binary needs no
/// install tree. Each entry maps an import name to its file and source.
fn luaSources(b: *std.Build) *std.Build.Module {
    const prelude = "src/lua/prelude";
    const files = b.addWriteFiles();
    var index: std.ArrayList(u8) = .empty;
    index.appendSlice(b.allocator, "pub const modules = [_]struct { name: [:0]const u8, file: [:0]const u8, source: [:0]const u8 }{\n") catch @panic("OOM");

    b.dependOnDirectoryContents(b.path(prelude));
    var dir = b.root.openDir(b.graph.io, prelude, .{ .iterate = true }) catch
        @panic(prelude ++ " missing");
    defer dir.close(b.graph.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch @panic(prelude ++ " unreadable")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lt);

    for (names.items) |name| {
        const stem = name[0 .. name.len - ".lua".len];
        _ = files.addCopyFile(b.path(b.fmt("{s}/{s}", .{ prelude, name })), name);
        index.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .file = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ stem, name, name })) catch @panic("OOM");
    }
    index.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const root = files.add("lua_sources.zig", index.items);
    return b.createModule(.{ .root_source_file = root });
}
