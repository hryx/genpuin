//! Read a Lua canvas table into a Scene. Everything lands in the arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const bind_passes = @import("bind_passes.zig");
const util = @import("util.zig");
const Lua = util.Lua;
const scene = genpuin.scene;

const Ctx = struct {
    lua: *Lua,
    arena: Allocator,
    items: std.ArrayList(scene.Item) = .empty,
    layers: std.ArrayList(scene.Layer) = .empty,
    color_map_keys: std.StringHashMapUnmanaged(u32) = .empty,
    /// One Gradient per Lua gradient table, so SVG export writes each once.
    gradients: std.AutoHashMapUnmanaged(*const anyopaque, *const scene.Gradient) = .empty,
};

/// Canvas at `index` to Scene. Lua errors are raised for malformed input.
pub fn canvas(lua: *Lua, arena: Allocator, index_in: i32) !scene.Scene {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("expected a canvas", .{});
    var ctx: Ctx = .{ .lua = lua, .arena = arena };

    const w = util.optNumber(lua, index, "width", 0);
    const h = util.optNumber(lua, index, "height", 0);
    if (!(w > 0 and h > 0)) lua.raiseErrorStr("canvas needs a positive width and height", .{});

    var bg: [3]f32 = .{ 0, 0, 0 };
    _ = lua.getField(index, "bg");
    if (util.readColor(lua, -1)) |c| bg = .{ c[0], c[1], c[2] };
    lua.pop(1);

    // gen.layer points c.elements at the newest layer's list, so skip it
    // when it is one of the layers already drawn.
    var layer_lists: std.ArrayList(?*const anyopaque) = .empty;
    if (lua.getField(index, "layers") == .table) {
        const layers = lua.absIndex(-1);
        for (1..util.len(lua, layers) + 1) |i| {
            _ = util.rawGet(lua, layers, i);
            const name = if (lua.getField(-1, "name") == .string) lua.toString(-1) catch unreachable else ""; // type checked by the condition
            const first = ctx.items.items.len;
            const name_owned = try arena.dupe(u8, name);
            lua.pop(1);
            _ = lua.getField(-1, "elements");
            try layer_lists.append(arena, lua.toPointer(-1));
            try elements(&ctx, -1);
            lua.pop(2);
            try ctx.layers.append(arena, .{ .name = name_owned, .item_first = first, .item_end = ctx.items.items.len });
        }
    }
    lua.pop(1);

    _ = lua.getField(index, "elements");
    const main = lua.toPointer(-1);
    const dup = for (layer_lists.items) |p| {
        if (p == main) break true;
    } else false;
    if (!dup) try elements(&ctx, -1);
    lua.pop(1);

    return .{ .w = w, .h = h, .bg = bg, .items = ctx.items.items, .layers = ctx.layers.items };
}

fn elements(ctx: *Ctx, index_in: i32) !void {
    const lua = ctx.lua;
    if (!lua.isTable(index_in)) return;
    const index = lua.absIndex(index_in);
    for (1..util.len(lua, index) + 1) |i| {
        _ = util.rawGet(lua, index, i);
        defer lua.pop(1);
        const el = lua.absIndex(-1);
        if (lua.getField(el, "pass") == .string) {
            const name = try ctx.arena.dupe(u8, lua.toString(-1) catch unreachable); // type checked by the condition
            lua.pop(1);
            _ = lua.getField(el, "opts");
            const pass = try bind_passes.parse(lua, ctx.arena, name, lua.absIndex(-1));
            lua.pop(1);
            const where = if (lua.getField(el, "where") == .string) lua.toString(-1) catch unreachable else ""; // type checked by the condition
            const post: scene.Post = .{ .pass = pass, .name = name, .where = try ctx.arena.dupe(u8, where) };
            lua.pop(1);
            try ctx.items.append(ctx.arena, .{ .pass = post });
            continue;
        }
        lua.pop(1);
        _ = lua.getField(el, "shape");
        const shape = try readShape(ctx, -1);
        lua.pop(1);
        _ = lua.getField(el, "style");
        const style = try readStyle(ctx, -1);
        lua.pop(1);
        try ctx.items.append(ctx.arena, .{ .draw = .{ .shape = shape, .style = style } });
    }
}

const ShapeType = enum { line, polyline, polygon, circle, ellipse, arc, rect, bezier, spline, compound, field };

