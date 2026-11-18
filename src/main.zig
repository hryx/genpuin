//! genpuin CLI: run art scripts and export the canvas each one draws.
//! Every render, one per script or one per variation of a sweep, is a
//! job with its own Lua state. A fixed set of workers pulls jobs from a
//! shared counter, so `-j` caps the total however the work is split.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const genpuin = @import("genpuin");
const Format = genpuin.image_io.Format;
const zlua = @import("zlua");

const core = @import("lua/core.zig");
const host_mod = @import("lua/host.zig");
const util = @import("lua/util.zig");
const Lua = zlua.Lua;

const usage =
    \\Usage: genpuin <script.lua>... [options] [-- script args]
    \\
    \\  -o <path>        With one script: the output file, format from its
    \\                   extension .png .ppm .svg. With several scripts, or
    \\                   a path ending in /: a directory, created if
    \\                   missing. Without -o, each script writes
    \\                   <script>.png (or <script>-sheet.png for a sweep)
    \\                   in the current directory. An SVG shows exactly
    \\                   what the PNG shows, so a canvas SVG cannot draw,
    \\                   such as one with a post pass, is an error and no
    \\                   file is written
    \\  --format <fmt>   png, ppm or svg for output names genpuin makes up
    \\                   (default png)
    \\  --vector-only    With an SVG output: leave post passes out and
    \\                   write just the shapes
    \\  -s <number>      Raster scale factor (default 1)
    \\  --ss <n>         Supersample n x n per pixel (default 1)
    \\  --depth <8|16>   PNG bits per channel (default 8)
    \\  --vary <n>       Variation: gen.seed and gen.noiseSeed mix in n
    \\  --vary <a>..<b>  Render variations a to b into one contact sheet
    \\                   per script
    \\  --tile <px>      Contact sheet tile width (default 320)
    \\  -j <n>           Renders at once, across all scripts and
    \\                   variations (default: CPU count)
    \\  -h, --help       Show this help
    \\
    \\Options and script args apply to every script. Each script runs in
    \\its own Lua state, and one failing does not stop the others.
    \\
;

const Args = struct {
    scripts: []const [:0]const u8 = &.{},
    output: ?[]const u8 = null,
    format: ?Format = null,
    scale: f64 = 1,
    ss: u32 = 1,
    depth: genpuin.image_io.Depth = .@"8",
    vary_lo: i64 = 0,
    vary_hi: ?i64 = null,
    tile: u32 = 320,
    jobs: ?u32 = null,
    vector_only: bool = false,
    script_args: []const []const u8 = &.{},
};

const UsageError = error{Usage};
const ParseError = error{ Usage, Help, NoScript } || Allocator.Error;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Put the message for a usage error in `diag`.
fn usageError(diag: *Io.Writer, comptime fmt: []const u8, args: anytype) UsageError {
    diag.print(fmt, args) catch {};
    return error.Usage;
}

fn parseArgs(arena: Allocator, argv: []const [:0]const u8, diag: *Io.Writer) ParseError!Args {
    var scripts: std.ArrayList([:0]const u8) = .empty;
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const is = struct {
            fn eql(x: []const u8, y: []const u8) bool {
                return std.mem.eql(u8, x, y);
            }
        }.eql;
        if (is(arg, "-h") or is(arg, "--help")) {
            return error.Help;
        } else if (is(arg, "--")) {
            a.script_args = argv[i + 1 ..];
            break;
        } else if (is(arg, "--vector-only")) {
            a.vector_only = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            if (!takesValue(arg)) return usageError(diag, "unknown option: {s}", .{arg});
            i += 1;
            if (i >= argv.len) return usageError(diag, "{s} needs a value", .{arg});
            try parseOption(&a, arg, argv[i], diag);
        } else {
            try scripts.append(arena, arg);
        }
    }
    if (scripts.items.len == 0) return error.NoScript;
    a.scripts = scripts.items;
    return a;
}

fn takesValue(name: []const u8) bool {
    const valued = [_][]const u8{ "-o", "--format", "-s", "--ss", "--depth", "--vary", "--tile", "-j" };
    for (valued) |v| if (std.mem.eql(u8, name, v)) return true;
    return false;
}

