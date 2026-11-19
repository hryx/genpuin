//! Density rendering. Points from attractors, fractal flames or a script
//! are splatted into an f32 histogram Field. Tone mapping happens when the
//! Field is drawn (log tone in render.fieldColor), so this module only
//! counts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("Field.zig");
const math = @import("math.zig");

pub const attractor = @import("density/attractor.zig");
pub const flame = @import("density/flame.zig");

pub const Splat = enum { nearest, bilinear };

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

/// Maps scene points onto the cells of a w x h grid covering `rect`.
pub const Mapper = struct {
    sx: f64,
    sy: f64,
    ox: f64,
    oy: f64,

    pub fn init(rect: Rect, w: u32, h: u32) Mapper {
        assert(rect.w != 0 and rect.h != 0);
        const sx = @as(f64, @floatFromInt(w)) / rect.w;
        const sy = @as(f64, @floatFromInt(h)) / rect.h;
        return .{ .sx = sx, .sy = sy, .ox = -rect.x * sx, .oy = -rect.y * sy };
    }

    /// Continuous cell coordinates. Cell (i, j) spans [i, i+1) x [j, j+1).
    pub inline fn map(self: Mapper, x: f64, y: f64) [2]f64 {
        return .{ x * self.sx + self.ox, y * self.sy + self.oy };
    }
};

/// Add `weight` at continuous cell coordinates (u, v). Bilinear spreads
/// it over the four cells whose centers surround the point. Points
/// outside the grid are dropped.
pub inline fn add(f: *Field, mode: Splat, u: f64, v: f64, weight: f32) void {
    switch (mode) {
        .nearest => {
            if (!(u >= 0 and v >= 0)) return;
            const x: u64 = @intFromFloat(u);
            const y: u64 = @intFromFloat(v);
            if (x >= f.w or y >= f.h) return;
            f.data[@intCast(y * f.w + x)] += weight;
        },
        .bilinear => {
            const fu = u - 0.5;
            const fv = v - 0.5;
            if (!(fu > -1 and fv > -1 and fu < @as(f64, @floatFromInt(f.w)) and fv < @as(f64, @floatFromInt(f.h)))) return;
            const x0f = @floor(fu);
            const y0f = @floor(fv);
            const tx: f32 = @floatCast(fu - x0f);
            const ty: f32 = @floatCast(fv - y0f);
            const x0: i64 = @intFromFloat(x0f);
            const y0: i64 = @intFromFloat(y0f);
            addCell(f, x0, y0, (1 - tx) * (1 - ty) * weight);
            addCell(f, x0 + 1, y0, tx * (1 - ty) * weight);
            addCell(f, x0, y0 + 1, (1 - tx) * ty * weight);
            addCell(f, x0 + 1, y0 + 1, tx * ty * weight);
        },
    }
}

inline fn addCell(f: *Field, x: i64, y: i64, w: f32) void {
    if (x < 0 or y < 0 or x >= f.w or y >= f.h) return;
    f.data[@intCast(y * f.w + x)] += w;
}

/// Splat scene points into `f` through `rect`. Each point is {x, y} with
/// an optional per-point weight. A snapper moves each point before it
/// lands, with lengths in cells of `f`.
pub fn splatPoints(
    f: *Field,
    rect: Rect,
    mode: Splat,
    points: []const [2]f64,
    weights: ?[]const f32,
    snapper: ?*Snapper,
) void {
    if (weights) |ws| assert(ws.len == points.len);
    const m: Mapper = .init(rect, f.w, f.h);
    for (points, 0..) |p, i| {
        var c = m.map(p[0], p[1]);
        if (snapper) |s| {
            const d = s.offset(c[0], c[1]);
            c = .{ c[0] + d[0], c[1] + d[1] };
        }
        add(f, mode, c[0], c[1], if (weights) |ws| ws[i] else 1);
    }
}

