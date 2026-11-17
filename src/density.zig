//! Density rendering. Points from attractors, fractal flames or a script
//! are splatted into an f32 histogram Field. Tone mapping happens when the
//! Field is drawn (log tone in render.fieldColor), so this module only
//! counts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("Field.zig");

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
/// an optional per-point weight.
pub fn splatPoints(f: *Field, rect: Rect, mode: Splat, points: []const [2]f64, weights: ?[]const f32) void {
    if (weights) |ws| assert(ws.len == points.len);
    const m: Mapper = .init(rect, f.w, f.h);
    for (points, 0..) |p, i| {
        const c = m.map(p[0], p[1]);
        add(f, mode, c[0], c[1], if (weights) |ws| ws[i] else 1);
    }
}

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
    splatPoints(&f, .{ .x = 0, .y = 0, .w = 100, .h = 50 }, .nearest, &pts, &ws);
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

test {
    _ = attractor;
    _ = flame;
}
