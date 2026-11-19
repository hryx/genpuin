//! Operations on point paths: arc-length sampling, subdivision, Chaikin
//! smoothing, jitter, stippling, dashing, and cubic Bezier and
//! Catmull-Rom evaluation. Results are allocated in the caller's
//! allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const Rng = @import("rand.zig").Rng;
const pointInPolygon = @import("spatial.zig").pointInPolygon;
const EdgeSet = @import("../pathops/EdgeSet.zig");

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

/// Lower and upper corners of an axis-aligned box.
pub const Box = [2]Vec2;

/// The box around `pts`. Empty input gives an inverted infinite box.
pub fn pointsBox(pts: []const Vec2) Box {
    var min: Vec2 = .{ std.math.inf(f64), std.math.inf(f64) };
    var max: Vec2 = .{ -std.math.inf(f64), -std.math.inf(f64) };
    for (pts) |p| {
        if (p[0] < min[0]) min[0] = p[0];
        if (p[1] < min[1]) min[1] = p[1];
        if (p[0] > max[0]) max[0] = p[0];
        if (p[1] > max[1]) max[1] = p[1];
    }
    return .{ min, max };
}

pub fn growBox(b: Box, p: Vec2) Box {
    return .{
        .{ @min(b[0][0], p[0]), @min(b[0][1], p[1]) },
        .{ @max(b[1][0], p[0]), @max(b[1][1], p[1]) },
    };
}

/// The exact box of a cubic Bezier: its ends plus the points where
/// dx/dt or dy/dt is zero.
pub fn cubicBox(c: Cubic) Box {
    var b = pointsBox(&.{ c[0], c[3] });
    for (0..2) |k| {
        const a = c[1][k] - c[0][k];
        const m = c[2][k] - c[1][k];
        const e = c[3][k] - c[2][k];
        // B'(t) / 3 = qa t^2 + qb t + a.
        const qa = a - 2 * m + e;
        const qb = 2 * (m - a);
        var roots: [2]f64 = .{ -1, -1 };
        if (@abs(qa) < 1e-12) {
            if (qb != 0) roots[0] = -a / qb;
        } else {
            const disc = qb * qb - 4 * qa * a;
            if (disc >= 0) {
                const sq = @sqrt(disc);
                roots = .{ (-qb + sq) / (2 * qa), (-qb - sq) / (2 * qa) };
            }
        }
        for (roots) |t| {
            if (t > 0 and t < 1) b = growBox(b, bezierPoint(c, t));
        }
    }
    return b;
}

/// The area stipple keeps dots in, read as the rasterizer fills it.
pub const Region = union(enum) {
    /// Every dot of the box is kept. Open paths have no inside.
    open: Box,
    /// Even-odd crossing test, as spatial.pointInPolygon.
    polygon: []const Vec2,
    /// Nonzero winding over all contours.
    compound: []const []const Vec2,
    circle: struct { c: Vec2, r: f64 },
    ellipse: struct { c: Vec2, rx: f64, ry: f64 },
    /// Corner radii follow render.zig: a zero radius takes the other one,
    /// and each is clamped to half the side.
    rect: struct { x: f64, y: f64, w: f64, h: f64, rx: f64 = 0, ry: f64 = 0 },
    /// The pie slice from the center that the rasterizer fills for an arc.
    /// A sweep of a full turn or more is the whole disc.
    pie: struct { c: Vec2, r: f64, start: f64, end: f64 },

    pub fn box(region: Region) Box {
        return switch (region) {
            .open => |b| b,
            .polygon => |pts| pointsBox(pts),
            .compound => |cs| blk: {
                var b = pointsBox(&.{});
                for (cs) |c| {
                    const cb = pointsBox(c);
                    b = growBox(growBox(b, cb[0]), cb[1]);
                }
                break :blk b;
            },
            .circle => |c| .{ .{ c.c[0] - @abs(c.r), c.c[1] - @abs(c.r) }, .{ c.c[0] + @abs(c.r), c.c[1] + @abs(c.r) } },
            .ellipse => |e| .{ .{ e.c[0] - @abs(e.rx), e.c[1] - @abs(e.ry) }, .{ e.c[0] + @abs(e.rx), e.c[1] + @abs(e.ry) } },
            .rect => |r| pointsBox(&.{ .{ r.x, r.y }, .{ r.x + r.w, r.y + r.h } }),
            .pie => |p| pieBox(p.c, p.r, p.start, p.end),
        };
    }
};