fn parseOption(a: *Args, name: []const u8, v: []const u8, diag: *Io.Writer) UsageError!void {
    const is = struct {
        fn eql(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.eql;
    if (is(name, "-o")) {
        if (v.len == 0) return usageError(diag, "-o needs a path", .{});
        a.output = v;
    } else if (is(name, "--format")) {
        a.format = std.meta.stringToEnum(Format, v) orelse
            return usageError(diag, "--format is png, ppm or svg", .{});
    } else if (is(name, "-s")) {
        a.scale = std.fmt.parseFloat(f64, v) catch return usageError(diag, "-s needs a number", .{});
        if (!(a.scale > 0)) return usageError(diag, "-s must be positive", .{});
    } else if (is(name, "--ss")) {
        a.ss = std.fmt.parseInt(u32, v, 10) catch return usageError(diag, "--ss needs an integer", .{});
        if (a.ss < 1 or a.ss > 16) return usageError(diag, "--ss must be 1 to 16", .{});
    } else if (is(name, "--depth")) {
        a.depth = if (is(v, "16")) .@"16" else if (is(v, "8")) .@"8" else return usageError(diag, "--depth is 8 or 16", .{});
    } else if (is(name, "--vary")) {
        if (std.mem.indexOf(u8, v, "..")) |dots| {
            a.vary_lo = std.fmt.parseInt(i64, v[0..dots], 10) catch return usageError(diag, "bad --vary range", .{});
            a.vary_hi = std.fmt.parseInt(i64, v[dots + 2 ..], 10) catch return usageError(diag, "bad --vary range", .{});
            if (a.vary_hi.? < a.vary_lo) return usageError(diag, "--vary range is backwards", .{});
        } else {
            a.vary_lo = std.fmt.parseInt(i64, v, 10) catch return usageError(diag, "--vary needs an integer", .{});
            a.vary_hi = null;
        }
    } else if (is(name, "--tile")) {
        a.tile = std.fmt.parseInt(u32, v, 10) catch return usageError(diag, "--tile needs an integer", .{});
    } else if (is(name, "-j")) {
        a.jobs = std.fmt.parseInt(u32, v, 10) catch return usageError(diag, "-j needs an integer", .{});
        if (a.jobs.? < 1) return usageError(diag, "-j must be at least 1", .{});
    } else {
        unreachable; // takesValue lists every option handled here
    }
}

/// Where each script's result goes, decided before anything renders.
const Plan = struct {
    /// One per script: the image file, or the contact sheet for a sweep.
    outputs: []const []const u8,
    /// The directory -o names, to create up front.
    dir: ?[]const u8,
};

fn planOutputs(arena: Allocator, a: *const Args, diag: *Io.Writer) (UsageError || Allocator.Error)!Plan {
    assert(a.scripts.len > 0);
    const several = a.scripts.len > 1;
    const sheet = a.vary_hi != null;
    const dir: ?[]const u8 = if (a.output) |o|
        (if (several or std.fs.path.isSep(o[o.len - 1])) o else null)
    else
        null;
    const outputs = try arena.alloc([]const u8, a.scripts.len);

    var format: Format = a.format orelse .png;
    if (a.output != null and dir == null) {
        const file = a.output.?;
        const named = Format.fromPath(file) orelse .png;
        if (a.format) |f| {
            if (f != named) return usageError(diag, "--format {t} conflicts with -o {s}, which is {t}", .{ f, file, named });
        }
        format = named;
        outputs[0] = file;
    } else {
        if (dir) |d| {
            if (several and Format.fromPath(d) != null) {
                return usageError(diag, "-o {s} names a file, but {d} scripts need a directory", .{ d, a.scripts.len });
            }
        }
        const suffix = if (sheet) "-sheet" else "";
        for (outputs, a.scripts) |*out, script| {
            const name = try std.fmt.allocPrint(arena, "{s}{s}.{t}", .{ std.fs.path.stem(script), suffix, format });
            out.* = if (dir) |d| try std.fs.path.join(arena, &.{ d, name }) else name;
        }
        for (outputs, 0..) |out, i| for (outputs[0..i], 0..) |earlier, j| {
            if (std.mem.eql(u8, out, earlier)) {
                return usageError(diag, "{s} and {s} would both write {s}", .{ a.scripts[j], a.scripts[i], out });
            }
        };
    }

    if (a.vector_only) {
        if (sheet) return usageError(diag, "--vector-only cannot make a contact sheet", .{});
        if (format != .svg) return usageError(diag, "--vector-only needs an SVG output (-o file.svg or --format svg)", .{});
    }
    if (sheet and format == .svg) return usageError(diag, "a contact sheet cannot be an SVG", .{});
    return .{ .outputs = outputs, .dir = dir };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var diag_buf: [1024]u8 = undefined;
    var diag: Io.Writer = .fixed(&diag_buf);
    const args = parseArgs(arena, argv, &diag) catch |err| switch (err) {
        error.Help => return std.debug.print("{s}", .{usage}),
        error.NoScript => {
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        },
        error.Usage => fail("{s}", .{diag.buffered()}),
        error.OutOfMemory => return err,
    };
    const plan = planOutputs(arena, &args, &diag) catch |err| switch (err) {
        error.Usage => fail("{s}", .{diag.buffered()}),
        error.OutOfMemory => return err,
    };
    if (plan.dir) |d| Io.Dir.cwd().createDirPath(io, d) catch |err|
        fail("cannot create directory {s}: {t}", .{ d, err });

    var batch = try Batch.init(arena, .{
        .gpa = std.heap.smp_allocator,
        .io = io,
        .args = &args,
        .lua_dir = init.environ_map.get("GENPUIN_LUA_DIR"),
        .exe = argv[0],
        .outputs = plan.outputs,
    });
    const cpu: u32 = @intCast(std.Thread.getCpuCount() catch 4);
    try batch.run(args.jobs orelse cpu);
    if (!batch.finish()) std.process.exit(1);
}

/// Every render one invocation asks for. Job `i` is script
/// `i / variations` at variation `vary_lo + i % variations`.
const Batch = struct {
    gpa: Allocator,
    io: Io,
    args: *const Args,
    lua_dir: ?[]const u8,
    outputs: []const []const u8,
    /// One argv per script for its global `arg`.
    argvs: []const []const []const u8,
    /// 1 unless this is a sweep.
    variations: usize,
    /// Rendered tiles in job order for a sweep, otherwise empty.
    tiles: []?genpuin.Raster,
    /// Written only by the worker that ran the job.
    failed: []bool,
    next: std.atomic.Value(usize) = .init(0),
    /// Tests turn off the report on stderr.
    quiet: bool = false,

    const Options = struct {
        gpa: Allocator,
        io: Io,
        args: *const Args,
        lua_dir: ?[]const u8,
        exe: []const u8,
        outputs: []const []const u8,
    };

    fn init(arena: Allocator, opts: Options) !Batch {
        const a = opts.args;
        assert(opts.outputs.len == a.scripts.len);
        const variations: usize = if (a.vary_hi) |hi| @intCast(hi - a.vary_lo + 1) else 1;
        const job_count = a.scripts.len * variations;

        const argvs = try arena.alloc([]const []const u8, a.scripts.len);
        for (argvs, a.scripts) |*av, script| {
            const list = try arena.alloc([]const u8, 2 + a.script_args.len);
            list[0] = opts.exe;
            list[1] = script;
            @memcpy(list[2..], a.script_args);
            av.* = list;
        }
        const tiles = try arena.alloc(?genpuin.Raster, if (a.vary_hi != null) job_count else 0);
        @memset(tiles, null);
        const failed = try arena.alloc(bool, job_count);
        @memset(failed, false);

        return .{
            .gpa = opts.gpa,
            .io = opts.io,
            .args = a,
            .lua_dir = opts.lua_dir,
            .outputs = opts.outputs,
            .argvs = argvs,
            .variations = variations,
            .tiles = tiles,
            .failed = failed,
        };
    }

    /// Run every job on up to `jobs_max` workers, the calling thread
    /// being one of them. Where the Io cannot run a worker concurrently,
    /// it runs inline, so the batch degrades to sequential.
    fn run(b: *Batch, jobs_max: u32) Io.Cancelable!void {
        assert(jobs_max >= 1);
        const workers = @min(jobs_max, b.failed.len);
        var group: Io.Group = .init;
        defer group.cancel(b.io);
        for (1..workers) |_| {
            group.concurrent(b.io, work, .{b}) catch group.async(b.io, work, .{b});
        }
        b.work();
        try group.await(b.io);
    }

    fn work(b: *Batch) void {
        while (true) {
            const i = b.next.fetchAdd(1, .monotonic);
            if (i >= b.failed.len) return;
            b.failed[i] = !b.runJob(i);
        }
    }

    /// Render job `i` and print its report in one piece.
    fn runJob(b: *Batch, i: usize) bool {
        const script = i / b.variations;
        const vary = b.args.vary_lo + @as(i64, @intCast(i % b.variations));
        var report: Io.Writer.Allocating = .init(b.gpa);
        defer report.deinit();
        const w = &report.writer;

        const target: Target = if (b.args.vary_hi != null)
            .{ .tile = .{ .width = b.args.tile, .out = &b.tiles[i] } }
        else
            .{ .file = b.outputs[script] };
        var ok = true;
        b.runOne(script, vary, target, w) catch |err| {
            ok = false;
            if (target == .tile) w.print("vary {d} failed: {t}\n", .{ vary, err }) catch {};
        };
        b.emit(script, ok, report.written());
        return ok;
    }

    /// A failure is prefixed with its script's name when there are
    /// several scripts.
    fn emit(b: *const Batch, script: usize, ok: bool, text: []const u8) void {
        if (b.quiet or text.len == 0) return;
        if (ok or b.args.scripts.len == 1) {
            std.debug.print("{s}", .{text});
        } else {
            std.debug.print("{s}: {s}", .{ b.args.scripts[script], text });
        }
    }

    fn runOne(b: *Batch, script: usize, vary: i64, target: Target, w: *Io.Writer) !void {
        const path = b.args.scripts[script];
        var host: util.Host = .{ .gpa = b.gpa, .io = b.io, .vary = vary };
        const lua = try host_mod.create(&host, .{
            .script_dir = std.fs.path.dirname(path) orelse ".",
            .lua_dir = b.lua_dir,
            .argv = b.argvs[script],
        });
        defer lua.deinit();

        host_mod.runScript(lua, path) catch {
            try w.print("{s}\n", .{lua.toString(-1) catch "script failed"});
            return error.ScriptFailed;
        };
        if (!host_mod.pushCanvas(lua)) {
            if (target == .tile) {
                try w.print("vary {d}: script made no canvas\n", .{vary});
                return error.NoCanvas;
            }
            return;
        }
        const opts: core.RenderOptions = .{
            .scale = b.args.scale,
            .ss = b.args.ss,
            .depth = b.args.depth,
            .vector_only = b.args.vector_only,
        };

        switch (target) {
            .file => |out| {
                const left_out = host_mod.exportCanvas(lua, out, opts) catch |err| switch (err) {
                    error.SvgNeedsPixels, error.SvgUnsupported => {
                        const problem = lua.toString(-1) catch "SVG cannot show this canvas";
                        try printSvgRefusal(w, problem, out, err == error.SvgNeedsPixels);
                        return err;
                    },
                    else => return reportRenderError(lua, w, err),
                };
                try printWrote(w, out, left_out);
            },
            .tile => |t| {
                var r = core.renderCanvas(lua, -1, opts) catch |err| return reportRenderError(lua, w, err);
                defer r.deinit(b.gpa);
                const h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(r.h)) * @as(f64, @floatFromInt(t.width)) / @as(f64, @floatFromInt(r.w))))));
                t.out.* = try r.resizeBox(b.gpa, t.width, h);
            },
        }
    }

    /// Lay out each script's tiles on its sheet, then report whether
    /// every job and every sheet succeeded. A sheet is written even when
    /// some of its variations failed.
    fn finish(b: *Batch) bool {
        var ok = std.mem.indexOfScalar(bool, b.failed, true) == null;
        if (b.args.vary_hi == null) return ok;
        const n = b.variations;
        for (b.outputs, 0..) |out, script| {
            const tiles = b.tiles[script * n ..][0..n];
            defer for (tiles) |*t| if (t.*) |*r| r.deinit(b.gpa);
            b.writeSheet(tiles, out) catch |err| {
                ok = false;
                var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "cannot write {s}: {t}\n", .{ out, err }) catch "cannot write sheet\n";
                b.emit(script, false, text);
                continue;
            };
            var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Wrote {s} ({d} variations)\n", .{ out, n }) catch "Wrote sheet\n";
            b.emit(script, true, text);
        }
        return ok;
    }

    fn writeSheet(b: *const Batch, tiles: []const ?genpuin.Raster, out: []const u8) !void {
        const sheet_tiles = try b.gpa.alloc(genpuin.sheet.Tile, tiles.len);
        defer b.gpa.free(sheet_tiles);
        for (sheet_tiles, tiles, 0..) |*st, t, i| {
            st.* = .{ .raster = t, .label = b.args.vary_lo + @as(i64, @intCast(i)) };
        }
        var sheet = try genpuin.sheet.compose(b.gpa, sheet_tiles, .{});
        defer sheet.deinit(b.gpa);
        try genpuin.image_io.write(b.gpa, b.io, &sheet, out, .@"8");
    }
};

