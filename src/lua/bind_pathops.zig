//! core.pathops: polygon booleans, signed distance fields, contours,
//! offsets, hatching, simplification and plotter path ordering. These take
//! shape tables and return shape tables. Most are the gen.* functions
//! themselves, so an error raised here names the script line. Circles,
//! ellipses and rects are flattened by src/pathops/flatten.zig.

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
    .{ .name = "toContours", .func = zlua.wrap(toContours) },
    .{ .name = "clip", .func = zlua.wrap(clip) },
    .{ .name = "sdfEval", .func = zlua.wrap(sdfEval) },
    .{ .name = "sdfField", .func = zlua.wrap(sdfField) },
    .{ .name = "contours", .func = zlua.wrap(contours) },
    .{ .name = "offset", .func = zlua.wrap(offset) },
    .{ .name = "offsets", .func = zlua.wrap(offsets) },
    .{ .name = "hatch", .func = zlua.wrap(hatch) },
    .{ .name = "clipLines", .func = zlua.wrap(clipLines) },
    .{ .name = "simplify", .func = zlua.wrap(simplify) },
    .{ .name = "orderPaths", .func = zlua.wrap(orderPaths) },
    .{ .name = "joinPaths", .func = zlua.wrap(joinPaths) },
};

const max_depth = 64;

fn rule(lua: *Lua, index: i32) geom.FillRule {
    return util.optEnum(lua, geom.FillRule, index, "rule", .nonzero);
}

/// The scene rect an options table names, as opts.rect = {x, y, w, h} or
/// as opts.x, y, w and h. Missing parts take the default.
fn optRect(lua: *Lua, index: i32, default: sdf.Rect) sdf.Rect {
    if (lua.isTable(index)) {
        const kind = lua.getField(index, "rect");
        defer lua.pop(1);
        if (kind != .nil) {
            const r = lua.absIndex(-1);
            if (kind != .table) lua.raiseErrorStr("option 'rect' must be {x, y, w, h}", .{});
            return .{
                .x = rectPart(lua, r, 1, default.x),
                .y = rectPart(lua, r, 2, default.y),
                .w = rectPart(lua, r, 3, default.w),
                .h = rectPart(lua, r, 4, default.h),
            };
        }
    }
    return .{
        .x = util.optNumber(lua, index, "x", default.x),
        .y = util.optNumber(lua, index, "y", default.y),
        .w = util.optNumber(lua, index, "w", default.w),
        .h = util.optNumber(lua, index, "h", default.h),
    };
}

fn rectPart(lua: *Lua, r: i32, i: usize, default: f64) f64 {
    defer lua.pop(1);
    return switch (util.rawGet(lua, r, i)) {
        .number => lua.toNumber(-1) catch unreachable, // type checked by the switch
        .nil => default,
        else => lua.raiseErrorStr("option 'rect' must be {x, y, w, h}", .{}),
    };
}

// Shape tables in, shape tables out. The readers follow the Lua library
// they replace: a polygon's points and a compound's contours are taken as
// they are, a list of shapes is read element by element, and a list whose
// first element is a point is one contour or path.

const ShapeKind = enum { line, polyline, polygon, compound, rect, circle, ellipse };

const Tag = union(enum) {
    known: ShapeKind,
    /// No type field: a point list or a list of shapes.
    none,
    other,
};

fn shapeTag(lua: *Lua, index: i32) Tag {
    defer lua.pop(1);
    return switch (lua.getField(index, "type")) {
        .nil => .none,
        .string => if (std.meta.stringToEnum(ShapeKind, lua.toString(-1) catch unreachable)) |k| .{ .known = k } else .other, // type checked by the switch
        else => .other,
    };
}

/// tostring(shape.type), for an error message.
fn typeName(lua: *Lua, arena: Allocator, index: i32) ![:0]const u8 {
    if (!lua.isTable(index)) return lua.typeNameIndex(index);
    defer lua.pop(1);
    return switch (lua.getField(index, "type")) {
        .string => try arena.dupeSentinel(u8, lua.toString(-1) catch unreachable, 0), // type checked by the switch
        .nil => "nil",
        else => lua.typeNameIndex(-1),
    };
}

