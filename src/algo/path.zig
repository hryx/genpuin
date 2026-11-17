//! Operations on point paths: arc-length sampling, subdivision, Chaikin
//! smoothing, jitter, stippling, dashing, and cubic Bezier and
//! Catmull-Rom evaluation. Results are allocated in the caller's
//! allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

const libm = @import("../libm.zig");
const Rng = @import("rand.zig").Rng;
const pointInPolygon = @import("spatial.zig").pointInPolygon;

pub const Vec2 = [2]f64;

/// Cumulative distance from pts[0] to each point.
fn cumulativeLengths(gpa: Allocator, pts: []const Vec2) ![]f64 {
    const lengths = try gpa.alloc(f64, pts.len);
    var total: f64 = 0;
    lengths[0] = 0;
    for (1..pts.len) |i| {
        const dx = pts[i][0] - pts[i - 1][0];
        const dy = pts[i][1] - pts[i - 1][1];
        total = total + @sqrt(dx * dx + dy * dy);
        lengths[i] = total;
    }
    return lengths;
}

/// The point at distance `d` along the path. The search starts at
/// `from.*`, which must not be past the answer, and moves there when a
/// segment is found. Pass a fresh 1 when distances are not increasing.
fn pointAtDist(pts: []const Vec2, lengths: []const f64, d: f64, from: *usize) Vec2 {
    for (from.*..pts.len) |i| {
        if (!(d <= lengths[i])) continue;
        from.* = i;
        const seg_len = lengths[i] - lengths[i - 1];
        if (seg_len == 0) return pts[i];
        const t = (d - lengths[i - 1]) / seg_len;
        return .{
            pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * t,
            pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * t,
        };
    }
    return pts[pts.len - 1];
}

/// `n` points evenly spaced by arc length from the first point to the
/// last. Needs at least two points.
pub fn sampleAlong(gpa: Allocator, pts: []const Vec2, n: f64) ![]Vec2 {
    std.debug.assert(pts.len >= 2);
    const lengths = try cumulativeLengths(gpa, pts);
    defer gpa.free(lengths);
    const total = lengths[pts.len - 1];

    var out: std.ArrayList(Vec2) = .empty;
    errdefer out.deinit(gpa);
    // Distances only grow with i, so each search resumes where the last
    // one stopped.
    var from: usize = 1;
    var i: f64 = 0;
    while (i <= n - 1) : (i += 1) {
        const d = (i / (n - 1)) * total;
        try out.append(gpa, pointAtDist(pts, lengths, d, &from));
    }
    return out.toOwnedSlice(gpa);
}

/// Insert the midpoint of every edge, `iterations` times. Closed paths
/// include the edge from the last point back to the first.
pub fn subdivide(gpa: Allocator, pts_in: []const Vec2, closed: bool, iterations: f64) ![]Vec2 {
    std.debug.assert(pts_in.len >= 2);
    var pts = try gpa.dupe(Vec2, pts_in);
    errdefer gpa.free(pts);
    var k: f64 = 1;
    while (k <= iterations) : (k += 1) {
        const count = if (closed) pts.len else pts.len - 1;
        const out = try gpa.alloc(Vec2, 2 * count + @intFromBool(!closed));
        for (0..count) |i| {
            const a = pts[i];
            const b = pts[(i + 1) % pts.len];
            out[2 * i] = a;
            out[2 * i + 1] = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
        }
        if (!closed) out[out.len - 1] = pts[pts.len - 1];
        gpa.free(pts);
        pts = out;
    }
    return pts;
}

/// Chaikin corner cutting (Chaikin 1974), `iterations` times. Open paths
/// keep their endpoints. Needs at least three points.
pub fn smooth(gpa: Allocator, pts_in: []const Vec2, closed: bool, iterations: f64) ![]Vec2 {
    std.debug.assert(pts_in.len >= 3);
    var pts = try gpa.dupe(Vec2, pts_in);
    errdefer gpa.free(pts);
    var k: f64 = 1;
    while (k <= iterations) : (k += 1) {
        const count = if (closed) pts.len else pts.len - 1;
        const out = try gpa.alloc(Vec2, 2 * count);
        for (0..count) |i| {
            const a = pts[i];
            const b = pts[(i + 1) % pts.len];
            out[2 * i] = .{ a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25 };
            out[2 * i + 1] = .{ a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75 };
        }
        if (!closed) {
            out[0] = pts[0];
            out[out.len - 1] = pts[pts.len - 1];
        }
        gpa.free(pts);
        pts = out;
    }
    return pts;
}