/// Quantizes the points a render plots onto a lattice. Lengths are in
/// output cells of the Field, so the look does not change with
/// supersampling.
pub const Snap = struct {
    pub const Mode = enum { grid, rows, columns, hex, polar };

    /// Lattice spacing. Polar uses it for the ring spacing.
    cell: f64,
    /// Rows snaps y only and columns x only, in the rotated frame.
    mode: Mode = .grid,
    /// How far a snapped point moves toward its lattice point, 0 to 1.
    amount: f64 = 1,
    /// Radius of a uniform random offset in a disc added after snapping,
    /// as a fraction of `cell`.
    jitter: f64 = 0,
    /// Probability that a point is snapped at all.
    chance: f64 = 1,
    /// Lattice rotation in degrees. Polar turns its spokes by it.
    angle: f64 = 0,
    /// Polar center. Null is the middle of the Field.
    center: ?[2]f64 = null,
    spokes: u32 = 24,
    /// Write the snapped point back into the orbit, so the map iterates on
    /// the lattice. Off, only the plotted point moves.
    feedback: bool = false,
};

/// A Snap prepared for one histogram, with lengths in histogram cells and
/// its own generator for jitter and chance, so the orbit's random stream
/// is the same with or without snapping.
pub const Snapper = struct {
    mode: Snap.Mode,
    cell: f64,
    amount: f64,
    jitter: f64,
    chance: f64,
    angle: f64,
    cos_a: f64,
    sin_a: f64,
    /// A lattice point of the planar modes, the center of output cell
    /// (0, 0), so snapped points splat onto whole output cells.
    origin: [2]f64,
    center: [2]f64,
    spoke: f64,
    prng: std.Random.DefaultPrng,

    /// `w` and `h` are the output size and `factor` the supersample
    /// factor of the histogram the points land in.
    pub fn init(s: Snap, w: u32, h: u32, factor: u32, seed: u64) Snapper {
        assert(s.cell > 0 and std.math.isFinite(s.cell));
        assert(s.amount >= 0 and s.amount <= 1);
        assert(s.jitter >= 0);
        assert(s.chance >= 0 and s.chance <= 1);
        assert(s.spokes >= 1);
        assert(factor >= 1);
        const k: f64 = @floatFromInt(factor);
        const angle = s.angle * std.math.pi / 180.0;
        const center = s.center orelse [2]f64{
            @as(f64, @floatFromInt(w)) / 2,
            @as(f64, @floatFromInt(h)) / 2,
        };
        return .{
            .mode = s.mode,
            .cell = s.cell * k,
            .amount = s.amount,
            .jitter = s.jitter * s.cell * k,
            .chance = s.chance,
            .angle = angle,
            .cos_a = math.cos(angle),
            .sin_a = math.sin(angle),
            .origin = .{ 0.5 * k, 0.5 * k },
            .center = .{ center[0] * k, center[1] * k },
            .spoke = 2 * std.math.pi / @as(f64, @floatFromInt(s.spokes)),
            .prng = .init(seed ^ stream),
        };
    }

    /// Mixed into the render seed so snap draws from a stream of its own.
    const stream: u64 = 0xa076_1d64_78bd_642f;

    /// The displacement to add to the point at cell coordinates (u, v).
    /// Zero when the chance roll misses or `amount` is 0 and there is no
    /// jitter.
    pub fn offset(self: *Snapper, u: f64, v: f64) [2]f64 {
        const r = self.prng.random();
        if (self.chance < 1 and !(r.float(f64) < self.chance)) return .{ 0, 0 };
        var d: [2]f64 = .{ 0, 0 };
        if (self.amount > 0) {
            const l = self.lattice(u, v);
            d = .{ l[0] * self.amount, l[1] * self.amount };
        }
        if (self.jitter > 0) {
            const j = disc(r);
            d = .{ d[0] + j[0] * self.jitter, d[1] + j[1] * self.jitter };
        }
        return d;
    }

    /// Snap a map-space point through `m` and return it in map space.
    pub fn feed(self: *Snapper, m: Mapper, x: f64, y: f64) [2]f64 {
        const c = m.map(x, y);
        const d = self.offset(c[0], c[1]);
        return .{ x + d[0] / m.sx, y + d[1] / m.sy };
    }

    /// From (u, v) to the nearest lattice point. Untouched axes of an
    /// unrotated lattice come out as exact zeros.
    fn lattice(self: *const Snapper, u: f64, v: f64) [2]f64 {
        const du = u - self.origin[0];
        const dv = v - self.origin[1];
        const x = self.cos_a * du + self.sin_a * dv;
        const y = self.cos_a * dv - self.sin_a * du;
        return switch (self.mode) {
            .grid => self.unrotate(.{ self.nearest(x) - x, self.nearest(y) - y }),
            .rows => self.unrotate(.{ 0, self.nearest(y) - y }),
            .columns => self.unrotate(.{ self.nearest(x) - x, 0 }),
            .hex => self.unrotate(self.hex(x, y)),
            .polar => self.polar(u, v),
        };
    }

    fn nearest(self: *const Snapper, x: f64) f64 {
        return @round(x / self.cell) * self.cell;
    }

    fn unrotate(self: *const Snapper, d: [2]f64) [2]f64 {
        return .{ self.cos_a * d[0] - self.sin_a * d[1], self.sin_a * d[0] + self.cos_a * d[1] };
    }

    /// A triangular lattice with rows along x is two rectangular lattices
    /// of pitch (cell, cell sqrt 3), the second shifted by half a pitch.
    /// The nearest point is the nearer of the nearest in each.
    fn hex(self: *const Snapper, x: f64, y: f64) [2]f64 {
        const px = self.cell;
        const py = self.cell * @sqrt(3.0);
        const ax = @round(x / px) * px - x;
        const ay = @round(y / py) * py - y;
        const bx = @round((x - px / 2) / px) * px + px / 2 - x;
        const by = @round((y - py / 2) / py) * py + py / 2 - y;
        if (ax * ax + ay * ay <= bx * bx + by * by) return .{ ax, ay };
        return .{ bx, by };
    }

    fn polar(self: *const Snapper, u: f64, v: f64) [2]f64 {
        const dx = u - self.center[0];
        const dy = v - self.center[1];
        const r = self.nearest(@sqrt(dx * dx + dy * dy));
        const t = @round((math.atan2(dy, dx) - self.angle) / self.spoke) * self.spoke + self.angle;
        return .{ self.center[0] + r * math.cos(t) - u, self.center[1] + r * math.sin(t) - v };
    }

    /// Uniform in the unit disc by rejection. Each try lands with
    /// probability pi / 4, so running out of tries never happens in
    /// practice.
    fn disc(r: std.Random) [2]f64 {
        for (0..32) |_| {
            const x = r.float(f64) * 2 - 1;
            const y = r.float(f64) * 2 - 1;
            if (x * x + y * y <= 1) return .{ x, y };
        }
        return .{ 0, 0 };
    }
};

