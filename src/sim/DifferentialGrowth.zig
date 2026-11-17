//! Differential growth of a polyline, after Anders Hoff's differential
//! line (inconvergent.net, 2016). Each step every node is pushed away
//! from non-neighbours within a radius, pulled toward its two neighbours
//! to a rest length, smoothed toward their midpoint and jittered. Edges
//! longer than max_edge are then split. Repulsion between nodes along
//! the curve stretches it, splitting adds nodes, and the line buckles.
//! Neighbour queries go through a grid rebuilt by counting sort each step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const common = @import("common.zig");
const Vec2 = common.Vec2;
const Rect = common.Rect;
const Mask = common.Mask;

const DifferentialGrowth = @This();

nodes: std.ArrayList(Vec2),
scratch: std.ArrayList(Vec2),
force: std.ArrayList(Vec2),
cell_start: std.ArrayList(u32),
sorted: std.ArrayList(u32),
cell_of: std.ArrayList(u32),
grid: Grid,
opts: Options,
prng: std.Random.DefaultPrng,

pub const Options = struct {
    closed: bool = true,
    max_edge: f64 = 4,
    /// Spring length between neighbours. Defaults to half of max_edge.
    rest_length: ?f64 = null,
    repel_radius: f64 = 10,
    repel: f64 = 0.6,
    attract: f64 = 0.4,
    alignment: f64 = 0.3,
    noise: f64 = 0.1,
    /// Chance per step that each edge splits even when short. Adds
    /// irregular bursts of growth.
    growth: f64 = 0,
    max_nodes: u32 = 20_000,
    bounds: ?Rect = null,
    mask: ?Mask = null,
};

pub fn init(gpa: Allocator, path: []const Vec2, opts: Options, seed: u64) !DifferentialGrowth {
    assert(opts.max_edge > 0);
    assert(opts.repel_radius > 0);
    var self: DifferentialGrowth = .{
        .nodes = .empty,
        .scratch = .empty,
        .force = .empty,
        .cell_start = .empty,
        .sorted = .empty,
        .cell_of = .empty,
        .grid = undefined,
        .opts = opts,
        .prng = .init(seed),
    };
    errdefer self.deinit(gpa);
    try self.nodes.appendSlice(gpa, path);
    try self.split(gpa);
    return self;
}

pub fn deinit(self: *DifferentialGrowth, gpa: Allocator) void {
    self.nodes.deinit(gpa);
    self.scratch.deinit(gpa);
    self.force.deinit(gpa);
    self.cell_start.deinit(gpa);
    self.sorted.deinit(gpa);
    self.cell_of.deinit(gpa);
    self.* = undefined;
}

pub fn points(self: *const DifferentialGrowth) []const Vec2 {
    return self.nodes.items;
}

pub fn step(self: *DifferentialGrowth, gpa: Allocator, n: u32) !void {
    for (0..n) |_| {
        if (self.nodes.items.len < 2) return;
        try self.buildGrid(gpa);
        try self.computeForces(gpa);
        self.move();
        try self.split(gpa);
    }
}

const Grid = struct {
    origin: Vec2,
    cell_size: f64,
    cols: u32,
    rows: u32,

    fn cellOf(g: Grid, p: Vec2) [2]u32 {
        const cx: u32 = @intFromFloat(@max(0, @floor((p[0] - g.origin[0]) / g.cell_size)));
        const cy: u32 = @intFromFloat(@max(0, @floor((p[1] - g.origin[1]) / g.cell_size)));
        return .{ @min(cx, g.cols - 1), @min(cy, g.rows - 1) };
    }
};