/// Push t[i] of the table at `index` unless it is nil, as ipairs walks.
fn pushItem(lua: *Lua, index: i32, i: usize) bool {
    if (util.rawGet(lua, index, i) != .nil) return true;
    lua.pop(1);
    return false;
}

/// Whether the table at `index` is a point list: its first element is a
/// table holding a number.
fn isPointList(lua: *Lua, index: i32) bool {
    defer lua.pop(1);
    if (util.rawGet(lua, index, 1) != .table) return false;
    defer lua.pop(1);
    return util.rawGet(lua, -1, 1) == .number;
}

/// A point list whose first point carries no type field, so it cannot
/// be a list of shapes.
fn isBarePath(lua: *Lua, index: i32) bool {
    if (!isPointList(lua, index)) return false;
    _ = util.rawGet(lua, index, 1);
    defer lua.pop(2);
    return lua.getField(-1, "type") == .nil;
}

fn shapeVec2(lua: *Lua, index: i32, key: [:0]const u8) Vec2 {
    defer lua.pop(1);
    _ = lua.getField(index, key);
    return util.readVec2(lua, -1) orelse lua.raiseErrorStr("shape needs '%s' as {x, y}", .{key.ptr});
}

fn shapeNumber(lua: *Lua, index: i32, key: [:0]const u8) f64 {
    return shapeOptNumber(lua, index, key) orelse lua.raiseErrorStr("shape needs a number '%s'", .{key.ptr});
}

fn shapeOptNumber(lua: *Lua, index: i32, key: [:0]const u8) ?f64 {
    defer lua.pop(1);
    if (lua.getField(index, key) != .number) return null;
    return lua.toNumber(-1) catch unreachable; // type checked above
}

/// Collects contours into a Lua list at a stack slot, sharing the point
/// lists already in the shape, as gen.toContours returns them.
const LuaSink = struct {
    lua: *Lua,
    out: i32,
    len: usize = 0,

    /// Pop the top value into the next slot.
    fn add(sink: *LuaSink) void {
        sink.len += 1;
        util.rawSet(sink.lua, sink.out, sink.len);
    }

    fn pointList(sink: *LuaSink, index: i32) !void {
        sink.lua.pushValue(index);
        sink.add();
    }

    fn contourList(sink: *LuaSink, index: i32) !void {
        var i: usize = 1;
        while (pushItem(sink.lua, index, i)) : (i += 1) sink.add();
    }

    fn generated(sink: *LuaSink, pts: []const Vec2) !void {
        util.pushPoints(sink.lua, pts);
        sink.add();
    }
};

/// Collects contours or paths as point slices in an arena.
const ZigSink = struct {
    lua: *Lua,
    arena: Allocator,
    list: std.ArrayList([]const Vec2) = .empty,

    fn pointList(sink: *ZigSink, index: i32) !void {
        try sink.list.append(sink.arena, try util.readPoints(sink.lua, sink.arena, index));
    }

    fn contourList(sink: *ZigSink, index: i32) !void {
        try sink.list.appendSlice(sink.arena, try util.readContours(sink.lua, sink.arena, index));
    }

    fn generated(sink: *ZigSink, pts: []const Vec2) !void {
        try sink.list.append(sink.arena, pts);
    }
};

