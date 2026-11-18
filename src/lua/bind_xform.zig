//! core.xform: affine transforms of shape tables, and the kaleidoscope
//! built on them. The prelude exports these as gen.translate and friends
//! directly, so an error names the script line that made the call.
//!
//! A transformed shape is a shallow copy of the input with its geometry
//! replaced, so extra keys ride along. A shape that flattens to a polygon
//! comes back as a fresh {type, points} table. The geometry is
//! src/algo/xform.zig.

const std = @import("std");

const zlua = @import("zlua");
const c = zlua.c;
const genpuin = @import("genpuin");
const xform = genpuin.algo.xform;
const Transform = xform.Transform;

const util = @import("util.zig");
const Lua = util.Lua;
const Vec2 = util.Vec2;

pub const functions = [_]zlua.FnReg{
    .{ .name = "translate", .func = zlua.wrap(translate) },
    .{ .name = "rotate", .func = zlua.wrap(rotate) },
    .{ .name = "rotateAround", .func = zlua.wrap(rotateAround) },
    .{ .name = "scale", .func = zlua.wrap(scale) },
    .{ .name = "scaleAround", .func = zlua.wrap(scaleAround) },
    .{ .name = "reflectX", .func = zlua.wrap(reflectX) },
    .{ .name = "reflectY", .func = zlua.wrap(reflectY) },
    .{ .name = "reflect", .func = zlua.wrap(reflect) },
    .{ .name = "kaleidoscope", .func = zlua.wrap(kaleidoscope) },
};

fn checkVec2(lua: *Lua, arg: i32) Vec2 {
    return util.readVec2(lua, arg) orelse lua.argError(arg, "expected a point {x, y}");
}

/// translate(shape, dx, dy)
fn translate(lua: *Lua) i32 {
    push(lua, 1, .{ .translate = .{ lua.checkNumber(2), lua.checkNumber(3) } });
    return 1;
}

/// rotate(shape, angle) around the origin
fn rotate(lua: *Lua) i32 {
    push(lua, 1, .{ .rotate = .init(lua.checkNumber(2)) });
    return 1;
}

/// rotateAround(shape, angle, pivot)
fn rotateAround(lua: *Lua) i32 {
    push(lua, 1, .rotateAround(lua.checkNumber(2), checkVec2(lua, 3)));
    return 1;
}

/// scale(shape, sx, sy?) from the origin, uniform without sy
fn scale(lua: *Lua) i32 {
    const sx = lua.checkNumber(2);
    const sy = lua.optNumber(3) orelse sx;
    push(lua, 1, .{ .scale = .{ sx, sy } });
    return 1;
}

/// scaleAround(shape, sx, sy, pivot)
fn scaleAround(lua: *Lua) i32 {
    const factor: Vec2 = .{ lua.checkNumber(2), lua.checkNumber(3) };
    push(lua, 1, .{ .scale_around = .{ .factor = factor, .pivot = checkVec2(lua, 4) } });
    return 1;
}

/// reflectX(shape) negates x
fn reflectX(lua: *Lua) i32 {
    push(lua, 1, .reflect_x);
    return 1;
}

/// reflectY(shape) negates y
fn reflectY(lua: *Lua) i32 {
    push(lua, 1, .reflect_y);
    return 1;
}

/// reflect(shape, center, angle) across the axis through center
fn reflect(lua: *Lua) i32 {
    push(lua, 1, .reflectAcross(checkVec2(lua, 2), lua.checkNumber(3)));
    return 1;
}

/// kaleidoscope(n, center, shapes) -> for each shape and each of the n
/// slices, a copy rotated into the slice and one mirrored across its
/// bisector.
fn kaleidoscope(lua: *Lua) i32 {
    const n = lua.checkNumber(1);
    const center = checkVec2(lua, 2);
    lua.checkType(3, .table);
    const slice = (2 * std.math.pi) / n;
    lua.newTable();
    var k: usize = 0;
    var s: usize = 1;
    while (pushItem(lua, 3, s)) : (s += 1) {
        const shape = lua.absIndex(-1);
        var i: f64 = 0;
        while (i <= n - 1) : (i += 1) {
            push(lua, shape, .rotateAround(i * slice, center));
            k += 1;
            util.rawSet(lua, -3, k);
            push(lua, shape, .reflectAcross(center, (i + 1) * slice / 2));
            k += 1;
            util.rawSet(lua, -3, k);
        }
        lua.pop(1);
    }
    return 1;
}

const Kind = enum { line, polyline, polygon, spline, compound, bezier, circle, ellipse, rect, arc, field };

