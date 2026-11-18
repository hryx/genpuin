//! genpuin CLI: run art scripts and export the canvas each one draws.
//! Every render, one per script or one per variation, is a job with its
//! own Lua state. A fixed set of workers pulls jobs from a shared
//! counter, so `-j` caps the total however the work is split.

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
    \\  -o <file>        Write exactly this file, format from its extension
    \\                   .png .ppm .svg. Only for a run with one output
    \\  -d <dir>         Directory for made-up names, created if missing
    \\                   (default: the current directory)
    \\  -f <fmt>         png, ppm or svg for made-up names (default png)
    \\  -s <number>      Raster scale factor (default 1)
    \\  --ss <n>         Supersample n x n per pixel (default 1)
    \\  --depth <8|16>   PNG bits per channel (default 8)
    \\  --vector-only    With SVG output: leave post passes out and write
    \\                   just the shapes
    \\  --vary <n>       Variation: gen.seed and gen.noiseSeed mix in n
    \\  --vary <a>..<b>  One full-size file per variation, a to b
    \\  --sheet          With a --vary range: one numbered contact sheet
    \\                   per script instead of the files
    \\  --tile <px>      Contact sheet tile width (default 320)
    \\  -j <n>           Renders at once, across all scripts and
    \\                   variations (default: CPU count)
    \\  -h, --help       Show this help
    \\
    \\Made-up names are <script>.<fmt>, <script>-<n>.<fmt> with --vary
    \\(n zero-padded to the widest variation in the run), and
    \\<script>-sheet.<fmt> with --sheet.
    \\
    \\An SVG shows exactly what the PNG shows, so a canvas SVG cannot
    \\draw, such as one with a post pass, is an error and no file is
    \\written.
    \\
    \\Options and script args apply to every script. Each script runs in
    \\its own Lua state, and one failing does not stop the others.
    \\
    \\Examples:
    \\  genpuin a.lua                         a.png
    \\  genpuin a.lua -o cover.svg            cover.svg
    \\  genpuin a.lua b.lua -d out            out/a.png out/b.png
    \\  genpuin a.lua --vary 1..16 -d picks   picks/a-01.png to a-16.png
    \\  genpuin a.lua --vary 1..64 --sheet    a-sheet.png
    \\
;

