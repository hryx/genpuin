//! Field filters that sit next to noise: gaussian blur and gradient.

const std = @import("std");
const libm = @import("../libm.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");

/// Separable gaussian blur with standard deviation `sigma` in cells. The
/// kernel reaches three sigma and edges are clamped. Returns a new Field.
pub fn blur(gpa: Allocator, f: *const Field, sigma: f32) !Field {
    assert(sigma >= 0);
    var out = try f.clone(gpa);
    errdefer out.deinit(gpa);
    if (sigma == 0) return out;

    const radius: u32 = @intFromFloat(@ceil(sigma * 3));
    const kernel = try gpa.alloc(f32, 2 * radius + 1);
    defer gpa.free(kernel);
    var total: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        k.* = @floatCast(libm.exp(-d * d / (2 * sigma * sigma)));
        total += k.*;
    }
    for (kernel) |*k| k.* /= total;

    const line = try gpa.alloc(f32, @max(f.w, f.h) + 2 * radius);
    defer gpa.free(line);
    for (0..f.h) |y| {
        convolve(line, out.data[y * f.w ..], 1, f.w, kernel, radius);
    }
    for (0..f.w) |x| {
        convolve(line, out.data[x..], f.w, f.h, kernel, radius);
    }
    return out;
}

/// Convolve `n` values spaced `stride` apart, through a clamped copy in `line`.
fn convolve(line: []f32, data: []f32, stride: usize, n: usize, kernel: []const f32, radius: u32) void {
    const padded = line[0 .. n + 2 * radius];
    for (padded, 0..) |*p, i| {
        const src = std.math.clamp(@as(i64, @intCast(i)) - radius, 0, @as(i64, @intCast(n)) - 1);
        p.* = data[@as(usize, @intCast(src)) * stride];
    }
    for (0..n) |i| {
        var acc: f32 = 0;
        for (kernel, padded[i..][0..kernel.len]) |k, p| acc += k * p;
        data[i * stride] = acc;
    }
}

pub const Gradient = struct {
    dx: Field,
    dy: Field,

    pub fn deinit(self: *Gradient, gpa: Allocator) void {
        self.dx.deinit(gpa);
        self.dy.deinit(gpa);
    }
};

/// Central differences per cell, one sided at the edges.
pub fn gradient(gpa: Allocator, f: *const Field) !Gradient {
    var dx: Field = try .init(gpa, f.w, f.h, 0);
    errdefer dx.deinit(gpa);
    var dy: Field = try .init(gpa, f.w, f.h, 0);
    errdefer dy.deinit(gpa);
    for (0..f.h) |y| for (0..f.w) |x| {
        const xi: i64 = @intCast(x);
        const yi: i64 = @intCast(y);
        const x0 = @max(xi - 1, 0);
        const x1 = @min(xi + 1, @as(i64, f.w) - 1);
        const y0 = @max(yi - 1, 0);
        const y1 = @min(yi + 1, @as(i64, f.h) - 1);
        const i = y * f.w + x;
        const sx: f32 = @floatFromInt(@max(x1 - x0, 1));
        const sy: f32 = @floatFromInt(@max(y1 - y0, 1));
        dx.data[i] = (f.at(x1, yi) - f.at(x0, yi)) / sx;
        dy.data[i] = (f.at(xi, y1) - f.at(xi, y0)) / sy;
    };
    return .{ .dx = dx, .dy = dy };
}

test "filter: blur keeps the total and spreads a spike" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 21, 21, 0);
    defer f.deinit(gpa);
    f.set(10, 10, 1);
    var b = try blur(gpa, &f, 2);
    defer b.deinit(gpa);
    var total: f32 = 0;
    for (b.data) |v| total += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1), total, 1e-4);
    try std.testing.expect(b.get(10, 10) < 0.1);
    try std.testing.expect(b.get(12, 10) > 0);
    try std.testing.expectApproxEqAbs(b.get(12, 10), b.get(10, 12), 1e-6);
}

test "filter: gradient of a ramp is constant" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 5, 4, 0);
    defer f.deinit(gpa);
    for (0..4) |y| for (0..5) |x| f.set(@intCast(x), @intCast(y), @floatFromInt(3 * x + y));
    var g = try gradient(gpa, &f);
    defer g.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 3), g.dx.get(0, 0));
    try std.testing.expectEqual(@as(f32, 3), g.dx.get(2, 1));
    try std.testing.expectEqual(@as(f32, 1), g.dy.get(4, 3));
}