/// Bounds around a point cloud, trimming `trim` of the points on each
/// side per axis, padded by `pad` of the span, then widened on one axis
/// so w/h matches `aspect`. Sorts `xs` and `ys` in place.
pub fn fitBounds(xs: []f64, ys: []f64, trim: f64, pad: f64, aspect: f64) Rect {
    assert(xs.len == ys.len);
    assert(xs.len > 0);
    std.mem.sortUnstable(f64, xs, {}, std.sort.asc(f64));
    std.mem.sortUnstable(f64, ys, {}, std.sort.asc(f64));
    const last: f64 = @floatFromInt(xs.len - 1);
    const lo: usize = @intFromFloat(@round(last * trim));
    const hi: usize = xs.len - 1 - lo;
    var x0 = xs[lo];
    var x1 = xs[hi];
    var y0 = ys[lo];
    var y1 = ys[hi];
    var w = x1 - x0;
    var h = y1 - y0;
    if (!(w > 1e-9)) w = @max(h, 1);
    if (!(h > 1e-9)) h = @max(w, 1);
    const cx = (x0 + x1) / 2;
    const cy = (y0 + y1) / 2;
    w *= 1 + 2 * pad;
    h *= 1 + 2 * pad;
    if (w / h < aspect) w = h * aspect else h = w / aspect;
    x0 = cx - w / 2;
    y0 = cy - h / 2;
    x1 = x0 + w;
    y1 = y0 + h;
    return .{ .x = x0, .y = y0, .w = w, .h = h };
}