fn gridFor(self: *const DifferentialGrowth) Grid {
    var lo: Vec2 = self.nodes.items[0];
    var hi: Vec2 = lo;
    for (self.nodes.items) |p| {
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    const n: f64 = @floatFromInt(self.nodes.items.len);
    const area = (hi[0] - lo[0] + 1) * (hi[1] - lo[1] + 1);
    // Cells no smaller than the repel radius, and no more than about
    // four per node so a stray node can't blow up the grid.
    const cell_size = @max(self.opts.repel_radius, @sqrt(area / (4 * n + 64)));
    return .{
        .origin = lo,
        .cell_size = cell_size,
        .cols = @intFromFloat(@floor((hi[0] - lo[0]) / cell_size) + 1),
        .rows = @intFromFloat(@floor((hi[1] - lo[1]) / cell_size) + 1),
    };
}

fn buildGrid(self: *DifferentialGrowth, gpa: Allocator) !void {
    const g = self.gridFor();
    const cells = @as(usize, g.cols) * g.rows;
    const n = self.nodes.items.len;
    try self.cell_start.resize(gpa, cells + 1);
    try self.sorted.resize(gpa, n);
    try self.cell_of.resize(gpa, n);
    const start = self.cell_start.items;
    @memset(start, 0);
    for (self.nodes.items, self.cell_of.items) |p, *c| {
        const xy = g.cellOf(p);
        c.* = xy[1] * g.cols + xy[0];
        start[c.* + 1] += 1;
    }
    for (1..cells + 1) |i| start[i] += start[i - 1];
    for (self.cell_of.items, 0..) |c, i| {
        self.sorted.items[start[c]] = @intCast(i);
        start[c] += 1;
    }
    // The fill pass advanced each start to the next cell's start.
    var i = cells;
    while (i > 0) : (i -= 1) start[i] = start[i - 1];
    start[0] = 0;
    self.grid = g;
}

fn neighbours(self: *const DifferentialGrowth, i: usize) [2]?usize {
    const n = self.nodes.items.len;
    const prev: ?usize = if (i > 0) i - 1 else if (self.opts.closed) n - 1 else null;
    const next: ?usize = if (i + 1 < n) i + 1 else if (self.opts.closed) 0 else null;
    return .{ prev, next };
}

fn computeForces(self: *DifferentialGrowth, gpa: Allocator) !void {
    const o = &self.opts;
    const rng = self.prng.random();
    const nodes = self.nodes.items;
    try self.force.resize(gpa, nodes.len);
    const rest = o.rest_length orelse o.max_edge / 2;
    const g = self.grid;
    const radius2 = o.repel_radius * o.repel_radius;
    for (nodes, self.force.items, 0..) |p, *f, i| {
        f.* = .{ 0, 0 };
        const nb = self.neighbours(i);
        for (nb) |maybe| if (maybe) |j| {
            const q = nodes[j];
            const d = common.dist(p, q);
            if (d > 1e-9) {
                const k = o.attract * (d - rest) / d;
                f[0] += (q[0] - p[0]) * k;
                f[1] += (q[1] - p[1]) * k;
            }
        };
        if (nb[0] != null and nb[1] != null) {
            const a = nodes[nb[0].?];
            const b = nodes[nb[1].?];
            f[0] += ((a[0] + b[0]) / 2 - p[0]) * o.alignment;
            f[1] += ((a[1] + b[1]) / 2 - p[1]) * o.alignment;
        }

        const c = g.cellOf(p);
        const y0 = c[1] -| 1;
        const x0 = c[0] -| 1;
        const y1 = @min(c[1] + 1, g.rows - 1);
        const x1 = @min(c[0] + 1, g.cols - 1);
        for (y0..y1 + 1) |cy| {
            const row = cy * g.cols;
            const s = self.cell_start.items[row + x0];
            const e = self.cell_start.items[row + x1 + 1];
            for (self.sorted.items[s..e]) |j_u32| {
                const j: usize = j_u32;
                if (j == i or j == nb[0] or j == nb[1]) continue;
                const q = nodes[j];
                const dx = p[0] - q[0];
                const dy = p[1] - q[1];
                const d2 = dx * dx + dy * dy;
                if (d2 >= radius2 or d2 < 1e-18) continue;
                const d = @sqrt(d2);
                const k = o.repel * (o.repel_radius - d) / (o.repel_radius * d);
                f[0] += dx * k;
                f[1] += dy * k;
            }
        }
        if (o.noise > 0) {
            const u = common.randomUnit(rng);
            f[0] += u[0] * o.noise;
            f[1] += u[1] * o.noise;
        }
    }
}

fn allowed(self: *const DifferentialGrowth, p: Vec2) bool {
    if (self.opts.bounds) |b| if (!b.contains(p)) return false;
    if (self.opts.mask) |m| if (!m.allows(p)) return false;
    return true;
}

fn move(self: *DifferentialGrowth) void {
    const disp_max = self.opts.max_edge / 2;
    for (self.nodes.items, self.force.items) |*p, f| {
        const len = std.math.hypot(f[0], f[1]);
        const k = if (len > disp_max) disp_max / len else 1;
        const q: Vec2 = .{ p[0] + f[0] * k, p[1] + f[1] * k };
        if (self.allowed(q)) p.* = q;
    }
}

/// Split edges longer than max_edge into equal pieces that fit, plus
/// random splits when growth is set, until max_nodes is reached.
fn split(self: *DifferentialGrowth, gpa: Allocator) !void {
    const o = &self.opts;
    const rng = self.prng.random();
    const nodes = self.nodes.items;
    const n = nodes.len;
    if (n < 2) return;
    self.scratch.clearRetainingCapacity();
    const edges = if (o.closed) n else n - 1;
    var budget: usize = @as(usize, o.max_nodes) -| n;
    for (0..n) |i| {
        try self.scratch.append(gpa, nodes[i]);
        if (i >= edges) continue;
        const a = nodes[i];
        const b = nodes[(i + 1) % n];
        const len = common.dist(a, b);
        var pieces: usize = @intFromFloat(@max(1, @ceil(len / o.max_edge)));
        if (pieces == 1 and o.growth > 0 and len > 1e-6 and rng.float(f64) < o.growth) pieces = 2;
        pieces = @min(pieces, budget + 1);
        budget -= pieces - 1;
        for (1..pieces) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(pieces));
            try self.scratch.append(gpa, .{ std.math.lerp(a[0], b[0], t), std.math.lerp(a[1], b[1], t) });
        }
    }
    std.mem.swap(std.ArrayList(Vec2), &self.nodes, &self.scratch);
}

