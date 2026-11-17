//! The edges of a set of contours, indexed for nearest-edge distance and
//! box queries (a bounding volume hierarchy) and for winding numbers
//! (edges binned into horizontal bands).

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const geom = @import("geom.zig");
const Vec2 = geom.Vec2;

const EdgeSet = @This();

edges: [][2]Vec2,
nodes: []Node,
lo: Vec2,
hi: Vec2,
band_h: f64,
band_start: []u32,
band_items: []u32,

const leaf_size = 4;
const stack_len = 96;

const Node = struct {
    lo: Vec2,
    hi: Vec2,
    /// Leaves index `edges` directly, inner nodes index their left child.
    first: u32,
    /// Zero for an inner node.
    count: u32,
    right: u32,
};

/// Index every edge of `contours`. Closed contours get their closing
/// edge. Zero-length edges are dropped.
pub fn init(gpa: Allocator, contours: geom.Contours, closed: bool) !EdgeSet {
    var list: std.ArrayList([2]Vec2) = .empty;
    errdefer list.deinit(gpa);
    for (contours) |c| {
        if (c.len < 2) continue;
        const n = if (closed) c.len else c.len - 1;
        for (0..n) |i| {
            const a = c[i];
            const b = c[(i + 1) % c.len];
            if (!geom.eql(a, b)) try list.append(gpa, .{ a, b });
        }
    }
    const edges = try list.toOwnedSlice(gpa);
    errdefer gpa.free(edges);

    var self: EdgeSet = .{
        .edges = edges,
        .nodes = &.{},
        .lo = .{ 0, 0 },
        .hi = .{ 0, 0 },
        .band_h = 1,
        .band_start = &.{},
        .band_items = &.{},
    };
    if (edges.len == 0) {
        self.band_start = try gpa.alloc(u32, 1);
        self.band_start[0] = 0;
        return self;
    }
    self.nodes = try buildTree(gpa, edges);
    errdefer gpa.free(self.nodes);
    self.lo = self.nodes[0].lo;
    self.hi = self.nodes[0].hi;
    try self.buildBands(gpa);
    return self;
}

pub fn deinit(self: *EdgeSet, gpa: Allocator) void {
    gpa.free(self.edges);
    gpa.free(self.nodes);
    gpa.free(self.band_start);
    gpa.free(self.band_items);
    self.* = undefined;
}

fn edgeBox(e: [2]Vec2) [2]Vec2 {
    return .{
        .{ @min(e[0][0], e[1][0]), @min(e[0][1], e[1][1]) },
        .{ @max(e[0][0], e[1][0]), @max(e[0][1], e[1][1]) },
    };
}

const SortCtx = struct {
    axis: usize,
    fn less(ctx: SortCtx, a: [2]Vec2, b: [2]Vec2) bool {
        return a[0][ctx.axis] + a[1][ctx.axis] < b[0][ctx.axis] + b[1][ctx.axis];
    }
};

/// Median-split tree built top down with an explicit work list. Edges
/// are reordered in place so every node owns a contiguous run.
fn buildTree(gpa: Allocator, edges: [][2]Vec2) ![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(gpa);
    const Work = struct { node: u32, start: u32, end: u32 };
    var work: std.ArrayList(Work) = .empty;
    defer work.deinit(gpa);

    try nodes.append(gpa, undefined);
    try work.append(gpa, .{ .node = 0, .start = 0, .end = @intCast(edges.len) });
    while (work.pop()) |w| {
        const run = edges[w.start..w.end];
        var box = edgeBox(run[0]);
        for (run[1..]) |e| {
            const b = edgeBox(e);
            box = .{ .{ @min(box[0][0], b[0][0]), @min(box[0][1], b[0][1]) }, .{ @max(box[1][0], b[1][0]), @max(box[1][1], b[1][1]) } };
        }
        if (run.len <= leaf_size) {
            nodes.items[w.node] = .{ .lo = box[0], .hi = box[1], .first = w.start, .count = @intCast(run.len), .right = 0 };
            continue;
        }
        const axis: usize = if (box[1][0] - box[0][0] >= box[1][1] - box[0][1]) 0 else 1;
        const ctx: SortCtx = .{ .axis = axis };
        std.mem.sortUnstable([2]Vec2, run, ctx, SortCtx.less);
        const mid = w.start + @as(u32, @intCast(run.len / 2));
        const left: u32 = @intCast(nodes.items.len);
        try nodes.append(gpa, undefined);
        const right: u32 = @intCast(nodes.items.len);
        try nodes.append(gpa, undefined);
        nodes.items[w.node] = .{ .lo = box[0], .hi = box[1], .first = left, .count = 0, .right = right };
        try work.append(gpa, .{ .node = left, .start = w.start, .end = mid });
        try work.append(gpa, .{ .node = right, .start = mid, .end = w.end });
    }
    return nodes.toOwnedSlice(gpa);
}