/// Feed the closed contours of the shape at `index` to `sink`. False
/// for an open shape, which may leave the sink partly filled.
fn walkClosed(lua: *Lua, arena: Allocator, sink: anytype, index_in: i32, depth: u32) !bool {
    const index = lua.absIndex(index_in);
    if (depth > max_depth) lua.raiseErrorStr("shape lists nest deeper than 64", .{});
    if (!lua.isTable(index)) return false;
    const kind = switch (shapeTag(lua, index)) {
        .other => return false,
        .known => |k| k,
        .none => {
            if (isPointList(lua, index)) {
                try sink.pointList(index);
                return true;
            }
            var i: usize = 1;
            while (pushItem(lua, index, i)) : (i += 1) {
                const closed = try walkClosed(lua, arena, sink, -1, depth + 1);
                lua.pop(1);
                if (!closed) return false;
            }
            return true;
        },
    };
    switch (kind) {
        .line, .polyline => return false,
        .polygon => {
            defer lua.pop(1);
            if (lua.getField(index, "points") != .nil) try sink.pointList(-1);
        },
        .compound => {
            defer lua.pop(1);
            if (lua.getField(index, "contours") == .nil) return false;
            if (!lua.isTable(-1)) lua.raiseErrorStr("compound needs a list of contours", .{});
            try sink.contourList(lua.absIndex(-1));
        },
        .rect => try sink.generated(try pathops.flatten.rect(arena, .{
            .x = shapeNumber(lua, index, "x"),
            .y = shapeNumber(lua, index, "y"),
            .w = shapeNumber(lua, index, "w"),
            .h = shapeNumber(lua, index, "h"),
            .rx = shapeOptNumber(lua, index, "rx"),
            .ry = shapeOptNumber(lua, index, "ry"),
        })),
        .circle => {
            const c = shapeVec2(lua, index, "center");
            const r = shapeNumber(lua, index, "r");
            try sink.generated(try pathops.flatten.ellipse(arena, c, r, r));
        },
        .ellipse => {
            const c = shapeVec2(lua, index, "center");
            const rx = shapeNumber(lua, index, "rx");
            const ry = shapeNumber(lua, index, "ry");
            try sink.generated(try pathops.flatten.ellipse(arena, c, rx, ry));
        },
    }
    return true;
}

/// Feed the shape at `index` to `sink` as open point paths: line work as
/// it is, closed shapes as loops that repeat their first point.
fn walkPaths(lua: *Lua, sink: *ZigSink, index_in: i32, depth: u32) !void {
    const index = lua.absIndex(index_in);
    if (depth > max_depth) lua.raiseErrorStr("shape lists nest deeper than 64", .{});
    if (!lua.isTable(index)) lua.raiseErrorStr("expected line work, got %s", .{lua.typeNameIndex(index).ptr});
    switch (shapeTag(lua, index)) {
        .known => |kind| switch (kind) {
            .line => {
                const pts = try sink.arena.alloc(Vec2, 2);
                pts[0] = shapeVec2(lua, index, "a");
                pts[1] = shapeVec2(lua, index, "b");
                return sink.generated(pts);
            },
            .polyline => {
                defer lua.pop(1);
                if (lua.getField(index, "points") != .nil) try sink.pointList(-1);
                return;
            },
            .polygon, .compound, .rect, .circle, .ellipse => {},
        },
        .none => {
            if (isBarePath(lua, index)) return sink.pointList(index);
            var i: usize = 1;
            while (pushItem(lua, index, i)) : (i += 1) {
                try walkPaths(lua, sink, -1, depth + 1);
                lua.pop(1);
            }
            return;
        },
        .other => {},
    }
    var closed: ZigSink = .{ .lua = lua, .arena = sink.arena };
    if (!try walkClosed(lua, sink.arena, &closed, index, depth)) {
        lua.raiseErrorStr("expected line work, got %s", .{(try typeName(lua, sink.arena, index)).ptr});
    }
    for (closed.list.items) |c| {
        if (c.len == 0) {
            try sink.generated(c);
            continue;
        }
        const loop = try sink.arena.alloc(Vec2, c.len + 1);
        @memcpy(loop[0..c.len], c);
        loop[c.len] = c[0];
        try sink.generated(loop);
    }
}

/// The closed contours of the shape at `index`, or null for an open shape.
fn closedContours(lua: *Lua, arena: Allocator, index: i32) !?geom.Contours {
    var sink: ZigSink = .{ .lua = lua, .arena = arena };
    if (!try walkClosed(lua, arena, &sink, index, 0)) return null;
    return sink.list.items;
}

fn needClosed(lua: *Lua, arena: Allocator, index: i32, what: [:0]const u8) !geom.Contours {
    return (try closedContours(lua, arena, index)) orelse
        lua.raiseErrorStr("%s: expected a closed shape, got %s", .{ what.ptr, (try typeName(lua, arena, index)).ptr });
}

fn readPaths(lua: *Lua, arena: Allocator, index: i32) !geom.Contours {
    var sink: ZigSink = .{ .lua = lua, .arena = arena };
    try walkPaths(lua, &sink, index, 0);
    return sink.list.items;
}

fn pushCompound(lua: *Lua, cs: []const []const Vec2) void {
    lua.createTable(0, 2);
    _ = lua.pushString("compound");
    lua.setField(-2, "type");
    util.pushContours(lua, cs);
    lua.setField(-2, "contours");
}

