//! A 2D grid of f32 values. Noise, simulations and density renders all
//! produce Fields, and a Field can be drawn onto a canvas through a
//! palette or traced into contour lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @This();

w: u32,
h: u32,
data: []f32,

pub fn init(gpa: Allocator, w: u32, h: u32, value: f32) !Field {
    assert(w > 0 and h > 0);
    const data = try gpa.alloc(f32, @as(usize, w) * h);
    @memset(data, value);
    return .{ .w = w, .h = h, .data = data };
}

pub fn deinit(self: *Field, gpa: Allocator) void {
    gpa.free(self.data);
    self.* = undefined;
}

pub fn clone(self: *const Field, gpa: Allocator) !Field {
    return .{ .w = self.w, .h = self.h, .data = try gpa.dupe(f32, self.data) };
}

pub fn get(self: *const Field, x: u32, y: u32) f32 {
    assert(x < self.w and y < self.h);
    return self.data[@as(usize, y) * self.w + x];
}

pub fn set(self: *Field, x: u32, y: u32, v: f32) void {
    assert(x < self.w and y < self.h);
    self.data[@as(usize, y) * self.w + x] = v;
}

pub fn ptr(self: *Field, x: u32, y: u32) *f32 {
    assert(x < self.w and y < self.h);
    return &self.data[@as(usize, y) * self.w + x];
}

/// Edge-clamped read.
pub fn at(self: *const Field, x: i64, y: i64) f32 {
    const cx: u32 = @intCast(std.math.clamp(x, 0, @as(i64, self.w) - 1));
    const cy: u32 = @intCast(std.math.clamp(y, 0, @as(i64, self.h) - 1));
    return self.get(cx, cy);
}

/// Wrapping read, for toroidal simulations.
pub fn wrap(self: *const Field, x: i64, y: i64) f32 {
    const cx: u32 = @intCast(@mod(x, @as(i64, self.w)));
    const cy: u32 = @intCast(@mod(y, @as(i64, self.h)));
    return self.get(cx, cy);
}

/// Bilinear sample with cell centers at integer + 0.5, edge-clamped.
pub fn sample(self: *const Field, x: f64, y: f64) f32 {
    const fx = x - 0.5;
    const fy = y - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const tx: f32 = @floatCast(fx - x0);
    const ty: f32 = @floatCast(fy - y0);
    const ix: i64 = @intFromFloat(x0);
    const iy: i64 = @intFromFloat(y0);
    const a = self.at(ix, iy);
    const b = self.at(ix + 1, iy);
    const c = self.at(ix, iy + 1);
    const d = self.at(ix + 1, iy + 1);
    return std.math.lerp(std.math.lerp(a, b, tx), std.math.lerp(c, d, tx), ty);
}

pub fn minMax(self: *const Field) [2]f32 {
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (self.data) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    return .{ lo, hi };
}

/// Rescale in place to 0..1. A flat field becomes all zeros.
pub fn normalize(self: *Field) void {
    const r = self.minMax();
    const span = r[1] - r[0];
    if (span <= 0) {
        @memset(self.data, 0);
        return;
    }
    for (self.data) |*v| v.* = (v.* - r[0]) / span;
}

test "Field: bilinear sample hits cell centers" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 2, 1, 0);
    defer f.deinit(gpa);
    f.set(1, 0, 1);
    try std.testing.expectEqual(@as(f32, 0), f.sample(0.5, 0.5));
    try std.testing.expectEqual(@as(f32, 1), f.sample(1.5, 0.5));
    try std.testing.expectEqual(@as(f32, 0.5), f.sample(1.0, 0.5));
}

test "Field: normalize maps to unit range" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 3, 1, 0);
    defer f.deinit(gpa);
    f.set(0, 0, -2);
    f.set(2, 0, 2);
    f.normalize();
    try std.testing.expectEqual(@as(f32, 0), f.get(0, 0));
    try std.testing.expectEqual(@as(f32, 0.5), f.get(1, 0));
    try std.testing.expectEqual(@as(f32, 1), f.get(2, 0));
}
