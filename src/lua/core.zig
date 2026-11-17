//! The native module, imported by the prelude as "core". Top-level
//! functions render and export canvases. Each extension registers a
//! subtable (core.field, core.post, ...) from its own bind_*.zig file.

const std = @import("std");

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
};

const top = [_]zlua.FnReg{
    .{ .name = "export", .func = zlua.wrap(exportCanvas) },
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
    lua.pushInteger(@intCast(util.getHost(lua).vary));
    lua.setField(-2, "vary");
    return 1;
}

pub const RenderOptions = struct {
    scale: f64 = 1,
    ss: u32 = 1,
    depth: genpuin.image_io.Depth = .@"8",
};

pub fn readRenderOptions(lua: *Lua, index: i32) RenderOptions {
    const ss = util.optInt(lua, index, "ss", 1);
    if (ss < 1 or ss > 16) lua.raiseErrorStr("ss must be 1 to 16", .{});
    const depth = util.optInt(lua, index, "depth", 8);
    return .{
        .scale = util.optNumber(lua, index, "scale", 1),
        .ss = @intCast(ss),
        .depth = if (depth == 16) .@"16" else .@"8",
    };
}

/// Render the canvas at `index` with the Lua state's allocator.
pub fn renderCanvas(lua: *Lua, index: i32, opts: RenderOptions) !genpuin.Raster {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const s = try marshal.canvas(lua, arena_state.allocator(), index);
    return genpuin.render.render(gpa, &s, .{ .scale = opts.scale, .ss = opts.ss });
}

/// export(canvas, path, {scale, ss, depth}) writes PPM or PNG by extension.
fn exportCanvas(lua: *Lua) !i32 {
    const path = lua.toString(2) catch lua.argError(2, "expected an output path");
    const opts = readRenderOptions(lua, 3);
    var r = try renderCanvas(lua, 1, opts);
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
    const limit: u32 = if (name.len <= 3) 1 else 2;
    var best: ?[]const u8 = null;
    var best_d: u32 = limit + 1;
    lua.pushNil();
    while (lua.next(2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch continue;
        const d = editDistance(name, key, limit) orelse continue;
        if (d < best_d or (d == best_d and std.mem.lessThan(u8, key, best.?))) {
            best = key;
            best_d = d;
        }
    }
    if (best) |b| _ = lua.pushString(b) else lua.pushNil();
    return 1;
}

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

test "core: edit distance counts a swap of neighbours as one edit" {
    try std.testing.expectEqual(@as(?u32, 1), editDistance("cirlce", "circle", 2));
    try std.testing.expectEqual(@as(?u32, 1), editDistance("stpe", "step", 2));
    try std.testing.expectEqual(@as(?u32, 0), editDistance("rect", "rect", 2));
    try std.testing.expectEqual(@as(?u32, 2), editDistance("polgon", "polygons", 2));
    try std.testing.expectEqual(@as(?u32, null), editDistance("noise", "voronoi", 2));
    try std.testing.expectEqual(@as(?u32, 3), editDistance("", "abc", 3));
}
