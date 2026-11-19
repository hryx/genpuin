//! Strange attractors of 2D iterated maps, rendered as density.
//! One long orbit is iterated and every point after warmup is splatted.

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const density = @import("../density.zig");

pub const Kind = enum {
    clifford,
    dejong,
    svensson,
    bedhead,
    hopalong,
    gumowski_mira,
    tinkerbell,
    ikeda,
    fractal_dream,
    symmetric_icon,
};

/// Map parameters. Each kind reads the ones it needs.
pub const Params = struct {
    a: f64,
    b: f64,
    c: f64 = 0,
    d: f64 = 0,
    e: f64 = 0,
    degree: u32 = 0,
};

/// Parameters known to give a good picture.
pub fn defaults(kind: Kind) Params {
    return switch (kind) {
        .clifford => .{ .a = -1.4, .b = 1.6, .c = 1.0, .d = 0.7 },
        .dejong => .{ .a = 1.4, .b = -2.3, .c = 2.4, .d = -2.1 },
        .svensson => .{ .a = 1.5, .b = -1.8, .c = 1.6, .d = 0.9 },
        .bedhead => .{ .a = -0.81, .b = -0.92 },
        .hopalong => .{ .a = -11, .b = 0.05, .c = 0.5 },
        .gumowski_mira => .{ .a = -0.496, .b = 0.008, .c = 0.05 },
        .tinkerbell => .{ .a = 0.9, .b = -0.6013, .c = 2.0, .d = 0.5 },
        .ikeda => .{ .a = 0.9, .b = 0.4, .c = 6.0 },
        .fractal_dream => .{ .a = -0.966918, .b = 2.879879, .c = 0.765145, .d = 0.744728 },
        .symmetric_icon => .{ .a = -2.08, .b = 1.0, .c = -0.1, .d = 0.167, .e = 0, .degree = 7 },
    };
}

fn startPoint(kind: Kind) [2]f64 {
    return switch (kind) {
        .tinkerbell => .{ -0.72, -0.64 },
        .gumowski_mira => .{ 0.5, 0.5 },
        .symmetric_icon => .{ 0.01, 0.003 },
        .clifford, .dejong, .svensson, .bedhead, .hopalong, .ikeda, .fractal_dream => .{ 0.1, 0.1 },
    };
}

/// One step of the map. Sources: Clifford Pickover, "Chaos in
/// Wonderland" (clifford, fractal dream), Paul Bourke's attractor pages
/// (de Jong, Svensson, bedhead), Barry Martin via Dewdney's Computer
/// Recreations, Sept. 1986 (hopalong), Gumowski and Mira (1980), Nusse and
/// Yorke (tinkerbell), Ikeda (1979), and Field and Golubitsky, "Symmetry in
/// Chaos" (symmetric icon, a = lambda, b = alpha, c = beta, d = gamma,
/// e = omega).
pub inline fn step(comptime kind: Kind, p: Params, x: f64, y: f64) [2]f64 {
    switch (kind) {
        .clifford => return .{
            math.sin(p.a * y) + p.c * math.cos(p.a * x),
            math.sin(p.b * x) + p.d * math.cos(p.b * y),
        },
        .dejong => return .{ math.sin(p.a * y) - math.cos(p.b * x), math.sin(p.c * x) - math.cos(p.d * y) },
        .svensson => return .{
            p.d * math.sin(p.a * x) - math.sin(p.b * y),
            p.c * math.cos(p.a * x) + math.cos(p.b * y),
        },
        .bedhead => return .{ math.sin(x * y / p.b) * y + math.cos(p.a * x - y), x + math.sin(y) / p.b },
        .hopalong => {
            const s: f64 = if (x < 0) -1 else 1;
            return .{ y - s * @sqrt(@abs(p.b * x - p.c)), p.a - x };
        },
        .gumowski_mira => {
            const nx = y + p.b * (1 - p.c * y * y) * y + mira(p.a, x);
            return .{ nx, -x + mira(p.a, nx) };
        },
        .tinkerbell => return .{
            x * x - y * y + p.a * x + p.b * y,
            2 * x * y + p.c * x + p.d * y,
        },
        .ikeda => {
            const t = p.b - p.c / (1 + x * x + y * y);
            const ct = math.cos(t);
            const st = math.sin(t);
            return .{ 1 + p.a * (x * ct - y * st), p.a * (x * st + y * ct) };
        },
        .fractal_dream => return .{
            math.sin(y * p.b) + p.c * math.sin(x * p.b),
            math.sin(x * p.a) + p.d * math.sin(y * p.a),
        },
        .symmetric_icon => {
            var zr = x;
            var zi = y;
            for (1..@max(p.degree, 2) - 1) |_| {
                const r = zr * x - zi * y;
                zi = zi * x + zr * y;
                zr = r;
            }
            const re_zn = x * zr - y * zi;
            const q = p.a + p.b * (x * x + y * y) + p.c * re_zn;
            return .{ q * x + p.d * zr - p.e * y, q * y - p.d * zi + p.e * x };
        },
    }
}

