//! The native module, imported by the prelude as "core". Top-level
//! functions render and export canvases. Each extension registers a
//! subtable (core.field, core.post, ...) from its own bind_*.zig file.

const std = @import("std");
const assert = std.debug.assert;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const marshal = @import("marshal.zig");
const util = @import("util.zig");
const Lua = util.Lua;

const groups = .{
    .{ "field", @import("bind_field.zig") },
    .{ "post", @import("bind_passes.zig") },
    .{ "texture", @import("bind_texture.zig") },
    .{ "sim", @import("bind_sim.zig") },
    .{ "pathops", @import("bind_pathops.zig") },
    .{ "wfc", @import("bind_wfc.zig") },
    .{ "algo", @import("bind_algo.zig") },
    .{ "xform", @import("bind_xform.zig") },
};

const top = [_]zlua.FnReg{
    .{ .name = "export", .func = zlua.wrap(exportCanvas) },
    .{ .name = "exportSvg", .func = zlua.wrap(exportSvgLua) },
    .{ .name = "closest", .func = zlua.wrap(closest) },
};

pub fn open(lua: *Lua) i32 {
    lua.newTable();
    util.setFuncs(lua, &top);
    inline for (groups) |g| {
        lua.newTable();
        util.setFuncs(lua, &g[1].functions);
        lua.setField(-2, g[0]);
    }
    return 1;
}

pub const RenderOptions = struct {
    /// Output width in pixels, the height following the canvas aspect.
    /// Null renders one pixel per canvas unit.
    width: ?u32 = null,
    ss: u32 = 1,
    depth: genpuin.image_io.Depth = .@"8",
    /// SVG only: leave post passes out instead of refusing the canvas.
    vector_only: bool = false,
};

pub fn readRenderOptions(lua: *Lua, index: i32) RenderOptions {
    const ss = util.optInt(lua, index, "ss", 1);
    if (ss < 1 or ss > 16) lua.raiseErrorStr("ss must be 1 to 16", .{});
    const depth = util.optInt(lua, index, "depth", 8);
    return .{
        .width = optWidth(lua, index),
        .ss = @intCast(ss),
        .depth = if (depth == 16) .@"16" else .@"8",
        .vector_only = util.optBool(lua, index, "vectorOnly", false),
    };
}

/// Option `width`: absent, or a whole number of pixels from 1 to
/// render.side_max.
fn optWidth(lua: *Lua, index: i32) ?u32 {
    if (!lua.isTable(index)) return null;
    defer lua.pop(1);
    switch (lua.getField(index, "width")) {
        .nil, .none => return null,
        .number => {
            const n = lua.toNumber(-1) catch unreachable; // type checked by the switch
            if (n >= 1 and n <= genpuin.render.side_max and @floor(n) == n) return @intFromFloat(n);
        },
        else => {},
    }
    lua.raiseErrorStr("option 'width' must be a whole number of pixels from 1 to %d", .{@as(c_int, genpuin.render.side_max)});
}

/// Render the canvas at `index` with the Lua state's allocator. A Lua
/// error while reading the canvas returns error.CanvasFailed, and an
/// output over render.side_max error.TooLarge, each with the message
/// pushed on top of the stack.
pub fn renderCanvas(lua: *Lua, index: i32, opts: RenderOptions) !genpuin.Raster {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var call: MarshalCall = .{ .arena = arena_state.allocator() };
    const canvas = lua.absIndex(index);
    lua.pushFunction(zlua.wrap(marshalProtected));
    lua.pushLightUserdata(&call);
    lua.pushValue(canvas);
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch return error.CanvasFailed;

    const s = &call.scene;
    const scale = if (opts.width) |w| genpuin.render.scaleForWidth(s.w, w) else 1;
    const size = genpuin.render.outputSize(s.w, s.h, scale);
    if (opts.width) |w| assert(size.w == w);
    if (!size.fits()) {
        _ = lua.pushString(try tooLargeMessage(arena_state.allocator(), s, opts.width, size));
        return error.TooLarge;
    }
    return genpuin.render.render(gpa, s, .{ .scale = scale, .ss = opts.ss });
}

fn tooLargeMessage(arena: std.mem.Allocator, s: *const genpuin.scene.Scene, width: ?u32, size: genpuin.render.Size) ![]const u8 {
    const limit = genpuin.render.side_max;
    if (width) |w| {
        return std.fmt.allocPrint(arena, "width {d} on a {d}x{d} canvas makes a {d}x{d} image, over the {d} px limit on a side", .{ w, s.w, s.h, size.w, size.h, limit });
    }
    return std.fmt.allocPrint(arena, "a {d}x{d} canvas makes a {d}x{d} image, over the {d} px limit on a side", .{ s.w, s.h, size.w, size.h, limit });
}

pub const SvgError = error{
    /// The canvas is malformed. The Lua error message is on the stack.
    CanvasFailed,
    /// A post pass needs pixels. Its line is on the stack.
    SvgNeedsPixels,
    /// A draw SVG cannot show. Its message is on the stack.
    SvgUnsupported,
};

/// Write the canvas at `index` to `path` as SVG and return how many post
/// passes were left out, which is zero unless `vector_only` allows it.
/// Nothing is written when the canvas cannot be shown exactly.
pub fn exportSvg(lua: *Lua, index: i32, path: []const u8, opts: RenderOptions) !usize {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var call: MarshalCall = .{ .arena = arena };
    const canvas = lua.absIndex(index);
    lua.pushFunction(zlua.wrap(marshalProtected));
    lua.pushLightUserdata(&call);
    lua.pushValue(canvas);
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch return error.CanvasFailed;

    var s = call.scene;
    const left_out = if (opts.vector_only) genpuin.svg.passCount(&s) else 0;
    if (opts.vector_only) s = try genpuin.svg.withoutPasses(arena, &s);
    if (genpuin.svg.check(&s)) |problem| {
        _ = lua.pushString(try std.fmt.allocPrint(arena, "{f}", .{problem}));
        return switch (problem) {
            .pass => error.SvgNeedsPixels,
            .draw => error.SvgUnsupported,
        };
    }
    var doc: std.Io.Writer.Allocating = .init(arena);
    try genpuin.svg.write(gpa, &doc.writer, &s, .{ .width = opts.width });
    const io = util.getHost(lua).io;
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc.written() });
    return left_out;
}