/// Push the image of the shape at `index` under `t`.
fn push(lua: *Lua, index_in: i32, t: Transform) void {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("xform: expected a shape table", .{});
    const kind: ?Kind = blk: {
        defer lua.pop(1);
        if (lua.getField(index, "type") != .string) break :blk null;
        break :blk std.meta.stringToEnum(Kind, lua.toString(-1) catch unreachable); // type checked above
    };
    switch (kind orelse return util.pushCopy(lua, index)) {
        .line => {
            util.pushCopy(lua, index);
            setPoint(lua, "a", t.apply(needVec2(lua, index, "a")));
            setPoint(lua, "b", t.apply(needVec2(lua, index, "b")));
        },
        .bezier => {
            util.pushCopy(lua, index);
            inline for (.{ "p0", "p1", "p2", "p3" }) |key| setPoint(lua, key, t.apply(needVec2(lua, index, key)));
        },
        .polyline, .polygon, .spline => {
            util.pushCopy(lua, index);
            _ = lua.getField(index, "points");
            pushMapped(lua, -1, t);
            lua.setField(-3, "points");
            lua.pop(1);
        },
        .compound => {
            util.pushCopy(lua, index);
            _ = lua.getField(index, "contours");
            const contours = lua.absIndex(-1);
            if (!lua.isTable(contours)) lua.raiseErrorStr("xform: compound needs a list of contours", .{});
            lua.newTable();
            var i: usize = 1;
            while (pushItem(lua, contours, i)) : (i += 1) {
                pushMapped(lua, -1, t);
                lua.remove(-2);
                util.rawSet(lua, -2, i);
            }
            lua.remove(-2);
            lua.setField(-2, "contours");
        },
        .circle => {
            const circle: xform.Circle = .{ .center = needVec2(lua, index, "center"), .r = needNumber(lua, index, "r") };
            switch (xform.circle(t, circle)) {
                .circle => |img| {
                    util.pushCopy(lua, index);
                    setPoint(lua, "center", img.center);
                    setNumber(lua, "r", img.r);
                },
                .ellipse => |img| {
                    util.pushCopy(lua, index);
                    setPoint(lua, "center", img.center);
                    _ = lua.pushString("ellipse");
                    lua.setField(-2, "type");
                    lua.pushNil();
                    lua.setField(-2, "r");
                    setNumber(lua, "rx", img.rx);
                    setNumber(lua, "ry", img.ry);
                },
                .polygon => |outline| pushPolygon(lua, outline, t),
            }
        },
        .ellipse => {
            const e: xform.Ellipse = .{
                .center = needVec2(lua, index, "center"),
                .rx = needNumber(lua, index, "rx"),
                .ry = needNumber(lua, index, "ry"),
            };
            switch (xform.ellipse(t, e)) {
                .ellipse => |img| {
                    util.pushCopy(lua, index);
                    setPoint(lua, "center", img.center);
                    setNumber(lua, "rx", img.rx);
                    setNumber(lua, "ry", img.ry);
                },
                .polygon => |outline| pushPolygon(lua, outline, t),
            }
        },
        .rect => {
            var r = readBox(lua, index);
            r.rx = optNumber(lua, index, "rx");
            r.ry = optNumber(lua, index, "ry");
            switch (xform.rect(t, r)) {
                .rect => |img| {
                    util.pushCopy(lua, index);
                    setBox(lua, img);
                    setOptNumber(lua, "rx", img.rx);
                    setOptNumber(lua, "ry", img.ry);
                },
                .polygon => |outline| pushPolygon(lua, outline, t),
            }
        },
        .arc => {
            const a: xform.Arc = .{
                .center = needVec2(lua, index, "center"),
                .r = needNumber(lua, index, "r"),
                .start = needNumber(lua, index, "startAngle"),
                .end = needNumber(lua, index, "endAngle"),
            };
            const img = xform.arc(t, a) catch |err| switch (err) {
                error.NonUniformScale => lua.raiseErrorStr("xform: an arc cannot take a non-uniform scale", .{}),
            };
            util.pushCopy(lua, index);
            setPoint(lua, "center", img.center);
            setNumber(lua, "r", img.r);
            setNumber(lua, "startAngle", img.start);
            setNumber(lua, "endAngle", img.end);
        },
        .field => {
            const img = xform.image(t, readBox(lua, index)) catch |err| switch (err) {
                error.ImageTransform => lua.raiseErrorStr("xform: an image only takes translation and positive axis scales", .{}),
            };
            util.pushCopy(lua, index);
            setBox(lua, img);
        },
    }
}