const Target = union(enum) {
    file: []const u8,
    /// Render to a raster scaled to this width, for a contact sheet.
    tile: struct { width: u32, out: *?genpuin.Raster },
};

/// A post pass gets a second line with both ways out.
fn printSvgRefusal(w: *Io.Writer, problem: []const u8, path: []const u8, needs_pixels: bool) !void {
    try w.print("{s}\n", .{problem});
    if (!needs_pixels) return;
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    try w.print("  (use -o {s}.png, or --vector-only to export just the shapes)\n", .{stem});
}

fn printWrote(w: *Io.Writer, path: []const u8, left_out: usize) !void {
    switch (left_out) {
        0 => try w.print("Wrote {s}\n", .{path}),
        1 => try w.print("Wrote {s} (left out: 1 post pass)\n", .{path}),
        else => try w.print("Wrote {s} (left out: {d} post passes)\n", .{ path, left_out }),
    }
}

fn reportRenderError(lua: *Lua, w: *Io.Writer, err: anyerror) anyerror {
    switch (err) {
        error.CanvasFailed => try w.print("render failed: {s}\n", .{lua.toString(-1) catch "canvas is malformed"}),
        else => try w.print("render failed: {t}\n", .{err}),
    }
    return err;
}

test "main: a post pass refusal points at a PNG and at --vector-only" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try printSvgRefusal(&w, "fh.lua:45: gen.post.pixelSort needs pixels and has no vector form", "out/fh.svg", true);
    try std.testing.expectEqualStrings(
        "fh.lua:45: gen.post.pixelSort needs pixels and has no vector form\n" ++
            "  (use -o out/fh.png, or --vector-only to export just the shapes)\n",
        w.buffered(),
    );
}