fn bandCount(self: *const EdgeSet) usize {
    return self.band_start.len - 1;
}

fn bandOf(self: *const EdgeSet, y: f64) usize {
    const f = @floor((y - self.lo[1]) / self.band_h);
    const last: f64 = @floatFromInt(self.bandCount() - 1);
    return @intFromFloat(std.math.clamp(f, 0, last));
}

fn buildBands(self: *EdgeSet, gpa: Allocator) !void {
    const span = self.hi[1] - self.lo[1];
    const n_f = std.math.clamp(@sqrt(@as(f64, @floatFromInt(self.edges.len))) * 2, 1, 4096);
    const n: usize = @intFromFloat(n_f);
    self.band_h = if (span > 0) span / n_f else 1;
    self.band_start = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(self.band_start);
    @memset(self.band_start, 0);
    for (self.edges) |e| {
        const b = edgeBox(e);
        for (self.bandOf(b[0][1])..self.bandOf(b[1][1]) + 1) |r| self.band_start[r + 1] += 1;
    }
    for (1..n + 1) |r| self.band_start[r] += self.band_start[r - 1];
    self.band_items = try gpa.alloc(u32, self.band_start[n]);
    const fill = try gpa.dupe(u32, self.band_start[0..n]);
    defer gpa.free(fill);
    for (self.edges, 0..) |e, i| {
        const b = edgeBox(e);
        for (self.bandOf(b[0][1])..self.bandOf(b[1][1]) + 1) |r| {
            self.band_items[fill[r]] = @intCast(i);
            fill[r] += 1;
        }
    }
}

/// Edges that may cross the horizontal line at y.
pub fn band(self: *const EdgeSet, y: f64) []const u32 {
    if (self.edges.len == 0 or y < self.lo[1] or y > self.hi[1]) return &.{};
    const r = self.bandOf(y);
    return self.band_items[self.band_start[r]..self.band_start[r + 1]];
}

/// Winding number of the edges around p, counting edges as closed loops.
/// Points exactly on an edge get whichever side the half-open rule picks.
pub fn winding(self: *const EdgeSet, p: Vec2) i32 {
    var w: i32 = 0;
    for (self.band(p[1])) |i| w += crossingSign(self.edges[i], p);
    return w;
}

/// Contribution of one edge to the winding number at p, after Sunday's
/// crossing rule for a ray toward +x.
pub fn crossingSign(e: [2]Vec2, p: Vec2) i32 {
    const a = e[0];
    const b = e[1];
    if (a[1] <= p[1]) {
        if (b[1] > p[1] and geom.orient(a, b, p) > 0) return 1;
    } else if (b[1] <= p[1] and geom.orient(a, b, p) < 0) return -1;
    return 0;
}

fn boxDist2(p: Vec2, lo: Vec2, hi: Vec2) f64 {
    const dx = @max(lo[0] - p[0], 0, p[0] - hi[0]);
    const dy = @max(lo[1] - p[1], 0, p[1] - hi[1]);
    return dx * dx + dy * dy;
}

