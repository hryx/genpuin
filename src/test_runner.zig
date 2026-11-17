//! Runs every test-*.lua in a directory (test/ by default), each in a
//! fresh Lua state set up as the CLI sets one up, plus the `testing`
//! global from src/lua/bind_testing.zig. Built and run by `zig build
//! test`, never installed. Exits 1 when any file fails.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bind_testing = @import("lua/bind_testing.zig");
const host_mod = @import("lua/host.zig");
const util = @import("lua/util.zig");
const Lua = util.Lua;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 2) {
        std.debug.print("usage: test_runner [dir]\n", .{});
        std.process.exit(2);
    }
    const dir = if (args.len == 2) args[1] else "test";
    const config: bind_testing.Config = .{
        .exe = args[0],
        .lua_dir = init.environ_map.get("GENPUIN_LUA_DIR"),
    };

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;

    const files = try findTests(arena, io, dir);
    if (files.len == 0) {
        try out.print("No test files in {s}.\n", .{dir});
        try out.flush();
        return;
    }
    try Io.Dir.cwd().createDirPath(io, "out/test");

    var failures: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        try out.print("\n──── {s} ────\n", .{file});
        try out.flush();
        if (try runFile(std.heap.smp_allocator, io, &config, file, out)) {
            try out.print("PASSED\n", .{});
        } else {
            try failures.append(arena, file);
        }
        try out.flush();
    }

    try out.print("\n══════════════════════════════\n", .{});
    if (failures.items.len == 0) {
        try out.print("All {d} test file(s) passed.\n", .{files.len});
    } else {
        try out.print("{d}/{d} test file(s) failed:\n", .{ failures.items.len, files.len });
        for (failures.items) |f| try out.print("  {s}\n", .{f});
    }
    try out.flush();
    if (failures.items.len > 0) std.process.exit(1);
}

/// The paths of dir/test-*.lua, sorted.
fn findTests(arena: Allocator, io: Io, dir_path: []const u8) ![]const [:0]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var files: std.ArrayList([:0]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "test-") or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        try files.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir_path, entry.name }, 0));
    }
    std.mem.sort([:0]const u8, files.items, {}, struct {
        fn lessThan(_: void, l: [:0]const u8, r: [:0]const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);
    return files.items;
}

/// Run one file and report why it failed, if it did. A file passes when
/// it returns or calls os.exit with a zero code.
fn runFile(gpa: Allocator, io: Io, config: *const bind_testing.Config, path: [:0]const u8, out: *Io.Writer) !bool {
    var host: util.Host = .{ .gpa = gpa, .io = io };
    const lua = host_mod.create(&host, .{
        .script_dir = std.fs.path.dirname(path) orelse ".",
        .lua_dir = config.lua_dir,
        .argv = &.{ config.exe, path },
    }) catch |err| {
        try out.print("FAILED: Lua setup: {s}\n", .{@errorName(err)});
        return false;
    };
    defer lua.deinit();
    bind_testing.install(lua, config);

    const result = host_mod.runScript(lua, path);
    flushStdout(lua);
    if (bind_testing.exitCode(lua)) |code| {
        if (code == 0) return true;
        try out.print("FAILED: os.exit({d})\n", .{code});
        return false;
    }
    result catch {
        try out.print("FAILED: {s}\n", .{lua.toString(-1) catch "error object is not a string"});
        return false;
    };
    return true;
}

/// Lua's print writes through C's buffered stdout. Flushing it before the
/// runner writes keeps the two in order.
fn flushStdout(lua: *Lua) void {
    const top = lua.getTop();
    defer lua.setTop(top);
    util.loadBuffer(lua, "io.stdout:flush()", "=flush") catch return;
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch {};
}