/// Push t[i] of the table at `index` unless it is nil, as ipairs walks.
fn pushItem(lua: *Lua, index: i32, i: usize) bool {
    if (util.rawGet(lua, index, i) != .nil) return true;
    lua.pop(1);
    return false;
}

/// Push a new list of the points of the list at `index` mapped by `t`.
/// Like ipairs, the list ends at the first nil. This is the hot path of
/// every transform, so it talks to the C API directly and keeps the call
/// count per point low.
fn pushMapped(lua: *Lua, index_in: i32, t: Transform) void {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("xform: expected a list of points", .{});
    const l: *c.lua_State = @ptrCast(lua);
    c.lua_createtable(l, @intCast(util.len(lua, index)), 0);
    var i: c_int = 1;
    while (true) : (i += 1) {
        rawGetIndex(l, index, i);
        switch (c.lua_type(l, -1)) {
            c.LUA_TTABLE => {},
            c.LUA_TNIL => {
                c.lua_settop(l, -2);
                break;
            },
            else => lua.raiseErrorStr("xform: point %d is not {x, y}", .{i}),
        }
        rawGetIndex(l, -1, 1);
        rawGetIndex(l, -2, 2);
        var x_ok: c_int = 0;
        var y_ok: c_int = 0;
        const x = c.lua_tonumberx(l, -2, &x_ok);
        const y = c.lua_tonumberx(l, -1, &y_ok);
        if (x_ok == 0 or y_ok == 0) lua.raiseErrorStr("xform: point %d is not {x, y}", .{i});
        c.lua_settop(l, -4);
        const p = t.apply(.{ x, y });
        c.lua_createtable(l, 2, 0);
        c.lua_pushnumber(l, p[0]);
        c.lua_rawseti(l, -2, 1);
        c.lua_pushnumber(l, p[1]);
        c.lua_rawseti(l, -2, 2);
        c.lua_rawseti(l, -2, i);
    }
}

/// lua_rawgeti, which returns the type from Lua 5.3 on.
fn rawGetIndex(l: *c.lua_State, index: c_int, i: c_int) void {
    _ = c.lua_rawgeti(l, index, i);
}

fn pushPolygon(lua: *Lua, outline: anytype, t: Transform) void {
    lua.createTable(0, 2);
    _ = lua.pushString("polygon");
    lua.setField(-2, "type");
    const n = outline.len();
    lua.createTable(@intCast(n), 0);
    for (0..n) |i| {
        util.pushVec2(lua, t.apply(outline.point(i)));
        util.rawSet(lua, -2, i + 1);
    }
    lua.setField(-2, "points");
}

fn needVec2(lua: *Lua, index: i32, key: [:0]const u8) Vec2 {
    defer lua.pop(1);
    _ = lua.getField(index, key);
    return util.readVec2(lua, -1) orelse lua.raiseErrorStr("xform: shape needs '%s' as {x, y}", .{key.ptr});
}

fn needNumber(lua: *Lua, index: i32, key: [:0]const u8) f64 {
    return optNumber(lua, index, key) orelse lua.raiseErrorStr("xform: shape needs a number '%s'", .{key.ptr});
}

fn optNumber(lua: *Lua, index: i32, key: [:0]const u8) ?f64 {
    defer lua.pop(1);
    if (lua.getField(index, key) != .number) return null;
    return lua.toNumber(-1) catch unreachable; // type checked above
}

fn readBox(lua: *Lua, index: i32) xform.Rect {
    return .{
        .x = needNumber(lua, index, "x"),
        .y = needNumber(lua, index, "y"),
        .w = needNumber(lua, index, "w"),
        .h = needNumber(lua, index, "h"),
    };
}

fn setPoint(lua: *Lua, key: [:0]const u8, p: Vec2) void {
    util.pushVec2(lua, p);
    lua.setField(-2, key);
}

fn setNumber(lua: *Lua, key: [:0]const u8, v: f64) void {
    lua.pushNumber(v);
    lua.setField(-2, key);
}

fn setOptNumber(lua: *Lua, key: [:0]const u8, v: ?f64) void {
    if (v) |x| lua.pushNumber(x) else lua.pushNil();
    lua.setField(-2, key);
}

fn setBox(lua: *Lua, r: xform.Rect) void {
    setNumber(lua, "x", r.x);
    setNumber(lua, "y", r.y);
    setNumber(lua, "w", r.w);
    setNumber(lua, "h", r.h);
}