/// Sum `factor` x `factor` blocks of `src` into a new Field.
pub fn downsample(gpa: Allocator, src: *const Field, factor: u32) !Field {
    assert(factor >= 1);
    assert(src.w % factor == 0 and src.h % factor == 0);
    const w = src.w / factor;
    const h = src.h / factor;
    var out: Field = try .init(gpa, w, h, 0);
    for (0..src.h) |y| {
        const row = src.data[y * src.w ..][0..src.w];
        const dst = out.data[(y / factor) * w ..][0..w];
        for (row, 0..) |v, x| dst[x / factor] += v;
    }
    return out;
}

/// The histogram a render accumulates into, at `supersample` times the
/// output size. `finish` sums it down to the output size.
pub const Histogram = struct {
    field: Field,
    factor: u32,
    mapper: Mapper,
    splat: Splat,

    pub fn init(gpa: Allocator, w: u32, h: u32, supersample: u32, bounds: Rect, splat: Splat) !Histogram {
        assert(supersample >= 1);
        const f: Field = try .init(gpa, w * supersample, h * supersample, 0);
        return .{
            .field = f,
            .factor = supersample,
            .mapper = .init(bounds, f.w, f.h),
            .splat = splat,
        };
    }

    pub fn deinit(self: *Histogram, gpa: Allocator) void {
        self.field.deinit(gpa);
    }

    pub inline fn plot(self: *Histogram, x: f64, y: f64, weight: f32) void {
        const c = self.mapper.map(x, y);
        add(&self.field, self.splat, c[0], c[1], weight);
    }

    /// Plot at histogram cell coordinates, as from `mapper`.
    pub inline fn plotCell(self: *Histogram, u: f64, v: f64, weight: f32) void {
        add(&self.field, self.splat, u, v, weight);
    }

    /// Consumes the histogram and returns the output-size Field.
    pub fn finish(self: *Histogram, gpa: Allocator) !Field {
        if (self.factor == 1) {
            const f = self.field;
            self.field = undefined;
            return f;
        }
        defer self.deinit(gpa);
        return downsample(gpa, &self.field, self.factor);
    }
};

test "density: bilinear splat keeps the weight and centers on the cell" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 4, 4, 0);
    defer f.deinit(gpa);
    add(&f, .bilinear, 1.5, 1.5, 1);
    try std.testing.expectEqual(@as(f32, 1), f.get(1, 1));
    add(&f, .bilinear, 2.0, 2.5, 2);
    try std.testing.expectEqual(@as(f32, 1), f.get(1, 2));
    try std.testing.expectEqual(@as(f32, 1), f.get(2, 2));
    add(&f, .nearest, 3.9, 0.1, 5);
    try std.testing.expectEqual(@as(f32, 5), f.get(3, 0));
    add(&f, .bilinear, -3, 2, 1);
    add(&f, .nearest, 4, 2, 1);
    var total: f32 = 0;
    for (f.data) |v| total += v;
    try std.testing.expectEqual(@as(f32, 8), total);
}

test "density: splatPoints maps the scene rect onto cells" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 10, 5, 0);
    defer f.deinit(gpa);
    const pts = [_][2]f64{ .{ 25, 15 }, .{ 25, 15 }, .{ 95, 45 } };
    const ws = [_]f32{ 1, 2, 4 };
    splatPoints(&f, .{ .x = 0, .y = 0, .w = 100, .h = 50 }, .nearest, &pts, &ws, null);
    try std.testing.expectEqual(@as(f32, 3), f.get(2, 1));
    try std.testing.expectEqual(@as(f32, 4), f.get(9, 4));
}