/// exportSvg(canvas, path, {vectorOnly, width}) -> passes left out, or
/// nil and a message when the canvas cannot be written. A malformed
/// canvas raises.
fn exportSvgLua(lua: *Lua) !i32 {
    const path = lua.toString(2) catch lua.argError(2, "expected an output path");
    const left_out = exportSvg(lua, 1, path, readRenderOptions(lua, 3)) catch |err| switch (err) {
        error.CanvasFailed => lua.raiseError(),
        error.SvgNeedsPixels, error.SvgUnsupported => {
            lua.pushNil();
            lua.insert(-2);
            _ = lua.pushString(if (err == error.SvgNeedsPixels) "pass" else "draw");
            return 3;
        },
        else => return err,
    };
    lua.pushInteger(@intCast(left_out));
    return 1;
}

/// Marshal raises Lua errors, which longjmp past Zig frames. Running it
/// under a protected call keeps them away from the C API's panic handler
/// and lets renderCanvas free the arena.
const MarshalCall = struct {
    arena: std.mem.Allocator,
    scene: genpuin.scene.Scene = undefined,
};

fn marshalProtected(lua: *Lua) !i32 {
    const call = lua.toUserdata(MarshalCall, 1) catch unreachable; // pushed by renderCanvas
    call.scene = try marshal.canvas(lua, call.arena, 2);
    return 0;
}

/// export(canvas, path, {width, ss, depth}) writes PPM or PNG by extension.
fn exportCanvas(lua: *Lua) !i32 {
    const path = lua.toString(2) catch lua.argError(2, "expected an output path");
    const opts = readRenderOptions(lua, 3);
    var r = renderCanvas(lua, 1, opts) catch |err| switch (err) {
        error.CanvasFailed, error.TooLarge => lua.raiseError(),
        else => return err,
    };
    defer r.deinit(lua.allocator());
    const h = util.getHost(lua);
    try genpuin.image_io.write(lua.allocator(), h.io, &r, path, opts.depth);
    return 0;
}

/// closest(name, t) -> the string key of t nearest to name, or nil when
/// none is close enough to be a likely typo. Ties go to the smaller key so
/// the answer does not depend on table order.
fn closest(lua: *Lua) i32 {
    const name = lua.checkString(1);
    lua.checkType(2, .table);
    var near: Nearest = .init(name);
    lua.pushNil();
    while (lua.next(2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        near.consider(lua.toString(-2) catch continue);
    }
    if (near.best) |b| _ = lua.pushString(b) else lua.pushNil();
    return 1;
}

/// The candidate nearest to `name` by edit distance, kept only when it is
/// close enough to be a likely typo.
pub const Nearest = struct {
    name: []const u8,
    limit: u32,
    best: ?[]const u8 = null,
    best_d: u32,

    pub fn init(name: []const u8) Nearest {
        const limit: u32 = if (name.len <= 3) 1 else 2;
        return .{ .name = name, .limit = limit, .best_d = limit + 1 };
    }

    pub fn consider(near: *Nearest, key: []const u8) void {
        const d = editDistance(near.name, key, near.limit) orelse return;
        if (d < near.best_d or (d == near.best_d and std.mem.lessThan(u8, key, near.best.?))) {
            near.best = key;
            near.best_d = d;
        }
    }
};

/// Optimal string alignment distance (Levenshtein plus adjacent
/// transpositions), or null when it exceeds `limit` or a string is longer
/// than the row buffers.
fn editDistance(a: []const u8, b: []const u8, limit: u32) ?u32 {
    const max_len = 64;
    if (a.len > max_len or b.len > max_len) return null;
    if (@max(a.len, b.len) - @min(a.len, b.len) > limit) return null;
    var rows: [3][max_len + 1]u32 = undefined;
    for (0..b.len + 1) |j| rows[0][j] = @intCast(j);
    for (a, 1..) |ca, i| {
        const prev2 = &rows[(i + 1) % 3];
        const prev = &rows[(i + 2) % 3];
        const cur = &rows[i % 3];
        cur[0] = @intCast(i);
        for (b, 1..) |cb, j| {
            const cost: u32 = @intFromBool(ca != cb);
            var d = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
            if (i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb) d = @min(d, prev2[j - 2] + 1);
            cur[j] = d;
        }
    }
    const d = rows[a.len % 3][b.len];
    return if (d <= limit) d else null;
}

test {
    inline for (groups) |g| _ = g[1];
}

test "core: edit distance counts a swap of neighbors as one edit" {
    try std.testing.expectEqual(@as(?u32, 1), editDistance("cirlce", "circle", 2));
    try std.testing.expectEqual(@as(?u32, 1), editDistance("stpe", "step", 2));
    try std.testing.expectEqual(@as(?u32, 0), editDistance("rect", "rect", 2));
    try std.testing.expectEqual(@as(?u32, 2), editDistance("polgon", "polygons", 2));
    try std.testing.expectEqual(@as(?u32, null), editDistance("noise", "voronoi", 2));
    try std.testing.expectEqual(@as(?u32, 3), editDistance("", "abc", 3));
}
