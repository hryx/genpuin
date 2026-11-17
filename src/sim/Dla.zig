//! Off-lattice diffusion-limited aggregation (Witten and Sander 1981).
//! Walkers start on a circle just outside the cluster and move in steps
//! as long as the gap to the nearest particle allows, so they cross empty
//! space fast and slow to a fraction of a radius near the cluster. On
//! contact a walker snaps to exactly touch the particle it hit, which
//! becomes its parent. A grid of linked lists finds neighbors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const common = @import("common.zig");
const Vec2 = common.Vec2;
const Rect = common.Rect;

const Dla = @This();

radius: f64,
stickiness: f64,
bias: Vec2,
bounds: ?Rect,
walk_steps_max: u32,
points: std.ArrayList(Vec2),
/// Index of the particle each one stuck to. Seeds point at themselves.
parent: std.ArrayList(u32),
/// Seeds are generation 0, a particle is one more than its parent.
depth: std.ArrayList(u32),
seed_count: u32,
center: Vec2,
cluster_radius: f64,
grid: Grid,
prng: std.Random.DefaultPrng,

pub const Options = struct {
    radius: f64 = 2,
    /// Chance a walker sticks on each contact.
    stickiness: f64 = 1,
    /// Drift added to every step, as a fraction of the step length.
    bias: Vec2 = .{ 0, 0 },
    /// Walkers reflect off these walls instead of being killed far out.
    bounds: ?Rect = null,
    seeds: []const Vec2 = &.{},
    /// Seed particles packed along this segment, touching.
    seed_line: ?[2]Vec2 = null,
    /// Give up on a walker after this many steps.
    walk_steps_max: u32 = 1_000_000,
};

/// Square grid of linked lists with cells of 4 radii, covering
/// origin + [0, cells * cell_size) on both axes.
const Grid = struct {
    origin: Vec2,
    cell_size: f64,
    cells: u32,
    head: []u32,
    next: std.ArrayList(u32),

    const none = std.math.maxInt(u32);

    fn deinit(g: *Grid, gpa: Allocator) void {
        gpa.free(g.head);
        g.next.deinit(gpa);
    }

    fn cellOf(g: *const Grid, p: Vec2) ?[2]u32 {
        const cx = @floor((p[0] - g.origin[0]) / g.cell_size);
        const cy = @floor((p[1] - g.origin[1]) / g.cell_size);
        const n: f64 = @floatFromInt(g.cells);
        if (!(cx >= 0 and cy >= 0 and cx < n and cy < n)) return null;
        return .{ @intFromFloat(cx), @intFromFloat(cy) };
    }

    fn insert(g: *Grid, gpa: Allocator, index: u32, p: Vec2) !void {
        assert(g.next.items.len == index);
        const c = g.cellOf(p) orelse unreachable; // the grid grows before this
        const slot = @as(usize, c[1]) * g.cells + c[0];
        try g.next.append(gpa, g.head[slot]);
        g.head[slot] = index;
    }
};

pub const Error = error{NoSeeds} || Allocator.Error;

pub fn init(gpa: Allocator, opts: Options, seed: u64) Error!Dla {
    assert(opts.radius > 0);
    var self: Dla = .{
        .radius = opts.radius,
        .stickiness = std.math.clamp(opts.stickiness, 1e-3, 1),
        .bias = opts.bias,
        .bounds = opts.bounds,
        .walk_steps_max = opts.walk_steps_max,
        .points = .empty,
        .parent = .empty,
        .depth = .empty,
        .seed_count = 0,
        .center = .{ 0, 0 },
        .cluster_radius = 0,
        .grid = .{ .origin = .{ 0, 0 }, .cell_size = 4 * opts.radius, .cells = 0, .head = &.{}, .next = .empty },
        .prng = .init(seed),
    };
    errdefer self.deinit(gpa);

    try self.points.appendSlice(gpa, opts.seeds);
    if (opts.seed_line) |line| {
        const len = common.dist(line[0], line[1]);
        const packed_count: u32 = @intFromFloat(@floor(len / (2 * opts.radius)) + 1);
        for (0..packed_count) |i| {
            const t = if (packed_count == 1) 0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(packed_count - 1));
            try self.points.append(gpa, .{
                std.math.lerp(line[0][0], line[1][0], t),
                std.math.lerp(line[0][1], line[1][1], t),
            });
        }
    }
    if (self.points.items.len == 0) return error.NoSeeds;
    self.seed_count = @intCast(self.points.items.len);

    var sum: Vec2 = .{ 0, 0 };
    for (self.points.items, 0..) |p, i| {
        sum[0] += p[0];
        sum[1] += p[1];
        try self.parent.append(gpa, @intCast(i));
        try self.depth.append(gpa, 0);
    }
    const n: f64 = @floatFromInt(self.points.items.len);
    self.center = .{ sum[0] / n, sum[1] / n };
    for (self.points.items) |p| self.cluster_radius = @max(self.cluster_radius, common.dist(p, self.center));
    try self.rebuildGrid(gpa);
    return self;
}

