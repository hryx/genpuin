//! Closed outlines of circles, ellipses and rects for the path operations,
//! which take point contours only. Curves get enough segments that the
//! chord sag stays near 0.05 units.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const geom = @import("geom.zig");
const Vec2 = geom.Vec2;

const sag = 0.05;

/// Lua's math.min and math.max keep the first argument unless the second
/// is strictly beyond it, which differs from @min and @max on signed
/// zeros and NaN. These match the Lua library this was ported from.
fn luaMin(a: f64, b: f64) f64 {
    return if (b < a) b else a;
}

fn luaMax(a: f64, b: f64) f64 {
    return if (b > a) b else a;
}

/// Segments for a curve of radius r spanning `sweep` radians, 4 to 2048,
/// or 1 for a degenerate radius.
pub fn arcSegments(r: f64, sweep: f64) f64 {
    if (r <= 0) return 1;
    const n = @ceil(sweep / (2 * math.acos(luaMax(1 - sag / r, -1))));
    return luaMax(4, luaMin(n, 2048));
}

pub fn ellipse(gpa: Allocator, center: Vec2, rx: f64, ry: f64) ![]Vec2 {
    const n = arcSegments(luaMax(rx, ry), 2 * std.math.pi);
    const pts = try gpa.alloc(Vec2, @intFromFloat(n));
    for (pts, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / n * 2 * std.math.pi;
        p.* = .{ center[0] + rx * math.cos(t), center[1] + ry * math.sin(t) };
    }
    return pts;
}

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rx: ?f64 = null,
    ry: ?f64 = null,
};

/// Corners clockwise from the top right in y-down space, each a quarter
/// arc when the rect is rounded. ry defaults to the clamped rx.
pub fn rect(gpa: Allocator, r: Rect) ![]Vec2 {
    const rx = luaMin(r.rx orelse 0, r.w / 2);
    const ry = luaMin(r.ry orelse rx, r.h / 2);
    if (rx <= 0 or ry <= 0) {
        const pts = try gpa.alloc(Vec2, 4);
        pts[0..4].* = .{ .{ r.x, r.y }, .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h } };
        return pts;
    }
    const corners = [4]struct { Vec2, f64 }{
        .{ .{ r.x + r.w - rx, r.y + ry }, -std.math.pi / 2.0 },
        .{ .{ r.x + r.w - rx, r.y + r.h - ry }, 0 },
        .{ .{ r.x + rx, r.y + r.h - ry }, std.math.pi / 2.0 },
        .{ .{ r.x + rx, r.y + ry }, std.math.pi },
    };
    const n = arcSegments(luaMax(rx, ry), std.math.pi / 2.0);
    const per_corner: usize = @as(usize, @intFromFloat(n)) + 1;
    const pts = try gpa.alloc(Vec2, 4 * per_corner);
    for (corners, 0..) |corner, k| {
        const c, const start = corner;
        for (pts[k * per_corner ..][0..per_corner], 0..) |*p, i| {
            const t = start + @as(f64, @floatFromInt(i)) / n * std.math.pi / 2.0;
            p.* = .{ c[0] + rx * math.cos(t), c[1] + ry * math.sin(t) };
        }
    }
    return pts;
}

const testing = std.testing;

test "flatten: segment count follows the sag bound and its limits" {
    try testing.expectEqual(@as(f64, 1), arcSegments(0, std.math.pi));
    try testing.expectEqual(@as(f64, 4), arcSegments(0.01, std.math.pi / 2.0));
    try testing.expectEqual(@as(f64, 2048), arcSegments(1e9, 2 * std.math.pi));
    // With r = 0.1, acos(0.5) is pi / 3, so a full turn needs three
    // segments and the floor of four applies.
    try testing.expectEqual(@as(f64, 4), arcSegments(0.1, 2 * std.math.pi));
}

test "flatten: an ellipse starts on the +x axis" {
    const pts = try ellipse(testing.allocator, .{ 1, 2 }, 10, 5);
    defer testing.allocator.free(pts);
    try testing.expectEqual(Vec2{ 11, 2 }, pts[0]);
    const q = pts[pts.len / 4];
    try testing.expectApproxEqAbs(@as(f64, 7), q[1], 1e-9);
}

test "flatten: a square rect has four corners" {
    const pts = try rect(testing.allocator, .{ .x = 1, .y = 2, .w = 3, .h = 4 });
    defer testing.allocator.free(pts);
    try testing.expectEqualSlices(Vec2, &.{ .{ 1, 2 }, .{ 4, 2 }, .{ 4, 6 }, .{ 1, 6 } }, pts);
}

test "flatten: a rounded rect clamps its radius to half the side" {
    const pts = try rect(testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = 4, .rx = 9 });
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 0), pts.len % 4);
    for (pts) |p| {
        try testing.expect(p[0] >= -1e-9 and p[0] <= 10 + 1e-9);
        try testing.expect(p[1] >= -1e-9 and p[1] <= 4 + 1e-9);
    }
    try testing.expectApproxEqAbs(@as(f64, 5), pts[0][0], 1e-9);
}
