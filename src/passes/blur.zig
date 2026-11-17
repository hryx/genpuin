//! Gaussian blur and bloom.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Raster = @import("../Raster.zig");
const common = @import("common.zig");

const Frame = common.Frame;
const V3 = common.V3;

pub const Blur = struct {
    /// Gaussian standard deviation in scene units.
    radius: f64 = 4,
};

pub const Bloom = struct {
    /// Luma above which pixels start to glow.
    threshold: f32 = 0.7,
    radius: f64 = 20,
    strength: f32 = 1,
};

pub fn blur(gpa: Allocator, r: *Raster, p: *const Blur, frame: Frame) !void {
    try gaussian(gpa, r, frame.px(p.radius));
}

pub fn bloom(gpa: Allocator, r: *Raster, p: *const Bloom, frame: Frame) !void {
    var glow = try r.clone(gpa);
    defer glow.deinit(gpa);
    const span = @max(1e-3, 1 - p.threshold);
    for (0..@as(usize, r.w) * r.h) |i| {
        const c = common.pixel(&glow, i);
        const k = std.math.clamp((Raster.luminance(c) - p.threshold) / span, 0, 1);
        common.setPixel(&glow, i, c * @as(V3, @splat(k)));
    }
    try gaussian(gpa, &glow, frame.px(p.radius));
    const s: V3 = @splat(p.strength);
    for (0..@as(usize, r.w) * r.h) |i| {
        common.setPixel(r, i, common.clamp01(common.pixel(r, i) + common.pixel(&glow, i) * s));
    }
}

const passes = 3;

/// Three box blurs approximating a gaussian, with box widths from Kovesi,
/// "Fast almost-Gaussian filtering" (2010). Edges clamp. Cost does not
/// depend on sigma.
pub fn gaussian(gpa: Allocator, r: *Raster, sigma: f64) !void {
    if (sigma < 0.3) return;
    const n: f64 = passes;
    const w_ideal = @sqrt(12 * sigma * sigma / n + 1);
    var wl: i64 = @intFromFloat(@floor(w_ideal));
    if (@mod(wl, 2) == 0) wl -= 1;
    const wlf: f64 = @floatFromInt(wl);
    const m_ideal = (12 * sigma * sigma - n * wlf * wlf - 4 * n * wlf - 3 * n) / (-4 * wlf - 4);
    const m: i64 = @intFromFloat(@round(m_ideal));

    const tmp = try gpa.alloc(f32, r.pix.len);
    defer gpa.free(tmp);
    const sums = try gpa.alloc(f32, @as(usize, r.w) * 3);
    defer gpa.free(sums);
    for (0..passes) |i| {
        const width = if (@as(i64, @intCast(i)) < m) wl else wl + 2;
        const k: u32 = @intCast(@divExact(width - 1, 2));
        if (k == 0) continue;
        boxRows(r, tmp, k);
        boxColumns(r, tmp, sums, k);
    }
}

/// Horizontal box of radius k from r into tmp.
fn boxRows(r: *const Raster, tmp: []f32, k: u32) void {
    const w = r.w;
    const inv: V3 = @splat(1 / @as(f32, @floatFromInt(2 * k + 1)));
    for (0..r.h) |y| {
        const row = r.pix[y * w * 3 ..][0 .. w * 3];
        const out = tmp[y * w * 3 ..][0 .. w * 3];
        const at = struct {
            fn f(s: []const f32, x: i64, len: u32) V3 {
                const c: usize = @intCast(std.math.clamp(x, 0, @as(i64, len) - 1));
                return s[c * 3 ..][0..3].*;
            }
        }.f;
        var sum: V3 = at(row, 0, w) * @as(V3, @splat(@floatFromInt(k + 1)));
        for (1..k + 1) |i| sum += at(row, @intCast(i), w);
        for (0..w) |x| {
            out[x * 3 ..][0..3].* = sum * inv;
            const xi: i64 = @intCast(x);
            sum += at(row, xi + k + 1, w) - at(row, xi - k, w);
        }
    }
}