fn num(ctx: *Ctx, index: i32, key: [:0]const u8) f64 {
    const lua = ctx.lua;
    defer lua.pop(1);
    if (lua.getField(index, key) != .number) lua.raiseErrorStr("shape field '%s' must be a number", .{key.ptr});
    return lua.toNumber(-1) catch unreachable; // type checked on the line above
}

fn vec(ctx: *Ctx, index: i32, key: [:0]const u8) scene.Vec2 {
    const lua = ctx.lua;
    defer lua.pop(1);
    _ = lua.getField(index, key);
    return util.readVec2(lua, -1) orelse lua.raiseErrorStr("shape field '%s' must be {x, y}", .{key.ptr});
}

fn points(ctx: *Ctx, index: i32, key: [:0]const u8) ![]scene.Vec2 {
    const lua = ctx.lua;
    _ = lua.getField(index, key);
    defer lua.pop(1);
    return util.readPoints(lua, ctx.arena, -1);
}

fn readShape(ctx: *Ctx, index_in: i32) !scene.Shape {
    const lua = ctx.lua;
    if (!lua.isTable(index_in)) lua.raiseErrorStr("draw needs a shape", .{});
    const index = lua.absIndex(index_in);
    _ = lua.getField(index, "type");
    const type_name = lua.toString(-1) catch lua.raiseErrorStr("shape has no type", .{});
    const t = std.meta.stringToEnum(ShapeType, type_name) orelse
        lua.raiseErrorStr("unknown shape type '%s'", .{type_name.ptr});
    lua.pop(1);
    return switch (t) {
        .line => .{ .line = .{ vec(ctx, index, "a"), vec(ctx, index, "b") } },
        .polyline => .{ .polyline = try points(ctx, index, "points") },
        .polygon => .{ .polygon = try points(ctx, index, "points") },
        .spline => .{ .spline = try points(ctx, index, "points") },
        .circle => .{ .circle = .{ .c = vec(ctx, index, "center"), .r = num(ctx, index, "r") } },
        .ellipse => .{ .ellipse = .{ .c = vec(ctx, index, "center"), .rx = num(ctx, index, "rx"), .ry = num(ctx, index, "ry") } },
        .arc => .{ .arc = .{
            .c = vec(ctx, index, "center"),
            .r = num(ctx, index, "r"),
            .start = num(ctx, index, "startAngle"),
            .end = num(ctx, index, "endAngle"),
        } },
        .rect => .{ .rect = .{
            .x = num(ctx, index, "x"),
            .y = num(ctx, index, "y"),
            .w = num(ctx, index, "w"),
            .h = num(ctx, index, "h"),
            .rx = util.optNumber(lua, index, "rx", 0),
            .ry = util.optNumber(lua, index, "ry", 0),
        } },
        .bezier => .{ .bezier = .{ vec(ctx, index, "p0"), vec(ctx, index, "p1"), vec(ctx, index, "p2"), vec(ctx, index, "p3") } },
        .compound => blk: {
            _ = lua.getField(index, "contours");
            defer lua.pop(1);
            const cs = try util.readContours(lua, ctx.arena, -1);
            break :blk .{ .compound = @ptrCast(cs) };
        },
        .field => .{ .field = try readFieldImage(ctx, index) },
    };
}

fn readFieldImage(ctx: *Ctx, index: i32) !scene.FieldImage {
    const lua = ctx.lua;
    _ = lua.getField(index, "field");
    const f = util.toField(lua, -1) orelse lua.raiseErrorStr("image shape needs a field", .{});
    lua.pop(1);
    _ = lua.getField(index, "palette");
    const stops = try util.readStops(lua, ctx.arena, -1);
    lua.pop(1);

    var range: ?[2]f32 = null;
    _ = lua.getField(index, "range");
    if (lua.isTable(-1)) {
        const lo = util.numberAt(lua, -1, 1) orelse 0;
        const hi = util.numberAt(lua, -1, 2) orelse 1;
        range = .{ @floatCast(lo), @floatCast(hi) };
    }
    lua.pop(1);

    var tone: scene.Tone = .linear;
    switch (lua.getField(index, "tone")) {
        .string => {
            const s = lua.toString(-1) catch unreachable; // type checked by the switch
            if (std.mem.eql(u8, s, "log")) tone = .{ .log = @floatCast(util.optNumber(lua, index, "toneK", 100)) };
        },
        .number => tone = .{ .gamma = @floatCast(lua.toNumber(-1) catch 1) },
        else => {},
    }
    lua.pop(1);

    return .{
        .field = f,
        .x = num(ctx, index, "x"),
        .y = num(ctx, index, "y"),
        .w = num(ctx, index, "w"),
        .h = num(ctx, index, "h"),
        .palette = stops,
        .range = range,
        .tone = tone,
        .smooth = util.optBool(lua, index, "smooth", true),
    };
}