const Args = struct {
    scripts: []const [:0]const u8 = &.{},
    output: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    format: ?Format = null,
    scale: f64 = 1,
    ss: u32 = 1,
    depth: genpuin.image_io.Depth = .@"8",
    vary: ?i64 = null,
    vary_hi: ?i64 = null,
    sheet: bool = false,
    tile: ?u32 = null,
    jobs: ?u32 = null,
    vector_only: bool = false,
    script_args: []const []const u8 = &.{},

    /// Variations each script renders: the --vary range, or 1.
    fn variationCount(a: *const Args) usize {
        const hi = a.vary_hi orelse return 1;
        return @intCast(hi - a.vary.? + 1);
    }

    /// The variation job `index` of a script renders.
    fn variation(a: *const Args, index: usize) i64 {
        return (a.vary orelse 0) + @as(i64, @intCast(index));
    }
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

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn parseArgs(arena: Allocator, argv: []const [:0]const u8, diag: *Io.Writer) ParseError!Args {
    var scripts: std.ArrayList([:0]const u8) = .empty;
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            return error.Help;
        } else if (eql(arg, "--")) {
            a.script_args = argv[i + 1 ..];
            break;
        } else if (eql(arg, "--vector-only")) {
            a.vector_only = true;
        } else if (eql(arg, "--sheet")) {
            a.sheet = true;
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
    const valued = [_][]const u8{ "-o", "-d", "-f", "-s", "--ss", "--depth", "--vary", "--tile", "-j" };
    for (valued) |v| if (eql(name, v)) return true;
    return false;
}

fn parseOption(a: *Args, name: []const u8, v: []const u8, diag: *Io.Writer) UsageError!void {
    if (eql(name, "-o")) {
        if (v.len == 0) return usageError(diag, "-o needs a file name", .{});
        a.output = v;
    } else if (eql(name, "-d")) {
        if (v.len == 0) return usageError(diag, "-d needs a directory", .{});
        a.dir = v;
    } else if (eql(name, "-f")) {
        a.format = std.meta.stringToEnum(Format, v) orelse
            return usageError(diag, "-f is png, ppm or svg", .{});
    } else if (eql(name, "-s")) {
        a.scale = std.fmt.parseFloat(f64, v) catch return usageError(diag, "-s needs a number", .{});
        if (!(a.scale > 0)) return usageError(diag, "-s must be positive", .{});
    } else if (eql(name, "--ss")) {
        a.ss = std.fmt.parseInt(u32, v, 10) catch return usageError(diag, "--ss needs an integer", .{});
        if (a.ss < 1 or a.ss > 16) return usageError(diag, "--ss must be 1 to 16", .{});
    } else if (eql(name, "--depth")) {
        a.depth = if (eql(v, "16")) .@"16" else if (eql(v, "8")) .@"8" else return usageError(diag, "--depth is 8 or 16", .{});
    } else if (eql(name, "--vary")) {
        if (std.mem.indexOf(u8, v, "..")) |dots| {
            a.vary = std.fmt.parseInt(i64, v[0..dots], 10) catch return usageError(diag, "bad --vary range", .{});
            a.vary_hi = std.fmt.parseInt(i64, v[dots + 2 ..], 10) catch return usageError(diag, "bad --vary range", .{});
            if (a.vary_hi.? < a.vary.?) return usageError(diag, "--vary range is backwards", .{});
        } else {
            a.vary = std.fmt.parseInt(i64, v, 10) catch return usageError(diag, "--vary needs an integer", .{});
            a.vary_hi = null;
        }
    } else if (eql(name, "--tile")) {
        a.tile = std.fmt.parseInt(u32, v, 10) catch return usageError(diag, "--tile needs an integer", .{});
        if (a.tile.? < 1) return usageError(diag, "--tile must be at least 1", .{});
    } else if (eql(name, "-j")) {
        a.jobs = std.fmt.parseInt(u32, v, 10) catch return usageError(diag, "-j needs an integer", .{});
        if (a.jobs.? < 1) return usageError(diag, "-j must be at least 1", .{});
    } else {
        unreachable; // takesValue lists every option handled here
    }
}

/// Where every render goes, decided before anything renders.
const Plan = struct {
    /// One file per job in job order, or with --sheet one sheet per
    /// script.
    outputs: []const []const u8,
    /// The directory -d names, to create up front.
    dir: ?[]const u8,
};

fn planOutputs(arena: Allocator, a: *const Args, diag: *Io.Writer) (UsageError || Allocator.Error)!Plan {
    assert(a.scripts.len > 0);
    if (a.sheet and a.vary_hi == null) return usageError(diag, "--sheet needs a --vary range such as 1..16", .{});
    if (a.tile != null and !a.sheet) return usageError(diag, "--tile sets the contact sheet tile width, so it needs --sheet", .{});
    if (a.output != null and a.dir != null) return usageError(diag, "-o names one file and -d a directory for made-up names. Use one of them", .{});

    const per_script = if (a.sheet) 1 else a.variationCount();
    const count = a.scripts.len * per_script;
    const format = if (a.output) |file| try outputFormat(a, file, count, diag) else a.format orelse .png;
    if (a.vector_only) {
        if (a.sheet) return usageError(diag, "--vector-only cannot make a contact sheet", .{});
        if (format != .svg) return usageError(diag, "--vector-only needs an SVG output (-o file.svg or -f svg)", .{});
    }
    if (a.sheet and format == .svg) return usageError(diag, "a contact sheet cannot be an SVG", .{});

    const outputs = try arena.alloc([]const u8, count);
    if (a.output) |file| {
        assert(count == 1);
        outputs[0] = file;
        return .{ .outputs = outputs, .dir = null };
    }
    const width = variationWidth(a);
    for (a.scripts, 0..) |script, s| {
        for (outputs[s * per_script ..][0..per_script], 0..) |*out, v| {
            const name = try madeUpName(arena, std.fs.path.stem(script), a, width, v, format);
            out.* = if (a.dir) |d| try std.fs.path.join(arena, &.{ d, name }) else name;
        }
    }
    for (outputs, 0..) |out, i| for (outputs[0..i], 0..) |earlier, j| {
        if (std.ascii.eqlIgnoreCase(out, earlier)) {
            return usageError(diag, "{s} and {s} would both write {s}", .{
                a.scripts[j / per_script], a.scripts[i / per_script], out,
            });
        }
    };
    return .{ .outputs = outputs, .dir = a.dir };
}

/// The format of the one file -o names, checked against the run.
fn outputFormat(a: *const Args, file: []const u8, count: usize, diag: *Io.Writer) UsageError!Format {
    if (std.fs.path.isSep(file[file.len - 1])) {
        return usageError(diag, "-o {s} is a directory. Use -d {s} for a directory", .{ file, file });
    }
    if (count > 1) {
        return usageError(diag, "-o {s} names one file, but this run writes {d}. Use -d <dir> for a directory", .{ file, count });
    }
    const named = Format.fromPath(file) orelse
        return usageError(diag, "-o {s} needs a .png, .ppm or .svg extension", .{file});
    if (a.format) |f| {
        if (f != named) return usageError(diag, "-f {t} conflicts with -o {s}, which is {t}", .{ f, file, named });
    }
    return named;
}

/// Digits in the widest variation of a run, so names sort in order.
fn variationWidth(a: *const Args) usize {
    const lo = a.vary orelse return 0;
    const hi = a.vary_hi orelse lo;
    return @max(digitCount(@abs(lo)), digitCount(@abs(hi)));
}

fn digitCount(n: u64) usize {
    var digits: usize = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) digits += 1;
    return digits;
}

