//! Lua's `math` table on genpuin's maths, the same on every Lua flavour.
//!
//! The transcendental math.* functions and `^` already run src/math.zig
//! through the C symbols math_exports.zig provides. `install` evens out
//! what the flavours offer. math.atan2, math.pow, math.log10, math.sinh,
//! math.cosh and math.tanh are added where the flavour lacks them (Lua
//! 5.3 and later). On PUC Lua math.log(x, b) is replaced by LuaJIT's
//! log2(x) * (1 / log2(b)), so a based log gives the same bits on both.

const std = @import("std");

const zlua = @import("zlua");
const math = @import("genpuin").math;

const bind_testing = @import("bind_testing.zig");
const util = @import("util.zig");
const Lua = util.Lua;

/// Fill in the math table of a fresh state. Call after openLibs.
pub fn install(lua: *Lua) void {
    _ = lua.getGlobal("math");
    addMissing(lua, "atan2", zlua.wrap(Binary(math.atan2).lua));
    addMissing(lua, "pow", zlua.wrap(Binary(math.pow).lua));
    addMissing(lua, "log10", zlua.wrap(Unary(math.log10).lua));
    addMissing(lua, "sinh", zlua.wrap(Unary(math.sinh).lua));
    addMissing(lua, "cosh", zlua.wrap(Unary(math.cosh).lua));
    addMissing(lua, "tanh", zlua.wrap(Unary(math.tanh).lua));
    if (zlua.lang != .luajit) {
        lua.pushFunction(zlua.wrap(log));
        lua.setField(-2, "log");
    }
    lua.pop(1);
}

fn addMissing(lua: *Lua, name: [:0]const u8, f: zlua.CFn) void {
    const present = lua.getField(-1, name) != .nil;
    lua.pop(1);
    if (present) return;
    lua.pushFunction(f);
    lua.setField(-2, name);
}

fn Unary(comptime f: fn (f64) f64) type {
    return struct {
        fn lua(l: *Lua) i32 {
            l.pushNumber(f(l.checkNumber(1)));
            return 1;
        }
    };
}

fn Binary(comptime f: fn (f64, f64) f64) type {
    return struct {
        fn lua(l: *Lua) i32 {
            l.pushNumber(f(l.checkNumber(1), l.checkNumber(2)));
            return 1;
        }
    };
}

/// math.log(x, base?) with LuaJIT's formula for the based form.
fn log(lua: *Lua) i32 {
    const x = lua.checkNumber(1);
    if (lua.getTop() < 2) {
        lua.pushNumber(math.log(x));
    } else {
        lua.pushNumber(math.logBase(x, lua.checkNumber(2)));
    }
    return 1;
}

