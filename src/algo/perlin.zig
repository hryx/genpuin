//! 2D improved Perlin noise (Perlin, "Improving Noise", SIGGRAPH 2002)
//! with eight gradients and a permutation table shuffled by an LCG. The
//! LCG runs in f64 the way LuaJIT ran the original Lua, rounding
//! included, so seeded noise matches existing art.

const std = @import("std");

const math = @import("../math.zig");

pub const Perlin = struct {
    perm: [512]u8,

    /// Fisher-Yates over 0..255 driven by s = (s * 1103515245 + 12345)
    /// mod (2^31 - 1). Only the integer part of `seed` is used.
    pub fn init(seed: f64) Perlin {
        var p: [256]u8 = undefined;
        for (&p, 0..) |*v, i| v.* = @intCast(i);
        var s = @floor(seed);
        var i: usize = 255;
        while (i >= 1) : (i -= 1) {
            s = math.luajitMod(s * 1103515245 + 12345, 2147483647);
            const span: f64 = @floatFromInt(i + 1);
            const jf = math.mod(s, span);
            const j: usize = if (jf >= 0 and jf < span) @intFromFloat(jf) else 0;
            std.mem.swap(u8, &p[i], &p[j]);
        }
        var out: Perlin = undefined;
        for (&out.perm, 0..) |*v, k| v.* = p[k % 256];
        return out;
    }

    /// Roughly in [-1, 1]. NaN for non-finite input.
    pub fn noise(n: *const Perlin, x: f64, y: f64) f64 {
        const fx = @floor(x);
        const fy = @floor(y);
        const xm = math.mod(fx, 256);
        const ym = math.mod(fy, 256);
        if (!(xm >= 0 and xm < 256 and ym >= 0 and ym < 256)) return std.math.nan(f64);
        const xi: usize = @intFromFloat(xm);
        const yi: usize = @intFromFloat(ym);
        const xf = x - fx;
        const yf = y - fy;
        const u = fade(xf);
        const v = fade(yf);

        const p = &n.perm;
        const aa = grad[p[p[xi] + yi] % 8];
        const ab = grad[p[p[xi] + yi + 1] % 8];
        const ba = grad[p[p[xi + 1] + yi] % 8];
        const bb = grad[p[p[xi + 1] + yi + 1] % 8];

        const x1 = dot(aa, xf, yf) * (1 - u) + dot(ba, xf - 1, yf) * u;
        const x2 = dot(ab, xf, yf - 1) * (1 - u) + dot(bb, xf - 1, yf - 1) * u;
        return x1 * (1 - v) + x2 * v;
    }

    /// Fractal Brownian motion: `octaves` layers of noise, each at
    /// `lacunarity` times the frequency and `gain` times the amplitude
    /// of the one before, normalized by the total amplitude.
    pub fn fbm(n: *const Perlin, x: f64, y: f64, octaves: f64, lacunarity: f64, gain: f64) f64 {
        var sum: f64 = 0;
        var amp: f64 = 1;
        var freq: f64 = 1;
        var amp_total: f64 = 0;
        var i: f64 = 1;
        while (i <= octaves) : (i += 1) {
            sum = sum + n.noise(x * freq, y * freq) * amp;
            amp_total = amp_total + amp;
            amp = amp * gain;
            freq = freq * lacunarity;
        }
        return sum / amp_total;
    }

    /// Follow the flow field with angle noise(x * scale, y * scale) * 2pi
    /// from `start` in steps of `step_len`. out[0] is the start.
    pub fn trace(n: *const Perlin, out: [][2]f64, start: [2]f64, scale: f64, step_len: f64) void {
        if (out.len == 0) return;
        var x = start[0];
        var y = start[1];
        out[0] = start;
        for (out[1..]) |*p| {
            const angle = n.noise(x * scale, y * scale) * std.math.pi * 2;
            x = x + math.cos(angle) * step_len;
            y = y + math.sin(angle) * step_len;
            p.* = .{ x, y };
        }
    }
};

const grad = [8][2]f64{
    .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
    .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
};

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn dot(g: [2]f64, x: f64, y: f64) f64 {
    return g[0] * x + g[1] * y;
}

const testing = std.testing;

// Expected values were printed by the Lua implementation this replaces.

test "perlin: seed 0 matches the Lua table" {
    const n: Perlin = .init(0);
    try testing.expectEqual(@as(f64, -0.625), n.noise(0.5, 0.5));
    try testing.expectEqual(@as(f64, -0.35544204711914062), n.noise(1.25, 3.75));
    try testing.expectEqual(@as(f64, 0.25107599999999908), n.noise(-10.3, 200.7));
}

test "perlin: seed 42 matches the Lua table" {
    const n: Perlin = .init(42);
    try testing.expectEqual(@as(f64, -0.125), n.noise(0.5, 0.5));
    try testing.expectEqual(@as(f64, -0.13116359710693359), n.noise(1.25, 3.75));
    try testing.expectEqual(@as(f64, 0.17743038768000491), n.noise(-10.3, 200.7));
}

test "perlin: large seed keeps the f64 LCG rounding" {
    const n: Perlin = .init(123456789);
    try testing.expectEqual(@as(f64, 0.375), n.noise(0.5, 0.5));
    try testing.expectEqual(@as(f64, -0.23793401759999969), n.noise(7.3, 9.1));
}

test "perlin: fbm matches the Lua sum" {
    const n: Perlin = .init(42);
    try testing.expectEqual(@as(f64, -0.28546561015873007), n.fbm(0.3, 0.7, 6, 2, 0.5));
    try testing.expectEqual(@as(f64, -0.27284709159655451), n.fbm(12.1, -4.4, 3, 2.5, 0.4));
}

test "perlin: trace takes unit steps" {
    const n: Perlin = .init(3);
    var pts: [5][2]f64 = undefined;
    n.trace(&pts, .{ 10, 20 }, 0.01, 2);
    try testing.expectEqual([2]f64{ 10, 20 }, pts[0]);
    for (pts[1..], pts[0..4]) |b, a| {
        try testing.expectApproxEqAbs(@as(f64, 2), std.math.hypot(b[0] - a[0], b[1] - a[1]), 1e-12);
    }
}

test "perlin: zero at lattice points and NaN for infinity" {
    const n: Perlin = .init(7);
    try testing.expectEqual(@as(f64, 0), n.noise(3, 4));
    try testing.expect(std.math.isNan(n.noise(std.math.inf(f64), 0)));
}