fn readPaint(ctx: *Ctx, index: i32, key: [:0]const u8) !scene.Paint {
    const lua = ctx.lua;
    _ = lua.getField(index, key);
    defer lua.pop(1);
    if (!lua.isTable(-1)) return .none;
    if (util.readColor(lua, -1)) |c| return .{ .solid = c };
    const table = lua.toPointer(-1).?;
    if (ctx.gradients.get(table)) |g| return .{ .gradient = g };
    if (lua.getField(-1, "stops") != .table) {
        lua.pop(1);
        return .none;
    }
    const stops = try util.readStops(lua, ctx.arena, -1);
    lua.pop(1);
    const g = try ctx.arena.create(scene.Gradient);
    _ = lua.getField(-1, "type");
    const kind = lua.toString(-1) catch "";
    lua.pop(1);
    const t = lua.absIndex(-1);
    if (std.mem.eql(u8, kind, "radialGradient")) {
        g.* = .{ .geometry = .{ .radial = .{ .c = .{ num(ctx, t, "cx"), num(ctx, t, "cy") }, .r = num(ctx, t, "r") } }, .stops = stops };
    } else {
        g.* = .{ .geometry = .{ .linear = .{
            .a = .{ num(ctx, t, "x1"), num(ctx, t, "y1") },
            .b = .{ num(ctx, t, "x2"), num(ctx, t, "y2") },
        } }, .stops = stops };
    }
    try ctx.gradients.put(ctx.arena, table, g);
    return .{ .gradient = g };
}

fn readStyle(ctx: *Ctx, index_in: i32) !scene.Style {
    const lua = ctx.lua;
    var st: scene.Style = .{};
    if (!lua.isTable(index_in)) return st;
    const index = lua.absIndex(index_in);
    st.fill = try readPaint(ctx, index, "fill");
    st.stroke = try readPaint(ctx, index, "stroke");
    st.opacity = @floatCast(util.optNumber(lua, index, "opacity", 1));
    st.fill_opacity = @floatCast(util.optNumber(lua, index, "fillOpacity", 1));
    st.stroke_opacity = @floatCast(util.optNumber(lua, index, "strokeOpacity", 1));
    st.stroke_width = util.optNumber(lua, index, "strokeWidth", 1);
    st.cap = util.optEnum(lua, scene.Cap, index, "strokeLinecap", .butt);
    st.blend = util.optEnum(lua, scene.Blend, index, "blendMode", .normal);
    st.dash_offset = util.optNumber(lua, index, "strokeDashoffset", 0);
    _ = lua.getField(index, "strokeDasharray");
    if (lua.isTable(-1)) {
        const a = util.numberAt(lua, -1, 1) orelse 0;
        const b = util.numberAt(lua, -1, 2) orelse a;
        if (a > 0) st.dash = .{ a, b };
    }
    lua.pop(1);
    _ = lua.getField(index, "colorMap");
    if (lua.isTable(-1)) st.color_map = try readColorMap(ctx, -1);
    lua.pop(1);
    return st;
}

/// colorMap tables are solved by the Zig solver behind colormap.lua.
/// Matrices that print alike at six significant digits share a key.
fn readColorMap(ctx: *Ctx, index_in: i32) !scene.ColorMap {
    const bind_algo = @import("bind_algo.zig");
    const m = try bind_algo.solveColorMap(ctx.lua, index_in);
    var cm: scene.ColorMap = .{ .m = undefined, .key = 0 };
    var key: std.ArrayList(u8) = .empty;
    for (m, 0..) |row, r| for (row, 0..) |v, c| {
        cm.m[r][c] = @floatCast(v);
        try key.print(ctx.arena, "{e:.5} ", .{v});
    };
    const gop = try ctx.color_map_keys.getOrPut(ctx.arena, key.items);
    if (!gop.found_existing) gop.value_ptr.* = ctx.color_map_keys.count() - 1;
    cm.key = gop.value_ptr.*;
    return cm;
}