fn pieBox(c: Vec2, r: f64, start: f64, end: f64) Box {
    const lo = @min(start, end);
    const sweep = @abs(end - start);
    var b = pointsBox(&.{
        c,
        .{ c[0] + r * math.cos(start), c[1] + r * math.sin(start) },
        .{ c[0] + r * math.cos(end), c[1] + r * math.sin(end) },
    });
    for (0..4) |k| {
        const t = @as(f64, @floatFromInt(k)) * std.math.pi / 2.0;
        if (sweep >= std.math.tau or math.mod(t - lo, std.math.tau) <= sweep) {
            b = growBox(b, .{ c[0] + r * math.cos(t), c[1] + r * math.sin(t) });
        }
    }
    return b;
}

fn insideRect(x: f64, y: f64, w: f64, h: f64, rx_in: f64, ry_in: f64, p: Vec2) bool {
    const x0 = @min(x, x + w);
    const y0 = @min(y, y + h);
    const aw = @abs(w);
    const ah = @abs(h);
    if (!(p[0] >= x0 and p[0] <= x0 + aw and p[1] >= y0 and p[1] <= y0 + ah)) return false;
    if (!(rx_in > 0 or ry_in > 0)) return true;
    const rx = @min(if (rx_in > 0) rx_in else ry_in, aw / 2);
    const ry = @min(if (ry_in > 0) ry_in else rx_in, ah / 2);
    if (!(rx > 0 and ry > 0)) return true;
    // Distance past the inner rect whose corners are the arc centers.
    const dx = (p[0] - std.math.clamp(p[0], x0 + rx, x0 + aw - rx)) / rx;
    const dy = (p[1] - std.math.clamp(p[1], y0 + ry, y0 + ah - ry)) / ry;
    return dx * dx + dy * dy <= 1;
}

fn insidePie(c: Vec2, r: f64, start: f64, end: f64, p: Vec2) bool {
    const dx = p[0] - c[0];
    const dy = p[1] - c[1];
    if (!(dx * dx + dy * dy <= r * r)) return false;
    const sweep = @abs(end - start);
    if (sweep >= std.math.tau) return true;
    // A negative radius puts every point half a turn round.
    const a = if (r < 0) math.atan2(-dy, -dx) else math.atan2(dy, dx);
    return math.mod(a - @min(start, end), std.math.tau) <= sweep;
}