/// `<stem>[-<variation>].<format>`, or `<stem>-sheet.<format>`.
fn madeUpName(arena: Allocator, stem: []const u8, a: *const Args, width: usize, index: usize, format: Format) Allocator.Error![]const u8 {
    if (a.sheet) return std.fmt.allocPrint(arena, "{s}-sheet.{t}", .{ stem, format });
    if (a.vary == null) return std.fmt.allocPrint(arena, "{s}.{t}", .{ stem, format });
    const v = a.variation(index);
    return std.fmt.allocPrint(arena, "{[stem]s}-{[sign]s}{[abs]d:0>[width]}.{[format]t}", .{
        .stem = stem,
        .sign = if (v < 0) "-" else "",
        .abs = @abs(v),
        .width = width,
        .format = format,
    });
}

/// -o must name a file, which an existing directory is not.
fn refuseDirectoryOutput(io: Io, a: *const Args, diag: *Io.Writer) UsageError!void {
    const file = a.output orelse return;
    const stat = Io.Dir.cwd().statFile(io, file, .{}) catch return;
    if (stat.kind == .directory) {
        return usageError(diag, "-o {s} is a directory. Use -d {s} for a directory", .{ file, file });
    }
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
    refuseDirectoryOutput(io, &args, &diag) catch fail("{s}", .{diag.buffered()});
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
/// `i / variations` at variation `i % variations` of the range.
const Batch = struct {
    gpa: Allocator,
    io: Io,
    args: *const Args,
    lua_dir: ?[]const u8,
    outputs: []const []const u8,
    /// One argv per script for its global `arg`.
    argvs: []const []const []const u8,
    /// 1 unless --vary names a range.
    variations: usize,
    /// Rendered tiles in job order for --sheet, otherwise empty.
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
        const variations = a.variationCount();
        const job_count = a.scripts.len * variations;
        assert(opts.outputs.len == if (a.sheet) a.scripts.len else job_count);

        const argvs = try arena.alloc([]const []const u8, a.scripts.len);
        for (argvs, a.scripts) |*av, script| {
            const list = try arena.alloc([]const u8, 2 + a.script_args.len);
            list[0] = opts.exe;
            list[1] = script;
            @memcpy(list[2..], a.script_args);
            av.* = list;
        }
        const tiles = try arena.alloc(?genpuin.Raster, if (a.sheet) job_count else 0);
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
        const vary = b.args.variation(i % b.variations);
        var report: Io.Writer.Allocating = .init(b.gpa);
        defer report.deinit();
        const w = &report.writer;

        const target: Target = if (b.args.sheet)
            .{ .tile = .{ .width = b.args.tile orelse 320, .out = &b.tiles[i] } }
        else
            .{ .file = b.outputs[i] };
        var ok = true;
        b.runOne(script, vary, target, w) catch |err| {
            ok = false;
            if (b.args.vary_hi != null) w.print("vary {d} failed: {t}\n", .{ vary, err }) catch {};
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
            // A missing tile would leave a hole in the sheet. A missing
            // file is what `--vary n` alone does, so it stays silent.
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
                        const fix: SvgFix = if (err == error.SvgUnsupported)
                            .none
                        else if (b.args.output != null) .{ .png_file = out } else .png_format;
                        try printSvgRefusal(w, problem, fix);
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
        if (!b.args.sheet) return ok;
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
            st.* = .{ .raster = t, .label = b.args.variation(i) };
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

/// The way out a refused SVG suggests.
const SvgFix = union(enum) {
    /// No raster-only feature to blame, so no hint.
    none,
    /// The run has made-up names, so -f picks the format.
    png_format,
    /// The SVG file -o names.
    png_file: []const u8,
};

/// A post pass gets a second line with both ways out.
fn printSvgRefusal(w: *Io.Writer, problem: []const u8, fix: SvgFix) !void {
    try w.print("{s}\n", .{problem});
    switch (fix) {
        .none => {},
        .png_format => try w.print("  (use -f png, or --vector-only to export just the shapes)\n", .{}),
        .png_file => |path| {
            const stem = path[0 .. path.len - std.fs.path.extension(path).len];
            try w.print("  (use -o {s}.png, or --vector-only to export just the shapes)\n", .{stem});
        },
    }
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

test "main: a post pass refusal with -o points at the PNG file and --vector-only" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try printSvgRefusal(&w, "fh.lua:45: gen.post.pixelSort needs pixels and has no vector form", .{ .png_file = "out/fh.svg" });
    try std.testing.expectEqualStrings(
        "fh.lua:45: gen.post.pixelSort needs pixels and has no vector form\n" ++
            "  (use -o out/fh.png, or --vector-only to export just the shapes)\n",
        w.buffered(),
    );
}

test "main: a post pass refusal with made-up names points at -f png" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try printSvgRefusal(&w, "fh.lua:45: gen.post.pixelSort needs pixels and has no vector form", .png_format);
    try std.testing.expectEqualStrings(
        "fh.lua:45: gen.post.pixelSort needs pixels and has no vector form\n" ++
            "  (use -f png, or --vector-only to export just the shapes)\n",
        w.buffered(),
    );
}

test "main: other refusals have no hint" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try printSvgRefusal(&w, "draw 3 (circle): blendMode 'add' has no SVG form. Write a PNG instead", .none);
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

/// The arguments `argv` parses to, with the program name filled in.
fn testArgs(arena: Allocator, argv: []const [:0]const u8, diag: *Io.Writer) !*const Args {
    const full = try arena.alloc([:0]const u8, argv.len + 1);
    full[0] = "genpuin";
    @memcpy(full[1..], argv);
    const args = try arena.create(Args);
    args.* = try parseArgs(arena, full, diag);
    return args;
}

/// The outputs `argv` plans, or the usage error it makes.
fn testPlan(arena: Allocator, argv: []const [:0]const u8, diag: *Io.Writer) !Plan {
    return planOutputs(arena, try testArgs(arena, argv, diag), diag);
}

fn expectOutputs(argv: []const [:0]const u8, expected: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const plan = try testPlan(arena_state.allocator(), argv, &diag);
    try std.testing.expectEqual(expected.len, plan.outputs.len);
    for (expected, plan.outputs) |e, o| try std.testing.expectEqualStrings(e, o);
}

fn expectUsage(argv: []const [:0]const u8, message: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Usage, testPlan(arena_state.allocator(), argv, &diag));
    try std.testing.expectEqualStrings(message, diag.buffered());
}

test "main: one script writes its stem in the current directory" {
    try expectOutputs(&.{"art/a.lua"}, &.{"a.png"});
    try expectOutputs(&.{ "art/a.lua", "-f", "svg" }, &.{"a.svg"});
    try expectOutputs(&.{ "art/a.lua", "-f", "ppm" }, &.{"a.ppm"});
}

test "main: -o writes exactly the file it names" {
    try expectOutputs(&.{ "art/a.lua", "-o", "x/b.ppm" }, &.{"x/b.ppm"});
    try expectOutputs(&.{ "art/a.lua", "-o", "x/b.ppm", "-f", "ppm" }, &.{"x/b.ppm"});
    try expectOutputs(&.{ "art/a.lua", "-o", "cover.SVG" }, &.{"cover.SVG"});
    try expectOutputs(&.{ "art/a.lua", "-o", "seven.png", "--vary", "7" }, &.{"seven.png"});
    try expectOutputs(&.{ "art/a.lua", "-o", "s.png", "--vary", "1..4", "--sheet" }, &.{"s.png"});
}

test "main: -d holds the made-up names" {
    try expectOutputs(&.{ "art/a.lua", "-d", "out" }, &.{"out/a.png"});
    try expectOutputs(&.{ "art/a.lua", "-d", "out/" }, &.{"out/a.png"});
    try expectOutputs(&.{ "a.lua", "sub/b.lua", "-d", "out", "-f", "ppm" }, &.{ "out/a.ppm", "out/b.ppm" });
    try expectOutputs(&.{ "a.lua", "sub/b.lua", "c.lua" }, &.{ "a.png", "b.png", "c.png" });
    try expectOutputs(&.{ "a.lua", "b.lua", "-f", "svg", "--vector-only" }, &.{ "a.svg", "b.svg" });
}

test "main: the -d plan names the directory to create" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const with = try testPlan(arena_state.allocator(), &.{ "a.lua", "-d", "picks" }, &diag);
    try std.testing.expectEqualStrings("picks", with.dir.?);
    const without = try testPlan(arena_state.allocator(), &.{ "a.lua", "-o", "a.png" }, &diag);
    try std.testing.expect(without.dir == null);
}

