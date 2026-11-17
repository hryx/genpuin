//! Fractal flames after Scott Draves and Erik Reckase, "The Fractal Flame
//! Algorithm" (2003, rev. 2008). A chaos game picks a transform by
//! weight, applies its affine map, then a weighted sum of variation
//! functions. Every point lands in a density histogram and a color
//! histogram, and the color coordinate moves halfway toward the
//! transform's color on each step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const density = @import("../density.zig");

/// Variation numbers in the paper's appendix: linear 0, sinusoidal 1,
/// ... cross 48.
pub const Variation = enum {
    linear,
    sinusoidal,
    spherical,
    swirl,
    horseshoe,
    polar,
    handkerchief,
    heart,
    disc,
    spiral,
    hyperbolic,
    diamond,
    ex,
    julia,
    bent,
    waves,
    fisheye,
    popcorn,
    exponential,
    power,
    cosine,
    rings,
    fan,
    eyefish,
    bubble,
    cylinder,
    noise,
    blur,
    gaussian,
    tangent,
    square,
    cross,
};

pub const Term = struct {
    variation: Variation,
    weight: f64,
};

/// Affine coefficients follow the paper: (a x + b y + c, d x + e y + f).
pub const Affine = [6]f64;
pub const identity: Affine = .{ 1, 0, 0, 0, 1, 0 };

pub const Transform = struct {
    weight: f64 = 1,
    affine: Affine = identity,
    /// Applied after the variations.
    post: ?Affine = null,
    terms: []const Term = &.{.{ .variation = .linear, .weight = 1 }},
    color: f64 = 0,
    /// How far the color coordinate moves toward `color` per step.
    color_speed: f64 = 0.5,
};

pub const Options = struct {
    transforms: []const Transform,
    /// Applied to each point before plotting, never fed back.
    final: ?Transform = null,
    /// n > 1 adds n-fold rotational symmetry. n < -1 also mirrors.
    symmetry: i32 = 1,
    iterations: u64 = 1_000_000,
    w: u32,
    h: u32,
    seed: u64 = 1,
    supersample: u32 = 1,
    splat: density.Splat = .bilinear,
    /// Flame-space rect. Null fits it from a pilot run.
    bounds: ?density.Rect = null,
};

pub const Result = struct {
    density: Field,
    /// Average color coordinate per cell, 0 where nothing landed.
    color: Field,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        self.density.deinit(gpa);
        self.color.deinit(gpa);
    }
};

const Point = struct { x: f64, y: f64, c: f64 };

/// Polar quantities shared by the variations. The paper's theta is
/// atan2(x, y), so sin(theta) = x / r and cos(theta) = y / r.
const Pre = struct {
    x: f64,
    y: f64,
    r2: f64,
    r: f64,
    theta: f64,
    sin_t: f64,
    cos_t: f64,

    fn init(x: f64, y: f64) Pre {
        const r2 = x * x + y * y + 1e-20;
        const r = @sqrt(r2);
        return .{ .x = x, .y = y, .r2 = r2, .r = r, .theta = std.math.atan2(x, y), .sin_t = x / r, .cos_t = y / r };
    }
};

