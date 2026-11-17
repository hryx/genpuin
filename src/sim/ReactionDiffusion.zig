//! Gray-Scott reaction-diffusion on two f32 grids, after Pearson 1993,
//! "Complex patterns in a simple system". The Laplacian is the 9-point
//! stencil from Karl Sims' tutorial (0.2 edges, 0.05 corners, -1 center).
//! A starts at 1 and B at 0. Seeding drops B into the grid.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const common = @import("common.zig");

const ReactionDiffusion = @This();

w: u32,
h: u32,
a: []f32,
b: []f32,
a_next: []f32,
b_next: []f32,
/// Per-cell rates when a map was given, empty otherwise.
feed_map: []f32,
kill_map: []f32,
feed: f32,
kill: f32,
da: f32,
db: f32,
dt: f32,
wrap: bool,

pub const Options = struct {
    w: u32,
    h: u32,
    feed: f32 = 0.055,
    kill: f32 = 0.062,
    da: f32 = 1.0,
    db: f32 = 0.5,
    dt: f32 = 1.0,
    wrap: bool = true,
    /// Absolute feed rate per cell, stretched over the grid.
    feed_map: ?*const Field = null,
    kill_map: ?*const Field = null,
};

pub const Preset = enum { coral, mitosis, worms, spots, maze, fingerprint, holes, waves, chaos };

pub const Rates = struct { feed: f32, kill: f32 };

/// Feed and kill rates for the default da = 1, db = 0.5, dt = 1.
pub fn presetRates(p: Preset) Rates {
    return switch (p) {
        .coral => .{ .feed = 0.0545, .kill = 0.062 },
        .mitosis => .{ .feed = 0.0367, .kill = 0.0649 },
        .worms => .{ .feed = 0.078, .kill = 0.061 },
        .spots => .{ .feed = 0.035, .kill = 0.065 },
        .maze => .{ .feed = 0.029, .kill = 0.057 },
        .fingerprint => .{ .feed = 0.037, .kill = 0.06 },
        .holes => .{ .feed = 0.039, .kill = 0.058 },
        .waves => .{ .feed = 0.014, .kill = 0.045 },
        .chaos => .{ .feed = 0.026, .kill = 0.051 },
    };
}

pub fn init(gpa: Allocator, opts: Options) !ReactionDiffusion {
    assert(opts.w >= 3 and opts.h >= 3);
    const n = @as(usize, opts.w) * opts.h;

    const a = try gpa.alloc(f32, n);
    errdefer gpa.free(a);
    const b = try gpa.alloc(f32, n);
    errdefer gpa.free(b);
    const a_next = try gpa.alloc(f32, n);
    errdefer gpa.free(a_next);
    const b_next = try gpa.alloc(f32, n);
    errdefer gpa.free(b_next);

    const mapped = opts.feed_map != null or opts.kill_map != null;
    const feed_map = try gpa.alloc(f32, if (mapped) n else 0);
    errdefer gpa.free(feed_map);
    const kill_map = try gpa.alloc(f32, if (mapped) n else 0);
    errdefer gpa.free(kill_map);

    if (mapped) {
        if (opts.feed_map) |m| common.resample(feed_map, opts.w, opts.h, m) else @memset(feed_map, opts.feed);
        if (opts.kill_map) |m| common.resample(kill_map, opts.w, opts.h, m) else @memset(kill_map, opts.kill);
    }
    @memset(a, 1);
    @memset(b, 0);
    return .{
        .w = opts.w,
        .h = opts.h,
        .a = a,
        .b = b,
        .a_next = a_next,
        .b_next = b_next,
        .feed_map = feed_map,
        .kill_map = kill_map,
        .feed = opts.feed,
        .kill = opts.kill,
        .da = opts.da,
        .db = opts.db,
        .dt = opts.dt,
        .wrap = opts.wrap,
    };
}

pub fn deinit(self: *ReactionDiffusion, gpa: Allocator) void {
    gpa.free(self.a);
    gpa.free(self.b);
    gpa.free(self.a_next);
    gpa.free(self.b_next);
    gpa.free(self.feed_map);
    gpa.free(self.kill_map);
    self.* = undefined;
}