/// Hard inputs as IEEE bits: zeros, subnormals, near multiples of pi/2,
/// huge arguments, values next to 1 for log, overflow edges for exp and
/// pow. The same sets as test/test-math.lua.
const hard = .{
    .trig = &[_][2]u64{
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x0000000000000000 },
        .{ 0x8000000000000001, 0x0000000000000000 },
        .{ 0x0010000000000000, 0x0000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0000000000000000 },
        .{ 0x3e45798ee2308c3a, 0x0000000000000000 },
        .{ 0x3ee4f8b588e368f1, 0x0000000000000000 },
        .{ 0x3fe0000000000000, 0x0000000000000000 },
        .{ 0x3fe921fb54442d18, 0x0000000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0x4008000000000000, 0x0000000000000000 },
        .{ 0x4059000000000000, 0x0000000000000000 },
        .{ 0x4086300000000000, 0x0000000000000000 },
        .{ 0x412e848000000000, 0x0000000000000000 },
        .{ 0xc12e848000000000, 0x0000000000000000 },
        .{ 0x430c6bf526340000, 0x0000000000000000 },
        .{ 0xc30c6bf526340000, 0x0000000000000000 },
        .{ 0x4480f0cf064dd592, 0x0000000000000000 },
        .{ 0x41d0000000000000, 0x0000000000000000 },
        .{ 0x43b0000000000000, 0x0000000000000000 },
        .{ 0x7e37e43c8800759c, 0x0000000000000000 },
        .{ 0x7fefffffffffffff, 0x0000000000000000 },
        .{ 0x7506ac5b262ca1ff, 0x0000000000000000 },
        .{ 0x7506ac5b262ca1ff, 0x0000000000000000 },
        .{ 0x3ff921fb54442d18, 0x0000000000000000 },
        .{ 0x3ff921fb54442d17, 0x0000000000000000 },
        .{ 0x3ff921fb54442d19, 0x0000000000000000 },
        .{ 0xbff921fb54442d18, 0x0000000000000000 },
        .{ 0x400921fb54442d18, 0x0000000000000000 },
        .{ 0x400921fb54442d17, 0x0000000000000000 },
        .{ 0x400921fb54442d19, 0x0000000000000000 },
        .{ 0xc00921fb54442d18, 0x0000000000000000 },
        .{ 0x4012d97c7f3321d2, 0x0000000000000000 },
        .{ 0x4012d97c7f3321d1, 0x0000000000000000 },
        .{ 0x4012d97c7f3321d3, 0x0000000000000000 },
        .{ 0xc012d97c7f3321d2, 0x0000000000000000 },
        .{ 0x401921fb54442d18, 0x0000000000000000 },
        .{ 0x401921fb54442d17, 0x0000000000000000 },
        .{ 0x401921fb54442d19, 0x0000000000000000 },
        .{ 0xc01921fb54442d18, 0x0000000000000000 },
        .{ 0x401f6a7a2955385e, 0x0000000000000000 },
        .{ 0x401f6a7a2955385d, 0x0000000000000000 },
        .{ 0x401f6a7a2955385f, 0x0000000000000000 },
        .{ 0xc01f6a7a2955385e, 0x0000000000000000 },
        .{ 0x4025fdbbe9bba775, 0x0000000000000000 },
        .{ 0x4025fdbbe9bba774, 0x0000000000000000 },
        .{ 0x4025fdbbe9bba776, 0x0000000000000000 },
        .{ 0xc025fdbbe9bba775, 0x0000000000000000 },
        .{ 0x402f6a7a2955385e, 0x0000000000000000 },
        .{ 0x402f6a7a2955385d, 0x0000000000000000 },
        .{ 0x402f6a7a2955385f, 0x0000000000000000 },
        .{ 0xc02f6a7a2955385e, 0x0000000000000000 },
        .{ 0x4063a28c59d5433b, 0x0000000000000000 },
        .{ 0x4063a28c59d5433a, 0x0000000000000000 },
        .{ 0x4063a28c59d5433c, 0x0000000000000000 },
        .{ 0xc063a28c59d5433b, 0x0000000000000000 },
        .{ 0x40988b2f704a9409, 0x0000000000000000 },
        .{ 0x40988b2f704a9408, 0x0000000000000000 },
        .{ 0x40988b2f704a940a, 0x0000000000000000 },
        .{ 0xc0988b2f704a9409, 0x0000000000000000 },
        .{ 0x41032cbd0fba43a7, 0x0000000000000000 },
        .{ 0x41032cbd0fba43a6, 0x0000000000000000 },
        .{ 0x41032cbd0fba43a8, 0x0000000000000000 },
        .{ 0xc1032cbd0fba43a7, 0x0000000000000000 },
    },
    .asin = &[_][2]u64{
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x0000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0000000000000000 },
        .{ 0x3c670ef54646d497, 0x0000000000000000 },
        .{ 0x3e45798ee2308c3a, 0x0000000000000000 },
        .{ 0x3fc0000000000000, 0x0000000000000000 },
        .{ 0x3fe0000000000000, 0x0000000000000000 },
        .{ 0xbfe0000000000000, 0x0000000000000000 },
        .{ 0x3fdfffffffffffff, 0x0000000000000000 },
        .{ 0x3fe6a09e667f3bcd, 0x0000000000000000 },
        .{ 0x3fefffffffffffff, 0x0000000000000000 },
        .{ 0xbfefffffffffffff, 0x0000000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0xbff0000000000000, 0x0000000000000000 },
        .{ 0x3fef333333333333, 0x0000000000000000 },
        .{ 0x3fe2000000000000, 0x0000000000000000 },
    },
    .atan = &[_][2]u64{
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x0000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0000000000000000 },
        .{ 0x3e45798ee2308c3a, 0x0000000000000000 },
        .{ 0x3fdc000000000000, 0x0000000000000000 },
        .{ 0x3fe6000000000000, 0x0000000000000000 },
        .{ 0x3ff3000000000000, 0x0000000000000000 },
        .{ 0x4003800000000000, 0x0000000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0xbff0000000000000, 0x0000000000000000 },
        .{ 0x4197d78400000000, 0x0000000000000000 },
        .{ 0x7e37e43c8800759c, 0x0000000000000000 },
        .{ 0x7fefffffffffffff, 0x0000000000000000 },
        .{ 0x7ff0000000000000, 0x0000000000000000 },
        .{ 0xfff0000000000000, 0x0000000000000000 },
        .{ 0x4050800000000000, 0x0000000000000000 },
        .{ 0x4410000000000000, 0x0000000000000000 },
    },
    .atan2 = &[_][2]u64{
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x8000000000000000 },
        .{ 0x0000000000000000, 0x8000000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0x0000000000000000, 0xbff0000000000000 },
        .{ 0x8000000000000000, 0xbff0000000000000 },
        .{ 0x3ff0000000000000, 0x3ff0000000000000 },
        .{ 0x3ff0000000000000, 0xbff0000000000000 },
        .{ 0xbff0000000000000, 0xbff0000000000000 },
        .{ 0x0000000000000001, 0x3ff0000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000001 },
        .{ 0x7e37e43c8800759c, 0x01a56e1fc2f8f359 },
        .{ 0x01a56e1fc2f8f359, 0x7e37e43c8800759c },
        .{ 0x7ff0000000000000, 0x7ff0000000000000 },
        .{ 0xfff0000000000000, 0x7ff0000000000000 },
        .{ 0x7ff0000000000000, 0xfff0000000000000 },
        .{ 0x4008000000000000, 0xc010000000000000 },
        .{ 0xc008000000000000, 0x4010000000000000 },
        .{ 0x3e45798ee2308c3a, 0xbff0000000000000 },
    },
    .hyp = &[_][2]u64{
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x0000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0000000000000000 },
        .{ 0x3ddb7cdfd9d7bdbb, 0x0000000000000000 },
        .{ 0x3e2fc862d3e17360, 0x0000000000000000 },
        .{ 0x3fd0000000000000, 0x0000000000000000 },
        .{ 0x3fe0000000000000, 0x0000000000000000 },
        .{ 0x3fe62e42fefa39ef, 0x0000000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0xbff0000000000000, 0x0000000000000000 },
        .{ 0x4000000000000000, 0x0000000000000000 },
        .{ 0x4024000000000000, 0x0000000000000000 },
        .{ 0x4034000000000000, 0x0000000000000000 },
        .{ 0x4036000000000000, 0x0000000000000000 },
        .{ 0x4044000000000000, 0x0000000000000000 },
        .{ 0x40862e3d70a3d70a, 0x0000000000000000 },
        .{ 0x4086333333333333, 0x0000000000000000 },
        .{ 0xc086333333333333, 0x0000000000000000 },
        .{ 0x4086380000000000, 0x0000000000000000 },
        .{ 0x7ff0000000000000, 0x0000000000000000 },
        .{ 0xfff0000000000000, 0x0000000000000000 },
    },
    .exp = &[_][2]u64{
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x0000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0000000000000000 },
        .{ 0x3c9cd2b297d889bc, 0x0000000000000000 },
        .{ 0x3ddb7cdfd9d7bdbb, 0x0000000000000000 },
        .{ 0x3fe0000000000000, 0x0000000000000000 },
        .{ 0x3fe62e42fefa39ef, 0x0000000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0xbff0000000000000, 0x0000000000000000 },
        .{ 0x4000000000000000, 0x0000000000000000 },
        .{ 0x4024000000000000, 0x0000000000000000 },
        .{ 0x4059000000000000, 0x0000000000000000 },
        .{ 0x4085e00000000000, 0x0000000000000000 },
        .{ 0x40862e42fefa39ef, 0x0000000000000000 },
        .{ 0x40862e51eb851eb8, 0x0000000000000000 },
        .{ 0xc086231eb851eb85, 0x0000000000000000 },
        .{ 0xc08748cccccccccd, 0x0000000000000000 },
        .{ 0xc08749999999999a, 0x0000000000000000 },
        .{ 0xc087500000000000, 0x0000000000000000 },
        .{ 0x7ff0000000000000, 0x0000000000000000 },
        .{ 0xfff0000000000000, 0x0000000000000000 },
        .{ 0x3fd62e42fefa39ef, 0x0000000000000000 },
    },
    .log = &[_][2]u64{
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0x3fefffffffffffff, 0x0000000000000000 },
        .{ 0x3ff0000000000001, 0x0000000000000000 },
        .{ 0x3fee000000000000, 0x0000000000000000 },
        .{ 0x3ff1000000000000, 0x0000000000000000 },
        .{ 0x3fefff2e48e8a71e, 0x0000000000000000 },
        .{ 0x3ff00068db8bac71, 0x0000000000000000 },
        .{ 0x3fe0000000000000, 0x0000000000000000 },
        .{ 0x4000000000000000, 0x0000000000000000 },
        .{ 0x4024000000000000, 0x0000000000000000 },
        .{ 0x4059000000000000, 0x0000000000000000 },
        .{ 0x408f400000000000, 0x0000000000000000 },
        .{ 0x3fb999999999999a, 0x0000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x0000000000000000 },
        .{ 0x0010000000000000, 0x0000000000000000 },
        .{ 0x7e37e43c8800759c, 0x0000000000000000 },
        .{ 0x7fefffffffffffff, 0x0000000000000000 },
        .{ 0x4005bf0a8b145769, 0x0000000000000000 },
        .{ 0x4008000000000000, 0x0000000000000000 },
        .{ 0x401c000000000000, 0x0000000000000000 },
        .{ 0x7ff0000000000000, 0x0000000000000000 },
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x8000000000000000, 0x0000000000000000 },
        .{ 0xbff0000000000000, 0x0000000000000000 },
    },
    .pow = &[_][2]u64{
        .{ 0x4000000000000000, 0x3fe0000000000000 },
        .{ 0x4000000000000000, 0xbfe0000000000000 },
        .{ 0x4000000000000000, 0x4000000000000000 },
        .{ 0xc000000000000000, 0x4008000000000000 },
        .{ 0xc000000000000000, 0x4000000000000000 },
        .{ 0xc000000000000000, 0x3fe0000000000000 },
        .{ 0x0000000000000000, 0xbff0000000000000 },
        .{ 0x8000000000000000, 0xbff0000000000000 },
        .{ 0x0000000000000000, 0x0000000000000000 },
        .{ 0x3ff0000000000000, 0x7ff0000000000000 },
        .{ 0xbff0000000000000, 0x7ff0000000000000 },
        .{ 0x4024000000000000, 0x4073400000000000 },
        .{ 0x4024000000000000, 0x4073500000000000 },
        .{ 0x4024000000000000, 0xc074300000000000 },
        .{ 0x4024000000000000, 0xc074400000000000 },
        .{ 0x3ff0000000000001, 0x4341c37937e08000 },
        .{ 0x3fefffffffffffff, 0x4341c37937e08000 },
        .{ 0x4000000000000000, 0x408ff80000000000 },
        .{ 0x4000000000000000, 0x4090000000000000 },
        .{ 0x4000000000000000, 0xc090c80000000000 },
        .{ 0x4000000000000000, 0xc090cc0000000000 },
        .{ 0x3ff8000000000000, 0x3ffb333333333333 },
        .{ 0x4008000000000000, 0x3ffb333333333333 },
        .{ 0x401e000000000000, 0x40344ccccccccccd },
        .{ 0x7e37e43c8800759c, 0x4000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x4000000000000000 },
        .{ 0x3fe0000000000000, 0x412e848000000000 },
        .{ 0x16687e92154ef7ac, 0x3ff8000000000000 },
        .{ 0x7ff0000000000000, 0xc000000000000000 },
        .{ 0xfff0000000000000, 0x4008000000000000 },
        .{ 0x405edd2f1a9fbe77, 0xc01d000000000000 },
        .{ 0x4004000000000000, 0x43e0000000000000 },
    },
    .fmod = &[_][2]u64{
        .{ 0x4016000000000000, 0x4000000000000000 },
        .{ 0xc016000000000000, 0x4000000000000000 },
        .{ 0x4016000000000000, 0xc000000000000000 },
        .{ 0x7e37e43c8800759c, 0x4008000000000000 },
        .{ 0x3ff0000000000000, 0x0000000000000000 },
        .{ 0x0000000000000001, 0x3ff0000000000000 },
        .{ 0x4480f0cf064dd592, 0x3fb999999999999a },
        .{ 0x8000000000000000, 0x3ff0000000000000 },
        .{ 0x7ff0000000000000, 0x3ff0000000000000 },
        .{ 0x3ff0000000000000, 0x7ff0000000000000 },
        .{ 0x401c000000000000, 0x401c000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x0189b759505df0d1 },
        .{ 0x401921fb54442d18, 0x3fb999999999999a },
    },
    .logBase = &[_][2]u64{
        .{ 0x4020000000000000, 0x4000000000000000 },
        .{ 0x408f400000000000, 0x4024000000000000 },
        .{ 0x4059000000000000, 0x4024000000000000 },
        .{ 0x4000000000000000, 0x4024000000000000 },
        .{ 0x4054400000000000, 0x4008000000000000 },
        .{ 0x3fe0000000000000, 0x4000000000000000 },
        .{ 0x01a56e1fc2f8f359, 0x401c000000000000 },
        .{ 0x4014000000000000, 0x3fe0000000000000 },
        .{ 0x3ff0000000000000, 0x4008000000000000 },
        .{ 0x4008000000000000, 0x3ff0000000000000 },
        .{ 0x4024000000000000, 0x4005bf0a8b145769 },
    },
};