/// Uniform random dots over the box of `region`, about `density` per
/// unit area, keeping those inside it. Each dot draws x then y from
/// `rng`, kept or not, so the stream advances by twice the dot count of
/// the box whatever the shape.
pub fn stipple(gpa: Allocator, rng: *Rng, region: Region, density: f64) ![]Vec2 {
    const b = region.box();
    const min = b[0];
    const w = b[1][0] - min[0];
    const h = b[1][1] - min[1];
    const count = @floor(w * h * density);

    var edges: ?EdgeSet = switch (region) {
        .compound => |cs| try .init(gpa, cs, true),
        else => null,
    };
    defer if (edges) |*e| e.deinit(gpa);

    var dots: std.ArrayList(Vec2) = .empty;
    errdefer dots.deinit(gpa);
    if (!std.math.isFinite(count)) return dots.toOwnedSlice(gpa);
    var i: f64 = 1;
    while (i <= count) : (i += 1) {
        const px = min[0] + rng.next() * w;
        const py = min[1] + rng.next() * h;
        const p: Vec2 = .{ px, py };
        const keep = switch (region) {
            .open => true,
            .polygon => |pts| pointInPolygon(p, pts),
            .compound => edges.?.winding(p) != 0,
            .circle => |c| (px - c.c[0]) * (px - c.c[0]) + (py - c.c[1]) * (py - c.c[1]) <= c.r * c.r,
            .ellipse => |e| blk: {
                const u = (px - e.c[0]) / e.rx;
                const v = (py - e.c[1]) / e.ry;
                break :blk u * u + v * v <= 1;
            },
            .rect => |r| insideRect(r.x, r.y, r.w, r.h, r.rx, r.ry, p),
            .pie => |a| insidePie(a.c, a.r, a.start, a.end, p),
        };
        if (keep) try dots.append(gpa, p);
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
/// with p0 and p3 as neighbors.
pub fn catmullRomToBezier(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2) Cubic {
    return .{
        p1,
        .{ p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6 },
        .{ p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6 },
        p2,
    };
}

/// One Bezier segment per gap between points of a Catmull-Rom spline.
/// The end points are doubled as their own neighbors.
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
        out.angles[k] = math.atan2(next[1] - prev[1], next[0] - prev[0]);
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
    const dots = try stipple(testing.allocator, &rng, .{ .polygon = &tri }, 1);
    defer testing.allocator.free(dots);
    try testing.expect(dots.len > 20 and dots.len < 80);
    for (dots) |d| try testing.expect(d[0] + d[1] <= 10);
}

test "path: stipple draws two numbers per dot of the box for any region" {
    const square = [_]Vec2{ .{ -5, -5 }, .{ 5, -5 }, .{ 5, 5 }, .{ -5, 5 } };
    const regions = [_]Region{
        .{ .polygon = &square },
        .{ .circle = .{ .c = .{ 0, 0 }, .r = 5 } },
        .{ .rect = .{ .x = -5, .y = -5, .w = 10, .h = 10, .rx = 3 } },
        .{ .open = .{ .{ -5, -5 }, .{ 5, 5 } } },
    };
    var want: Rng = .init(3);
    for (0..2 * 50) |_| _ = want.next();
    for (regions) |region| {
        var rng: Rng = .init(3);
        const dots = try stipple(testing.allocator, &rng, region, 0.5);
        defer testing.allocator.free(dots);
        try testing.expectEqual(want.x.s, rng.x.s);
    }
}

test "path: stipple keeps a circle's dots on its disc" {
    var rng: Rng = .init(5);
    const dots = try stipple(testing.allocator, &rng, .{ .circle = .{ .c = .{ 10, 20 }, .r = 4 } }, 4);
    defer testing.allocator.free(dots);
    // 64 * 4 = 256 tries over the box, pi / 4 of them inside.
    try testing.expect(dots.len > 170 and dots.len < 230);
    for (dots) |d| try testing.expect((d[0] - 10) * (d[0] - 10) + (d[1] - 20) * (d[1] - 20) <= 16);
}

test "path: a compound's hole stays empty" {
    var rng: Rng = .init(6);
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 9, 0 }, .{ 9, 9 }, .{ 0, 9 } };
    const hole = [_]Vec2{ .{ 3, 3 }, .{ 3, 6 }, .{ 6, 6 }, .{ 6, 3 } };
    const dots = try stipple(testing.allocator, &rng, .{ .compound = &.{ &outer, &hole } }, 4);
    defer testing.allocator.free(dots);
    try testing.expect(dots.len > 250);
    for (dots) |d| try testing.expect(!(d[0] > 3 and d[0] < 6 and d[1] > 3 and d[1] < 6));
}

test "path: a rounded rect cuts its corners" {
    const r: Region = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 6, .rx = 2 } };
    try testing.expectEqual(Box{ .{ 0, 0 }, .{ 10, 6 } }, r.box());
    var rng: Rng = .init(7);
    const dots = try stipple(testing.allocator, &rng, r, 8);
    defer testing.allocator.free(dots);
    for (dots) |d| {
        const dx = d[0] - std.math.clamp(d[0], 2, 8);
        const dy = d[1] - std.math.clamp(d[1], 2, 4);
        try testing.expect(dx * dx + dy * dy <= 4);
    }
}

test "path: a pie's box holds the axis points inside its sweep" {
    const quarter: Region = .{ .pie = .{ .c = .{ 0, 0 }, .r = 2, .start = 0.5, .end = 2 } };
    const b = quarter.box();
    try testing.expectEqual(@as(f64, 0), b[0][1]);
    try testing.expectEqual(@as(f64, 2), b[1][1]);
    try testing.expect(b[0][0] < 0 and b[1][0] < 2);
    const full: Region = .{ .pie = .{ .c = .{ 1, 1 }, .r = 1, .start = 0, .end = 7 } };
    try testing.expectEqual(Box{ .{ 0, 0 }, .{ 2, 2 } }, full.box());
}

test "path: cubicBox finds the curve's turning points" {
    const b = cubicBox(.{ .{ 0, 0 }, .{ 0, 40 }, .{ 40, 40 }, .{ 40, 0 } });
    try testing.expectEqual(Box{ .{ 0, 0 }, .{ 40, 30 } }, b);
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