/// Each coordinate moved by a uniform amount in [-amount, amount), x
/// then y for each point in order.
pub fn jitter(gpa: Allocator, rng: *Rng, pts: []const Vec2, amount: f64) ![]Vec2 {
    const out = try gpa.alloc(Vec2, pts.len);
    for (pts, out) |p, *o| {
        const x = p[0] + rng.range(-amount, amount);
        o.* = .{ x, p[1] + rng.range(-amount, amount) };
    }
    return out;
}

/// Stroke widths for `segment_count` pieces of a path, interpolated from
/// `start` to `end`.
pub fn taperWidths(gpa: Allocator, segment_count: usize, start: f64, end: f64) ![]f64 {
    const out = try gpa.alloc(f64, segment_count);
    const last: f64 = @as(f64, @floatFromInt(segment_count)) - 1;
    for (out, 0..) |*w, i| {
        const t = @as(f64, @floatFromInt(i)) / last;
        w.* = start + (end - start) * t;
    }
    return out;
}

/// Uniform random dots over the bounding box of `pts`, about `density`
/// per unit area. Closed paths keep only the dots inside them.
pub fn stipple(gpa: Allocator, rng: *Rng, pts: []const Vec2, closed: bool, density: f64) ![]Vec2 {
    var min: Vec2 = .{ std.math.inf(f64), std.math.inf(f64) };
    var max: Vec2 = .{ -std.math.inf(f64), -std.math.inf(f64) };
    for (pts) |p| {
        if (p[0] < min[0]) min[0] = p[0];
        if (p[1] < min[1]) min[1] = p[1];
        if (p[0] > max[0]) max[0] = p[0];
        if (p[1] > max[1]) max[1] = p[1];
    }
    const w = max[0] - min[0];
    const h = max[1] - min[1];
    const count = @floor(w * h * density);

    var dots: std.ArrayList(Vec2) = .empty;
    errdefer dots.deinit(gpa);
    if (!std.math.isFinite(count)) return dots.toOwnedSlice(gpa);
    var i: f64 = 1;
    while (i <= count) : (i += 1) {
        const px = min[0] + rng.next() * w;
        const py = min[1] + rng.next() * h;
        if (!closed or pointInPolygon(.{ px, py }, pts)) try dots.append(gpa, .{ px, py });
    }
    return dots.toOwnedSlice(gpa);
}

/// Dashes of `dash_len` separated by gaps of `gap_len`, each a polyline
/// that keeps the path's vertices inside it. Needs at least two points
/// and a positive dash plus gap. Allocated in `arena`.
pub fn dash(arena: Allocator, pts: []const Vec2, dash_len: f64, gap_len: f64) ![][]Vec2 {
    std.debug.assert(pts.len >= 2);
    const cycle = dash_len + gap_len;
    std.debug.assert(cycle > 0);
    const lengths = try cumulativeLengths(arena, pts);
    const total = lengths[pts.len - 1];

    var dashes: std.ArrayList([]Vec2) = .empty;
    var seg: std.ArrayList(Vec2) = .empty;
    var d: f64 = 0;
    while (d < total) : (d = d + cycle) {
        const dash_end = @min(d + dash_len, total);
        var from: usize = 1;
        seg.clearRetainingCapacity();
        try seg.append(arena, pointAtDist(pts, lengths, d, &from));
        for (1..pts.len) |i| {
            if (lengths[i] > d and lengths[i] < dash_end) try seg.append(arena, pts[i]);
        }
        from = 1;
        try seg.append(arena, pointAtDist(pts, lengths, dash_end, &from));
        try dashes.append(arena, try arena.dupe(Vec2, seg.items));
    }
    return dashes.items;
}

pub const Cubic = [4]Vec2;

pub fn bezierPoint(c: Cubic, t: f64) Vec2 {
    const u = 1 - t;
    var out: Vec2 = undefined;
    for (0..2) |k| {
        out[k] = u * u * u * c[0][k] + 3 * u * u * t * c[1][k] + 3 * u * t * t * c[2][k] + t * t * t * c[3][k];
    }
    return out;
}

pub fn bezierTangent(c: Cubic, t: f64) Vec2 {
    const u = 1 - t;
    var out: Vec2 = undefined;
    for (0..2) |k| {
        out[k] = 3 * u * u * (c[1][k] - c[0][k]) + 6 * u * t * (c[2][k] - c[1][k]) + 3 * t * t * (c[3][k] - c[2][k]);
    }
    return out;
}

/// The Bezier form of the uniform Catmull-Rom segment from p1 to p2,
/// with p0 and p3 as neighbours.
pub fn catmullRomToBezier(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2) Cubic {
    return .{
        p1,
        .{ p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6 },
        .{ p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6 },
        p2,
    };
}

