//! The transcendental maths genpuin uses, in place of the platform libm.
//! Zig code calls these rather than the builtins directly, and the CLI's
//! Lua binds to the same code (src/lua/math_exports.zig), so a result is
//! the same on every OS.
//!
//! sin, cos, tan, exp, log, log2, log10 and fmod are the builtins, which
//! lower to calls to those C symbols. The CLI links them to compiler-rt's
//! definitions. The rest are std.math's pure Zig versions. Each is
//! noinline so LLVM never sees a builtin next to another or with a
//! constant argument: it would merge sin and cos of one value into
//! Darwin's __sincos_stret and fold constants with the compiler's own
//! maths. Correctly rounded operations (@sqrt, @floor, + - * /) give the
//! same bits everywhere and stay builtins at the call sites.

const std = @import("std");

pub noinline fn sin(x: f64) f64 {
    return @sin(x);
}

pub noinline fn cos(x: f64) f64 {
    return @cos(x);
}

pub noinline fn tan(x: f64) f64 {
    return @tan(x);
}

pub noinline fn exp(x: f64) f64 {
    return @exp(x);
}

pub noinline fn log(x: f64) f64 {
    return @log(x);
}

pub noinline fn log2(x: f64) f64 {
    return @log2(x);
}

pub noinline fn log10(x: f64) f64 {
    return @log10(x);
}

pub noinline fn fmod(x: f64, y: f64) f64 {
    return @rem(x, y);
}

pub noinline fn asin(x: f64) f64 {
    return std.math.asin(x);
}

pub noinline fn acos(x: f64) f64 {
    return std.math.acos(x);
}

pub noinline fn atan(x: f64) f64 {
    return std.math.atan(x);
}

pub noinline fn atan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}

pub noinline fn sinh(x: f64) f64 {
    return std.math.sinh(x);
}

pub noinline fn cosh(x: f64) f64 {
    return std.math.cosh(x);
}

pub noinline fn tanh(x: f64) f64 {
    return std.math.tanh(x);
}

/// x raised to y. Squares exactly when y is 2, as Lua 5.4 and LuaJIT's
/// compiled traces do for `x ^ 2`.
pub noinline fn pow(x: f64, y: f64) f64 {
    if (y == 2) return x * x;
    return std.math.pow(f64, x, y);
}

/// Logarithm of x in base b, as LuaJIT's math.log(x, b) computes it.
pub fn logBase(x: f64, b: f64) f64 {
    return log2(x) * (1.0 / log2(b));
}

/// Floored modulo, the result taking the sign of b: Lua 5.4's float `%`
/// and gen.mod on every flavour. fmod is exact, so the only rounding is
/// the one addition that moves a remainder of the wrong sign into b's
/// range.
pub fn mod(a: f64, b: f64) f64 {
    const m = fmod(a, b);
    const wrong_sign = if (m > 0) b < 0 else m < 0 and b > 0;
    return if (wrong_sign) m + b else m;
}

/// LuaJIT's float `%`, a - floor(a / b) * b. Rounds in the division and
/// again in the product, so it can miss the true remainder by a whole b
/// (luajitMod(1, 0.1) is 0). For seeded algorithms ported from LuaJIT
/// scripts whose output depends on that rounding, like Perlin's LCG.
pub fn luajitMod(a: f64, b: f64) f64 {
    return a - @floor(a / b) * b;
}

test "math: mod follows the divisor's sign" {
    try std.testing.expectEqual(@as(f64, 1), mod(-7, 4));
    try std.testing.expectEqual(@as(f64, 3), mod(7, 4));
    try std.testing.expectEqual(@as(f64, -1), mod(7, -4));
    try std.testing.expectEqual(@as(f64, 0.5), mod(2.5, 1));
    try std.testing.expectEqual(@as(f64, 0.5), mod(-2.5, 1));
}

test "math: mod is exact where luajitMod rounds" {
    try std.testing.expectEqual(@as(u64, 0x3fb9999999999996), @as(u64, @bitCast(mod(1, 0.1))));
    try std.testing.expectEqual(@as(f64, 0), luajitMod(1, 0.1));
}

test "math: luajitMod follows the divisor's sign" {
    try std.testing.expectEqual(@as(f64, 1), luajitMod(-7, 4));
    try std.testing.expectEqual(@as(f64, -1), luajitMod(7, -4));
}