fn variation(v: Variation, p: *const Pre, aff: *const Affine, rng: std.Random) [2]f64 {
    const x = p.x;
    const y = p.y;
    const r = p.r;
    const pi = std.math.pi;
    switch (v) {
        .linear => return .{ x, y },
        .sinusoidal => return .{ @sin(x), @sin(y) },
        .spherical => return .{ x / p.r2, y / p.r2 },
        .swirl => {
            const s = @sin(p.r2);
            const c = @cos(p.r2);
            return .{ x * s - y * c, x * c + y * s };
        },
        .horseshoe => return .{ (x - y) * (x + y) / r, 2 * x * y / r },
        .polar => return .{ p.theta / pi, r - 1 },
        .handkerchief => return .{ r * @sin(p.theta + r), r * @cos(p.theta - r) },
        .heart => return .{ r * @sin(p.theta * r), -r * @cos(p.theta * r) },
        .disc => {
            const t = p.theta / pi;
            return .{ t * @sin(pi * r), t * @cos(pi * r) };
        },
        .spiral => return .{ (p.cos_t + @sin(r)) / r, (p.sin_t - @cos(r)) / r },
        .hyperbolic => return .{ p.sin_t / r, r * p.cos_t },
        .diamond => return .{ p.sin_t * @cos(r), p.cos_t * @sin(r) },
        .ex => {
            const p0 = @sin(p.theta + r);
            const p1 = @cos(p.theta - r);
            const a = p0 * p0 * p0;
            const b = p1 * p1 * p1;
            return .{ r * (a + b), r * (a - b) };
        },
        .julia => {
            const omega: f64 = if (rng.boolean()) pi else 0;
            const sr = @sqrt(r);
            return .{ sr * @cos(p.theta / 2 + omega), sr * @sin(p.theta / 2 + omega) };
        },
        .bent => return .{ if (x < 0) 2 * x else x, if (y < 0) y / 2 else y },
        .waves => {
            const c2 = aff[2] * aff[2] + 1e-6;
            const f2 = aff[5] * aff[5] + 1e-6;
            return .{ x + aff[1] * @sin(y / c2), y + aff[4] * @sin(x / f2) };
        },
        .fisheye => {
            const k = 2 / (r + 1);
            return .{ k * y, k * x };
        },
        .popcorn => return .{ x + aff[2] * @sin(@tan(3 * y)), y + aff[5] * @sin(@tan(3 * x)) },
        .exponential => {
            const k = @exp(x - 1);
            return .{ k * @cos(pi * y), k * @sin(pi * y) };
        },
        .power => {
            const k = std.math.pow(f64, r, p.sin_t);
            return .{ k * p.cos_t, k * p.sin_t };
        },
        .cosine => return .{ @cos(pi * x) * std.math.cosh(y), -@sin(pi * x) * std.math.sinh(y) },
        .rings => {
            const c2 = aff[2] * aff[2] + 1e-6;
            const k = @mod(r + c2, 2 * c2) - c2 + r * (1 - c2);
            return .{ k * p.cos_t, k * p.sin_t };
        },
        .fan => {
            const t = pi * aff[2] * aff[2] + 1e-6;
            const a = if (@mod(p.theta + aff[5], t) > t / 2) p.theta - t / 2 else p.theta + t / 2;
            return .{ r * @cos(a), r * @sin(a) };
        },
        .eyefish => {
            const k = 2 / (r + 1);
            return .{ k * x, k * y };
        },
        .bubble => {
            const k = 4 / (p.r2 + 4);
            return .{ k * x, k * y };
        },
        .cylinder => return .{ @sin(x), y },
        .noise => {
            const a = rng.float(f64);
            const t = 2 * pi * rng.float(f64);
            return .{ a * x * @cos(t), a * y * @sin(t) };
        },
        .blur => {
            const a = rng.float(f64);
            const t = 2 * pi * rng.float(f64);
            return .{ a * @cos(t), a * @sin(t) };
        },
        .gaussian => {
            var s: f64 = -2;
            for (0..4) |_| s += rng.float(f64);
            const t = 2 * pi * rng.float(f64);
            return .{ s * @cos(t), s * @sin(t) };
        },
        .tangent => return .{ @sin(x) / @cos(y), @tan(y) },
        .square => return .{ rng.float(f64) - 0.5, rng.float(f64) - 0.5 },
        .cross => {
            const d = x * x - y * y;
            const k = @sqrt(1 / (d * d + 1e-20));
            return .{ k * x, k * y };
        },
    }
}

fn applyAffine(a: *const Affine, x: f64, y: f64) [2]f64 {
    return .{ a[0] * x + a[1] * y + a[2], a[3] * x + a[4] * y + a[5] };
}

