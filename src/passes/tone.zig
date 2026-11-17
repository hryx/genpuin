//! Per-pixel tone passes: grain, levels and scanlines.

const std = @import("std");
const libm = @import("../libm.zig");

const Raster = @import("../Raster.zig");
const common = @import("common.zig");

const Frame = common.Frame;
const V3 = common.V3;

pub const Grain = struct {
    /// Peak noise added to each channel.
    amount: f32 = 0.1,
    /// Same noise on every channel.
    mono: bool = true,
    /// Grain cell size in scene units. Cells are blended bilinearly.
    size: f64 = 1,
    seed: u64 = 1,
};

pub fn grain(r: *Raster, p: *const Grain, frame: Frame) void {
    const cell = @max(1, frame.px(p.size));
    const inv: f32 = @floatCast(1 / cell);
    for (0..r.h) |y| for (0..r.w) |x| {
        const gx = @as(f32, @floatFromInt(x + frame.x0)) * inv;
        const gy = @as(f32, @floatFromInt(y + frame.y0)) * inv;
        var n: V3 = undefined;
        inline for (0..3) |ch| {
            n[ch] = if (ch > 0 and p.mono) n[0] else valueNoise(p.seed, gx, gy, ch);
        }
        const i = y * r.w + x;
        common.setPixel(r, i, common.clamp01(common.pixel(r, i) + n * @as(V3, @splat(p.amount))));
    };
}

/// Bilinear value noise in -1..1 from a triangular distribution per lattice
/// point, so most grain is small and a little is strong.
fn valueNoise(seed: u64, x: f32, y: f32, ch: u64) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix: i64 = @intFromFloat(fx);
    const iy: i64 = @intFromFloat(fy);
    const tx = x - fx;
    const ty = y - fy;
    const a = lattice(seed, ix, iy, ch);
    if (tx == 0 and ty == 0) return a;
    const b = lattice(seed, ix + 1, iy, ch);
    const c = lattice(seed, ix, iy + 1, ch);
    const d = lattice(seed, ix + 1, iy + 1, ch);
    return std.math.lerp(std.math.lerp(a, b, tx), std.math.lerp(c, d, tx), ty);
}

fn lattice(seed: u64, x: i64, y: i64, ch: u64) f32 {
    return common.hash01(seed, x, y, ch * 2) + common.hash01(seed, x, y, ch * 2 + 1) - 1;
}

pub const Levels = struct {
    black: f32 = 0,
    white: f32 = 1,
    /// Above 1 brightens midtones.
    gamma: f32 = 1,
    out_black: f32 = 0,
    out_white: f32 = 1,
};

pub fn levels(r: *Raster, p: *const Levels) void {
    const span = @max(1e-6, p.white - p.black);
    const inv_gamma = 1 / @max(1e-6, p.gamma);
    for (r.pix) |*v| {
        const t = std.math.clamp((v.* - p.black) / span, 0, 1);
        const g: f32 = if (p.gamma == 1) t else @floatCast(libm.pow(t, inv_gamma));
        v.* = std.math.lerp(p.out_black, p.out_white, g);
    }
}

pub const Scanlines = struct {
    /// Line spacing in scene units.
    period: f64 = 4,
    /// Dark band width in scene units.
    width: f64 = 2,
    /// 0..1, how much the band darkens.
    strength: f32 = 0.5,
    /// x draws horizontal lines, y vertical ones.
    axis: enum { x, y } = .x,
};

pub fn scanlines(r: *Raster, p: *const Scanlines, frame: Frame) void {
    const lines = if (p.axis == .x) r.h else r.w;
    const offset = if (p.axis == .x) frame.y0 else frame.x0;
    for (0..lines) |k| {
        const a = @as(f64, @floatFromInt(k + offset)) / frame.scale;
        const b = @as(f64, @floatFromInt(k + offset + 1)) / frame.scale;
        const cover = (bandIntegral(b, p.period, p.width) - bandIntegral(a, p.period, p.width)) / (b - a);
        const f: f32 = 1 - p.strength * @as(f32, @floatCast(cover));
        if (f == 1) continue;
        switch (p.axis) {
            .x => for (r.pix[r.index(0, @intCast(k))..][0 .. r.w * 3]) |*v| {
                v.* *= f;
            },
            .y => for (0..r.h) |y| {
                const i = r.index(@intCast(k), @intCast(y));
                for (r.pix[i..][0..3]) |*v| v.* *= f;
            },
        }
    }
}

/// Length of dark band inside 0..t, for bands [n p, n p + width).
fn bandIntegral(t: f64, period: f64, width: f64) f64 {
    const w = @min(width, period);
    return @floor(t / period) * w + @min(@mod(t, period), w);
}

test "grain: zero amount is a no-op, mono stays gray" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 4, .{ 0.5, 0.5, 0.5 });
    defer r.deinit(gpa);
    grain(&r, &.{ .amount = 0 }, .whole(&r, 1));
    try std.testing.expectEqual(common.Rgb{ 0.5, 0.5, 0.5 }, r.get(3, 3));
    grain(&r, &.{ .amount = 0.2, .seed = 9 }, .whole(&r, 1));
    var moved = false;
    for (0..16) |i| {
        const c = r.get(@intCast(i % 4), @intCast(i / 4));
        try std.testing.expect(c[0] == c[1] and c[1] == c[2]);
        try std.testing.expect(@abs(c[0] - 0.5) <= 0.2);
        moved = moved or c[0] != 0.5;
    }
    try std.testing.expect(moved);
}

test "grain: size scales with the image" {
    const gpa = std.testing.allocator;
    var a: Raster = try .init(gpa, 2, 2, .{ 0.5, 0.5, 0.5 });
    defer a.deinit(gpa);
    var b: Raster = try .init(gpa, 4, 4, .{ 0.5, 0.5, 0.5 });
    defer b.deinit(gpa);
    grain(&a, &.{ .seed = 3 }, .whole(&a, 1));
    grain(&b, &.{ .seed = 3 }, .whole(&b, 2));
    try std.testing.expectEqual(a.get(1, 1), b.get(2, 2));
}

test "levels: black, white and gamma" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 1, .{ 0.1, 0.5, 0.9 });
    defer r.deinit(gpa);
    levels(&r, &.{ .black = 0.1, .white = 0.9, .gamma = 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.pix[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), r.pix[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.pix[2], 1e-6);
}

test "scanlines: darken by coverage, same at any scale" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 4, .{ 1, 1, 1 });
    defer r.deinit(gpa);
    scanlines(&r, &.{ .period = 2, .width = 1, .strength = 0.5 }, .whole(&r, 1));
    try std.testing.expectEqual(@as(f32, 0.5), r.get(0, 0)[0]);
    try std.testing.expectEqual(@as(f32, 1), r.get(0, 1)[0]);
    try std.testing.expectEqual(@as(f32, 0.5), r.get(0, 2)[0]);

    var half: Raster = try .init(gpa, 1, 2, .{ 1, 1, 1 });
    defer half.deinit(gpa);
    // At scale 0.5 each pixel spans one period, so each is half covered.
    scanlines(&half, &.{ .period = 2, .width = 1, .strength = 0.5 }, .whole(&half, 0.5));
    try std.testing.expectEqual(@as(f32, 0.75), half.get(0, 1)[0]);
}
