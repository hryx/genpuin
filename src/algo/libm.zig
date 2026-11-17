//! Transcendental functions as LuaJIT computes them. LuaJIT calls the
//! platform libm for math.sin, cos, log and atan2, and Zig's own versions
//! differ from it in the last bit for some inputs, so ported code calls
//! libm whenever libc is linked.

const std = @import("std");
const builtin = @import("builtin");

const c = struct {
    extern "c" fn sin(x: f64) f64;
    extern "c" fn cos(x: f64) f64;
    extern "c" fn log(x: f64) f64;
    extern "c" fn atan2(y: f64, x: f64) f64;
};

pub fn sin(x: f64) f64 {
    return if (builtin.link_libc) c.sin(x) else @sin(x);
}

pub fn cos(x: f64) f64 {
    return if (builtin.link_libc) c.cos(x) else @cos(x);
}

pub fn log(x: f64) f64 {
    return if (builtin.link_libc) c.log(x) else @log(x);
}

pub fn atan2(y: f64, x: f64) f64 {
    return if (builtin.link_libc) c.atan2(y, x) else std.math.atan2(y, x);
}

/// Lua's float modulo, a - floor(a / b) * b, as LuaJIT evaluates it.
pub fn mod(a: f64, b: f64) f64 {
    return a - @floor(a / b) * b;
}

test "libm: Lua modulo follows the divisor's sign" {
    try std.testing.expectEqual(@as(f64, 1), mod(-7, 4));
    try std.testing.expectEqual(@as(f64, 3), mod(7, 4));
    try std.testing.expectEqual(@as(f64, 0.5), mod(2.5, 1));
}