test "density: fitBounds trims outliers and matches aspect" {
    var xs = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 1000 };
    var ys = [_]f64{ 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4 };
    const r = fitBounds(&xs, &ys, 0.1, 0, 1);
    // Kept x 1..8 and y 0.5..4, then h grows to match w.
    try std.testing.expectEqual(@as(f64, 7), r.w);
    try std.testing.expectEqual(@as(f64, 7), r.h);
    try std.testing.expectEqual(@as(f64, 1), r.x);
    try std.testing.expectEqual(@as(f64, -1.25), r.y);
}

test "density: downsample sums blocks" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 4, 2, 1);
    defer f.deinit(gpa);
    var d = try downsample(gpa, &f, 2);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), d.w);
    try std.testing.expectEqual(@as(f32, 4), d.get(1, 0));
}

/// Points spread over a 64 x 64 grid, off any lattice.
fn testPoints(comptime n: usize) [n][2]f64 {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var pts: [n][2]f64 = undefined;
    for (&pts) |*p| p.* = .{ r.float(f64) * 64, r.float(f64) * 64 };
    return pts;
}

fn snapped(s: *Snapper, p: [2]f64) [2]f64 {
    const d = s.offset(p[0], p[1]);
    return .{ p[0] + d[0], p[1] + d[1] };
}

fn expectWhole(x: f64) !void {
    try std.testing.expectApproxEqAbs(@round(x), x, 1e-9);
}

test "density: grid snaps onto cell centers spaced in output cells" {
    // Supersample 2: a cell of 4 output cells is 8 histogram cells, and
    // output cell centers sit on whole histogram coordinates.
    var s: Snapper = .init(.{ .cell = 4 }, 32, 32, 2, 1);
    for (testPoints(200)) |p| {
        const q = snapped(&s, p);
        try expectWhole((q[0] - 1) / 8);
        try expectWhole((q[1] - 1) / 8);
        try std.testing.expect(@abs(q[0] - p[0]) <= 4 and @abs(q[1] - p[1]) <= 4);
    }
}

test "density: rows leave x untouched and columns leave y" {
    var rows: Snapper = .init(.{ .cell = 5, .mode = .rows }, 64, 64, 1, 1);
    var cols: Snapper = .init(.{ .cell = 5, .mode = .columns }, 64, 64, 1, 1);
    for (testPoints(200)) |p| {
        const a = snapped(&rows, p);
        try std.testing.expectEqual(p[0], a[0]);
        try expectWhole((a[1] - 0.5) / 5);
        const b = snapped(&cols, p);
        try std.testing.expectEqual(p[1], b[1]);
        try expectWhole((b[0] - 0.5) / 5);
    }
}

test "density: a rotated grid lands on the rotated lattice" {
    var s: Snapper = .init(.{ .cell = 6, .angle = 30 }, 64, 64, 1, 1);
    const c = math.cos(std.math.pi / 6.0);
    const sn = math.sin(std.math.pi / 6.0);
    for (testPoints(200)) |p| {
        const q = snapped(&s, p);
        const dx = q[0] - 0.5;
        const dy = q[1] - 0.5;
        try expectWhole((c * dx + sn * dy) / 6);
        try expectWhole((c * dy - sn * dx) / 6);
    }
}

test "density: hex snaps to the nearest triangular lattice point" {
    const cell = 7.0;
    const row = cell * @sqrt(3.0) / 2.0;
    var s: Snapper = .init(.{ .cell = cell, .mode = .hex }, 64, 64, 1, 1);
    for (testPoints(200)) |p| {
        const q = snapped(&s, p);
        const j = (q[1] - 0.5) / row;
        try expectWhole(j);
        try expectWhole((q[0] - 0.5 - @round(j) * cell / 2) / cell);
        // No point is farther from its lattice point than a hexagon's
        // corner, cell / sqrt 3.
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        try std.testing.expect(@sqrt(dx * dx + dy * dy) <= cell / @sqrt(3.0) + 1e-9);
    }
}

