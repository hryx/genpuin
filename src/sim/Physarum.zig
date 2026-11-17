//! Physarum transport networks after Jeff Jones 2010, "Characteristics of
//! pattern formation and evolution in approximations of physarum transport
//! networks". Agents sense the trail map ahead and to each side, turn
//! toward the strongest reading, step forward and deposit. The trail then
//! diffuses through a 3x3 mean filter and decays.
//!
//! Headings are kept as unit vectors and turned by fixed rotations, so the
//! agent loop has no trig.

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const common = @import("common.zig");
const Vec2 = common.Vec2;

const Physarum = @This();

w: u32,
h: u32,
trail: []f32,
scratch: []f32,
/// Added to the trail every step. Empty when there is no food.
food: []f32,
x: []f32,
y: []f32,
dx: []f32,
dy: []f32,
sensor: Rotation,
turn: Rotation,
sensor_dist: f32,
speed: f32,
deposit: f32,
decay: f32,
diffuse: f32,
wrap: bool,
prng: std.Random.DefaultPrng,

pub const Spawn = union(enum) {
    random,
    /// Uniform in a centered disc, random headings.
    disc,
    /// On a centered circle, facing the center.
    ring,
    /// Round-robin over these cells, random headings.
    points: []const Vec2,
};

pub const Options = struct {
    w: u32,
    h: u32,
    agents: u32 = 100_000,
    sensor_angle: f32 = std.math.pi / 4.0,
    sensor_dist: f32 = 9,
    turn: f32 = std.math.pi / 4.0,
    speed: f32 = 1,
    deposit: f32 = 5,
    decay: f32 = 0.1,
    /// 0 keeps the trail sharp, 1 replaces it with its 3x3 mean each step.
    diffuse: f32 = 1,
    wrap: bool = true,
    spawn: Spawn = .random,
    food: ?*const Field = null,
    food_weight: f32 = 1,
};

const Rotation = struct {
    c: f32,
    s: f32,

    fn init(angle: f32) Rotation {
        return .{ .c = @floatCast(math.cos(angle)), .s = @floatCast(math.sin(angle)) };
    }
};

pub fn init(gpa: Allocator, opts: Options, seed: u64) !Physarum {
    assert(opts.w >= 3 and opts.h >= 3);
    assert(opts.sensor_dist < @as(f32, @floatFromInt(@min(opts.w, opts.h)))); // one wrap per read
    assert(opts.speed < @as(f32, @floatFromInt(@min(opts.w, opts.h))));
    const cells = @as(usize, opts.w) * opts.h;

    const trail = try gpa.alloc(f32, cells);
    errdefer gpa.free(trail);
    const scratch = try gpa.alloc(f32, cells);
    errdefer gpa.free(scratch);
    const food = try gpa.alloc(f32, if (opts.food != null) cells else 0);
    errdefer gpa.free(food);
    const x = try gpa.alloc(f32, opts.agents);
    errdefer gpa.free(x);
    const y = try gpa.alloc(f32, opts.agents);
    errdefer gpa.free(y);
    const dx = try gpa.alloc(f32, opts.agents);
    errdefer gpa.free(dx);
    const dy = try gpa.alloc(f32, opts.agents);
    errdefer gpa.free(dy);

    @memset(trail, 0);
    if (opts.food) |f| {
        common.resample(food, opts.w, opts.h, f);
        for (food) |*v| v.* *= opts.food_weight;
    }
    var self: Physarum = .{
        .w = opts.w,
        .h = opts.h,
        .trail = trail,
        .scratch = scratch,
        .food = food,
        .x = x,
        .y = y,
        .dx = dx,
        .dy = dy,
        .sensor = .init(opts.sensor_angle),
        .turn = .init(opts.turn),
        .sensor_dist = opts.sensor_dist,
        .speed = opts.speed,
        .deposit = opts.deposit,
        .decay = opts.decay,
        .diffuse = opts.diffuse,
        .wrap = opts.wrap,
        .prng = .init(seed),
    };
    self.spawn(opts.spawn);
    return self;
}

pub fn deinit(self: *Physarum, gpa: Allocator) void {
    gpa.free(self.trail);
    gpa.free(self.scratch);
    gpa.free(self.food);
    gpa.free(self.x);
    gpa.free(self.y);
    gpa.free(self.dx);
    gpa.free(self.dy);
    self.* = undefined;
}