fn apply(t: *const Transform, p: Point, rng: std.Random) Point {
    const q = applyAffine(&t.affine, p.x, p.y);
    const pre: Pre = .init(q[0], q[1]);
    var x: f64 = 0;
    var y: f64 = 0;
    for (t.terms) |term| {
        const v = variation(term.variation, &pre, &t.affine, rng);
        x += term.weight * v[0];
        y += term.weight * v[1];
    }
    if (t.post) |post| {
        const s = applyAffine(&post, x, y);
        x = s[0];
        y = s[1];
    }
    return .{ .x = x, .y = y, .c = p.c + (t.color - p.c) * t.color_speed };
}

const table_len = 1024;

/// The chaos game state: transforms with symmetry added, and a lookup
/// table that picks one in proportion to its weight from 10 random bits.
const Game = struct {
    transforms: []const Transform,
    final: ?Transform,
    table: [table_len]u16,
    prng: std.Random.DefaultPrng,
    p: Point,

    fn init(arena: Allocator, o: *const Options) !Game {
        assert(o.transforms.len > 0);
        const list = try withSymmetry(arena, o.transforms, o.symmetry);
        assert(list.len <= std.math.maxInt(u16));
        var g: Game = .{
            .transforms = list,
            .final = o.final,
            .table = undefined,
            .prng = .init(o.seed),
            .p = undefined,
        };
        var total: f64 = 0;
        for (list) |t| total += @max(t.weight, 0);
        if (!(total > 0)) return error.NoWeight;
        var acc: f64 = 0;
        var k: usize = 0;
        for (list, 0..) |t, i| {
            acc += @max(t.weight, 0);
            const end: usize = @intFromFloat(@round(acc / total * table_len));
            while (k < end) : (k += 1) g.table[k] = @intCast(i);
        }
        while (k < table_len) : (k += 1) g.table[k] = @intCast(list.len - 1);
        g.restart();
        return g;
    }

    fn restart(self: *Game) void {
        const r = self.prng.random();
        self.p = .{ .x = r.float(f64) * 2 - 1, .y = r.float(f64) * 2 - 1, .c = r.float(f64) };
        for (0..20) |_| _ = self.next();
    }

    /// Advance one step and return the point to plot.
    fn next(self: *Game) Point {
        const r = self.prng.random();
        const t = &self.transforms[self.table[r.int(u32) & (table_len - 1)]];
        var p = apply(t, self.p, r);
        if (!(@abs(p.x) + @abs(p.y) < 1e10)) {
            const rr = self.prng.random();
            p = .{ .x = rr.float(f64) * 2 - 1, .y = rr.float(f64) * 2 - 1, .c = self.p.c };
        }
        self.p = p;
        if (self.final) |*f| return apply(f, p, r);
        return p;
    }
};

fn withSymmetry(arena: Allocator, transforms: []const Transform, symmetry: i32) ![]const Transform {
    const n: u32 = @abs(symmetry);
    if (n <= 1 and symmetry >= -1) return transforms;
    const mirror = symmetry < 0;
    var list: std.ArrayList(Transform) = .empty;
    try list.appendSlice(arena, transforms);
    var mean: f64 = 0;
    for (transforms) |t| mean += t.weight;
    mean /= @floatFromInt(transforms.len);
    if (mirror) try list.append(arena, .{ .weight = mean, .affine = .{ -1, 0, 0, 0, 1, 0 }, .color_speed = 0 });
    for (1..@max(n, 1)) |k| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        const c = @cos(a);
        const s = @sin(a);
        try list.append(arena, .{ .weight = mean, .affine = .{ c, -s, 0, s, c, 0 }, .color_speed = 0 });
    }
    return list.items;
}

const pilot_len = 40_000;

pub const Error = error{NoWeight} || Allocator.Error;