test "main: --vary names every file with its variation" {
    try expectOutputs(&.{ "a.lua", "--vary", "7" }, &.{"a-7.png"});
    try expectOutputs(&.{ "a.lua", "--vary", "12", "-f", "svg" }, &.{"a-12.svg"});
    try expectOutputs(&.{ "a.lua", "--vary", "2..4" }, &.{ "a-2.png", "a-3.png", "a-4.png" });
    try expectOutputs(&.{ "a.lua", "b.lua", "--vary", "1..2", "-d", "out" }, &.{
        "out/a-1.png", "out/a-2.png", "out/b-1.png", "out/b-2.png",
    });
    try expectOutputs(&.{ "a.lua", "--vary", "-2..1" }, &.{ "a--2.png", "a--1.png", "a-0.png", "a-1.png" });
}

test "main: variations are zero-padded to the widest in the run" {
    try expectOutputs(&.{ "a.lua", "--vary", "8..11" }, &.{ "a-08.png", "a-09.png", "a-10.png", "a-11.png" });
    try expectOutputs(&.{ "a.lua", "--vary", "99..100", "-f", "ppm" }, &.{ "a-099.ppm", "a-100.ppm" });
    try expectOutputs(&.{ "a.lua", "--vary", "-12..-11" }, &.{ "a--12.png", "a--11.png" });

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const plan = try testPlan(arena_state.allocator(), &.{ "a.lua", "--vary", "1..16", "-d", "picks" }, &diag);
    try std.testing.expectEqual(@as(usize, 16), plan.outputs.len);
    try std.testing.expectEqualStrings("picks/a-01.png", plan.outputs[0]);
    try std.testing.expectEqualStrings("picks/a-09.png", plan.outputs[8]);
    try std.testing.expectEqualStrings("picks/a-16.png", plan.outputs[15]);
}