fn spawn(self: *Physarum, how: Spawn) void {
    const rng = self.prng.random();
    const fw: f64 = @floatFromInt(self.w);
    const fh: f64 = @floatFromInt(self.h);
    const r_max = 0.35 * @min(fw, fh);
    for (self.x, 0..) |_, i| {
        const angle = rng.float(f64) * std.math.tau;
        var p: Vec2 = undefined;
        var heading = angle;
        switch (how) {
            .random => p = .{ rng.float(f64) * fw, rng.float(f64) * fh },
            .disc => {
                const r = r_max * @sqrt(rng.float(f64));
                const t = rng.float(f64) * std.math.tau;
                p = .{ fw / 2 + r * math.cos(t), fh / 2 + r * math.sin(t) };
            },
            .ring => {
                p = .{ fw / 2 + r_max * math.cos(angle), fh / 2 + r_max * math.sin(angle) };
                heading = angle + std.math.pi;
            },
            .points => |pts| {
                assert(pts.len > 0);
                p = pts[i % pts.len];
                heading = rng.float(f64) * std.math.tau;
            },
        }
        self.place(i, p, heading);
    }
}

fn place(self: *Physarum, i: usize, p: Vec2, heading: f64) void {
    const fw: f64 = @floatFromInt(self.w);
    const fh: f64 = @floatFromInt(self.h);
    self.x[i] = @floatCast(std.math.clamp(p[0], 0, std.math.nextAfter(f64, fw, 0)));
    self.y[i] = @floatCast(std.math.clamp(p[1], 0, std.math.nextAfter(f64, fh, 0)));
    self.dx[i] = @floatCast(math.cos(heading));
    self.dy[i] = @floatCast(math.sin(heading));
}

/// Agent state as rows of {x, y, heading}, for handing between runs.
pub fn agentsToField(self: *const Physarum, gpa: Allocator) !Field {
    var f: Field = try .init(gpa, 3, @intCast(self.x.len), 0);
    for (self.x, self.y, self.dx, self.dy, 0..) |x, y, dx, dy, i| {
        f.data[i * 3 + 0] = x;
        f.data[i * 3 + 1] = y;
        f.data[i * 3 + 2] = @floatCast(math.atan2(dy, dx));
    }
    return f;
}

/// Overwrite agents from rows of {x, y, heading}. The field must hold one
/// row per agent.
pub fn loadAgents(self: *Physarum, f: *const Field) void {
    assert(f.w == 3);
    assert(f.h == self.x.len);
    for (0..self.x.len) |i| {
        self.place(i, .{ f.data[i * 3], f.data[i * 3 + 1] }, f.data[i * 3 + 2]);
    }
}

pub fn loadTrail(self: *Physarum, f: *const Field) void {
    common.resample(self.trail, self.w, self.h, f);
}

pub fn step(self: *Physarum, n: u32) void {
    for (0..n) |_| {
        self.moveAgents();
        self.diffuseTrail();
    }
}

fn moveAgents(self: *Physarum) void {
    if (self.wrap) self.moveAll(true) else self.moveAll(false);
}

const lanes = 8;

fn moveAll(self: *Physarum, comptime wrap: bool) void {
    const rng = self.prng.random();
    const n = self.x.len;
    var bits: u64 = 0;
    var i: usize = 0;
    var batch: u32 = 0;
    while (i + lanes <= n) : ({
        i += lanes;
        batch += 1;
    }) {
        if (batch % (64 / lanes) == 0) bits = rng.int(u64);
        self.moveBatch(lanes, wrap, i, @truncate(bits));
        bits >>= lanes;
    }
    while (i < n) : (i += 1) self.moveBatch(1, wrap, i, rng.int(u1));
}