pub fn deinit(self: *Dla, gpa: Allocator) void {
    self.points.deinit(gpa);
    self.parent.deinit(gpa);
    self.depth.deinit(gpa);
    self.grid.deinit(gpa);
    self.* = undefined;
}

/// Grid size that holds the cluster plus a walker's launch margin.
fn gridSpan(self: *const Dla) f64 {
    if (self.bounds) |b| return @max(b.w, b.h) + 2 * self.grid.cell_size;
    return 2 * (self.cluster_radius + 8 * self.radius) + 4 * self.grid.cell_size;
}

fn rebuildGrid(self: *Dla, gpa: Allocator) !void {
    const g = &self.grid;
    const span = self.gridSpan() * if (self.bounds == null) @as(f64, 2) else 1;
    const cells: u32 = @intFromFloat(@ceil(span / g.cell_size));
    gpa.free(g.head);
    g.head = &.{};
    g.head = try gpa.alloc(u32, @as(usize, cells) * cells);
    @memset(g.head, Grid.none);
    g.cells = cells;
    g.next.clearRetainingCapacity();
    if (self.bounds) |b| {
        g.origin = .{ b.x - g.cell_size, b.y - g.cell_size };
    } else {
        const half = @as(f64, @floatFromInt(cells)) * g.cell_size / 2;
        g.origin = .{ self.center[0] - half, self.center[1] - half };
    }
    for (self.points.items, 0..) |p, i| {
        // Seeds outside the bounds grid would be unreachable anyway.
        if (g.cellOf(p) == null) {
            try g.next.append(gpa, Grid.none);
            continue;
        }
        try g.insert(gpa, @intCast(i), p);
    }
}

fn gridCovers(self: *const Dla) bool {
    if (self.bounds != null) return true;
    const half = @as(f64, @floatFromInt(self.grid.cells)) * self.grid.cell_size / 2;
    return self.cluster_radius + 8 * self.radius + 2 * self.grid.cell_size < half;
}

const Nearest = struct { index: u32, dist: f64 };

fn nearest(self: *const Dla, p: Vec2) ?Nearest {
    const g = &self.grid;
    const c = g.cellOf(p) orelse return null;
    var best: ?Nearest = null;
    const y0 = c[1] -| 1;
    const x0 = c[0] -| 1;
    const y1 = @min(c[1] + 1, g.cells - 1);
    const x1 = @min(c[0] + 1, g.cells - 1);
    for (y0..y1 + 1) |cy| for (x0..x1 + 1) |cx| {
        var i = g.head[cy * g.cells + cx];
        while (i != Grid.none) : (i = g.next.items[i]) {
            const d = common.dist(p, self.points.items[i]);
            if (best == null or d < best.?.dist) best = .{ .index = i, .dist = d };
        }
    };
    return best;
}

pub fn count(self: *const Dla) u32 {
    return @intCast(self.points.items.len);
}

/// Add up to `n` particles. Returns how many stuck, which is fewer than
/// `n` only when a walker ran out of steps.
pub fn grow(self: *Dla, gpa: Allocator, n: u32) !u32 {
    try self.points.ensureUnusedCapacity(gpa, n);
    try self.parent.ensureUnusedCapacity(gpa, n);
    try self.depth.ensureUnusedCapacity(gpa, n);
    try self.grid.next.ensureUnusedCapacity(gpa, n);
    for (0..n) |done| {
        if (!try self.walk(gpa)) return @intCast(done);
    }
    return n;
}

fn launch(self: *Dla, rng: std.Random) Vec2 {
    const u = common.randomUnit(rng);
    const r = self.cluster_radius + 4 * self.radius;
    const p: Vec2 = .{ self.center[0] + u[0] * r, self.center[1] + u[1] * r };
    return if (self.bounds) |b| b.clamp(p) else p;
}

fn reflect(b: Rect, p: Vec2) Vec2 {
    var q = p;
    inline for (0..2) |axis| {
        const lo = if (axis == 0) b.x else b.y;
        const hi = lo + if (axis == 0) b.w else b.h;
        if (q[axis] < lo) q[axis] = @min(2 * lo - q[axis], hi);
        if (q[axis] > hi) q[axis] = @max(2 * hi - q[axis], lo);
    }
    return q;
}

fn walk(self: *Dla, gpa: Allocator) !bool {
    const rng = self.prng.random();
    const r = self.radius;
    const contact = 2 * r;
    const reach = self.grid.cell_size;
    const bias_len = std.math.hypot(self.bias[0], self.bias[1]);
    var p = self.launch(rng);
    for (0..self.walk_steps_max) |_| {
        const dc = common.dist(p, self.center);
        const near = self.nearest(p);
        if (near) |q| {
            if (q.dist < contact) {
                if (rng.float(f64) < self.stickiness) {
                    try self.stick(gpa, p, q.index);
                    return true;
                }
                p = self.touching(p, q.index);
            }
        }
        var gap = (if (near) |q| @min(q.dist, reach) else reach) - contact;
        gap = @max(gap, dc - self.cluster_radius - contact);
        const len = @max(gap, 0.5 * r) / (1 + bias_len);
        const u = common.randomUnit(rng);
        p = .{ p[0] + (u[0] + self.bias[0]) * len, p[1] + (u[1] + self.bias[1]) * len };
        if (self.bounds) |b| {
            p = reflect(b, p);
        } else if (dc > 2 * self.cluster_radius + 32 * r) {
            p = self.launch(rng);
        }
    }
    return false;
}

