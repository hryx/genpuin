//! Point queries and circle packing over small point sets. Everything is
//! brute force, as in the Lua original, which keeps results identical
//! and is fast enough for the few thousand items scripts use.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Rng = @import("rand.zig").Rng;
pub const Bounds = @import("rand.zig").Bounds;

pub const Vec2 = [2]f64;

/// Even-odd ray casting.
pub fn pointInPolygon(p: Vec2, poly: []const Vec2) bool {
    var hit = false;
    var j = poly.len -% 1;
    for (poly, 0..) |a, i| {
        const b = poly[j];
        if ((a[1] > p[1]) != (b[1] > p[1])) {
            const x = a[0] + (p[1] - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
            if (p[0] < x) hit = !hit;
        }
        j = i;
    }
    return hit;
}

fn dist(a: Vec2, b: Vec2) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return @sqrt(dx * dx + dy * dy);
}

pub const Hit = struct {
    index: u32,
    dist: f64,
};

/// The first point at the smallest distance from `q`, or null for an
/// empty list.
pub fn nearest(q: Vec2, points: []const Vec2) ?Hit {
    if (points.len == 0) return null;
    var best: Hit = .{ .index = 0, .dist = std.math.inf(f64) };
    for (points, 0..) |p, i| {
        const d = dist(q, p);
        if (d < best.dist) best = .{ .index = @intCast(i), .dist = d };
    }
    return best;
}

/// Points within `radius` of `q`, nearest first. Equal distances keep
/// list order. Allocated in `gpa`.
pub fn withinRadius(gpa: Allocator, q: Vec2, points: []const Vec2, radius: f64) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    const r2 = radius * radius;
    for (points, 0..) |p, i| {
        const dx = p[0] - q[0];
        const dy = p[1] - q[1];
        const d2 = dx * dx + dy * dy;
        if (d2 <= r2) try hits.append(gpa, .{ .index = @intCast(i), .dist = @sqrt(d2) });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.dist != b.dist) return a.dist < b.dist;
            return a.index < b.index;
        }
    }.lt);
    return hits.toOwnedSlice(gpa);
}

pub const Circle = struct {
    c: Vec2,
    r: f64,
};

pub const SeparateOptions = struct {
    iterations: f64 = 50,
    padding: f64 = 0,
    strength: f64 = 0.5,
    bounds: ?Bounds = null,
};

/// Push overlapping circles apart in place, up to `iterations` sweeps or
/// until nothing moves. Circles update in order within a sweep.
/// Coincident centres get a random push direction from `rng`.
pub fn separate(rng: *Rng, circles: []Circle, opts: SeparateOptions) void {
    var k: f64 = 1;
    while (k <= opts.iterations) : (k += 1) {
        var moved = false;
        for (circles, 0..) |*ci, i| {
            const cx = ci.c[0];
            const cy = ci.c[1];
            var dx: f64 = 0;
            var dy: f64 = 0;
            for (circles, 0..) |cj, j| {
                if (i == j) continue;
                var vx = cx - cj.c[0];
                var vy = cy - cj.c[1];
                var d = @sqrt(vx * vx + vy * vy);
                const min_dist = ci.r + cj.r + opts.padding;
                if (!(d < min_dist)) continue;
                if (d < 1e-10) {
                    vx = rng.next() - 0.5;
                    vy = rng.next() - 0.5;
                    d = @sqrt(vx * vx + vy * vy);
                }
                const overlap = (min_dist - d) * 0.5 * opts.strength;
                dx = dx + vx / d * overlap;
                dy = dy + vy / d * overlap;
                moved = true;
            }
            ci.c = .{ cx + dx, cy + dy };
            if (opts.bounds) |b| {
                ci.c[0] = @max(b.x + ci.r, @min(b.x + b.w - ci.r, ci.c[0]));
                ci.c[1] = @max(b.y + ci.r, @min(b.y + b.h - ci.r, ci.c[1]));
            }
        }
        if (!moved) break;
    }
}

pub const PackOptions = struct {
    bounds: Bounds,
    count: f64,
    /// Fixed radius. When null each circle draws one from the range.
    radius: ?f64 = null,
    radius_min: f64 = 0,
    radius_max: f64 = 0,
    padding: f64 = 0,
    attempts: f64 = 500,
    separation: f64 = 50,
};