/// Run the chaos game and return the density and average color Fields.
pub fn render(gpa: Allocator, o: Options) Error!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var game: Game = try .init(arena, &o);

    const bounds = o.bounds orelse blk: {
        const xs = try arena.alloc(f64, pilot_len);
        const ys = try arena.alloc(f64, pilot_len);
        for (xs, ys) |*x, *y| {
            const p = game.next();
            x.* = p.x;
            y.* = p.y;
        }
        const aspect = @as(f64, @floatFromInt(o.w)) / @as(f64, @floatFromInt(o.h));
        break :blk density.fitBounds(xs, ys, 0.004, 0.05, aspect);
    };

    var hist: density.Histogram = try .init(gpa, o.w, o.h, o.supersample, bounds, o.splat);
    errdefer hist.deinit(gpa);
    var color: density.Histogram = try .init(gpa, o.w, o.h, o.supersample, bounds, o.splat);
    errdefer color.deinit(gpa);
    for (0..o.iterations) |_| {
        const p = game.next();
        hist.plot(p.x, p.y, 1);
        color.plot(p.x, p.y, @floatCast(p.c));
    }
    var d = try hist.finish(gpa);
    errdefer d.deinit(gpa);
    const c = try color.finish(gpa);
    for (c.data, d.data) |*cv, dv| cv.* = if (dv > 0) cv.* / dv else 0;
    return .{ .density = d, .color = c };
}

/// Variations that make a decent picture when mixed at random. The
/// ones left out mostly fling points far away or need tuned affines.
const random_pool = [_]Variation{
    .linear,       .sinusoidal, .spherical, .swirl,  .horseshoe,  .polar,
    .handkerchief, .heart,      .disc,      .spiral, .hyperbolic, .diamond,
    .julia,        .bent,       .fisheye,   .bubble, .eyefish,    .ex,
    .cylinder,     .power,
};

pub const Random = struct {
    transforms: []Transform,
    symmetry: i32,
};

/// A random flame with `count` transforms, allocated in `arena`. A few
/// candidates are drawn and each gets a quick low resolution render. The
/// first bright enough under log tone wins, which weeds out the flames
/// that collapse to a few specks of dust.
pub fn random(arena: Allocator, seed: u64, count: u32) !Random {
    assert(count >= 1);
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var best: Random = undefined;
    var best_score: f64 = -1;
    for (0..random_tries) |_| {
        const cand = try candidate(arena, r, count);
        const score = try brightness(arena, &cand, r.int(u64));
        if (score > best_score) {
            best = cand;
            best_score = score;
        }
        if (score >= random_brightness_min) break;
    }
    return best;
}

const random_tries = 12;
const random_brightness_min = 0.1;

fn candidate(arena: Allocator, r: std.Random, count: u32) !Random {
    const ts = try arena.alloc(Transform, count);
    for (ts, 0..) |*t, i| {
        const angle = r.float(f64) * 2 * std.math.pi;
        const sx = 0.35 + r.float(f64) * 0.6;
        const sy = 0.35 + r.float(f64) * 0.6;
        const shear = (r.float(f64) - 0.5) * 0.6;
        const c = @cos(angle);
        const s = @sin(angle);
        const nterms = 1 + r.uintLessThan(u32, 2);
        const terms = try arena.alloc(Term, nterms);
        var total: f64 = 0;
        for (terms) |*term| {
            term.* = .{ .variation = random_pool[r.uintLessThan(usize, random_pool.len)], .weight = 0.2 + r.float(f64) };
            total += term.weight;
        }
        for (terms) |*term| term.weight /= total;
        t.* = .{
            .weight = 0.25 + r.float(f64),
            .affine = .{ sx * c, -sy * s + shear, r.float(f64) * 2 - 1, sx * s, sy * c, r.float(f64) * 2 - 1 },
            .terms = terms,
            .color = (@as(f64, @floatFromInt(i)) + r.float(f64) * 0.5) / @as(f64, @floatFromInt(count)),
        };
    }
    const roll = r.uintLessThan(u32, 10);
    const sym: i32 = if (roll < 6)
        1
    else if (roll < 8)
        @intCast(2 + r.uintLessThan(u32, 5))
    else
        -@as(i32, @intCast(2 + r.uintLessThan(u32, 4)));
    return .{ .transforms = ts, .symmetry = sym };
}