const Case = struct {
    name: []const u8,
    /// Lua chunk returning the function under test.
    lua: [:0]const u8,
    set: []const [2]u64,
};

const cases = [_]Case{
    .{ .name = "sin", .lua = "return math.sin", .set = hard.trig },
    .{ .name = "cos", .lua = "return math.cos", .set = hard.trig },
    .{ .name = "tan", .lua = "return math.tan", .set = hard.trig },
    .{ .name = "asin", .lua = "return math.asin", .set = hard.asin },
    .{ .name = "acos", .lua = "return math.acos", .set = hard.asin },
    .{ .name = "atan", .lua = "return function(x) return math.atan(x) end", .set = hard.atan },
    .{ .name = "atan2", .lua = "return math.atan2", .set = hard.atan2 },
    .{ .name = "sinh", .lua = "return math.sinh", .set = hard.hyp },
    .{ .name = "cosh", .lua = "return math.cosh", .set = hard.hyp },
    .{ .name = "tanh", .lua = "return math.tanh", .set = hard.hyp },
    .{ .name = "exp", .lua = "return math.exp", .set = hard.exp },
    .{ .name = "log", .lua = "return function(x) return math.log(x) end", .set = hard.log },
    .{ .name = "log2", .lua = "return function(x) return math.log(x, 2) end", .set = hard.log },
    .{ .name = "log10", .lua = "return math.log10", .set = hard.log },
    .{ .name = "pow", .lua = "return math.pow", .set = hard.pow },
    .{ .name = "pow", .lua = "return function(x, y) return x ^ y end", .set = hard.pow },
    .{ .name = "fmod", .lua = "return math.fmod", .set = hard.fmod },
    .{ .name = "logBase", .lua = "return function(x, b) return math.log(x, b) end", .set = hard.logBase },
};