test "main: --sheet writes one sheet per script" {
    try expectOutputs(&.{ "art/a.lua", "--vary", "1..4", "--sheet" }, &.{"a-sheet.png"});
    try expectOutputs(&.{ "a.lua", "b.lua", "--vary", "0..3", "--sheet", "-d", "out", "--tile", "100" }, &.{
        "out/a-sheet.png", "out/b-sheet.png",
    });
    try expectOutputs(&.{ "a.lua", "--vary", "1..64", "--sheet", "-f", "ppm" }, &.{"a-sheet.ppm"});
}

test "main: -o refuses a run with several outputs and suggests -d" {
    try expectUsage(&.{ "a.lua", "b.lua", "-o", "out.png" }, "-o out.png names one file, but this run writes 2. Use -d <dir> for a directory");
    try expectUsage(&.{ "a.lua", "-o", "out.png", "--vary", "1..16" }, "-o out.png names one file, but this run writes 16. Use -d <dir> for a directory");
    try expectUsage(&.{ "a.lua", "b.lua", "-o", "s.png", "--vary", "1..4", "--sheet" }, "-o s.png names one file, but this run writes 2. Use -d <dir> for a directory");
    try expectUsage(&.{ "a.lua", "-o", "out/" }, "-o out/ is a directory. Use -d out/ for a directory");
    try expectUsage(&.{ "a.lua", "-o", "plain" }, "-o plain needs a .png, .ppm or .svg extension");
    try expectUsage(&.{ "a.lua", "-o", "a.png", "-d", "out" }, "-o names one file and -d a directory for made-up names. Use one of them");
}