/// Set B to 1 inside a disc, in cell units.
pub fn seedDisc(self: *ReactionDiffusion, cx: f64, cy: f64, r: f64) void {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(cx - r), 0, @as(f64, @floatFromInt(self.w - 1))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(cx + r), 0, @as(f64, @floatFromInt(self.w - 1))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(cy - r), 0, @as(f64, @floatFromInt(self.h - 1))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(cy + r), 0, @as(f64, @floatFromInt(self.h - 1))));
    for (y0..y1 + 1) |y| for (x0..x1 + 1) |x| {
        const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
        const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
        if (dx * dx + dy * dy <= r * r) self.b[y * self.w + x] = 1;
    };
}

/// Drop `count` discs of radius `r` at random cells.
pub fn seedRandom(self: *ReactionDiffusion, seed: u64, count: u32, r: f64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    for (0..count) |_| {
        const x = rng.float(f64) * @as(f64, @floatFromInt(self.w));
        const y = rng.float(f64) * @as(f64, @floatFromInt(self.h));
        self.seedDisc(x, y, r);
    }
}

/// Load B from a Field, stretched to the grid. A is left as is.
pub fn loadB(self: *ReactionDiffusion, source: *const Field) void {
    common.resample(self.b, self.w, self.h, source);
}

pub fn loadA(self: *ReactionDiffusion, source: *const Field) void {
    common.resample(self.a, self.w, self.h, source);
}

pub fn step(self: *ReactionDiffusion, n: u32) void {
    const mapped = self.feed_map.len > 0;
    for (0..n) |_| {
        if (mapped) self.stepOnce(true) else self.stepOnce(false);
        std.mem.swap([]f32, &self.a, &self.a_next);
        std.mem.swap([]f32, &self.b, &self.b_next);
    }
}

const lanes = 8;
const Vf = @Vector(lanes, f32);

const Rows = struct {
    au: []const f32,
    am: []const f32,
    ad: []const f32,
    bu: []const f32,
    bm: []const f32,
    bd: []const f32,
    a_out: []f32,
    b_out: []f32,
    feed: []const f32,
    kill: []const f32,
};

fn stepOnce(self: *ReactionDiffusion, comptime mapped: bool) void {
    const w: usize = self.w;
    const h: usize = self.h;
    for (0..h) |y| {
        const yu = if (y > 0) y - 1 else if (self.wrap) h - 1 else 0;
        const yd = if (y + 1 < h) y + 1 else if (self.wrap) 0 else h - 1;
        const r: Rows = .{
            .au = self.a[yu * w ..][0..w],
            .am = self.a[y * w ..][0..w],
            .ad = self.a[yd * w ..][0..w],
            .bu = self.b[yu * w ..][0..w],
            .bm = self.b[y * w ..][0..w],
            .bd = self.b[yd * w ..][0..w],
            .a_out = self.a_next[y * w ..][0..w],
            .b_out = self.b_next[y * w ..][0..w],
            .feed = if (mapped) self.feed_map[y * w ..][0..w] else &.{},
            .kill = if (mapped) self.kill_map[y * w ..][0..w] else &.{},
        };
        self.cell(f32, mapped, r, if (self.wrap) w - 1 else 0, 0, 1);
        var x: usize = 1;
        while (x + lanes + 1 <= w) : (x += lanes) self.cell(Vf, mapped, r, x - 1, x, x + 1);
        while (x + 1 < w) : (x += 1) self.cell(f32, mapped, r, x - 1, x, x + 1);
        self.cell(f32, mapped, r, w - 2, w - 1, if (self.wrap) 0 else w - 1);
    }
}

inline fn load(comptime T: type, row: []const f32, i: usize) T {
    return if (T == f32) row[i] else row[i..][0..lanes].*;
}

inline fn splat(comptime T: type, v: f32) T {
    return if (T == f32) v else @splat(v);
}