fn mira(a: f64, x: f64) f64 {
    const x2 = x * x;
    return a * x + 2 * (1 - a) * x2 / (1 + x2);
}

pub const Options = struct {
    kind: Kind = .clifford,
    params: ?Params = null,
    iterations: u64 = 1_000_000,
    w: u32,
    h: u32,
    seed: u64 = 1,
    supersample: u32 = 1,
    splat: density.Splat = .bilinear,
    /// Map-space rect. Null fits it from a pilot run.
    bounds: ?density.Rect = null,
    /// Quantize plotted points. The pilot run is never snapped, so the
    /// fitted bounds are the same with or without it.
    snap: ?density.Snap = null,
};

const warmup = 1000;
const pilot_len = 50_000;

/// Iterate the map and return a w x h density Field.
pub fn render(gpa: Allocator, o: Options) !Field {
    return switch (o.kind) {
        inline else => |k| renderKind(k, gpa, o),
    };
}

const Orbit = struct {
    x: f64,
    y: f64,
    start: [2]f64,
    rng: std.Random.DefaultPrng,

    fn init(kind: Kind, seed: u64) Orbit {
        var o: Orbit = .{ .x = 0, .y = 0, .start = startPoint(kind), .rng = .init(seed) };
        o.restart();
        return o;
    }

    /// A small random nudge off the start point. Used again whenever the
    /// orbit escapes or turns into NaN.
    fn restart(self: *Orbit) void {
        const r = self.rng.random();
        self.x = self.start[0] + (r.float(f64) - 0.5) * 1e-3;
        self.y = self.start[1] + (r.float(f64) - 0.5) * 1e-3;
    }

    inline fn advance(self: *Orbit, comptime kind: Kind, p: Params) void {
        const n = step(kind, p, self.x, self.y);
        self.x = n[0];
        self.y = n[1];
        if (!(@abs(self.x) + @abs(self.y) < 1e8)) self.restart();
    }
};

fn renderKind(comptime kind: Kind, gpa: Allocator, o: Options) !Field {
    const p = o.params orelse defaults(kind);
    var orbit: Orbit = .init(kind, o.seed);
    for (0..warmup) |_| orbit.advance(kind, p);

    const bounds = o.bounds orelse blk: {
        const xs = try gpa.alloc(f64, pilot_len);
        defer gpa.free(xs);
        const ys = try gpa.alloc(f64, pilot_len);
        defer gpa.free(ys);
        for (xs, ys) |*x, *y| {
            orbit.advance(kind, p);
            x.* = orbit.x;
            y.* = orbit.y;
        }
        const aspect = @as(f64, @floatFromInt(o.w)) / @as(f64, @floatFromInt(o.h));
        break :blk density.fitBounds(xs, ys, 0.0005, 0.04, aspect);
    };

    var hist: density.Histogram = try .init(gpa, o.w, o.h, o.supersample, bounds, o.splat);
    errdefer hist.deinit(gpa);
    // The snap loops stay out of line so the plain loop compiles as it
    // did without them. Inlined, they cost the attractor about 2%.
    if (o.snap) |s| {
        var snapper: density.Snapper = .init(s, o.w, o.h, o.supersample, o.seed);
        if (s.feedback) {
            runFed(kind, p, &orbit, &hist, &snapper, o.iterations);
        } else {
            runSnapped(kind, p, &orbit, &hist, &snapper, o.iterations);
        }
    } else {
        for (0..o.iterations) |_| {
            orbit.advance(kind, p);
            hist.plot(orbit.x, orbit.y, 1);
        }
    }
    return hist.finish(gpa);
}

noinline fn runSnapped(
    comptime kind: Kind,
    p: Params,
    orbit: *Orbit,
    hist: *density.Histogram,
    snapper: *density.Snapper,
    iterations: u64,
) void {
    for (0..iterations) |_| {
        orbit.advance(kind, p);
        const c = hist.mapper.map(orbit.x, orbit.y);
        const d = snapper.offset(c[0], c[1]);
        hist.plotCell(c[0] + d[0], c[1] + d[1], 1);
    }
}

