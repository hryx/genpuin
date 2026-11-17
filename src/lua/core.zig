//! The `genpuin.core` native module. Top-level functions render and
//! export canvases. Each extension registers a subtable (core.field,
//! core.post, ...) from its own bind_*.zig file.

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
};

const top = [_]zlua.FnReg{
    .{ .name = "export", .func = zlua.wrap(exportCanvas) },
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
