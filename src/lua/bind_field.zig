//! core.field: create, read and transform Field userdata from Lua.
//! Methods are also reachable as f:get(x, y) and friends.

const std = @import("std");

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const util = @import("util.zig");
const Lua = util.Lua;
const Field = util.Field;

pub const functions = [_]zlua.FnReg{
    .{ .name = "new", .func = zlua.wrap(new) },
};

pub const methods = [_]zlua.FnReg{
    .{ .name = "get", .func = zlua.wrap(get) },
    .{ .name = "set", .func = zlua.wrap(set) },
    .{ .name = "add", .func = zlua.wrap(add) },
    .{ .name = "sample", .func = zlua.wrap(sample) },
    .{ .name = "size", .func = zlua.wrap(size) },
    .{ .name = "minMax", .func = zlua.wrap(minMax) },
    .{ .name = "normalize", .func = zlua.wrap(normalize) },
    .{ .name = "clone", .func = zlua.wrap(clone) },
    .{ .name = "fill", .func = zlua.wrap(fill) },
    .{ .name = "map", .func = zlua.wrap(map) },
    .{ .name = "combine", .func = zlua.wrap(combine) },
};

/// Register the Field metatable. Called once per state before any Field
/// is pushed.
pub fn registerMetatable(lua: *Lua) void {
    lua.newMetatable(util.field_meta) catch unreachable; // first and only registration
    lua.newTable();
    util.setFuncs(lua, &methods);
    lua.setField(-2, "__index");
    lua.pushFunction(zlua.wrap(util.fieldGc));
    lua.setField(-2, "__gc");
    lua.pushFunction(zlua.wrap(lenMeta));
    lua.setField(-2, "__len");
    lua.pop(1);
}

/// new(w, h, value?) -> Field
fn new(lua: *Lua) !i32 {
    const w = util.checkU32(lua, 1);
    const h = util.checkU32(lua, 2);
    const v: f32 = @floatCast(lua.optNumber(3) orelse 0);
    util.pushField(lua, try .init(lua.allocator(), w, h, v));
    return 1;
}

fn cell(lua: *Lua, f: *const Field, ax: i32, ay: i32) [2]u32 {
    const x = lua.checkNumber(ax);
    const y = lua.checkNumber(ay);
    if (!(x >= 0 and y >= 0 and x < @as(f64, @floatFromInt(f.w)) and y < @as(f64, @floatFromInt(f.h)))) {
        lua.raiseErrorStr("field cell (%f, %f) out of range", .{ x, y });
    }
    return .{ @intFromFloat(x), @intFromFloat(y) };
}

/// f:get(x, y) with zero-based cell coordinates.
fn get(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    const c = cell(lua, f, 2, 3);
    lua.pushNumber(f.get(c[0], c[1]));
    return 1;
}

fn set(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    const c = cell(lua, f, 2, 3);
    f.set(c[0], c[1], @floatCast(lua.checkNumber(4)));
    return 0;
}

fn add(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    const c = cell(lua, f, 2, 3);
    f.ptr(c[0], c[1]).* += @floatCast(lua.checkNumber(4));
    return 0;
}

/// f:sample(x, y) bilinear, in cell units, edge-clamped.
fn sample(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    lua.pushNumber(f.sample(lua.checkNumber(2), lua.checkNumber(3)));
    return 1;
}

fn size(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    lua.pushInteger(@intCast(f.w));
    lua.pushInteger(@intCast(f.h));
    return 2;
}

fn lenMeta(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    lua.pushInteger(@intCast(f.data.len));
    return 1;
}

fn minMax(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    const r = f.minMax();
    lua.pushNumber(r[0]);
    lua.pushNumber(r[1]);
    return 2;
}

fn normalize(lua: *Lua) i32 {
    util.checkField(lua, 1).normalize();
    lua.pushValue(1);
    return 1;
}

fn clone(lua: *Lua) !i32 {
    const f = util.checkField(lua, 1);
    util.pushField(lua, try f.clone(lua.allocator()));
    return 1;
}

/// f:fill(fn(x, y) -> v) calls back into Lua per cell. Fine for small
/// fields, slow for big ones.
fn fill(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    lua.checkType(2, .function);
    for (0..f.h) |y| for (0..f.w) |x| {
        lua.pushValue(2);
        lua.pushInteger(@intCast(x));
        lua.pushInteger(@intCast(y));
        lua.call(.{ .args = 2, .results = 1 });
        f.set(@intCast(x), @intCast(y), @floatCast(lua.toNumber(-1) catch 0));
        lua.pop(1);
    };
    lua.pushValue(1);
    return 1;
}

/// f:map(fn(v, x, y) -> v) in place.
fn map(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    lua.checkType(2, .function);
    for (0..f.h) |y| for (0..f.w) |x| {
        lua.pushValue(2);
        lua.pushNumber(f.get(@intCast(x), @intCast(y)));
        lua.pushInteger(@intCast(x));
        lua.pushInteger(@intCast(y));
        lua.call(.{ .args = 3, .results = 1 });
        f.set(@intCast(x), @intCast(y), @floatCast(lua.toNumber(-1) catch 0));
        lua.pop(1);
    };
    lua.pushValue(1);
    return 1;
}

const Op = enum { add, sub, mul, min, max, mix };

/// f:combine(op, other, t?) in place. `other` is a Field of the same
/// size or a number. `mix` lerps toward other by t.
fn combine(lua: *Lua) i32 {
    const f = util.checkField(lua, 1);
    const op_name = lua.toString(2) catch lua.argError(2, "expected an op name");
    const op = std.meta.stringToEnum(Op, op_name) orelse lua.argError(2, "unknown op");
    const t: f32 = @floatCast(lua.optNumber(4) orelse 0.5);
    const other = util.toField(lua, 3);
    const k: f32 = if (other == null) @floatCast(lua.checkNumber(3)) else 0;
    if (other) |o| if (o.w != f.w or o.h != f.h) lua.argError(3, "field sizes differ");
    for (f.data, 0..) |*v, i| {
        const b = if (other) |o| o.data[i] else k;
        v.* = switch (op) {
            .add => v.* + b,
            .sub => v.* - b,
            .mul => v.* * b,
            .min => @min(v.*, b),
            .max => @max(v.*, b),
            .mix => std.math.lerp(v.*, b, t),
        };
    }
    lua.pushValue(1);
    return 1;
}