/// The map runs on the lattice. A deterministic map on a finite set of
/// points falls into a cycle, so without jitter the orbit soon repeats a
/// handful of points. That is the look, and the loop still runs its
/// count.
noinline fn runFed(
    comptime kind: Kind,
    p: Params,
    orbit: *Orbit,
    hist: *density.Histogram,
    snapper: *density.Snapper,
    iterations: u64,
) void {
    for (0..iterations) |_| {
        orbit.advance(kind, p);
        const q = snapper.feed(hist.mapper, orbit.x, orbit.y);
        orbit.x = q[0];
        orbit.y = q[1];
        hist.plot(orbit.x, orbit.y, 1);
    }
}

test "attractor: clifford step matches the formula" {
    const p = defaults(.clifford);
    const n = step(.clifford, p, 0.1, 0.2);
    try std.testing.expectApproxEqAbs(math.sin(-1.4 * 0.2) + math.cos(-1.4 * 0.1), n[0], 1e-12);
    try std.testing.expectApproxEqAbs(math.sin(1.6 * 0.1) + 0.7 * math.cos(1.6 * 0.2), n[1], 1e-12);
}

test "attractor: symmetric icon with only lambda set is a pure scale" {
    const p: Params = .{ .a = 0.5, .b = 0, .c = 0, .d = 0, .degree = 2 };
    const n = step(.symmetric_icon, p, 2, -4);
    try std.testing.expectEqual(@as(f64, 1), n[0]);
    try std.testing.expectEqual(@as(f64, -2), n[1]);
}

test "attractor: render is deterministic and counts every iteration" {
    const gpa = std.testing.allocator;
    const o: Options = .{ .kind = .dejong, .iterations = 20_000, .w = 32, .h = 32, .seed = 3 };
    var a = try render(gpa, o);
    defer a.deinit(gpa);
    var b = try render(gpa, o);
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(f32, a.data, b.data);
    var total: f64 = 0;
    for (a.data) |v| total += v;
    // The fitted bounds trim a sliver of outliers, so nearly all land.
    try std.testing.expect(total > 19_000 and total < 20_000.5);
}

test "attractor: supersampling keeps the output size" {
    const gpa = std.testing.allocator;
    var f = try render(gpa, .{ .kind = .clifford, .iterations = 5000, .w = 16, .h = 8, .supersample = 2 });
    defer f.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 16), f.w);
    try std.testing.expectEqual(@as(u32, 8), f.h);
}

test "attractor: snap with amount 0 renders the unsnapped Field exactly" {
    const gpa = std.testing.allocator;
    const o: Options = .{ .kind = .clifford, .iterations = 20_000, .w = 32, .h = 32, .seed = 4, .supersample = 2 };
    var plain = try render(gpa, o);
    defer plain.deinit(gpa);
    var so = o;
    so.snap = .{ .cell = 3, .amount = 0, .chance = 0.4 };
    var a = try render(gpa, so);
    defer a.deinit(gpa);
    try std.testing.expectEqualSlices(f32, plain.data, a.data);
    so.snap.?.feedback = true;
    var b = try render(gpa, so);
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(f32, plain.data, b.data);
}

test "attractor: snapped render is deterministic and lands only on lattice cells" {
    const gpa = std.testing.allocator;
    const o: Options = .{
        .kind = .dejong,
        .iterations = 20_000,
        .w = 40,
        .h = 40,
        .seed = 2,
        .splat = .nearest,
        .snap = .{ .cell = 4 },
    };
    var a = try render(gpa, o);
    defer a.deinit(gpa);
    var b = try render(gpa, o);
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(f32, a.data, b.data);
    for (0..a.h) |y| for (0..a.w) |x| {
        if (x % 4 != 0 or y % 4 != 0) try std.testing.expectEqual(@as(f32, 0), a.get(@intCast(x), @intCast(y)));
    };
}

test "attractor: feedback terminates and stays finite" {
    const gpa = std.testing.allocator;
    inline for (.{ 0.0, 0.3 }) |jitter| {
        var f = try render(gpa, .{
            .kind = .clifford,
            .iterations = 50_000,
            .w = 64,
            .h = 64,
            .seed = 9,
            .snap = .{ .cell = 6, .jitter = jitter, .feedback = true },
        });
        defer f.deinit(gpa);
        var total: f64 = 0;
        for (f.data) |v| {
            try std.testing.expect(std.math.isFinite(v));
            total += v;
        }
        try std.testing.expect(total > 40_000 and total < 50_000.5);
    }
}
