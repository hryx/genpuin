//! Types and helpers shared by the pass implementations.

const std = @import("std");

const Field = @import("../Field.zig");
const Raster = @import("../Raster.zig");

pub const Rgb = Raster.Rgb;
pub const V3 = @Vector(3, f32);

/// Where the raster a pass sees sits in the full image. A pass restricted
/// to a region runs on a cropped copy, and anything tied to absolute
/// position (masks, noise, line phase) reads through this.
pub const Frame = struct {
    /// Pixels per scene unit.
    scale: f64,
    x0: u32 = 0,
    y0: u32 = 0,
    full_w: u32,
    full_h: u32,

    pub fn whole(r: *const Raster, scale: f64) Frame {
        return .{ .scale = scale, .full_w = r.w, .full_h = r.h };
    }

    /// A scene distance in pixels.
    pub fn px(self: Frame, d: f64) f64 {
        return d * self.scale;
    }

    /// A scene distance in whole pixels, at least `min`.
    pub fn pxInt(self: Frame, d: f64, min: i64) i64 {
        return @max(min, @as(i64, @intFromFloat(@round(std.math.clamp(d * self.scale, -1e9, 1e9)))));
    }

    /// Sample a field stretched over the full image at local pixel (x, y).
    pub fn sampleField(self: Frame, f: *const Field, x: f64, y: f64) f32 {
        const gx = (x + @as(f64, @floatFromInt(self.x0)) + 0.5) / @as(f64, @floatFromInt(self.full_w));
        const gy = (y + @as(f64, @floatFromInt(self.y0)) + 0.5) / @as(f64, @floatFromInt(self.full_h));
        return f.sample(gx * @as(f64, @floatFromInt(f.w)), gy * @as(f64, @floatFromInt(f.h)));
    }
};

pub fn pixel(r: *const Raster, i: usize) V3 {
    return r.pix[i * 3 ..][0..3].*;
}

pub fn setPixel(r: *Raster, i: usize, c: V3) void {
    r.pix[i * 3 ..][0..3].* = c;
}

pub fn clamp01(c: V3) V3 {
    return @min(@as(V3, @splat(1)), @max(@as(V3, @splat(0)), c));
}

/// Bilinear read with pixel centers at integer coordinates, edge-clamped.
pub fn sampleBilinear(r: *const Raster, x: f32, y: f32) V3 {
    const fx = @floor(x);
    const fy = @floor(y);
    const tx: V3 = @splat(x - fx);
    const ty: V3 = @splat(y - fy);
    const ix: i64 = @intFromFloat(std.math.clamp(fx, -1, @as(f32, @floatFromInt(r.w))));
    const iy: i64 = @intFromFloat(std.math.clamp(fy, -1, @as(f32, @floatFromInt(r.h))));
    const a: V3 = r.getClamped(ix, iy);
    const b: V3 = r.getClamped(ix + 1, iy);
    const c: V3 = r.getClamped(ix, iy + 1);
    const d: V3 = r.getClamped(ix + 1, iy + 1);
    const top = a + (b - a) * tx;
    const bottom = c + (d - c) * tx;
    return top + (bottom - top) * ty;
}

/// Stateless hash of a seed and integer coordinates to 0..1, for noise
/// that has to agree across region crops. SplitMix64 finalizer.
pub fn hash01(seed: u64, x: i64, y: i64, k: u64) f32 {
    var z = seed +% @as(u64, @bitCast(x)) *% 0x9E3779B97F4A7C15 +%
        @as(u64, @bitCast(y)) *% 0xC2B2AE3D27D4EB4F +% k *% 0x165667B19E3779F9;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    return @as(f32, @floatFromInt(z >> 40)) / @as(f32, 1 << 24);
}

pub fn hue(c: Rgb) f32 {
    const hi = @max(c[0], @max(c[1], c[2]));
    const lo = @min(c[0], @min(c[1], c[2]));
    const d = hi - lo;
    if (d <= 0) return 0;
    const h = if (hi == c[0])
        @mod((c[1] - c[2]) / d, 6)
    else if (hi == c[1])
        (c[2] - c[0]) / d + 2
    else
        (c[0] - c[1]) / d + 4;
    return h / 6;
}

pub fn saturation(c: Rgb) f32 {
    const hi = @max(c[0], @max(c[1], c[2]));
    const lo = @min(c[0], @min(c[1], c[2]));
    return if (hi <= 0) 0 else (hi - lo) / hi;
}

test "common: hue of primaries" {
    try std.testing.expectEqual(@as(f32, 0), hue(.{ 1, 0, 0 }));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), hue(.{ 0, 1, 0 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), hue(.{ 0, 0, 1 }), 1e-6);
}

test "common: hash01 is deterministic and in range" {
    const a = hash01(7, 3, 4, 0);
    try std.testing.expectEqual(a, hash01(7, 3, 4, 0));
    try std.testing.expect(a != hash01(8, 3, 4, 0));
    try std.testing.expect(a >= 0 and a < 1);
}