test "density: polar snaps angle to spokes and radius to rings" {
    var s: Snapper = .init(.{ .cell = 4, .mode = .polar, .spokes = 12 }, 64, 64, 1, 1);
    const step = 2 * std.math.pi / 12.0;
    for (testPoints(200)) |p| {
        const q = snapped(&s, p);
        const dx = q[0] - 32;
        const dy = q[1] - 32;
        const r = @sqrt(dx * dx + dy * dy);
        try expectWhole(r / 4);
        if (r > 0.5) try std.testing.expectApproxEqAbs(@round(math.atan2(dy, dx) / step), math.atan2(dy, dx) / step, 1e-7);
    }
}

test "density: amount 0 without jitter leaves every point exactly" {
    var s: Snapper = .init(.{ .cell = 3, .mode = .polar, .amount = 0, .chance = 0.5 }, 64, 64, 1, 1);
    for (testPoints(100)) |p| try std.testing.expectEqual(p, snapped(&s, p));
}

test "density: amount 0.5 moves halfway to the lattice" {
    var full: Snapper = .init(.{ .cell = 4 }, 64, 64, 1, 1);
    var half: Snapper = .init(.{ .cell = 4, .amount = 0.5 }, 64, 64, 1, 1);
    for (testPoints(50)) |p| {
        const a = full.offset(p[0], p[1]);
        const b = half.offset(p[0], p[1]);
        try std.testing.expectEqual(a[0] * 0.5, b[0]);
        try std.testing.expectEqual(a[1] * 0.5, b[1]);
    }
}

test "density: jitter stays within its disc around the lattice point" {
    var plain: Snapper = .init(.{ .cell = 8 }, 64, 64, 1, 1);
    var jit: Snapper = .init(.{ .cell = 8, .jitter = 0.3 }, 64, 64, 1, 1);
    var moved: u32 = 0;
    for (testPoints(500)) |p| {
        const a = snapped(&plain, p);
        const b = snapped(&jit, p);
        const d = @sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
        try std.testing.expect(d <= 0.3 * 8 + 1e-9);
        if (d > 0.3 * 8 / 2.0) moved += 1;
    }
    // A uniform disc puts three quarters of its points in the outer half
    // of the radius.
    try std.testing.expect(moved > 330 and moved < 420);
}

test "density: chance snaps about that share of points" {
    var s: Snapper = .init(.{ .cell = 4, .chance = 0.3 }, 64, 64, 1, 5);
    const pts = testPoints(10_000);
    var hits: u32 = 0;
    for (pts) |p| {
        const d = s.offset(p[0], p[1]);
        if (d[0] != 0 or d[1] != 0) hits += 1;
    }
    try std.testing.expect(hits > 2800 and hits < 3200);
}

test "density: the same seed gives the same jitter and the stream follows the seed" {
    const snap: Snap = .{ .cell = 4, .mode = .hex, .jitter = 0.5, .chance = 0.7 };
    var a: Snapper = .init(snap, 64, 64, 1, 11);
    var b: Snapper = .init(snap, 64, 64, 1, 11);
    var c: Snapper = .init(snap, 64, 64, 1, 12);
    var differs = false;
    for (testPoints(100)) |p| {
        const pa = snapped(&a, p);
        try std.testing.expectEqual(pa, snapped(&b, p));
        if (!std.meta.eql(pa, snapped(&c, p))) differs = true;
    }
    try std.testing.expect(differs);
}

test "density: feed moves a map-space point by the cell offset" {
    const m: Mapper = .init(.{ .x = -1, .y = -1, .w = 2, .h = 2 }, 64, 64);
    var s: Snapper = .init(.{ .cell = 8 }, 64, 64, 1, 1);
    const q = s.feed(m, 0.13, -0.41);
    const c = m.map(q[0], q[1]);
    try expectWhole((c[0] - 0.5) / 8);
    try expectWhole((c[1] - 0.5) / 8);
    var none: Snapper = .init(.{ .cell = 8, .amount = 0 }, 64, 64, 1, 1);
    try std.testing.expectEqual([2]f64{ 0.13, -0.41 }, none.feed(m, 0.13, -0.41));
}

test {
    _ = attractor;
    _ = flame;
}
