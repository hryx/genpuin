//! Voronoi cells by half-plane clipping: each cell starts as the bounds
//! rectangle and is clipped (Sutherland-Hodgman) against the bisector of
//! its site and every other site. O(n^2) per diagram, exact for convex
//! cells, and fine for the few hundred sites scripts use.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec2 = [2]f64;
pub const Bounds = @import("rand.zig").Bounds;

/// Keep the side of the line through `p` where dot(q - p, normal) <= 0.
/// `out` needs room for 2 * poly.len points. A convex polygon gains at
/// most one vertex, but rounding near the line can flip signs more often.
fn clipHalfPlane(poly: []const Vec2, p: Vec2, normal: Vec2, out: []Vec2) []Vec2 {
    std.debug.assert(out.len >= 2 * poly.len);
    var n: usize = 0;
    if (poly.len == 0) return out[0..0];
    var prev = poly[poly.len - 1];
    var prev_dot = (prev[0] - p[0]) * normal[0] + (prev[1] - p[1]) * normal[1];
    for (poly) |curr| {
        const curr_dot = (curr[0] - p[0]) * normal[0] + (curr[1] - p[1]) * normal[1];
        if (curr_dot <= 0) {
            if (prev_dot > 0) {
                out[n] = lerpAt(prev, curr, prev_dot, curr_dot);
                n += 1;
            }
            out[n] = curr;
            n += 1;
        } else if (prev_dot <= 0) {
            out[n] = lerpAt(prev, curr, prev_dot, curr_dot);
            n += 1;
        }
        prev = curr;
        prev_dot = curr_dot;
    }
    return out[0..n];
}

fn lerpAt(a: Vec2, b: Vec2, a_dot: f64, b_dot: f64) Vec2 {
    const t = a_dot / (a_dot - b_dot);
    return .{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
}

/// Scratch for clipping cells, reused across calls.
pub const Clipper = struct {
    front: std.ArrayList(Vec2) = .empty,
    back: std.ArrayList(Vec2) = .empty,

    pub fn deinit(c: *Clipper, gpa: Allocator) void {
        c.front.deinit(gpa);
        c.back.deinit(gpa);
    }

    /// The cell of sites[index] inside `bounds`. The slice points into
    /// the clipper and is valid until the next call.
    pub fn cell(c: *Clipper, gpa: Allocator, sites: []const Vec2, index: usize, bounds: Bounds) ![]const Vec2 {
        c.front.clearRetainingCapacity();
        try c.front.appendSlice(gpa, &.{
            .{ bounds.x, bounds.y },
            .{ bounds.x + bounds.w, bounds.y },
            .{ bounds.x + bounds.w, bounds.y + bounds.h },
            .{ bounds.x, bounds.y + bounds.h },
        });
        const s = sites[index];
        for (sites, 0..) |other, j| {
            if (j == index) continue;
            const mid: Vec2 = .{ (s[0] + other[0]) * 0.5, (s[1] + other[1]) * 0.5 };
            const normal: Vec2 = .{ other[0] - s[0], other[1] - s[1] };
            try c.back.resize(gpa, 2 * c.front.items.len);
            const n = clipHalfPlane(c.front.items, mid, normal, c.back.items).len;
            c.back.shrinkRetainingCapacity(n);
            std.mem.swap(std.ArrayList(Vec2), &c.front, &c.back);
            if (n == 0) break;
        }
        return c.front.items;
    }
};

pub const Cell = struct {
    site: u32,
    points: []Vec2,
};

/// Cells with at least three vertices, in site order. Allocated in
/// `arena`.
pub fn diagram(arena: Allocator, sites: []const Vec2, bounds: Bounds) ![]Cell {
    var clipper: Clipper = .{};
    var cells: std.ArrayList(Cell) = .empty;
    for (0..sites.len) |i| {
        const poly = try clipper.cell(arena, sites, i, bounds);
        if (poly.len < 3) continue;
        try cells.append(arena, .{ .site = @intCast(i), .points = try arena.dupe(Vec2, poly) });
    }
    return cells.items;
}

/// Lloyd relaxation in place: each site moves to its cell's centroid,
/// `iterations` times. Sites update in order, so later cells see the
/// moved earlier sites.
pub fn relax(gpa: Allocator, sites: []Vec2, bounds: Bounds, iterations: f64) !void {
    var clipper: Clipper = .{};
    defer clipper.deinit(gpa);
    var k: f64 = 1;
    while (k <= iterations) : (k += 1) {
        for (0..sites.len) |i| {
            const poly = try clipper.cell(gpa, sites, i, bounds);
            if (poly.len >= 3) sites[i] = centroid(poly);
        }
    }
}

/// Signed-area polygon centroid, falling back to the vertex mean for
/// degenerate polygons.
pub fn centroid(pts: []const Vec2) Vec2 {
    switch (pts.len) {
        0 => return .{ 0, 0 },
        1 => return pts[0],
        2 => return .{ (pts[0][0] + pts[1][0]) * 0.5, (pts[0][1] + pts[1][1]) * 0.5 },
        else => {},
    }
    var area: f64 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        const cross = p[0] * q[1] - q[0] * p[1];
        area = area + cross;
        cx = cx + (p[0] + q[0]) * cross;
        cy = cy + (p[1] + q[1]) * cross;
    }
    area = area * 0.5;
    if (@abs(area) < 1e-10) {
        cx = 0;
        cy = 0;
        for (pts) |p| {
            cx = cx + p[0];
            cy = cy + p[1];
        }
        const n: f64 = @floatFromInt(pts.len);
        return .{ cx / n, cy / n };
    }
    const factor = 1 / (6 * area);
    return .{ cx * factor, cy * factor };
}

const testing = std.testing;

test "voronoi: two sites split the bounds down the bisector" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const sites = [_]Vec2{ .{ 25, 50 }, .{ 75, 50 } };
    const cells = try diagram(arena_state.allocator(), &sites, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try testing.expectEqual(@as(usize, 2), cells.len);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 50, 0 }, .{ 50, 100 }, .{ 0, 100 } }, cells[0].points);
    try testing.expectEqual(@as(u32, 1), cells[1].site);
}

test "voronoi: a site outside the bounds gets no cell" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const sites = [_]Vec2{ .{ 50, 50 }, .{ 500, 50 } };
    const cells = try diagram(arena_state.allocator(), &sites, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try testing.expectEqual(@as(usize, 1), cells.len);
    try testing.expectEqual(@as(u32, 0), cells[0].site);
}

test "voronoi: relax moves sites to cell centroids" {
    var sites = [_]Vec2{ .{ 10, 50 }, .{ 30, 50 } };
    try relax(testing.allocator, &sites, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, 1);
    try testing.expectEqual(Vec2{ 10, 50 }, sites[0]);
    try testing.expectEqual(Vec2{ 60, 50 }, sites[1]);
}

test "voronoi: centroid of a unit square" {
    try testing.expectEqual(Vec2{ 0.5, 0.5 }, centroid(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }));
    try testing.expectEqual(Vec2{ 1, 1 }, centroid(&.{ .{ 0, 0 }, .{ 2, 2 }, .{ 1, 1 } }));
}