fn circle(gpa: Allocator, n: usize, r: f64) ![]Vec2 {
    const pts = try gpa.alloc(Vec2, n);
    for (pts, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * std.math.tau;
        p.* = .{ r * @cos(t), r * @sin(t) };
    }
    return pts;
}

fn longestEdge(pts: []const Vec2, closed: bool) f64 {
    var m: f64 = 0;
    for (0..pts.len - 1) |i| m = @max(m, common.dist(pts[i], pts[i + 1]));
    if (closed) m = @max(m, common.dist(pts[pts.len - 1], pts[0]));
    return m;
}

test "DifferentialGrowth: no edge is longer than max_edge after a step" {
    const gpa = std.testing.allocator;
    const start = try circle(gpa, 12, 10);
    defer gpa.free(start);
    var g: DifferentialGrowth = try .init(gpa, start, .{ .max_edge = 2, .repel_radius = 5, .noise = 0.3 }, 1);
    defer g.deinit(gpa);
    try std.testing.expect(longestEdge(g.points(), true) <= 2 + 1e-9);
    for (0..40) |_| {
        try g.step(gpa, 1);
        try std.testing.expect(longestEdge(g.points(), true) <= 2 + 1e-9);
    }
    try std.testing.expect(g.points().len > 32);
}

test "DifferentialGrowth: an open line keeps its edge count bound" {
    const gpa = std.testing.allocator;
    const start = [_]Vec2{ .{ 0, 0 }, .{ 50, 0 } };
    var g: DifferentialGrowth = try .init(gpa, &start, .{ .closed = false, .max_edge = 3, .max_nodes = 100 }, 2);
    defer g.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 18), g.points().len);
    try g.step(gpa, 200);
    try std.testing.expect(g.points().len <= 100);
}

test "DifferentialGrowth: bounds hold every node" {
    const gpa = std.testing.allocator;
    const start = try circle(gpa, 20, 5);
    defer gpa.free(start);
    const box: Rect = .{ .x = -8, .y = -8, .w = 16, .h = 16 };
    var g: DifferentialGrowth = try .init(gpa, start, .{ .max_edge = 2, .repel_radius = 4, .bounds = box }, 4);
    defer g.deinit(gpa);
    try g.step(gpa, 100);
    for (g.points()) |p| try std.testing.expect(box.contains(p));
}

test "DifferentialGrowth: same seed gives the same line" {
    const gpa = std.testing.allocator;
    const start = try circle(gpa, 10, 6);
    defer gpa.free(start);
    var one: DifferentialGrowth = try .init(gpa, start, .{ .growth = 0.05 }, 8);
    defer one.deinit(gpa);
    var two: DifferentialGrowth = try .init(gpa, start, .{ .growth = 0.05 }, 8);
    defer two.deinit(gpa);
    try one.step(gpa, 30);
    try two.step(gpa, 30);
    try std.testing.expectEqualSlices(Vec2, one.points(), two.points());
}
