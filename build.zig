const std = @import("std");

const Lang = enum { lua51, lua52, lua53, lua54, lua55, luajit };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const lang = b.option(Lang, "lang", "Lua flavour to embed (default luajit)") orelse .luajit;

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
    exe_mod.addImport("lua_sources", luaSources(b));

    const exe = b.addExecutable(.{ .name = "genpuin", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run genpuin with the given arguments").dependOn(&run.step);

    const test_step = b.step("test", "Run Zig unit tests and the Lua render tests");
    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    const lua_tests = b.addRunArtifact(exe);
    lua_tests.addArg("test/run.lua");
    lua_tests.setCwd(b.path("."));
    lua_tests.has_side_effects = true;
    test_step.dependOn(&lua_tests.step);

    const examples_step = b.step("examples", "Render every examples/*.lua to out/");
    const ext = b.option([]const u8, "ext", "Output format for the examples step (png, ppm, svg)") orelse "png";
    b.dependOnDirectoryContents(b.path("examples"));
    var dir = b.root.openDir(b.graph.io, "examples", .{ .iterate = true }) catch
        @panic("examples/ missing");
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch @panic("examples/ unreadable")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const stem = entry.name[0 .. entry.name.len - ".lua".len];
        const render = b.addRunArtifact(exe);
        render.setCwd(b.path("."));
        render.addArg(b.fmt("examples/{s}", .{entry.name}));
        render.addArg("-o");
        render.addArg(b.fmt("out/{s}/{s}.{s}", .{ ext, stem, ext }));
        render.has_side_effects = true;
        examples_step.dependOn(&render.step);
    }
}

/// A module embedding every genpuin/*.lua, so the binary needs no install
/// tree. Each entry maps a require name to its source.
fn luaSources(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var index: std.ArrayList(u8) = .empty;
    index.appendSlice(b.allocator, "pub const modules = [_]struct { name: [:0]const u8, source: [:0]const u8 }{\n") catch @panic("OOM");

    b.dependOnDirectoryContents(b.path("genpuin"));
    var dir = b.root.openDir(b.graph.io, "genpuin", .{ .iterate = true }) catch
        @panic("genpuin/ missing");
    defer dir.close(b.graph.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch @panic("genpuin/ unreadable")) |entry| {
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
        const mod_name = if (std.mem.eql(u8, stem, "init")) "genpuin" else b.fmt("genpuin.{s}", .{stem});
        _ = files.addCopyFile(b.path(b.fmt("genpuin/{s}", .{name})), name);
        index.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ mod_name, name })) catch @panic("OOM");
    }
    index.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const root = files.add("lua_sources.zig", index.items);
    return b.createModule(.{ .root_source_file = root });
}
