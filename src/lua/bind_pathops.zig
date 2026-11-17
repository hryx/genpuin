//! core.pathops: polygon booleans, signed distance fields, contours,
//! offsets, hatching, simplification and plotter path ordering. Shapes
//! cross as plain point lists. prelude/pathops.lua turns them into shapes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");
const pathops = genpuin.pathops;
const geom = pathops.geom;
const sdf = pathops.sdf;

const util = @import("util.zig");
const Lua = util.Lua;
const Vec2 = util.Vec2;

pub const functions = [_]zlua.FnReg{
    .{ .name = "clip", .func = zlua.wrap(clip) },
    .{ .name = "sdfEval", .func = zlua.wrap(sdfEval) },
    .{ .name = "sdfField", .func = zlua.wrap(sdfField) },
    .{ .name = "contours", .func = zlua.wrap(contours) },
    .{ .name = "offsets", .func = zlua.wrap(offsets) },
    .{ .name = "hatch", .func = zlua.wrap(hatch) },
    .{ .name = "clipLines", .func = zlua.wrap(clipLines) },
    .{ .name = "simplify", .func = zlua.wrap(simplify) },
    .{ .name = "orderPaths", .func = zlua.wrap(orderPaths) },
    .{ .name = "joinPaths", .func = zlua.wrap(joinPaths) },
};

fn rule(lua: *Lua, index: i32) geom.FillRule {
    return util.optEnum(lua, geom.FillRule, index, "rule", .nonzero);
}

fn optRect(lua: *Lua, index: i32, default: sdf.Rect) sdf.Rect {
    return .{
        .x = util.optNumber(lua, index, "x", default.x),
        .y = util.optNumber(lua, index, "y", default.y),
        .w = util.optNumber(lua, index, "w", default.w),
        .h = util.optNumber(lua, index, "h", default.h),
    };
}

/// clip(a, b, op, rule) -> contours. op is union, intersect, difference
/// or xor, rule nonzero or evenodd.
fn clip(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try util.readContours(lua, arena, 1);
    const b = try util.readContours(lua, arena, 2);
    const op_name = lua.toString(3) catch lua.argError(3, "expected an op name");
    const op = std.meta.stringToEnum(pathops.boolean.Op, op_name) orelse lua.argError(3, "op must be union, intersect, difference or xor");
    const r: geom.FillRule = blk: {
        const s = lua.toString(4) catch break :blk .nonzero;
        break :blk std.meta.stringToEnum(geom.FillRule, s) orelse lua.argError(4, "rule must be nonzero or evenodd");
    };
    const out = try pathops.boolean.compute(arena, a, b, op, r);
    util.pushContours(lua, out);
    return 1;
}

const NodeKind = enum { circle, box, segment, polygon, @"union", intersect, subtract, round, onion, translate, rotate, scale, repeat };

fn needVec2(lua: *Lua, index: i32, key: [:0]const u8) Vec2 {
    defer lua.pop(1);
    _ = lua.getField(index, key);
    return util.readVec2(lua, -1) orelse lua.raiseErrorStr("sdf node needs '%s' as {x, y}", .{key.ptr});
}

fn optVec2(lua: *Lua, index: i32, key: [:0]const u8, default: Vec2) Vec2 {
    defer lua.pop(1);
    if (lua.getField(index, key) == .number) {
        const v = lua.toNumber(-1) catch unreachable; // type checked on the line above
        return .{ v, v };
    }
    return util.readVec2(lua, -1) orelse default;
}

fn child(lua: *Lua, arena: Allocator, index: i32, i: usize, depth: usize) Allocator.Error!*const sdf.Node {
    defer lua.pop(1);
    if (util.rawGet(lua, index, i) != .table) lua.raiseErrorStr("sdf node is missing child %d", .{@as(c_int, @intCast(i))});
    return readNode(lua, arena, -1, depth + 1);
}