/// Mean brightness of a quick 64 x 64 render under log tone, the way
/// the picture will be seen. Dust and single hot spots score low.
fn brightness(arena: Allocator, cand: *const Random, seed: u64) !f64 {
    var res = render(arena, .{
        .transforms = cand.transforms,
        .symmetry = cand.symmetry,
        .iterations = 60_000,
        .w = 64,
        .h = 64,
        .seed = seed,
        .splat = .nearest,
    }) catch |err| switch (err) {
        error.NoWeight => return 0,
        error.OutOfMemory => return err,
    };
    defer res.deinit(arena);
    const peak = res.density.minMax()[1];
    if (!(peak > 0)) return 0;
    const k = 200.0;
    var sum: f64 = 0;
    for (res.density.data) |v| sum += @log(1 + k * v / peak);
    return sum / @log(1 + k) / @as(f64, @floatFromInt(res.density.data.len));
}

test "flame: linear identity transforms keep the point" {
    var prng: std.Random.DefaultPrng = .init(1);
    const t: Transform = .{ .color = 1 };
    const p = apply(&t, .{ .x = 0.25, .y = -0.5, .c = 0 }, prng.random());
    try std.testing.expectEqual(@as(f64, 0.25), p.x);
    try std.testing.expectEqual(@as(f64, -0.5), p.y);
    try std.testing.expectEqual(@as(f64, 0.5), p.c);
}

test "flame: variations follow the paper" {
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    const pre: Pre = .init(3, 4);
    const sph = variation(.spherical, &pre, &identity, r);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 25.0), sph[0], 1e-12);
    const hs = variation(.horseshoe, &pre, &identity, r);
    try std.testing.expectApproxEqAbs(@as(f64, (3.0 - 4.0) * 7.0 / 5.0), hs[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 24.0 / 5.0), hs[1], 1e-12);
    const fe = variation(.fisheye, &pre, &identity, r);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0 / 3.0), fe[0], 1e-12);
    const bt = variation(.bent, &Pre.init(-1, -1), &identity, r);
    try std.testing.expectEqual([2]f64{ -2, -0.5 }, bt);
}

test "flame: sierpinski gasket lands only off the center hole" {
    const gpa = std.testing.allocator;
    const half = [_]Transform{
        .{ .affine = .{ 0.5, 0, 0, 0, 0.5, 0 }, .color = 0 },
        .{ .affine = .{ 0.5, 0, 0.5, 0, 0.5, 0 }, .color = 0.5 },
        .{ .affine = .{ 0.5, 0, 0, 0, 0.5, 0.5 }, .color = 1 },
    };
    var res = try render(gpa, .{
        .transforms = &half,
        .iterations = 50_000,
        .w = 8,
        .h = 8,
        .splat = .nearest,
        .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    defer res.deinit(gpa);
    // The gasket's upper right quarter of the unit square is empty.
    try std.testing.expectEqual(@as(f32, 0), res.density.get(6, 6));
    try std.testing.expectEqual(@as(f32, 0), res.density.get(3, 3));
    try std.testing.expect(res.density.get(0, 0) > 0);
    try std.testing.expect(res.density.get(2, 0) > 0);
    // Points near the origin come mostly from transform 0, color 0.
    try std.testing.expect(res.color.get(0, 0) < 0.25);
}

test "flame: random flames are deterministic per seed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try random(arena_state.allocator(), 9, 3);
    const b = try random(arena_state.allocator(), 9, 3);
    try std.testing.expectEqual(a.symmetry, b.symmetry);
    try std.testing.expectEqual(a.transforms[2].affine, b.transforms[2].affine);
    try std.testing.expectEqual(@as(usize, 3), a.transforms.len);
}