test "main: -f must agree with the -o extension" {
    try expectUsage(&.{ "a.lua", "-o", "a.svg", "-f", "png" }, "-f png conflicts with -o a.svg, which is svg");
    try expectUsage(&.{ "a.lua", "-o", "a.png", "-f", "ppm" }, "-f ppm conflicts with -o a.png, which is png");
    try expectUsage(&.{ "a.lua", "-f", "gif" }, "-f is png, ppm or svg");
}

test "main: --sheet and --tile need each other and a range" {
    try expectUsage(&.{ "a.lua", "--sheet" }, "--sheet needs a --vary range such as 1..16");
    try expectUsage(&.{ "a.lua", "--vary", "3", "--sheet" }, "--sheet needs a --vary range such as 1..16");
    try expectUsage(&.{ "a.lua", "--vary", "1..3", "--tile", "200" }, "--tile sets the contact sheet tile width, so it needs --sheet");
    try expectUsage(&.{ "a.lua", "--vary", "1..3", "--sheet", "-f", "svg" }, "a contact sheet cannot be an SVG");
    try expectUsage(&.{ "a.lua", "--vary", "1..3", "--sheet", "-o", "s.svg" }, "a contact sheet cannot be an SVG");
    try expectUsage(&.{ "a.lua", "--vary", "1..3", "--sheet", "--tile", "0" }, "--tile must be at least 1");
}

test "main: duplicate outputs are caught without regard to case" {
    try expectUsage(&.{ "a.lua", "sub/a.lua", "-d", "out" }, "a.lua and sub/a.lua would both write out/a.png");
    try expectUsage(&.{ "x/a.lua", "y/a.lua" }, "x/a.lua and y/a.lua would both write a.png");
    try expectUsage(&.{ "A.lua", "a.lua" }, "A.lua and a.lua would both write a.png");
    try expectUsage(&.{ "x/A.lua", "a.lua", "--vary", "1..2" }, "x/A.lua and a.lua would both write a-1.png");
    try expectUsage(&.{ "a.lua", "x/A.lua", "--vary", "1..2", "--sheet" }, "a.lua and x/A.lua would both write A-sheet.png");
}

test "main: other usage errors are caught before rendering" {
    try expectUsage(&.{ "a.lua", "-j", "0" }, "-j must be at least 1");
    try expectUsage(&.{ "a.lua", "-o" }, "-o needs a value");
    try expectUsage(&.{ "a.lua", "-d", "" }, "-d needs a directory");
    try expectUsage(&.{ "a.lua", "--bogus" }, "unknown option: --bogus");
    try expectUsage(&.{ "a.lua", "--format", "svg" }, "unknown option: --format");
    try expectUsage(&.{ "a.lua", "--vary", "4..2" }, "--vary range is backwards");
}

test "main: --vector-only needs an SVG output" {
    try expectOutputs(&.{ "a.lua", "-o", "a.svg", "--vector-only" }, &.{"a.svg"});
    try expectOutputs(&.{ "a.lua", "-f", "svg", "--vary", "1..2", "--vector-only" }, &.{ "a-1.svg", "a-2.svg" });
    try expectUsage(&.{ "a.lua", "-o", "a.png", "--vector-only" }, "--vector-only needs an SVG output (-o file.svg or -f svg)");
    try expectUsage(&.{ "a.lua", "--vector-only" }, "--vector-only needs an SVG output (-o file.svg or -f svg)");
    try expectUsage(&.{ "a.lua", "--vector-only", "--vary", "0..3", "--sheet" }, "--vector-only cannot make a contact sheet");
}