/// Read an sdf node table built by prelude/pathops.lua into the arena.
fn readNode(lua: *Lua, arena: Allocator, index_in: i32, depth: usize) Allocator.Error!*const sdf.Node {
    if (depth > sdf.max_depth) lua.raiseErrorStr("sdf tree is deeper than 64", .{});
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("expected an sdf node", .{});
    const kind_name = (try util.optString(lua, arena, index, "sdf", null)) orelse lua.raiseErrorStr("not an sdf node", .{});
    const kind = std.meta.stringToEnum(NodeKind, kind_name) orelse
        lua.raiseErrorStr("unknown sdf node '%s'", .{(try arena.dupeSentinel(u8, kind_name, 0)).ptr});
    const node = try arena.create(sdf.Node);
    node.* = switch (kind) {
        .circle => .{ .circle = .{ .c = needVec2(lua, index, "c"), .r = util.optNumber(lua, index, "r", 1) } },
        .box => .{ .box = .{
            .c = needVec2(lua, index, "c"),
            .half = .{ util.optNumber(lua, index, "w", 1) / 2, util.optNumber(lua, index, "h", 1) / 2 },
        } },
        .segment => .{ .segment = .{ .a = needVec2(lua, index, "a"), .b = needVec2(lua, index, "b"), .r = util.optNumber(lua, index, "r", 0) } },
        .polygon => blk: {
            _ = lua.getField(index, "contours");
            const cs = try util.readContours(lua, arena, -1);
            lua.pop(1);
            break :blk .{ .polygon = .{ .contours = cs, .rule = rule(lua, index) } };
        },
        inline .@"union", .intersect, .subtract => |k| blk: {
            const n = util.len(lua, index);
            if (n == 0) lua.raiseErrorStr("sdf %s needs at least one child", .{@tagName(k).ptr});
            const children = try arena.alloc(sdf.Node, n);
            for (children, 1..) |*c, i| c.* = (try child(lua, arena, index, i, depth)).*;
            break :blk .{ .combine = .{ .op = @field(sdf.Combine, @tagName(k)), .children = children, .k = util.optNumber(lua, index, "k", 0) } };
        },
        .round => .{ .round = .{ .child = try child(lua, arena, index, 1, depth), .r = util.optNumber(lua, index, "r", 0) } },
        .onion => .{ .onion = .{ .child = try child(lua, arena, index, 1, depth), .t = util.optNumber(lua, index, "t", 1) } },
        .translate => .{ .translate = .{ .child = try child(lua, arena, index, 1, depth), .offset = optVec2(lua, index, "offset", .{ 0, 0 }) } },
        .rotate => .{ .rotate = .{
            .child = try child(lua, arena, index, 1, depth),
            .angle = util.optNumber(lua, index, "angle", 0),
            .center = optVec2(lua, index, "center", .{ 0, 0 }),
        } },
        .scale => blk: {
            const s = util.optNumber(lua, index, "s", 1);
            if (s == 0) lua.raiseErrorStr("sdf scale must not be zero", .{});
            break :blk .{ .scale = .{ .child = try child(lua, arena, index, 1, depth), .s = s } };
        },
        .repeat => blk: {
            const count = optVec2(lua, index, "count", .{ 0, 0 });
            break :blk .{ .repeat = .{
                .child = try child(lua, arena, index, 1, depth),
                .period = optVec2(lua, index, "period", .{ 1, 1 }),
                .count = .{ @intFromFloat(std.math.clamp(count[0], 0, 1e6)), @intFromFloat(std.math.clamp(count[1], 0, 1e6)) },
            } };
        },
    };
    return node;
}

fn program(lua: *Lua, arena: Allocator, index: i32) !sdf.Program {
    const root = try readNode(lua, arena, index, 0);
    return sdf.Program.init(arena, root);
}

/// sdfEval(node, x, y) -> distance
fn sdfEval(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const x = lua.checkNumber(2);
    const y = lua.checkNumber(3);
    const prog = try program(lua, arena, 1);
    lua.pushNumber(prog.eval(.{ x, y }));
    return 1;
}