fn sameBits(a: f64, b: f64) bool {
    return (std.math.isNan(a) and std.math.isNan(b)) or @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

/// A random input for `name`, spread over the range where the function is
/// interesting.
fn spread(r: std.Random, name: []const u8) [2]f64 {
    const eql = std.mem.eql;
    const a = r.float(f64);
    const b = r.float(f64);
    const sign: f64 = if (r.boolean()) -1 else 1;
    if (eql(u8, name, "sin") or eql(u8, name, "cos") or eql(u8, name, "tan"))
        return .{ if (a < 0.6) b * 100 - 50 else sign * math.pow(10, b * 19 - 3), 0 };
    if (eql(u8, name, "asin") or eql(u8, name, "acos")) return .{ b * 2 - 1, 0 };
    if (eql(u8, name, "atan")) return .{ sign * math.pow(10, b * 12 - 4), 0 };
    if (eql(u8, name, "atan2")) return .{ a * 20 - 10, b * 20 - 10 };
    if (eql(u8, name, "sinh") or eql(u8, name, "cosh") or eql(u8, name, "tanh")) return .{ a * 60 - 30, 0 };
    if (eql(u8, name, "exp")) return .{ (b - 0.5) * @as(f64, if (a < 0.5) 20 else 1450), 0 };
    if (eql(u8, name, "log") or eql(u8, name, "log2") or eql(u8, name, "log10"))
        return .{ if (a < 0.4) 0.5 + b * 1.5 else math.pow(10, b * 600 - 300), 0 };
    if (eql(u8, name, "pow")) return .{ math.pow(10, a * 6 - 3), b * 60 - 30 };
    if (eql(u8, name, "fmod")) return .{ sign * math.pow(10, a * 12), math.pow(10, b * 6 - 3) };
    if (eql(u8, name, "logBase")) return .{ math.pow(10, a * 20 - 10), 0.1 + b * 20 };
    unreachable;
}

fn runChunk(lua: *Lua, src: [:0]const u8, results: i32) !void {
    try util.loadBuffer(lua, src, "=test");
    try lua.protectedCall(.{ .args = 0, .results = results });
}

test "bind_math: Lua's math and ^ give math.zig's bits, interpreted and compiled" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    install(lua);

    const modes: []const [:0]const u8 = if (zlua.lang == .luajit)
        &.{ "jit.off() jit.flush()", "jit.on()" }
    else
        &.{""};
    const eval =
        \\local f, xs, ys = ...
        \\local out = {}
        \\for i = 1, #xs do out[i] = f(xs[i], ys[i]) end
        \\return out
    ;
    const n = 400;
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    for (modes) |mode| {
        try runChunk(lua, mode, 0);
        for (cases) |case| {
            var xs: [n]f64 = undefined;
            var ys: [n]f64 = undefined;
            for (case.set, 0..) |p, i| {
                xs[i] = @bitCast(p[0]);
                ys[i] = @bitCast(p[1]);
            }
            for (case.set.len..n) |i| {
                const s = spread(prng.random(), case.name);
                xs[i] = s[0];
                ys[i] = s[1];
            }

            try util.loadBuffer(lua, eval, "=eval");
            try runChunk(lua, case.lua, 1);
            for ([_]*const [n]f64{ &xs, &ys }) |v| {
                lua.newTable();
                for (v, 1..) |x, i| {
                    lua.pushNumber(x);
                    lua.setIndexRaw(-2, @intCast(i));
                }
            }
            try lua.protectedCall(.{ .args = 3, .results = 1 });
            defer lua.pop(1);

            for (xs, ys, 1..) |x, y, i| {
                _ = lua.getIndexRaw(-1, @intCast(i));
                const got = try lua.toNumber(-1);
                lua.pop(1);
                const want = bind_testing.byName(case.name, x, y).?;
                if (!sameBits(got, want)) {
                    std.debug.print("{s} ({s}) x=0x{x:0>16} y=0x{x:0>16} lua=0x{x:0>16} zig=0x{x:0>16}\n", .{
                        case.lua,                mode,
                        @as(u64, @bitCast(x)),   @as(u64, @bitCast(y)),
                        @as(u64, @bitCast(got)), @as(u64, @bitCast(want)),
                    });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