/// Vertical box of radius k from tmp back into r, one running sum per
/// column so rows stream through the cache.
fn boxColumns(r: *Raster, tmp: []const f32, sums: []f32, k: u32) void {
    const stride = @as(usize, r.w) * 3;
    const last: i64 = @as(i64, r.h) - 1;
    const inv = 1 / @as(f32, @floatFromInt(2 * k + 1));
    const row = struct {
        fn f(t: []const f32, y: i64, s: usize, l: i64) []const f32 {
            const c: usize = @intCast(std.math.clamp(y, 0, l));
            return t[c * s ..][0..s];
        }
    }.f;
    const first = row(tmp, 0, stride, last);
    for (sums, first) |*s, v| s.* = v * @as(f32, @floatFromInt(k + 1));
    for (1..k + 1) |i| {
        for (sums, row(tmp, @intCast(i), stride, last)) |*s, v| s.* += v;
    }
    for (0..r.h) |y| {
        const out = r.pix[y * stride ..][0..stride];
        for (out, sums) |*o, s| o.* = s * inv;
        const yi: i64 = @intCast(y);
        const add = row(tmp, yi + k + 1, stride, last);
        const sub = row(tmp, yi - k, stride, last);
        for (sums, add, sub) |*s, a, b| s.* += a - b;
    }
}

test "blur: keeps a flat image flat and conserves a centered impulse" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 41, 41, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(20, 20, .{ 1, 1, 1 });
    try blur(gpa, &r, &.{ .radius = 2 }, .whole(&r, 1));
    var sum: f32 = 0;
    for (0..r.w * r.h) |i| sum += r.pix[i * 3];
    try std.testing.expectApproxEqAbs(@as(f32, 1), sum, 1e-4);
    // A gaussian of sigma 2 peaks near 1 / (2 pi 4) = 0.040.
    try std.testing.expectApproxEqAbs(@as(f32, 0.040), r.get(20, 20)[0], 0.006);
    try std.testing.expect(r.get(20, 20)[0] > r.get(22, 20)[0]);
    try std.testing.expectApproxEqAbs(r.get(22, 20)[0], r.get(20, 22)[0], 1e-6);

    var flat: Raster = try .init(gpa, 5, 3, .{ 0.3, 0.6, 0.9 });
    defer flat.deinit(gpa);
    try blur(gpa, &flat, &.{ .radius = 3 }, .whole(&flat, 1));
    for (0..3) |c| try std.testing.expectApproxEqAbs(flat.pix[c], flat.get(4, 2)[c], 1e-5);
}

test "blur: radius is in scene units" {
    const gpa = std.testing.allocator;
    var a: Raster = try .init(gpa, 41, 1, .{ 0, 0, 0 });
    defer a.deinit(gpa);
    a.set(20, 0, .{ 1, 1, 1 });
    var b = try a.clone(gpa);
    defer b.deinit(gpa);
    try blur(gpa, &a, &.{ .radius = 4 }, .whole(&a, 1));
    try blur(gpa, &b, &.{ .radius = 2 }, .whole(&b, 2));
    try std.testing.expectEqualSlices(f32, a.pix, b.pix);
}

test "bloom: dark pixels stay, bright ones glow onto neighbours" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 21, 1, .{ 0.1, 0.1, 0.1 });
    defer r.deinit(gpa);
    r.set(10, 0, .{ 1, 1, 1 });
    try bloom(gpa, &r, &.{ .threshold = 0.5, .radius = 2 }, .whole(&r, 1));
    try std.testing.expectEqual(@as(f32, 0.1), r.get(0, 0)[0]);
    try std.testing.expect(r.get(11, 0)[0] > 0.15);
    try std.testing.expectEqual(@as(f32, 1), r.get(10, 0)[0]);
}