test "main: other refusals have no hint" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try printSvgRefusal(&w, "draw 3 (circle): blendMode 'add' has no SVG form. Write a PNG instead", "fh.svg", false);
    try std.testing.expectEqualStrings("draw 3 (circle): blendMode 'add' has no SVG form. Write a PNG instead\n", w.buffered());
}

test "main: the Wrote line counts what was left out" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try printWrote(&w, "fh.svg", 0);
    try printWrote(&w, "fh.svg", 1);
    try printWrote(&w, "fh.svg", 3);
    try std.testing.expectEqualStrings(
        "Wrote fh.svg\nWrote fh.svg (left out: 1 post pass)\nWrote fh.svg (left out: 3 post passes)\n",
        w.buffered(),
    );
}

/// The outputs `argv` plans, or the usage error it makes.
fn testPlan(arena: Allocator, argv: []const [:0]const u8, diag: *Io.Writer) ![]const []const u8 {
    const full = try arena.alloc([:0]const u8, argv.len + 1);
    full[0] = "genpuin";
    @memcpy(full[1..], argv);
    const args = try arena.create(Args);
    args.* = try parseArgs(arena, full, diag);
    return (try planOutputs(arena, args, diag)).outputs;
}

fn expectOutputs(argv: []const [:0]const u8, expected: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const outputs = try testPlan(arena_state.allocator(), argv, &diag);
    try std.testing.expectEqual(expected.len, outputs.len);
    for (expected, outputs) |e, o| try std.testing.expectEqualStrings(e, o);
}