/// One Bezier segment per gap between points of a Catmull-Rom spline.
/// The end points are doubled as their own neighbours.
pub fn splineToBeziers(gpa: Allocator, pts: []const Vec2) ![]Cubic {
    if (pts.len < 2) return gpa.alloc(Cubic, 0);
    const out = try gpa.alloc(Cubic, pts.len - 1);
    for (out, 0..) |*seg, i| {
        const p0 = pts[if (i == 0) 0 else i - 1];
        const p3 = pts[@min(i + 2, pts.len - 1)];
        seg.* = catmullRomToBezier(p0, pts[i], pts[i + 1], p3);
    }
    return out;
}

/// Positions and tangent angles at `n` evenly spaced interior samples
/// of a path, with t running 0..1 across them.
pub const Along = struct {
    points: []Vec2,
    angles: []f64,
    ts: []f64,
};

pub fn alongPath(arena: Allocator, pts: []const Vec2, n: f64) !Along {
    const s = try sampleAlong(arena, pts, n + 2);
    const count = if (s.len >= 3) s.len - 2 else 0;
    const out: Along = .{
        .points = s[1..][0..count],
        .angles = try arena.alloc(f64, count),
        .ts = try arena.alloc(f64, count),
    };
    for (0..count) |k| {
        const prev = s[k];
        const next = s[k + 2];
        out.angles[k] = libm.atan2(next[1] - prev[1], next[0] - prev[0]);
        out.ts[k] = @as(f64, @floatFromInt(k)) / @max(n - 1, 1);
    }
    return out;
}

const testing = std.testing;

test "path: sampleAlong spaces points by arc length" {
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } };
    const s = try sampleAlong(testing.allocator, &pts, 5);
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 10, 10 } }, s);
}

test "path: sampleAlong with one sample gives the last point" {
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 4, 0 } };
    const s = try sampleAlong(testing.allocator, &pts, 1);
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(Vec2, &.{.{ 4, 0 }}, s);
}

test "path: subdivide open and closed" {
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 } };
    const open = try subdivide(testing.allocator, &pts, false, 1);
    defer testing.allocator.free(open);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 } }, open);
    const closed = try subdivide(testing.allocator, &pts, true, 1);
    defer testing.allocator.free(closed);
    try testing.expectEqual(@as(usize, 6), closed.len);
    try testing.expectEqual(Vec2{ 1, 1 }, closed[5]);
}

test "path: smooth keeps open endpoints" {
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 } };
    const s = try smooth(testing.allocator, &pts, false, 1);
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 3, 0 }, .{ 4, 1 }, .{ 4, 4 } }, s);
}

test "path: jitter stays within amount" {
    var rng: Rng = .init(4);
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 10, 10 } };
    const j = try jitter(testing.allocator, &rng, &pts, 0.5);
    defer testing.allocator.free(j);
    for (pts, j) |p, q| {
        try testing.expect(@abs(p[0] - q[0]) <= 0.5);
        try testing.expect(@abs(p[1] - q[1]) <= 0.5);
    }
}

test "path: stipple keeps dots inside a closed shape" {
    var rng: Rng = .init(8);
    const tri = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } };
    const dots = try stipple(testing.allocator, &rng, &tri, true, 1);
    defer testing.allocator.free(dots);
    try testing.expect(dots.len > 20 and dots.len < 80);
    for (dots) |d| try testing.expect(d[0] + d[1] <= 10);
}

test "path: dash splits a line into dashes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 } };
    const ds = try dash(arena_state.allocator(), &pts, 2, 3);
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expectEqualSlices(Vec2, &.{ .{ 5, 0 }, .{ 7, 0 } }, ds[1]);
}

test "path: bezier ends and tangent" {
    const c: Cubic = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
    try testing.expectEqual(Vec2{ 0, 0 }, bezierPoint(c, 0));
    try testing.expectEqual(Vec2{ 1, 0 }, bezierPoint(c, 1));
    try testing.expectEqual(Vec2{ 0.5, 0.75 }, bezierPoint(c, 0.5));
    try testing.expectEqual(Vec2{ 0, 3 }, bezierTangent(c, 0));
}

test "path: splineToBeziers passes through every point" {
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 6 } };
    const segs = try splineToBeziers(testing.allocator, &pts);
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqual(Vec2{ 6, 0 }, segs[0][3]);
    try testing.expectEqual(Vec2{ 1, 0 }, segs[0][1]);
    try testing.expectEqual(Vec2{ 6, 6 }, segs[1][3]);
}

test "path: alongPath gives interior samples and tangents" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const pts = [_]Vec2{ .{ 0, 0 }, .{ 0, 9 } };
    const a = try alongPath(arena_state.allocator(), &pts, 2);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 3 }, .{ 0, 6 } }, a.points);
    try testing.expectEqual(std.math.pi / 2.0, a.angles[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 1 }, a.ts);
}