/// sdfField(node, {x, y, w, h, cols, rows}) -> Field
fn sdfField(lua: *Lua) !i32 {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rect = optRect(lua, 2, .{ .x = 0, .y = 0, .w = 256, .h = 256 });
    if (!(rect.w > 0 and rect.h > 0)) lua.raiseErrorStr("sdfField needs a rect with positive size", .{});
    const cols = std.math.clamp(util.optInt(lua, 2, "cols", 256), 1, 1 << 14);
    const default_rows: i64 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(cols)) * rect.h / rect.w)));
    const rows = std.math.clamp(util.optInt(lua, 2, "rows", default_rows), 1, 1 << 14);
    const prog = try program(lua, arena, 1);
    var f: util.Field = try .init(gpa, @intCast(cols), @intCast(rows), 0);
    errdefer f.deinit(gpa);
    prog.fill(&f, rect);
    util.pushField(lua, f);
    return 1;
}

fn pushShape(lua: *Lua, kind: [:0]const u8, pts: []const Vec2) void {
    lua.createTable(0, 3);
    _ = lua.pushString(kind);
    lua.setField(-2, "type");
    util.pushPoints(lua, pts);
    lua.setField(-2, "points");
}

/// contours(field, levels, {x, y, w, h, simplify}) -> shapes. Closed
/// lines come back as polygons, open ones as polylines, each with its
/// level.
fn contours(lua: *Lua) !i32 {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = util.checkField(lua, 1);
    var levels: std.ArrayList(f64) = .empty;
    if (lua.isNumber(2)) {
        try levels.append(arena, lua.toNumber(2) catch unreachable); // checked by isNumber
    } else if (lua.isTable(2)) {
        for (1..util.len(lua, 2) + 1) |i| {
            const v = util.numberAt(lua, 2, i) orelse lua.raiseErrorStr("level %d is not a number", .{@as(c_int, @intCast(i))});
            try levels.append(arena, v);
        }
    } else lua.argError(2, "expected a level or a list of levels");
    const fw: f64 = @floatFromInt(f.w);
    const fh: f64 = @floatFromInt(f.h);
    const rect = optRect(lua, 3, .{ .x = 0, .y = 0, .w = fw, .h = fh });
    const tol = util.optNumber(lua, 3, "simplify", 0);

    lua.newTable();
    var n: usize = 0;
    for (levels.items) |level| {
        const lines = try pathops.contour.trace(arena, f, @floatCast(level), rect);
        for (lines) |l| {
            const pts = if (tol > 0) try pathops.simplify.simplify(arena, l.points, tol, l.closed, .distance) else l.points;
            pushShape(lua, if (l.closed) "polygon" else "polyline", pts);
            lua.pushNumber(level);
            lua.setField(-2, "level");
            lua.pushBoolean(l.closed);
            lua.setField(-2, "closed");
            n += 1;
            util.rawSet(lua, -2, n);
        }
    }
    return 1;
}

/// offsets(contours, distances, {resolution, tolerance, rule, open})
/// -> one contour list per distance.
fn offsets(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cs = try util.readContours(lua, arena, 1);
    if (!lua.isTable(2)) lua.argError(2, "expected a list of distances");
    const ds = try arena.alloc(f64, util.len(lua, 2));
    for (ds, 1..) |*d, i| d.* = util.numberAt(lua, 2, i) orelse lua.raiseErrorStr("distance %d is not a number", .{@as(c_int, @intCast(i))});
    const opts: pathops.offset.Options = .{
        .resolution = util.optNumber(lua, 3, "resolution", 0),
        .tolerance = util.optNumber(lua, 3, "tolerance", -1),
        .rule = rule(lua, 3),
        .open = util.optBool(lua, 3, "open", false),
    };
    const out = try pathops.offset.offsets(arena, cs, ds, opts);
    lua.createTable(@intCast(out.len), 0);
    for (out, 1..) |o, i| {
        util.pushContours(lua, o);
        util.rawSet(lua, -2, i);
    }
    return 1;
}

fn hatchOptions(lua: *Lua, index: i32) pathops.hatch.Options {
    return .{
        .angle = util.optNumber(lua, index, "angle", 0),
        .spacing = util.optNumber(lua, index, "spacing", 4),
        .offset = util.optNumber(lua, index, "offset", 0),
        .inset = util.optNumber(lua, index, "inset", 0),
        .jitter = util.optNumber(lua, index, "jitter", 0),
        .seed = util.optSeed(lua, index),
        .rule = rule(lua, index),
        .cross = util.optBool(lua, index, "cross", false),
        .resolution = util.optNumber(lua, index, "resolution", 0),
    };
}