fn expectUsage(argv: []const [:0]const u8, message: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Usage, testPlan(arena_state.allocator(), argv, &diag));
    try std.testing.expectEqualStrings(message, diag.buffered());
}

test "main: one script writes its stem in the current directory, or the -o file" {
    try expectOutputs(&.{"art/a.lua"}, &.{"a.png"});
    try expectOutputs(&.{ "art/a.lua", "--format", "svg" }, &.{"a.svg"});
    try expectOutputs(&.{ "art/a.lua", "-o", "x/b.ppm" }, &.{"x/b.ppm"});
    try expectOutputs(&.{ "art/a.lua", "-o", "x/b.ppm", "--format", "ppm" }, &.{"x/b.ppm"});
    try expectOutputs(&.{ "art/a.lua", "-o", "plain" }, &.{"plain"});
    try expectOutputs(&.{ "art/a.lua", "-o", "out/" }, &.{"out/a.png"});
    try expectOutputs(&.{ "art/a.lua", "--vary", "1..4" }, &.{"a-sheet.png"});
}

test "main: several scripts write into the -o directory in the chosen format" {
    try expectOutputs(&.{ "a.lua", "sub/b.lua", "c.lua" }, &.{ "a.png", "b.png", "c.png" });
    try expectOutputs(&.{ "a.lua", "sub/b.lua", "-o", "out", "--format", "ppm" }, &.{ "out/a.ppm", "out/b.ppm" });
    try expectOutputs(&.{ "-o", "out/", "a.lua", "b.lua", "--vary", "0..3" }, &.{ "out/a-sheet.png", "out/b-sheet.png" });
    try expectOutputs(&.{ "a.lua", "b.lua", "--format", "svg", "--vector-only" }, &.{ "a.svg", "b.svg" });
}

