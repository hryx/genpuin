//! genpuin CLI: run an art script and export what it returns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const genpuin = @import("genpuin");
const zlua = @import("zlua");

const core = @import("lua/core.zig");
const host_mod = @import("lua/host.zig");
const util = @import("lua/util.zig");
const Lua = zlua.Lua;

const usage =
    \\Usage: genpuin <script.lua> [options] [-- script args]
    \\
    \\  -o <file>        Output file, format from extension: .svg .png .ppm
    \\                   (default <script>.svg, or <script>-sheet.png for a sweep)
    \\  -s <number>      Raster scale factor (default 1)
    \\  --ss <n>         Supersample n x n per pixel (default 1)
    \\  --depth <8|16>   PNG bits per channel (default 8)
    \\  --vary <n>       Variation: gen.seed and gen.noiseSeed mix in n
    \\  --vary <a>..<b>  Render variations a to b into one contact sheet
    \\  --tile <px>      Contact sheet tile width (default 320)
    \\  -j <n>           Parallel renders for a sweep (default: CPU count)
    \\  -h, --help       Show this help
    \\
;

const Args = struct {
    script: [:0]const u8,
    output: ?[]const u8 = null,
    scale: f64 = 1,
    ss: u32 = 1,
    depth: genpuin.image_io.Depth = .@"8",
    vary_lo: i64 = 0,
    vary_hi: ?i64 = null,
    tile: u32 = 320,
    jobs: ?u32 = null,
    script_args: []const []const u8 = &.{},
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parseArgs(argv: []const [:0]const u8) Args {
    var script: ?[:0]const u8 = null;
    var a: Args = .{ .script = undefined };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const val = struct {
            fn next(av: []const [:0]const u8, idx: *usize, name: []const u8) [:0]const u8 {
                idx.* += 1;
                if (idx.* >= av.len) fail("{s} needs a value", .{name});
                return av[idx.*];
            }
        }.next;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-o")) {
            a.output = val(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "-s")) {
            a.scale = std.fmt.parseFloat(f64, val(argv, &i, arg)) catch fail("-s needs a number", .{});
            if (!(a.scale > 0)) fail("-s must be positive", .{});
        } else if (std.mem.eql(u8, arg, "--ss")) {
            a.ss = std.fmt.parseInt(u32, val(argv, &i, arg), 10) catch fail("--ss needs an integer", .{});
            if (a.ss < 1 or a.ss > 16) fail("--ss must be 1 to 16", .{});
        } else if (std.mem.eql(u8, arg, "--depth")) {
            const d = val(argv, &i, arg);
            a.depth = if (std.mem.eql(u8, d, "16")) .@"16" else if (std.mem.eql(u8, d, "8")) .@"8" else fail("--depth is 8 or 16", .{});
        } else if (std.mem.eql(u8, arg, "--vary")) {
            const v = val(argv, &i, arg);
            if (std.mem.indexOf(u8, v, "..")) |dots| {
                a.vary_lo = std.fmt.parseInt(i64, v[0..dots], 10) catch fail("bad --vary range", .{});
                a.vary_hi = std.fmt.parseInt(i64, v[dots + 2 ..], 10) catch fail("bad --vary range", .{});
                if (a.vary_hi.? < a.vary_lo) fail("--vary range is backwards", .{});
            } else {
                a.vary_lo = std.fmt.parseInt(i64, v, 10) catch fail("--vary needs an integer", .{});
            }
        } else if (std.mem.eql(u8, arg, "--tile")) {
            a.tile = std.fmt.parseInt(u32, val(argv, &i, arg), 10) catch fail("--tile needs an integer", .{});
        } else if (std.mem.eql(u8, arg, "-j")) {
            a.jobs = std.fmt.parseInt(u32, val(argv, &i, arg), 10) catch fail("-j needs an integer", .{});
        } else if (std.mem.eql(u8, arg, "--")) {
            a.script_args = argv[i + 1 ..];
            break;
        } else if (arg.len > 1 and arg[0] == '-') {
            fail("unknown option: {s}", .{arg});
        } else {
            if (script != null) fail("unexpected argument: {s}", .{arg});
            script = arg;
        }
    }
    a.script = script orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    return a;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv);
    const lua_dir = init.environ_map.get("GENPUIN_LUA_DIR");

    var script_argv: std.ArrayList([]const u8) = .empty;
    try script_argv.append(arena, argv[0]);
    try script_argv.append(arena, args.script);
    try script_argv.appendSlice(arena, args.script_args);
    const ctx: RunContext = .{
        .gpa = std.heap.smp_allocator,
        .io = init.io,
        .args = &args,
        .lua_dir = lua_dir,
        .argv = script_argv.items,
    };

    if (args.vary_hi) |hi| return sweep(arena, ctx, hi);

    const stem = std.fs.path.stem(args.script);
    const output = args.output orelse try std.fmt.allocPrint(arena, "{s}.svg", .{stem});
    runOne(ctx, args.vary_lo, .{ .file = output }) catch std.process.exit(1);
}

const RunContext = struct {
    gpa: Allocator,
    io: Io,
    args: *const Args,
    lua_dir: ?[]const u8,
    argv: []const []const u8,
};