fn pushShape(lua: *Lua, kind: [:0]const u8, pts: []const Vec2) void {
    lua.createTable(0, 3);
    _ = lua.pushString(kind);
    lua.setField(-2, "type");
    util.pushPoints(lua, pts);
    lua.setField(-2, "points");
}

fn pushShapes(lua: *Lua, kind: [:0]const u8, paths: []const []const Vec2) void {
    lua.createTable(@intCast(paths.len), 0);
    for (paths, 1..) |pts, i| {
        pushShape(lua, kind, pts);
        util.rawSet(lua, -2, i);
    }
}

/// toContours(shape) -> the closed contours of a shape as a list of point
/// lists, or nil for an open shape. Point lists already in the shape are
/// shared, not copied, and a compound's contours list comes back as is.
fn toContours(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    if (lua.isTable(1) and std.meta.eql(shapeTag(lua, 1), .{ .known = .compound })) {
        _ = lua.getField(1, "contours");
        return 1;
    }
    lua.newTable();
    var sink: LuaSink = .{ .lua = lua, .out = lua.getTop() };
    if (!try walkClosed(lua, arena_state.allocator(), &sink, 1, 0)) lua.pushNil();
    return 1;
}

/// clip(a, b, op, {rule}) -> compound. b may be nil, op defaults to union.
fn clip(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b: geom.Contours = if (lua.toBoolean(2)) try needClosed(lua, arena, 2, "clip") else &.{};
    const a = try needClosed(lua, arena, 1, "clip");
    const op: pathops.boolean.Op = if (lua.isNoneOrNil(3)) .@"union" else blk: {
        const name = lua.toString(3) catch lua.argError(3, "expected an op name");
        break :blk std.meta.stringToEnum(pathops.boolean.Op, name) orelse lua.argError(3, "op must be union, intersect, difference or xor");
    };
    pushCompound(lua, try pathops.boolean.compute(arena, a, b, op, rule(lua, 4)));
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
    const x = lua.checkNumber(2);
    const y = lua.checkNumber(3);
    const prog = try program(lua, arena_state.allocator(), 1);
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

/// The shape at `index` as offset input: its closed contours, or open
/// paths when any part of it is line work.
fn offsetInput(lua: *Lua, arena: Allocator, index: i32) !struct { geom.Contours, bool } {
    if (try closedContours(lua, arena, index)) |cs| return .{ cs, false };
    return .{ try readPaths(lua, arena, index), true };
}

fn offsetOptions(lua: *Lua, index: i32, open: bool) pathops.offset.Options {
    return .{
        .resolution = util.optNumber(lua, index, "resolution", 0),
        .tolerance = util.optNumber(lua, index, "tolerance", -1),
        .rule = rule(lua, index),
        .open = open,
    };
}

/// offset(shape, distance, {resolution, tolerance, rule}) -> compound
fn offset(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cs, const open = try offsetInput(lua, arena, 1);
    const d = lua.checkNumber(2);
    const out = try pathops.offset.offsets(arena, cs, &.{d}, offsetOptions(lua, 3, open));
    pushCompound(lua, out[0]);
    return 1;
}

/// offsets(shape, distances, opts) -> one compound per distance, each
/// with its distance. distances is a list or {step, count, start}.
fn offsets(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cs, const open = try offsetInput(lua, arena, 1);
    if (!lua.isTable(2)) lua.argError(2, "expected a list of distances");
    var ds: std.ArrayList(f64) = .empty;
    const stepped = lua.getField(2, "step") != .nil;
    lua.pop(1);
    if (stepped) {
        const step = util.optNumber(lua, 2, "step", 0);
        const count = util.optNumber(lua, 2, "count", 1);
        const start = util.optNumber(lua, 2, "start", 0);
        var i: f64 = 1;
        while (i <= count) : (i += 1) try ds.append(arena, start + i * step);
    } else {
        for (1..util.len(lua, 2) + 1) |i| {
            const d = util.numberAt(lua, 2, i) orelse lua.raiseErrorStr("distance %d is not a number", .{@as(c_int, @intCast(i))});
            try ds.append(arena, d);
        }
    }
    const out = try pathops.offset.offsets(arena, cs, ds.items, offsetOptions(lua, 3, open));
    const integral = stepped and integerSteps(lua);
    lua.createTable(@intCast(out.len), 0);
    for (out, ds.items, 1..) |o, d, i| {
        pushCompound(lua, o);
        if (!stepped) {
            _ = util.rawGet(lua, 2, i);
        } else if (integral) {
            lua.pushInteger(@intFromFloat(d));
        } else {
            lua.pushNumber(d);
        }
        lua.setField(-2, "distance");
        util.rawSet(lua, -2, i);
    }
    return 1;
}

/// Whether Lua 5.3 and later would compute stepped distances as integers.
fn integerSteps(lua: *Lua) bool {
    return switch (zlua.lang) {
        .lua53, .lua54, .lua55 => integerStepsPuc(lua),
        else => false,
    };
}

fn integerStepsPuc(lua: *Lua) bool {
    defer lua.pop(2);
    _ = lua.getField(2, "step");
    const start_kind = lua.getField(2, "start");
    return lua.isInteger(-2) and (start_kind == .nil or lua.isInteger(-1));
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

/// hatch(shape, opts, seed) -> line shapes, or polylines when
/// opts.connect, or nil and a message when the shape is not closed.
fn hatch(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cs = (try closedContours(lua, arena, 1)) orelse {
        lua.pushNil();
        _ = lua.pushString(try std.fmt.allocPrint(arena, "hatch: expected a closed shape, got {s}", .{try typeName(lua, arena, 1)}));
        return 2;
    };
    var opts = hatchOptions(lua, 2);
    opts.seed = @bitCast(@as(i64, @intFromFloat(@floor(lua.checkNumber(3)))));
    if (!(opts.spacing > 0)) lua.raiseErrorStr("hatch spacing must be positive", .{});
    if (util.optBool(lua, 2, "connect", false)) {
        pushShapes(lua, "polyline", try pathops.hatch.hatchConnected(arena, cs, opts));
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

/// clipLines(lines, shape, {rule, outside}) -> polylines
fn clipLines(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try readPaths(lua, arena, 1);
    const cs = try needClosed(lua, arena, 2, "clipLines");
    const out = try pathops.hatch.clipLines(arena, lines, cs, rule(lua, 3), util.optBool(lua, 3, "outside", false));
    pushShapes(lua, "polyline", out);
    return 1;
}

/// opts may be the method name or a table holding it.
fn simplifyMethod(lua: *Lua, index: i32) pathops.simplify.Method {
    const name: [:0]const u8 = switch (lua.typeOf(index)) {
        .string => lua.toString(index) catch unreachable, // type checked by the switch
        .table => blk: {
            defer lua.pop(1);
            if (lua.getField(index, "method") != .string) break :blk "distance";
            break :blk lua.toString(-1) catch unreachable; // type checked above
        },
        else => "distance",
    };
    return std.meta.stringToEnum(pathops.simplify.Method, name) orelse lua.argError(index, "method must be distance or area");
}

/// simplify(shape, tolerance, opts) -> the shape with fewer points. A
/// line comes back as it is.
fn simplify(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const method = simplifyMethod(lua, 3);
    const tag = if (lua.isTable(1)) shapeTag(lua, 1) else Tag.other;
    switch (tag) {
        .known => |kind| switch (kind) {
            .line => {
                lua.pushValue(1);
                return 1;
            },
            .polyline => {
                _ = lua.getField(1, "points");
                const pts = try util.readPoints(lua, arena, -1);
                pushShape(lua, "polyline", try pathops.simplify.simplify(arena, pts, lua.checkNumber(2), false, method));
                return 1;
            },
            .polygon, .compound, .rect, .circle, .ellipse => {},
        },
        .none, .other => {},
    }
    const closed = try needClosed(lua, arena, 1, "simplify");
    const tol = lua.checkNumber(2);
    const cs = try arena.alloc([]const Vec2, closed.len);
    for (cs, closed) |*out, c| out.* = try pathops.simplify.simplify(arena, c, tol, true, method);
    if (cs.len == 1 and !std.meta.eql(tag, .{ .known = .compound })) {
        pushShape(lua, "polygon", cs[0]);
    } else {
        pushCompound(lua, cs);
    }
    return 1;
}

/// The first and last point of the path shape at `index`. A polygon ends
/// where it starts.
fn pathEnds(lua: *Lua, index: i32, tag: Tag, i: usize) [2]Vec2 {
    if (std.meta.eql(tag, .{ .known = .line })) {
        return .{ shapeVec2(lua, index, "a"), shapeVec2(lua, index, "b") };
    }
    const closed = std.meta.eql(tag, .{ .known = .polygon });
    if (!lua.isTable(index) or lua.getField(index, "points") != .table) {
        lua.raiseErrorStr("orderPaths: path %d is not a line, polyline or polygon", .{@as(c_int, @intCast(i))});
    }
    defer lua.pop(1);
    const n = util.len(lua, -1);
    _ = util.rawGet(lua, -1, 1);
    const first = util.readVec2(lua, -1);
    lua.pop(1);
    _ = util.rawGet(lua, -1, if (closed) 1 else n);
    const last = util.readVec2(lua, -1);
    lua.pop(1);
    if (first == null or last == null) lua.raiseErrorStr("orderPaths: path %d has no {x, y} end points", .{@as(c_int, @intCast(i))});
    return .{ first.?, last.? };
}

/// Push a copy of the path shape at `index` running the other way. Its
/// points are shared with the original, and a polygon keeps its first
/// point.
fn pushReversed(lua: *Lua, index: i32, tag: Tag) void {
    util.pushCopy(lua, index);
    if (std.meta.eql(tag, .{ .known = .line })) {
        _ = lua.getField(index, "b");
        lua.setField(-2, "a");
        _ = lua.getField(index, "a");
        lua.setField(-2, "b");
        return;
    }
    const closed = std.meta.eql(tag, .{ .known = .polygon });
    _ = lua.getField(index, "points");
    const pts = lua.getTop();
    const n = util.len(lua, pts);
    lua.createTable(@intCast(n), 0);
    for (1..n + 1) |i| {
        const source = if (closed) (if (i == 1) 1 else n + 2 - i) else n + 1 - i;
        _ = util.rawGet(lua, pts, source);
        util.rawSet(lua, -2, i);
    }
    lua.remove(pts);
    lua.setField(-2, "points");
}

/// orderPaths(list, {start, budget, neighbors}) -> the reordered list,
/// travel before, travel after. Paths that run better the other way come
/// back reversed.
fn orderPaths(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    lua.checkType(1, .table);
    var ends: std.ArrayList([2]Vec2) = .empty;
    var i: usize = 1;
    var tags: std.ArrayList(Tag) = .empty;
    while (pushItem(lua, 1, i)) : (i += 1) {
        const index = lua.getTop();
        const tag = if (lua.isTable(index)) shapeTag(lua, index) else Tag.other;
        try tags.append(arena, tag);
        try ends.append(arena, pathEnds(lua, index, tag, i));
        lua.pop(1);
    }
    const opts: pathops.order.Options = .{
        .start = if (lua.isTable(2)) optVec2(lua, 2, "start", .{ 0, 0 }) else .{ 0, 0 },
        .budget = @intCast(std.math.clamp(util.optInt(lua, 2, "budget", 4_000_000), 0, 1 << 40)),
        .neighbors = @intCast(std.math.clamp(util.optInt(lua, 2, "neighbors", 10), 1, 64)),
    };
    const o = try pathops.order.orderPaths(arena, ends.items, opts);
    lua.createTable(@intCast(o.order.len), 0);
    for (o.order, o.reversed, 1..) |k, reversed, slot| {
        _ = util.rawGet(lua, 1, k + 1);
        if (reversed) {
            pushReversed(lua, lua.getTop(), tags.items[k]);
            lua.remove(-2);
        }
        util.rawSet(lua, -2, slot);
    }
    lua.pushNumber(o.travel_before);
    lua.pushNumber(o.travel_after);
    return 3;
}

/// joinPaths(list, tolerance) -> polylines, and polygons for chains that
/// close on themselves
fn joinPaths(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try readPaths(lua, arena, 1);
    const tol = lua.optNumber(2) orelse 1e-9;
    const out = try pathops.order.joinPaths(arena, paths, tol);
    lua.createTable(@intCast(out.len), 0);
    for (out, 1..) |j, i| {
        pushShape(lua, if (j.closed) "polygon" else "polyline", j.points);
        util.rawSet(lua, -2, i);
    }
    return 1;
}