test "main: output usage errors are caught before rendering" {
    try expectUsage(&.{ "a.lua", "b.lua", "-o", "out.png" }, "-o out.png names a file, but 2 scripts need a directory");
    try expectUsage(&.{ "a.lua", "sub/a.lua", "-o", "out" }, "a.lua and sub/a.lua would both write out/a.png");
    try expectUsage(&.{ "x/a.lua", "y/a.lua" }, "x/a.lua and y/a.lua would both write a.png");
    try expectUsage(&.{ "a.lua", "-o", "a.svg", "--format", "png" }, "--format png conflicts with -o a.svg, which is svg");
    try expectUsage(&.{ "a.lua", "-o", "plain", "--format", "ppm" }, "--format ppm conflicts with -o plain, which is png");
    try expectUsage(&.{ "a.lua", "--format", "gif" }, "--format is png, ppm or svg");
    try expectUsage(&.{ "a.lua", "--vary", "1..3", "--format", "svg" }, "a contact sheet cannot be an SVG");
    try expectUsage(&.{ "a.lua", "-j", "0" }, "-j must be at least 1");
    try expectUsage(&.{ "a.lua", "-o" }, "-o needs a value");
    try expectUsage(&.{ "a.lua", "--bogus" }, "unknown option: --bogus");
}

test "main: --vector-only needs an SVG output" {
    try expectOutputs(&.{ "a.lua", "-o", "a.svg", "--vector-only" }, &.{"a.svg"});
    try expectUsage(&.{ "a.lua", "-o", "a.png", "--vector-only" }, "--vector-only needs an SVG output (-o file.svg or --format svg)");
    try expectUsage(&.{ "a.lua", "--vector-only" }, "--vector-only needs an SVG output (-o file.svg or --format svg)");
    try expectUsage(&.{ "a.lua", "-o", "a.svg", "--vector-only", "--vary", "0..3" }, "--vector-only cannot make a contact sheet");
}

test "main: no script and help are not usage errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.NoScript, parseArgs(arena_state.allocator(), &.{ "genpuin", "-s", "2" }, &diag));
    try std.testing.expectError(error.Help, parseArgs(arena_state.allocator(), &.{ "genpuin", "a.lua", "--help" }, &diag));
}

