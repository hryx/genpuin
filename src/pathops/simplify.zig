//! Line simplification: Ramer-Douglas-Peucker (Douglas and Peucker,
//! "Algorithms for the reduction of the number of points required to
//! represent a digitized line or its caricature", 1973) and
//! Visvalingam-Whyatt ("Line generalisation by repeated elimination of
//! points", The Cartographic Journal 30, 1993).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const geom = @import("geom.zig");
const Vec2 = geom.Vec2;

pub const Method = enum { distance, area };

/// Simplify an open or closed path. `tolerance` is a distance. The area
/// method drops points whose triangle with its neighbours has an area
/// under tolerance squared. Endpoints of an open path always stay and a
/// closed path keeps at least three points. Caller owns the result.
pub fn simplify(gpa: Allocator, pts: []const Vec2, tolerance: f64, closed: bool, method: Method) ![]Vec2 {
    if (pts.len <= 2 or (closed and pts.len <= 3) or tolerance <= 0) return gpa.dupe(Vec2, pts);
    const keep = try gpa.alloc(bool, pts.len);
    defer gpa.free(keep);
    switch (method) {
        .distance => try rdp(gpa, pts, tolerance, closed, keep),
        .area => try visvalingam(gpa, pts, tolerance * tolerance, closed, keep),
    }
    var n: usize = 0;
    for (keep) |k| n += @intFromBool(k);
    const out = try gpa.alloc(Vec2, n);
    var o: usize = 0;
    for (pts, keep) |p, k| if (k) {
        out[o] = p;
        o += 1;
    };
    return out;
}

fn rdp(gpa: Allocator, pts: []const Vec2, tol: f64, closed: bool, keep: []bool) !void {
    @memset(keep, false);
    const n = pts.len;
    const Range = struct { a: usize, b: usize };
    var stack: std.ArrayList(Range) = .empty;
    defer stack.deinit(gpa);
    keep[0] = true;
    if (closed) {
        // Anchor the ring at point 0 and the point farthest from it, then
        // treat both halves as open runs. Index n stands for point 0 again.
        var far: usize = 1;
        for (pts[1..], 1..) |p, i| {
            if (geom.dist(p, pts[0]) > geom.dist(pts[far], pts[0])) far = i;
        }
        keep[far] = true;
        try stack.append(gpa, .{ .a = 0, .b = far });
        try stack.append(gpa, .{ .a = far, .b = n });
    } else {
        keep[n - 1] = true;
        try stack.append(gpa, .{ .a = 0, .b = n - 1 });
    }
    const tol2 = tol * tol;
    while (stack.pop()) |r| {
        if (r.b <= r.a + 1) continue;
        const a = pts[r.a];
        const b = pts[r.b % n];
        var best: f64 = -1;
        var at: usize = 0;
        for (r.a + 1..r.b) |i| {
            const d = geom.segmentDist2(pts[i], a, b);
            if (d > best) {
                best = d;
                at = i;
            }
        }
        if (best <= tol2) continue;
        keep[at] = true;
        try stack.append(gpa, .{ .a = r.a, .b = at });
        try stack.append(gpa, .{ .a = at, .b = r.b });
    }
    if (closed) {
        var count: usize = 0;
        for (keep) |k| count += @intFromBool(k);
        if (count < 3) {
            // Both halves collapsed. Keep the point farthest off the chord.
            var best: f64 = -1;
            var at: usize = 1;
            var far: usize = 0;
            for (keep, 0..) |k, i| if (k and i != 0) {
                far = i;
            };
            for (pts, 0..) |p, i| {
                const d = geom.segmentDist2(p, pts[0], pts[far]);
                if (!keep[i] and d > best) {
                    best = d;
                    at = i;
                }
            }
            keep[at] = true;
        }
    }
}

const Heap = std.PriorityQueue(Entry, void, entryOrder);

const Entry = struct { area: f64, index: u32, stamp: u32 };

fn entryOrder(_: void, a: Entry, b: Entry) std.math.Order {
    return std.math.order(a.area, b.area);
}

fn triArea(a: Vec2, b: Vec2, c: Vec2) f64 {
    return @abs(geom.cross(geom.sub(b, a), geom.sub(c, a))) / 2;
}

fn visvalingam(gpa: Allocator, pts: []const Vec2, area_min: f64, closed: bool, keep: []bool) !void {
    const n = pts.len;
    @memset(keep, true);
    const prev = try gpa.alloc(u32, n);
    defer gpa.free(prev);
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    const stamp = try gpa.alloc(u32, n);
    defer gpa.free(stamp);
    @memset(stamp, 0);
    for (0..n) |i| {
        prev[i] = @intCast((i + n - 1) % n);
        next[i] = @intCast((i + 1) % n);
    }
    var heap: Heap = .empty;
    defer heap.deinit(gpa);
    const lo: usize = if (closed) 0 else 1;
    const hi: usize = if (closed) n else n - 1;
    for (lo..hi) |i| {
        try heap.push(gpa, .{ .area = triArea(pts[prev[i]], pts[i], pts[next[i]]), .index = @intCast(i), .stamp = 0 });
    }
    var left = n;
    const min_left: usize = if (closed) 3 else 2;
    var floor: f64 = 0;
    while (heap.pop()) |e| {
        if (e.stamp != stamp[e.index] or !keep[e.index]) continue;
        if (e.area >= area_min or left <= min_left) break;
        keep[e.index] = false;
        left -= 1;
        // Areas never drop below the last removed one, so a removal
        // cannot make a neighbour cheaper than what came before it.
        floor = @max(floor, e.area);
        const p = prev[e.index];
        const q = next[e.index];
        next[p] = q;
        prev[q] = p;
        for ([2]u32{ p, q }) |k| {
            if (!closed and (k == 0 or k == n - 1)) continue;
            stamp[k] += 1;
            const a = @max(floor, triArea(pts[prev[k]], pts[k], pts[next[k]]));
            try heap.push(gpa, .{ .area = a, .index = k, .stamp = stamp[k] });
        }
    }
}

test "simplify: rdp drops near-collinear points" {
    const gpa = std.testing.allocator;
    const line = [_]Vec2{ .{ 0, 0 }, .{ 1, 0.05 }, .{ 2, -0.05 }, .{ 3, 0 }, .{ 3, 3 } };
    const out = try simplify(gpa, &line, 0.1, false, .distance);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 } }, out);
}

test "simplify: closed square with midpoints keeps its corners" {
    const gpa = std.testing.allocator;
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
    for ([_]Method{ .distance, .area }) |m| {
        const out = try simplify(gpa, &sq, 0.01, true, m);
        defer gpa.free(out);
        try std.testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } }, out);
    }
}

test "simplify: area method removes the smallest triangles first" {
    const gpa = std.testing.allocator;
    const line = [_]Vec2{ .{ 0, 0 }, .{ 1, 0.1 }, .{ 2, 0 }, .{ 3, 2 }, .{ 4, 0 } };
    const out = try simplify(gpa, &line, 0.5, false, .area);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 3, 2 }, .{ 4, 0 } }, out);
}