/// One cell, or `lanes` contiguous cells when T is a vector. Neighbours
/// at xl and xr are offsets of the same width as x.
inline fn cell(self: *const ReactionDiffusion, comptime T: type, comptime mapped: bool, r: Rows, xl: usize, x: usize, xr: usize) void {
    const edge = splat(T, 0.2);
    const corner = splat(T, 0.05);
    const a = load(T, r.am, x);
    const b = load(T, r.bm, x);
    const lap_a = (load(T, r.au, x) + load(T, r.ad, x) + load(T, r.am, xl) + load(T, r.am, xr)) * edge +
        (load(T, r.au, xl) + load(T, r.au, xr) + load(T, r.ad, xl) + load(T, r.ad, xr)) * corner - a;
    const lap_b = (load(T, r.bu, x) + load(T, r.bd, x) + load(T, r.bm, xl) + load(T, r.bm, xr)) * edge +
        (load(T, r.bu, xl) + load(T, r.bu, xr) + load(T, r.bd, xl) + load(T, r.bd, xr)) * corner - b;
    const f = if (mapped) load(T, r.feed, x) else splat(T, self.feed);
    const k = if (mapped) load(T, r.kill, x) else splat(T, self.kill);
    const abb = a * b * b;
    const dt = splat(T, self.dt);
    const zero = splat(T, 0);
    const one = splat(T, 1);
    // Explicit Euler overshoots on hard seeds at low feed rates and can run
    // off to infinity. Clamping to the physical range keeps it bounded.
    const a_new = std.math.clamp(a + (splat(T, self.da) * lap_a - abb + f * (one - a)) * dt, zero, one);
    const b_new = std.math.clamp(b + (splat(T, self.db) * lap_b + abb - (k + f) * b) * dt, zero, one);
    if (T == f32) {
        r.a_out[x] = a_new;
        r.b_out[x] = b_new;
    } else {
        r.a_out[x..][0..lanes].* = a_new;
        r.b_out[x..][0..lanes].* = b_new;
    }
}

test "ReactionDiffusion: a uniform field stays uniform" {
    const gpa = std.testing.allocator;
    var rd: ReactionDiffusion = try .init(gpa, .{ .w = 21, .h = 13 });
    defer rd.deinit(gpa);
    @memset(rd.a, 0.5);
    @memset(rd.b, 0.25);
    rd.step(50);
    const a0 = rd.a[0];
    const b0 = rd.b[0];
    for (rd.a) |v| try std.testing.expectEqual(a0, v);
    for (rd.b) |v| try std.testing.expectEqual(b0, v);
}

test "ReactionDiffusion: no B means A stays at 1" {
    const gpa = std.testing.allocator;
    var rd: ReactionDiffusion = try .init(gpa, .{ .w = 16, .h = 16, .wrap = false });
    defer rd.deinit(gpa);
    rd.step(20);
    for (rd.a) |v| try std.testing.expectEqual(@as(f32, 1), v);
    for (rd.b) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

test "ReactionDiffusion: vector and scalar paths agree under wrap" {
    // A 1-cell spot on a torus must spread symmetrically, so the cells at
    // equal offsets left and right of it match whichever path computed them.
    const gpa = std.testing.allocator;
    var rd: ReactionDiffusion = try .init(gpa, .{ .w = 40, .h = 9 });
    defer rd.deinit(gpa);
    rd.b[4 * 40 + 20] = 1;
    rd.step(6);
    for (1..12) |d| {
        try std.testing.expectApproxEqAbs(rd.b[4 * 40 + 20 - d], rd.b[4 * 40 + 20 + d], 1e-6);
    }
    try std.testing.expect(rd.b[4 * 40 + 20] > 0);
    try std.testing.expect(rd.b[4 * 40 + 21] > 0);
}

test "ReactionDiffusion: same seed gives the same pattern" {
    const gpa = std.testing.allocator;
    var one: ReactionDiffusion = try .init(gpa, .{ .w = 32, .h = 32 });
    defer one.deinit(gpa);
    var two: ReactionDiffusion = try .init(gpa, .{ .w = 32, .h = 32 });
    defer two.deinit(gpa);
    one.seedRandom(7, 3, 3);
    two.seedRandom(7, 3, 3);
    one.step(40);
    two.step(40);
    try std.testing.expectEqualSlices(f32, one.b, two.b);
}

test "ReactionDiffusion: a feed map equal to the constant changes nothing" {
    const gpa = std.testing.allocator;
    var map: Field = try .init(gpa, 4, 4, 0.055);
    defer map.deinit(gpa);
    var plain: ReactionDiffusion = try .init(gpa, .{ .w = 24, .h = 24 });
    defer plain.deinit(gpa);
    var mapped: ReactionDiffusion = try .init(gpa, .{ .w = 24, .h = 24, .feed_map = &map });
    defer mapped.deinit(gpa);
    plain.seedDisc(12, 12, 3);
    mapped.seedDisc(12, 12, 3);
    plain.step(30);
    mapped.step(30);
    try std.testing.expectEqualSlices(f32, plain.b, mapped.b);
}