/// hatch(contours, opts) -> line shapes, or point lists when opts.connect.
fn hatch(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cs = try util.readContours(lua, arena, 1);
    const opts = hatchOptions(lua, 2);
    if (!(opts.spacing > 0)) lua.raiseErrorStr("hatch spacing must be positive", .{});
    if (util.optBool(lua, 2, "connect", false)) {
        const paths = try pathops.hatch.hatchConnected(arena, cs, opts);
        util.pushContours(lua, paths);
        return 1;
    }
    const segs = try pathops.hatch.hatch(arena, cs, opts);
    lua.createTable(@intCast(segs.len), 0);
    for (segs, 1..) |s, i| {
        lua.createTable(0, 3);
        _ = lua.pushString("line");
        lua.setField(-2, "type");
        util.pushVec2(lua, s[0]);
        lua.setField(-2, "a");
        util.pushVec2(lua, s[1]);
        lua.setField(-2, "b");
        util.rawSet(lua, -2, i);
    }
    return 1;
}

/// clipLines(lines, contours, {rule, outside}) -> point lists
fn clipLines(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try util.readContours(lua, arena, 1);
    const cs = try util.readContours(lua, arena, 2);
    const out = try pathops.hatch.clipLines(arena, lines, cs, rule(lua, 3), util.optBool(lua, 3, "outside", false));
    util.pushContours(lua, out);
    return 1;
}

/// simplify(points, tolerance, closed, method) -> points
fn simplify(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try util.readPoints(lua, arena, 1);
    const tol = lua.checkNumber(2);
    const closed = lua.toBoolean(3);
    const method: pathops.simplify.Method = blk: {
        const s = lua.toString(4) catch break :blk .distance;
        break :blk std.meta.stringToEnum(pathops.simplify.Method, s) orelse lua.argError(4, "method must be distance or area");
    };
    util.pushPoints(lua, try pathops.simplify.simplify(arena, pts, tol, closed, method));
    return 1;
}

/// orderPaths(ends, {start, budget, neighbors}) -> order, reversed,
/// before, after. `ends` lists {start, end} per path, and order holds
/// 1-based indices.
fn orderPaths(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pairs = try util.readContours(lua, arena, 1);
    const ends = try arena.alloc([2]Vec2, pairs.len);
    for (pairs, ends, 1..) |p, *e, i| {
        if (p.len != 2) lua.raiseErrorStr("path %d needs a start and an end", .{@as(c_int, @intCast(i))});
        e.* = .{ p[0], p[1] };
    }
    const opts: pathops.order.Options = .{
        .start = if (lua.isTable(2)) optVec2(lua, 2, "start", .{ 0, 0 }) else .{ 0, 0 },
        .budget = @intCast(std.math.clamp(util.optInt(lua, 2, "budget", 4_000_000), 0, 1 << 40)),
        .neighbors = @intCast(std.math.clamp(util.optInt(lua, 2, "neighbors", 10), 1, 64)),
    };
    const o = try pathops.order.orderPaths(arena, ends, opts);
    lua.createTable(@intCast(o.order.len), 0);
    for (o.order, 1..) |idx, i| {
        lua.pushInteger(@intCast(idx + 1));
        util.rawSet(lua, -2, i);
    }
    lua.createTable(@intCast(o.reversed.len), 0);
    for (o.reversed, 1..) |r, i| {
        lua.pushBoolean(r);
        util.rawSet(lua, -2, i);
    }
    lua.pushNumber(o.travel_before);
    lua.pushNumber(o.travel_after);
    return 4;
}

/// joinPaths(paths, tolerance) -> point lists, closed flags
fn joinPaths(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try util.readContours(lua, arena, 1);
    const tol = lua.optNumber(2) orelse 1e-9;
    const out = try pathops.order.joinPaths(arena, paths, tol);
    lua.createTable(@intCast(out.len), 0);
    for (out, 1..) |j, i| {
        util.pushPoints(lua, j.points);
        util.rawSet(lua, -2, i);
    }
    lua.createTable(@intCast(out.len), 0);
    for (out, 1..) |j, i| {
        lua.pushBoolean(j.closed);
        util.rawSet(lua, -2, i);
    }
    return 2;
}