/// Distance from p to the nearest edge, or `limit` when nothing is closer.
pub fn distance(self: *const EdgeSet, p: Vec2, limit: f64) f64 {
    if (self.nodes.len == 0) return limit;
    var best = limit * limit;
    var stack: [stack_len]u32 = undefined;
    var top: usize = 1;
    stack[0] = 0;
    while (top > 0) {
        top -= 1;
        const n = self.nodes[stack[top]];
        if (boxDist2(p, n.lo, n.hi) >= best) continue;
        if (n.count > 0) {
            for (self.edges[n.first..][0..n.count]) |e| best = @min(best, geom.segmentDist2(p, e[0], e[1]));
            continue;
        }
        const l = self.nodes[n.first];
        const r = self.nodes[n.right];
        const dl = boxDist2(p, l.lo, l.hi);
        const dr = boxDist2(p, r.lo, r.hi);
        assert(top + 2 <= stack_len); // tree depth is logarithmic
        if (dl < dr) {
            stack[top] = n.right;
            stack[top + 1] = n.first;
        } else {
            stack[top] = n.first;
            stack[top + 1] = n.right;
        }
        top += 2;
    }
    return @sqrt(best);
}

/// Append the index of every edge whose box touches lo..hi.
pub fn query(self: *const EdgeSet, gpa: Allocator, lo: Vec2, hi: Vec2, out: *std.ArrayList(u32)) !void {
    if (self.nodes.len == 0) return;
    var stack: [stack_len]u32 = undefined;
    var top: usize = 1;
    stack[0] = 0;
    while (top > 0) {
        top -= 1;
        const n = self.nodes[stack[top]];
        if (n.hi[0] < lo[0] or n.lo[0] > hi[0] or n.hi[1] < lo[1] or n.lo[1] > hi[1]) continue;
        if (n.count > 0) {
            for (n.first..n.first + n.count) |i| {
                const b = edgeBox(self.edges[i]);
                if (b[1][0] < lo[0] or b[0][0] > hi[0] or b[1][1] < lo[1] or b[0][1] > hi[1]) continue;
                try out.append(gpa, @intCast(i));
            }
            continue;
        }
        assert(top + 2 <= stack_len);
        stack[top] = n.first;
        stack[top + 1] = n.right;
        top += 2;
    }
}

test "EdgeSet: winding and distance of a square with a hole" {
    const gpa = std.testing.allocator;
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const hole = [_]Vec2{ .{ 3, 3 }, .{ 3, 7 }, .{ 7, 7 }, .{ 7, 3 } };
    var set: EdgeSet = try .init(gpa, &.{ &outer, &hole }, true);
    defer set.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 1), set.winding(.{ 1, 5 }));
    try std.testing.expectEqual(@as(i32, 0), set.winding(.{ 5, 5 }));
    try std.testing.expectEqual(@as(i32, 0), set.winding(.{ 11, 5 }));
    try std.testing.expectEqual(@as(f64, 1), set.distance(.{ 1, 5 }, 100));
    try std.testing.expectEqual(@as(f64, 2), set.distance(.{ 5, 5 }, 100));
    try std.testing.expectEqual(@as(f64, 5), set.distance(.{ 15, 5 }, 100));
    try std.testing.expectEqual(@as(f64, 3), set.distance(.{ 15, 5 }, 3));
}

test "EdgeSet: distance agrees with brute force on many edges" {
    const gpa = std.testing.allocator;
    var pts: [200]Vec2 = undefined;
    for (&pts, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / 200 * std.math.tau;
        const r = 50 + 20 * math.sin(7 * t);
        p.* = .{ r * math.cos(t), r * math.sin(t) };
    }
    var set: EdgeSet = try .init(gpa, &.{&pts}, true);
    defer set.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    for (0..200) |_| {
        const q: Vec2 = .{ rnd.float(f64) * 200 - 100, rnd.float(f64) * 200 - 100 };
        var best: f64 = std.math.inf(f64);
        for (0..pts.len) |i| best = @min(best, geom.segmentDist2(q, pts[i], pts[(i + 1) % pts.len]));
        try std.testing.expectApproxEqAbs(@sqrt(best), set.distance(q, 1e9), 1e-9);
    }
}