test "main: script args after -- go to every script" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const args = try parseArgs(arena_state.allocator(), &.{ "genpuin", "a.lua", "b.lua", "--", "c.lua", "-o" }, &diag);
    try std.testing.expectEqual(@as(usize, 2), args.scripts.len);
    try std.testing.expectEqual(@as(usize, 2), args.script_args.len);
    try std.testing.expectEqualStrings("c.lua", args.script_args[0]);
}

/// Render `scripts` in one batch and return each output's bytes.
fn testRender(arena: Allocator, dir: []const u8, scripts: []const [:0]const u8, jobs: u32, vary: ?[]const u8) ![]const []const u8 {
    const io = std.testing.io;
    var argv: std.ArrayList([:0]const u8) = .empty;
    try argv.append(arena, "genpuin");
    try argv.appendSlice(arena, scripts);
    try argv.appendSlice(arena, &.{ "-o", try std.fmt.allocPrintSentinel(arena, "{s}/", .{dir}, 0) });
    if (vary) |v| try argv.appendSlice(arena, &.{ "--vary", try arena.dupeSentinel(u8, v, 0) });

    var buf: [256]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const args = try arena.create(Args);
    args.* = try parseArgs(arena, argv.items, &diag);
    const plan = try planOutputs(arena, args, &diag);
    var batch = try Batch.init(arena, .{
        .gpa = std.testing.allocator,
        .io = io,
        .args = args,
        .lua_dir = null,
        .exe = "genpuin",
        .outputs = plan.outputs,
    });
    batch.quiet = true;
    try batch.run(jobs);
    try std.testing.expect(batch.finish());

    const bytes = try arena.alloc([]const u8, plan.outputs.len);
    for (bytes, plan.outputs) |*b, out| b.* = try Io.Dir.cwd().readFileAlloc(io, out, arena, .unlimited);
    return bytes;
}

test "main: a batch renders each script byte for byte as it renders alone" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(arena, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });

    const sources = [_][]const u8{
        \\gen.canvas(40, 30)
        \\gen.background({0.1, 0.1, 0.2})
        \\for _ = 1, 30 do
        \\    gen.draw(gen.circle({gen.randRange(0, 40), gen.randRange(0, 30)}, gen.randRange(1, 6)), {fill = {gen.rand(), 0.5, 0.8, 0.6}})
        \\end
        ,
        \\gen.canvas(32, 32)
        \\gen.background({1, 1, 1})
        \\gen.seed(7)
        \\for i = 1, 12 do
        \\    gen.draw(gen.line({gen.randRange(0, 32), 0}, {gen.randRange(0, 32), 32}), {stroke = {0, 0, 0}, strokeWidth = i / 4})
        \\end
        ,
        \\gen.canvas(24, 48)
        \\gen.background({0.9, 0.8, 0.6})
        \\gen.draw(gen.circle({12, 24}, gen.randRange(4, 10)), {fill = {0.6, 0.1, 0.1}})
        \\gen.post.invert()
        ,
    };
    const names = [_][]const u8{ "dots.lua", "lines.lua", "disc.lua" };
    var scripts: [names.len][:0]const u8 = undefined;
    for (&scripts, names, sources) |*s, name, source| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = source });
        s.* = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ root, name }, 0);
    }

    for ([_]?[]const u8{ null, "2..4" }) |vary| {
        var alone: [names.len][]const u8 = undefined;
        for (&alone, scripts, 0..) |*a, s, i| {
            const dir = try std.fmt.allocPrint(arena, "{s}/alone{d}", .{ root, i });
            a.* = (try testRender(arena, dir, &.{s}, 1, vary))[0];
        }
        for ([_]u32{ 1, 4 }) |jobs| {
            const dir = try std.fmt.allocPrint(arena, "{s}/j{d}", .{ root, jobs });
            const together = try testRender(arena, dir, &scripts, jobs, vary);
            for (alone, together) |a, t| try std.testing.expectEqualSlices(u8, a, t);
        }
    }
}

test {
    _ = @import("lua/host.zig");
    _ = @import("lua/bind_math.zig");
    _ = @import("lua/bind_testing.zig");
    _ = @import("lua/util.zig");
    _ = @import("lua/marshal.zig");
    _ = @import("lua/core.zig");
}