/// The point at contact distance from particle `index` in the direction of p.
fn touching(self: *Dla, p: Vec2, index: u32) Vec2 {
    const q = self.points.items[index];
    const d = common.dist(p, q);
    const u: Vec2 = if (d > 1e-9) .{ (p[0] - q[0]) / d, (p[1] - q[1]) / d } else common.randomUnit(self.prng.random());
    return .{ q[0] + u[0] * 2 * self.radius, q[1] + u[1] * 2 * self.radius };
}

fn stick(self: *Dla, gpa: Allocator, p: Vec2, parent: u32) !void {
    const at = self.touching(p, parent);
    const index: u32 = @intCast(self.points.items.len);
    self.points.appendAssumeCapacity(at);
    self.parent.appendAssumeCapacity(parent);
    self.depth.appendAssumeCapacity(self.depth.items[parent] + 1);
    self.cluster_radius = @max(self.cluster_radius, common.dist(at, self.center));
    if (!self.gridCovers()) {
        try self.rebuildGrid(gpa);
    } else if (self.grid.cellOf(at) == null) {
        try self.grid.next.append(gpa, Grid.none); // snapped just outside the bounds grid
    } else {
        try self.grid.insert(gpa, index, at);
    }
}

/// Number of particles in each particle's subtree, itself included.
/// Useful for tapering branches by how much hangs off them.
pub fn subtreeSizes(self: *const Dla, gpa: Allocator) ![]u32 {
    const sizes = try gpa.alloc(u32, self.points.items.len);
    @memset(sizes, 1);
    var i = self.points.items.len;
    while (i > self.seed_count) {
        i -= 1;
        sizes[self.parent.items[i]] += sizes[i];
    }
    return sizes;
}

test "Dla: grows the requested count and every link touches" {
    const gpa = std.testing.allocator;
    const r = 1.5;
    var d: Dla = try .init(gpa, .{ .radius = r, .seeds = &.{.{ 0, 0 }} }, 11);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 300), try d.grow(gpa, 300));
    try std.testing.expectEqual(@as(u32, 301), d.count());
    for (d.points.items[1..], d.parent.items[1..], 1..) |p, parent, i| {
        try std.testing.expect(parent < i);
        try std.testing.expectApproxEqAbs(2 * r, common.dist(p, d.points.items[parent]), 1e-9);
        try std.testing.expectEqual(d.depth.items[parent] + 1, d.depth.items[i]);
    }
}

test "Dla: same seed gives the same cluster" {
    const gpa = std.testing.allocator;
    var one: Dla = try .init(gpa, .{ .seeds = &.{.{ 5, 5 }} }, 3);
    defer one.deinit(gpa);
    var two: Dla = try .init(gpa, .{ .seeds = &.{.{ 5, 5 }} }, 3);
    defer two.deinit(gpa);
    _ = try one.grow(gpa, 120);
    _ = try two.grow(gpa, 120);
    try std.testing.expectEqualSlices(Vec2, one.points.items, two.points.items);
}

test "Dla: a seed line packs touching seeds and the cluster stays in bounds" {
    const gpa = std.testing.allocator;
    const bounds: Rect = .{ .x = 0, .y = 0, .w = 60, .h = 40 };
    var d: Dla = try .init(gpa, .{
        .radius = 1,
        .seed_line = .{ .{ 0, 40 }, .{ 60, 40 } },
        .bounds = bounds,
        .bias = .{ 0, 0.3 },
    }, 5);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 31), d.seed_count);
    try std.testing.expectEqual(@as(u32, 200), try d.grow(gpa, 200));
    for (d.points.items) |p| {
        try std.testing.expect(p[0] >= -2 and p[0] <= 62);
        try std.testing.expect(p[1] >= -2 and p[1] <= 42);
    }
}

test "Dla: subtree sizes sum back to the particle count" {
    const gpa = std.testing.allocator;
    var d: Dla = try .init(gpa, .{ .seeds = &.{.{ 0, 0 }} }, 1);
    defer d.deinit(gpa);
    _ = try d.grow(gpa, 50);
    const sizes = try d.subtreeSizes(gpa);
    defer gpa.free(sizes);
    try std.testing.expectEqual(@as(u32, 51), sizes[0]);
}

test "Dla: no seeds is an error" {
    try std.testing.expectError(error.NoSeeds, Dla.init(std.testing.allocator, .{}, 1));
}