test "main: -o refuses an existing directory and suggests -d" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "art.png");
    try tmp.dir.writeFile(io, .{ .sub_path = "old.png", .data = "x" });

    const dir = try std.fmt.allocPrintSentinel(arena, "{s}/{s}/art.png", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path }, 0);
    var buf: [512]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Usage, refuseDirectoryOutput(io, try testArgs(arena, &.{ "a.lua", "-o", dir }, &diag), &diag));
    const expected = try std.fmt.allocPrint(arena, "-o {s} is a directory. Use -d {s} for a directory", .{ dir, dir });
    try std.testing.expectEqualStrings(expected, diag.buffered());

    const file = try std.fmt.allocPrintSentinel(arena, "{s}/{s}/old.png", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path }, 0);
    try refuseDirectoryOutput(io, try testArgs(arena, &.{ "a.lua", "-o", file }, &diag), &diag);
    try refuseDirectoryOutput(io, try testArgs(arena, &.{ "a.lua", "-o", "missing/new.png" }, &diag), &diag);
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

/// Render `scripts` with `options` in one batch and return each output's
/// bytes in plan order.
fn testRender(arena: Allocator, scripts: []const [:0]const u8, jobs: u32, options: []const []const u8) ![]const []const u8 {
    const io = std.testing.io;
    var argv: std.ArrayList([:0]const u8) = .empty;
    try argv.appendSlice(arena, scripts);
    for (options) |o| try argv.append(arena, try arena.dupeSentinel(u8, o, 0));

    var buf: [256]u8 = undefined;
    var diag: Io.Writer = .fixed(&buf);
    const args = try testArgs(arena, argv.items, &diag);
    const plan = try planOutputs(arena, args, &diag);
    if (plan.dir) |d| try Io.Dir.cwd().createDirPath(io, d);
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

test "main: a batch renders each script and variation byte for byte as it renders alone" {
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

    const sweeps = [_][]const []const u8{ &.{}, &.{ "--vary", "2..4", "--sheet" } };
    for (sweeps, 0..) |sweep, k| {
        var alone: [names.len][]const u8 = undefined;
        for (&alone, scripts, 0..) |*a, s, i| {
            const dir = try std.fmt.allocPrint(arena, "{s}/alone{d}-{d}", .{ root, k, i });
            const options = try std.mem.concat(arena, []const u8, &.{ sweep, &.{ "-d", dir } });
            a.* = (try testRender(arena, &.{s}, 1, options))[0];
        }
        for ([_]u32{ 1, 4 }) |jobs| {
            const dir = try std.fmt.allocPrint(arena, "{s}/j{d}-{d}", .{ root, jobs, k });
            const options = try std.mem.concat(arena, []const u8, &.{ sweep, &.{ "-d", dir } });
            const together = try testRender(arena, &scripts, jobs, options);
            for (alone, together) |a, t| try std.testing.expectEqualSlices(u8, a, t);
        }
    }

    const variations = [_][]const u8{ "2", "3", "4" };
    var alone: [names.len * variations.len][]const u8 = undefined;
    for (scripts, 0..) |s, i| for (variations, 0..) |v, j| {
        const file = try std.fmt.allocPrint(arena, "{s}/alone-{d}-{s}.png", .{ root, i, v });
        alone[i * variations.len + j] = (try testRender(arena, &.{s}, 1, &.{ "--vary", v, "-o", file }))[0];
    };
    for ([_]u32{ 1, 4 }) |jobs| {
        const dir = try std.fmt.allocPrint(arena, "{s}/files-j{d}", .{ root, jobs });
        const together = try testRender(arena, &scripts, jobs, &.{ "--vary", "2..4", "-d", dir });
        try std.testing.expectEqual(alone.len, together.len);
        for (alone, together) |a, t| try std.testing.expectEqualSlices(u8, a, t);
    }
    try std.testing.expect(!std.mem.eql(u8, alone[0], alone[1]));
}

test {
    _ = @import("lua/host.zig");
    _ = @import("lua/bind_math.zig");
    _ = @import("lua/bind_testing.zig");
    _ = @import("lua/util.zig");
    _ = @import("lua/marshal.zig");
    _ = @import("lua/core.zig");
}