/// Sense, turn, move and deposit for `n` agents from `first`, as vectors.
/// There are no data-dependent branches since the turn decision is close
/// to random per agent. `coins` holds one random bit per agent.
inline fn moveBatch(self: *Physarum, comptime n: comptime_int, comptime wrap: bool, first: usize, coins: @Int(.unsigned, n)) void {
    const V = @Vector(n, f32);
    const I = @Vector(n, i32);
    const B = @Vector(n, bool);
    const fw: V = @splat(@floatFromInt(self.w));
    const fh: V = @splat(@floatFromInt(self.h));
    const zero: V = @splat(0);
    const one: V = @splat(1);

    const x: V = self.x[first..][0..n].*;
    const y: V = self.y[first..][0..n].*;
    const dx: V = self.dx[first..][0..n].*;
    const dy: V = self.dy[first..][0..n].*;

    const sc: V = @splat(self.sensor.c);
    const ss: V = @splat(self.sensor.s);
    const front = self.sense(n, wrap, x, y, dx, dy);
    const left = self.sense(n, wrap, x, y, dx * sc - dy * ss, dx * ss + dy * sc);
    const right = self.sense(n, wrap, x, y, dx * sc + dy * ss, -dx * ss + dy * sc);

    const coin_bits: @Vector(n, u1) = @bitCast(coins);
    const coin: V = @floatFromInt(coin_bits);
    const keep = and_(n, front > left, front > right);
    const lost = and_(n, front < left, front < right);
    var sign: V = @select(f32, left > right, one, @select(f32, right > left, -one, zero));
    sign = @select(f32, lost, coin * @as(V, @splat(2)) - one, sign);
    sign = @select(f32, keep, zero, sign);
    const c = @select(f32, sign == zero, one, @as(V, @splat(self.turn.c)));
    const s = sign * @as(V, @splat(self.turn.s));
    var ndx = dx * c - dy * s;
    var ndy = dx * s + dy * c;
    // Repeated rotations drift off unit length in f32.
    const inv = one / @sqrt(ndx * ndx + ndy * ndy);
    ndx *= inv;
    ndy *= inv;

    const speed: V = @splat(self.speed);
    var nx = x + ndx * speed;
    var ny = y + ndy * speed;
    var moved: B = @splat(true);
    if (wrap) {
        nx += @select(f32, nx < zero, fw, zero);
        nx -= @select(f32, nx >= fw, fw, zero);
        ny += @select(f32, ny < zero, fh, zero);
        ny -= @select(f32, ny >= fh, fh, zero);
        nx = @min(@max(nx, zero), @as(V, @splat(std.math.nextAfter(f32, @floatFromInt(self.w), 0))));
        ny = @min(@max(ny, zero), @as(V, @splat(std.math.nextAfter(f32, @floatFromInt(self.h), 0))));
    } else {
        moved = and_(n, and_(n, nx >= zero, ny >= zero), and_(n, nx < fw, ny < fh));
        // Agents that would leave turn around instead.
        nx = @select(f32, moved, nx, x);
        ny = @select(f32, moved, ny, y);
        ndx = @select(f32, moved, ndx, -ndx);
        ndy = @select(f32, moved, ndy, -ndy);
    }
    self.x[first..][0..n].* = nx;
    self.y[first..][0..n].* = ny;
    self.dx[first..][0..n].* = ndx;
    self.dy[first..][0..n].* = ndy;

    const cell: I = @as(I, @intFromFloat(ny)) * @as(I, @splat(@intCast(self.w))) + @as(I, @intFromFloat(nx));
    inline for (0..n) |k| {
        if (moved[k]) self.trail[@intCast(cell[k])] += self.deposit;
    }
}

inline fn and_(comptime n: comptime_int, a: @Vector(n, bool), b: @Vector(n, bool)) @Vector(n, bool) {
    return @select(bool, a, b, @as(@Vector(n, bool), @splat(false)));
}

inline fn sense(self: *const Physarum, comptime n: comptime_int, comptime wrap: bool, x: @Vector(n, f32), y: @Vector(n, f32), dx: @Vector(n, f32), dy: @Vector(n, f32)) @Vector(n, f32) {
    const I = @Vector(n, i32);
    const w: I = @splat(@intCast(self.w));
    const h: I = @splat(@intCast(self.h));
    const zero: I = @splat(0);
    const dist: @Vector(n, f32) = @splat(self.sensor_dist);
    var ix: I = @intFromFloat(@floor(x + dx * dist));
    var iy: I = @intFromFloat(@floor(y + dy * dist));
    if (wrap) {
        ix += @select(i32, ix < zero, w, zero);
        ix -= @select(i32, ix >= w, w, zero);
        iy += @select(i32, iy < zero, h, zero);
        iy -= @select(i32, iy >= h, h, zero);
    } else {
        ix = @min(@max(ix, zero), w - @as(I, @splat(1)));
        iy = @min(@max(iy, zero), h - @as(I, @splat(1)));
    }
    const index = iy * w + ix;
    var out: @Vector(n, f32) = undefined;
    inline for (0..n) |k| out[k] = self.trail[@intCast(index[k])];
    return out;
}