const Target = union(enum) {
    file: []const u8,
    /// Render to a raster scaled to this width, for a contact sheet.
    tile: struct { width: u32, out: *?genpuin.Raster },
};

fn runOne(ctx: RunContext, vary: i64, target: Target) !void {
    var host: util.Host = .{ .gpa = ctx.gpa, .io = ctx.io, .vary = vary };
    const lua = try host_mod.create(&host, .{
        .script_dir = std.fs.path.dirname(ctx.args.script) orelse ".",
        .lua_dir = ctx.lua_dir,
        .argv = ctx.argv,
    });
    defer lua.deinit();

    host_mod.runScript(lua, ctx.args.script) catch {
        std.debug.print("{s}\n", .{lua.toString(-1) catch "script failed"});
        return error.ScriptFailed;
    };
    if (!isCanvas(lua, -1)) {
        if (target == .tile) {
            std.debug.print("vary {d}: script returned no canvas\n", .{vary});
            return error.NoCanvas;
        }
        return;
    }
    const opts: core.RenderOptions = .{ .scale = ctx.args.scale, .ss = ctx.args.ss, .depth = ctx.args.depth };

    switch (target) {
        .file => |path| {
            const fmt = genpuin.image_io.Format.fromPath(path) orelse .svg;
            if (fmt == .svg) {
                try exportSvg(lua, path);
            } else {
                var r = core.renderCanvas(lua, -1, opts) catch |err| return reportRenderError(lua, err);
                defer r.deinit(ctx.gpa);
                try genpuin.image_io.write(ctx.gpa, ctx.io, &r, path, opts.depth);
            }
            std.debug.print("Wrote {s}\n", .{path});
        },
        .tile => |t| {
            var r = core.renderCanvas(lua, -1, opts) catch |err| return reportRenderError(lua, err);
            defer r.deinit(ctx.gpa);
            const h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(r.h)) * @as(f64, @floatFromInt(t.width)) / @as(f64, @floatFromInt(r.w))))));
            t.out.* = try r.resizeBox(ctx.gpa, t.width, h);
        },
    }
}

fn reportRenderError(lua: *Lua, err: anyerror) anyerror {
    _ = lua;
    std.debug.print("render failed: {s}\n", .{@errorName(err)});
    return err;
}

fn isCanvas(lua: *Lua, index: i32) bool {
    if (!lua.isTable(index)) return false;
    defer lua.pop(1);
    return lua.getField(index, "width") == .number;
}

fn exportSvg(lua: *Lua, path: []const u8) !void {
    const canvas = lua.absIndex(-1);
    _ = lua.getGlobal("require");
    _ = lua.pushStringZ("genpuin.svg");
    lua.call(.{ .args = 1, .results = 1 });
    _ = lua.getField(-1, "exportSvg");
    lua.pushValue(canvas);
    _ = lua.pushString(path);
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch {
        std.debug.print("{s}\n", .{lua.toString(-1) catch "svg export failed"});
        return error.SvgFailed;
    };
    lua.pop(1);
}

/// Render every variation in [lo, hi] on worker threads, then lay them
/// out on one sheet. Each worker owns its own Lua state.
fn sweep(arena: Allocator, ctx: RunContext, hi: i64) !void {
    const lo = ctx.args.vary_lo;
    const n: usize = @intCast(hi - lo + 1);
    const tiles = try arena.alloc(?genpuin.Raster, n);
    @memset(tiles, null);

    const cpu: u32 = @intCast(std.Thread.getCpuCount() catch 4);
    const jobs = @min(ctx.args.jobs orelse cpu, @as(u32, @intCast(n)));
    var next: std.atomic.Value(usize) = .init(0);
    const Worker = struct {
        fn run(c: RunContext, lo_: i64, ts: []?genpuin.Raster, counter: *std.atomic.Value(usize)) void {
            while (true) {
                const i = counter.fetchAdd(1, .monotonic);
                if (i >= ts.len) return;
                const v = lo_ + @as(i64, @intCast(i));
                runOne(c, v, .{ .tile = .{ .width = c.args.tile, .out = &ts[i] } }) catch |err| {
                    std.debug.print("vary {d} failed: {s}\n", .{ v, @errorName(err) });
                };
            }
        }
    };
    const threads = try arena.alloc(std.Thread, jobs);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ ctx, lo, tiles, &next });
    for (threads) |t| t.join();

    const sheet_tiles = try arena.alloc(genpuin.sheet.Tile, n);
    for (sheet_tiles, tiles, 0..) |*st, t, i| st.* = .{ .raster = t, .label = lo + @as(i64, @intCast(i)) };
    var sheet = try genpuin.sheet.compose(ctx.gpa, sheet_tiles, .{});
    defer sheet.deinit(ctx.gpa);
    for (tiles) |*t| if (t.*) |*r| r.deinit(ctx.gpa);

    const stem = std.fs.path.stem(ctx.args.script);
    const out = ctx.args.output orelse try std.fmt.allocPrint(arena, "{s}-sheet.png", .{stem});
    try genpuin.image_io.write(ctx.gpa, ctx.io, &sheet, out, .@"8");
    std.debug.print("Wrote {s} ({d} variations)\n", .{ out, n });
}

test {
    _ = @import("lua/util.zig");
    _ = @import("lua/marshal.zig");
}