/// Place up to `count` circles by best-candidate sampling: each circle
/// keeps the candidate with the most clearance, stopping early once 30
/// candidates have been tried and one fits. Then `separate` tidies the
/// result. Allocated in `gpa`.
pub fn packCircles(gpa: Allocator, rng: *Rng, opts: PackOptions) ![]Circle {
    var circles: std.ArrayList(Circle) = .empty;
    errdefer circles.deinit(gpa);
    const b = opts.bounds;
    var n: f64 = 1;
    while (n <= opts.count) : (n += 1) {
        const r = opts.radius orelse rng.range(opts.radius_min, opts.radius_max);
        var best: ?Vec2 = null;
        var best_clearance: f64 = -1;
        var attempt: f64 = 1;
        while (attempt <= opts.attempts) : (attempt += 1) {
            const px = b.x + r + rng.next() * @max(0, b.w - 2 * r);
            const py = b.y + r + rng.next() * @max(0, b.h - 2 * r);
            var clearance = std.math.inf(f64);
            for (circles.items) |o| {
                const d = dist(.{ px, py }, o.c) - o.r - r - opts.padding;
                if (d < clearance) clearance = d;
            }
            if (clearance >= 0 and clearance > best_clearance) {
                best = .{ px, py };
                best_clearance = clearance;
            }
            if (best_clearance >= 0 and attempt >= 30) break;
        }
        if (best) |c| try circles.append(gpa, .{ .c = c, .r = r });
    }
    if (opts.separation > 0 and circles.items.len > 0) {
        separate(rng, circles.items, .{ .iterations = opts.separation, .padding = opts.padding, .bounds = b });
    }
    return circles.toOwnedSlice(gpa);
}

const testing = std.testing;

test "spatial: pointInPolygon on a square" {
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    try testing.expect(pointInPolygon(.{ 5, 5 }, &sq));
    try testing.expect(!pointInPolygon(.{ 15, 5 }, &sq));
    try testing.expect(!pointInPolygon(.{ 5, 5 }, &.{}));
}

test "spatial: nearest keeps the first of equal distances" {
    const pts = [_]Vec2{ .{ 3, 0 }, .{ 0, 1 }, .{ -1, 0 } };
    const hit = nearest(.{ 0, 0 }, &pts).?;
    try testing.expectEqual(@as(u32, 1), hit.index);
    try testing.expectEqual(@as(f64, 1), hit.dist);
    try testing.expectEqual(@as(?Hit, null), nearest(.{ 0, 0 }, &.{}));
}

test "spatial: withinRadius sorts by distance" {
    const pts = [_]Vec2{ .{ 3, 0 }, .{ 0, 1 }, .{ 9, 9 }, .{ 0, 2 } };
    const hits = try withinRadius(testing.allocator, .{ 0, 0 }, &pts, 3);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 3), hits.len);
    try testing.expectEqual(@as(u32, 1), hits[0].index);
    try testing.expectEqual(@as(u32, 3), hits[1].index);
    try testing.expectEqual(@as(u32, 0), hits[2].index);
}

test "spatial: separate pushes two overlapping circles apart" {
    var rng: Rng = .init(1);
    var cs = [_]Circle{ .{ .c = .{ 0, 0 }, .r = 2 }, .{ .c = .{ 1, 0 }, .r = 2 } };
    separate(&rng, &cs, .{ .iterations = 200, .strength = 1 });
    try testing.expect(cs[1].c[0] - cs[0].c[0] >= 4 - 1e-9);
}

test "spatial: packCircles places non-overlapping circles in bounds" {
    var rng: Rng = .init(2);
    const cs = try packCircles(testing.allocator, &rng, .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .count = 20,
        .radius = 5,
        .separation = 0,
    });
    defer testing.allocator.free(cs);
    try testing.expectEqual(@as(usize, 20), cs.len);
    for (cs, 0..) |a, i| {
        try testing.expect(a.c[0] >= 5 and a.c[0] <= 95);
        for (cs[i + 1 ..]) |b| try testing.expect(dist(a.c, b.c) >= 10);
    }
}