/// Separable 3x3 mean, mixed with the unblurred trail by `diffuse`, then
/// decayed. Food lands after decay so a constant food cell settles at
/// food / decay.
fn diffuseTrail(self: *Physarum) void {
    const w: usize = self.w;
    const h: usize = self.h;
    const third: f32 = 1.0 / 3.0;
    for (0..h) |y| {
        const src = self.trail[y * w ..][0..w];
        const dst = self.scratch[y * w ..][0..w];
        const first = if (self.wrap) src[w - 1] else src[0];
        const last = if (self.wrap) src[0] else src[w - 1];
        dst[0] = (first + src[0] + src[1]) * third;
        for (1..w - 1) |x| dst[x] = (src[x - 1] + src[x] + src[x + 1]) * third;
        dst[w - 1] = (src[w - 2] + src[w - 1] + last) * third;
    }
    const keep = 1 - self.decay;
    const mix = self.diffuse;
    for (0..h) |y| {
        const yu = if (y > 0) y - 1 else if (self.wrap) h - 1 else 0;
        const yd = if (y + 1 < h) y + 1 else if (self.wrap) 0 else h - 1;
        const up = self.scratch[yu * w ..][0..w];
        const mid = self.scratch[y * w ..][0..w];
        const dn = self.scratch[yd * w ..][0..w];
        const row = self.trail[y * w ..][0..w];
        for (row, up, mid, dn) |*v, u, m, d| {
            const blur = (u + m + d) * third;
            v.* = (v.* + (blur - v.*) * mix) * keep;
        }
        if (self.food.len > 0) {
            for (row, self.food[y * w ..][0..w]) |*v, f| v.* += f;
        }
    }
}

test "Physarum: deposits add up with no decay or diffusion" {
    const gpa = std.testing.allocator;
    const agents = 50;
    const steps = 7;
    var p: Physarum = try .init(gpa, .{ .w = 32, .h = 24, .agents = agents, .deposit = 2, .decay = 0, .diffuse = 0 }, 1);
    defer p.deinit(gpa);
    p.step(steps);
    var sum: f64 = 0;
    for (p.trail) |v| sum += v;
    try std.testing.expectEqual(@as(f64, 2 * agents * steps), sum);
}

test "Physarum: diffusion alone conserves the trail on a torus" {
    const gpa = std.testing.allocator;
    var p: Physarum = try .init(gpa, .{ .w = 16, .h = 16, .agents = 10, .decay = 0, .deposit = 1 }, 3);
    defer p.deinit(gpa);
    p.step(20);
    var sum: f64 = 0;
    for (p.trail) |v| sum += v;
    try std.testing.expectApproxEqRel(@as(f64, 10 * 20), sum, 1e-4);
}

test "Physarum: agents stay inside the grid" {
    const gpa = std.testing.allocator;
    inline for (.{ true, false }) |wrap| {
        var p: Physarum = try .init(gpa, .{ .w = 20, .h = 10, .agents = 200, .speed = 1.7, .wrap = wrap, .spawn = .ring }, 5);
        defer p.deinit(gpa);
        p.step(60);
        for (p.x, p.y) |x, y| {
            try std.testing.expect(x >= 0 and x < 20);
            try std.testing.expect(y >= 0 and y < 10);
        }
    }
}

test "Physarum: same seed gives the same trail" {
    const gpa = std.testing.allocator;
    var one: Physarum = try .init(gpa, .{ .w = 24, .h = 24, .agents = 300 }, 9);
    defer one.deinit(gpa);
    var two: Physarum = try .init(gpa, .{ .w = 24, .h = 24, .agents = 300 }, 9);
    defer two.deinit(gpa);
    one.step(15);
    two.step(15);
    try std.testing.expectEqualSlices(f32, one.trail, two.trail);
}

test "Physarum: agents round-trip through a Field" {
    const gpa = std.testing.allocator;
    var p: Physarum = try .init(gpa, .{ .w = 24, .h = 24, .agents = 4, .spawn = .{ .points = &.{.{ 3, 4 }} } }, 2);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 3), p.x[2]);
    var f = try p.agentsToField(gpa);
    defer f.deinit(gpa);
    const dx = p.dx[1];
    p.loadAgents(&f);
    try std.testing.expectApproxEqAbs(dx, p.dx[1], 1e-6);
    try std.testing.expectEqual(@as(f32, 4), p.y[3]);
}
