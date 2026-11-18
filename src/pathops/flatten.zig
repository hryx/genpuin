//! Point outlines of the curved shapes for the path operations, which
//! take point contours only: closed circles, ellipses and rects, and open
//! arcs, Beziers and splines. Curves get enough segments that the chord
//! sag stays near 0.05 units.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const geom = @import("geom.zig");
const Vec2 = geom.Vec2;
const path = @import("../algo/path.zig");
const Cubic = path.Cubic;

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

/// The open arc of radius r from angle `start` to `end`, both ends
/// included.
pub fn arc(gpa: Allocator, center: Vec2, r: f64, start: f64, end: f64) ![]Vec2 {
    const n = arcSegments(@abs(r), @abs(end - start));
    const pts = try gpa.alloc(Vec2, @as(usize, @intFromFloat(n)) + 1);
    for (pts, 0..) |*p, i| {
        const t = start + (end - start) * (@as(f64, @floatFromInt(i)) / n);
        p.* = .{ center[0] + r * math.cos(t), center[1] + r * math.sin(t) };
    }
    return pts;
}

/// Uniform steps in t for a cubic Bezier, 1 to 2048. Wang's formula: n
/// steps keep the chord within sag when n^2 >= 3/4 * max|second
/// difference of the control points| / sag.
fn cubicSegments(c: Cubic) f64 {
    var d: f64 = 0;
    for (0..2) |i| {
        const ax = c[i][0] - 2 * c[i + 1][0] + c[i + 2][0];
        const ay = c[i][1] - 2 * c[i + 1][1] + c[i + 2][1];
        d = @max(d, @sqrt(ax * ax + ay * ay));
    }
    const n = @ceil(@sqrt(0.75 * d / sag));
    if (!(n >= 1)) return 1;
    return @min(n, 2048);
}

/// Append the points of `c` to `out`, leaving out its first point unless
/// `include_first`.
fn appendCubic(gpa: Allocator, out: *std.ArrayList(Vec2), c: Cubic, include_first: bool) !void {
    const n = cubicSegments(c);
    const count: usize = @intFromFloat(n);
    for (@intFromBool(!include_first)..count + 1) |i| {
        try out.append(gpa, path.bezierPoint(c, @as(f64, @floatFromInt(i)) / n));
    }
}

pub fn cubic(gpa: Allocator, c: Cubic) ![]Vec2 {
    var out: std.ArrayList(Vec2) = .empty;
    errdefer out.deinit(gpa);
    try appendCubic(gpa, &out, c, true);
    return out.toOwnedSlice(gpa);
}

/// The Catmull-Rom spline through `pts`, as drawn. Fewer than two points
/// come back as they are.
pub fn spline(gpa: Allocator, pts: []const Vec2) ![]Vec2 {
    if (pts.len < 2) return gpa.dupe(Vec2, pts);
    const segs = try path.splineToBeziers(gpa, pts);
    defer gpa.free(segs);
    var out: std.ArrayList(Vec2) = .empty;
    errdefer out.deinit(gpa);
    for (segs, 0..) |c, i| try appendCubic(gpa, &out, c, i == 0);
    return out.toOwnedSlice(gpa);
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

test "flatten: an arc runs from start to end on the circle" {
    const pts = try arc(testing.allocator, .{ 0, 0 }, 10, 0, std.math.pi / 2.0);
    defer testing.allocator.free(pts);
    try testing.expectEqual(Vec2{ 10, 0 }, pts[0]);
    try testing.expectApproxEqAbs(@as(f64, 10), pts[pts.len - 1][1], 1e-12);
    for (pts) |p| try testing.expectApproxEqAbs(@as(f64, 10), @sqrt(p[0] * p[0] + p[1] * p[1]), 1e-12);
}

test "flatten: a straight cubic is one segment" {
    const pts = try cubic(testing.allocator, .{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 } });
    defer testing.allocator.free(pts);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 3, 0 } }, pts);
}

test "flatten: a curved cubic stays within the sag" {
    const c: Cubic = .{ .{ 0, 0 }, .{ 0, 40 }, .{ 40, 40 }, .{ 40, 0 } };
    const pts = try cubic(testing.allocator, c);
    defer testing.allocator.free(pts);
    // Both second differences have length 40 * sqrt(2), so
    // n = ceil(sqrt(0.75 * 56.57 / 0.05)) = ceil(29.13) = 30.
    try testing.expectEqual(@as(usize, 31), pts.len);
    for (0..pts.len - 1) |i| {
        const mid = path.bezierPoint(c, (@as(f64, @floatFromInt(i)) + 0.5) / 30);
        const chord: Vec2 = .{ (pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2 };
        try testing.expect(geom.dist(mid, chord) <= sag);
    }
}

test "flatten: a spline passes through its points once each" {
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } };
    const out = try spline(testing.allocator, &pts);
    defer testing.allocator.free(out);
    try testing.expectEqual(pts[0], out[0]);
    try testing.expectEqual(pts[2], out[out.len - 1]);
    var hits: usize = 0;
    for (out) |p| hits += @intFromBool(std.meta.eql(p, pts[1]));
    try testing.expectEqual(@as(usize, 1), hits);
}
