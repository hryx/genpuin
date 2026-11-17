//! Quantize to a few levels per channel or to a palette, with ordered,
//! error diffusion or blue noise dithering. Posterize is the undithered
//! case.

const std = @import("std");
const libm = @import("../libm.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Raster = @import("../Raster.zig");
const common = @import("common.zig");

const Frame = common.Frame;
const Rgb = common.Rgb;
const V3 = common.V3;

pub const Method = enum { none, bayer, floyd, blue };

pub const Dither = struct {
    method: Method = .bayer,
    /// Levels per channel, used when `palette` is empty.
    levels: u32 = 2,
    palette: []const Rgb = &.{},
    /// Bayer matrix side: 2, 4, 8 or 16.
    matrix: u32 = 4,
    /// Dot size in scene units. 0 dithers single pixels.
    cell: f64 = 0,
    /// How far the threshold map pushes a value before quantizing. Null
    /// means one quantization step.
    spread: ?f32 = null,
};

const blue_size = 64;
const blue_seed = 0x5eed;

pub fn apply(gpa: Allocator, r: *Raster, p: *const Dither, frame: Frame) !void {
    assert(p.levels >= 2 or p.palette.len > 0);
    const cell: u32 = if (p.cell > 0) @intCast(frame.pxInt(p.cell, 1)) else 1;
    const map: ThresholdMap = switch (p.method) {
        .none, .floyd => .{ .size = 1, .t = &.{} },
        .bayer => try .bayer(gpa, p.matrix),
        .blue => try .blueNoise(gpa, blue_size, blue_seed),
    };
    defer gpa.free(map.t);
    const q: Quantizer = .{ .levels = p.levels, .palette = p.palette };
    const spread = p.spread orelse q.step();
    if (cell == 1) {
        try run(gpa, r, p.method, q, &map, spread, frame.x0, frame.y0);
        return;
    }
    var small = try cellAverage(gpa, r, cell);
    defer small.deinit(gpa);
    try run(gpa, &small, p.method, q, &map, spread, frame.x0 / cell, frame.y0 / cell);
    for (0..r.h) |y| for (0..r.w) |x| {
        r.set(@intCast(x), @intCast(y), small.get(@intCast(x / cell), @intCast(y / cell)));
    };
}

fn run(gpa: Allocator, r: *Raster, method: Method, q: Quantizer, map: *const ThresholdMap, spread: f32, ox: u32, oy: u32) !void {
    switch (method) {
        .none => for (0..@as(usize, r.w) * r.h) |i| {
            common.setPixel(r, i, q.nearest(common.pixel(r, i)));
        },
        .bayer, .blue => for (0..r.h) |y| for (0..r.w) |x| {
            const t = map.at(ox + @as(u32, @intCast(x)), oy + @as(u32, @intCast(y)));
            const i = y * r.w + x;
            const c = common.pixel(r, i) + @as(V3, @splat((t - 0.5) * spread));
            common.setPixel(r, i, q.nearest(c));
        },
        .floyd => try floydSteinberg(gpa, r, q),
    }
}

const Quantizer = struct {
    levels: u32,
    palette: []const Rgb,

    fn step(self: Quantizer) f32 {
        const n = if (self.palette.len > 0) self.palette.len else self.levels;
        return 1 / @as(f32, @floatFromInt(@max(1, n - 1)));
    }

    fn nearest(self: Quantizer, c_in: V3) V3 {
        const c = common.clamp01(c_in);
        if (self.palette.len == 0) {
            const k: V3 = @splat(@floatFromInt(self.levels - 1));
            return @round(c * k) / k;
        }
        var best: V3 = self.palette[0];
        var best_d = std.math.inf(f32);
        for (self.palette) |pc| {
            const d = c - @as(V3, pc);
            const dd = @reduce(.Add, d * d);
            if (dd < best_d) {
                best_d = dd;
                best = pc;
            }
        }
        return best;
    }
};

/// Floyd and Steinberg (1976) error diffusion, serpentine scan.
fn floydSteinberg(gpa: Allocator, r: *Raster, q: Quantizer) !void {
    const w = r.w;
    const err = try gpa.alloc(V3, @as(usize, w + 2) * 2);
    defer gpa.free(err);
    @memset(err, @splat(0));
    var cur = err[0 .. w + 2];
    var next = err[w + 2 ..];
    for (0..r.h) |y| {
        const flip = y % 2 == 1;
        for (0..w) |k| {
            const x = if (flip) w - 1 - k else k;
            const i = y * w + x;
            const old = common.clamp01(common.pixel(r, i) + cur[x + 1]);
            const new = q.nearest(old);
            common.setPixel(r, i, new);
            const e = old - new;
            const ahead = if (flip) x else x + 2;
            const behind = if (flip) x + 2 else x;
            cur[ahead] += e * @as(V3, @splat(7.0 / 16.0));
            next[behind] += e * @as(V3, @splat(3.0 / 16.0));
            next[x + 1] += e * @as(V3, @splat(5.0 / 16.0));
            next[ahead] += e * @as(V3, @splat(1.0 / 16.0));
        }
        std.mem.swap([]V3, &cur, &next);
        @memset(next, @splat(0));
    }
}

/// A tiling square of thresholds in 0..1.
const ThresholdMap = struct {
    size: u32,
    t: []f32,

    fn at(self: *const ThresholdMap, x: u32, y: u32) f32 {
        return self.t[(y % self.size) * self.size + x % self.size];
    }

    /// Bayer ordered dither matrix. Each bit pair of (x xor y, y) is a
    /// base 4 digit of the rank, lowest bits most significant.
    fn bayer(gpa: Allocator, size: u32) !ThresholdMap {
        assert(std.math.isPowerOfTwo(size));
        const bits = std.math.log2_int(u32, size);
        const t = try gpa.alloc(f32, size * size);
        const n: f32 = @floatFromInt(size * size);
        for (0..size) |y| for (0..size) |x| {
            var v: u32 = 0;
            for (0..bits) |i| {
                const xb: u32 = @intCast((x >> @intCast(i)) & 1);
                const yb: u32 = @intCast((y >> @intCast(i)) & 1);
                v = v * 4 + ((xb ^ yb) * 2 + yb);
            }
            t[y * size + x] = (@as(f32, @floatFromInt(v)) + 0.5) / n;
        };
        return .{ .size = size, .t = t };
    }

    /// Void and cluster, Ulichney 1993, "The void-and-cluster method for
    /// dither array generation". Gaussian energy with sigma 1.5 on a torus.
    fn blueNoise(gpa: Allocator, size: u32, seed: u64) !ThresholdMap {
        assert(std.math.isPowerOfTwo(size));
        const n = size * size;
        var vc: VoidCluster = try .init(gpa, size);
        defer vc.deinit(gpa);
        const rank = try gpa.alloc(u32, n);
        defer gpa.free(rank);

        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();
        const ones_initial = n / 10;
        var placed: u32 = 0;
        while (placed < ones_initial) {
            const i = rand.uintLessThan(u32, n);
            if (vc.bits[i]) continue;
            vc.toggle(i);
            placed += 1;
        }
        for (0..n) |_| {
            const c = vc.extreme(true);
            vc.toggle(c);
            const v = vc.extreme(false);
            vc.toggle(v);
            if (v == c) break;
        }

        const proto_bits = try gpa.dupe(bool, vc.bits);
        defer gpa.free(proto_bits);
        const proto_energy = try gpa.dupe(f32, vc.energy);
        defer gpa.free(proto_energy);

        var count = ones_initial;
        while (count > 0) {
            const c = vc.extreme(true);
            vc.toggle(c);
            count -= 1;
            rank[c] = count;
        }
        @memcpy(vc.bits, proto_bits);
        @memcpy(vc.energy, proto_energy);
        count = ones_initial;
        while (count < n) : (count += 1) {
            const v = vc.extreme(false);
            vc.toggle(v);
            rank[v] = count;
        }

        const t = try gpa.alloc(f32, n);
        for (t, rank) |*tv, rv| tv.* = (@as(f32, @floatFromInt(rv)) + 0.5) / @as(f32, @floatFromInt(n));
        return .{ .size = size, .t = t };
    }
};

const VoidCluster = struct {
    size: u32,
    bits: []bool,
    energy: []f32,
    kernel: []f32,

    fn init(gpa: Allocator, size: u32) !VoidCluster {
        const n = size * size;
        const bits = try gpa.alloc(bool, n);
        errdefer gpa.free(bits);
        const energy = try gpa.alloc(f32, n);
        errdefer gpa.free(energy);
        const kernel = try gpa.alloc(f32, n);
        @memset(bits, false);
        @memset(energy, 0);
        const sigma = 1.5;
        for (0..size) |y| for (0..size) |x| {
            const dx: f32 = @floatFromInt(@min(x, size - x));
            const dy: f32 = @floatFromInt(@min(y, size - y));
            kernel[y * size + x] = @floatCast(libm.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)));
        };
        return .{ .size = size, .bits = bits, .energy = energy, .kernel = kernel };
    }

    fn deinit(self: *VoidCluster, gpa: Allocator) void {
        gpa.free(self.bits);
        gpa.free(self.energy);
        gpa.free(self.kernel);
        self.* = undefined;
    }

    fn toggle(self: *VoidCluster, i: u32) void {
        self.bits[i] = !self.bits[i];
        const sign: f32 = if (self.bits[i]) 1 else -1;
        const s = self.size;
        const px = i % s;
        const py = i / s;
        for (0..s) |y| {
            const ky = (y + s - py) % s;
            const row = self.energy[y * s ..][0..s];
            const krow = self.kernel[ky * s ..][0..s];
            for (row, 0..) |*e, x| e.* += sign * krow[(x + s - px) % s];
        }
    }

    /// Tightest cluster among ones, or largest void among zeros.
    fn extreme(self: *const VoidCluster, ones: bool) u32 {
        var best: u32 = 0;
        var best_e: f32 = if (ones) -std.math.inf(f32) else std.math.inf(f32);
        for (self.energy, self.bits, 0..) |e, b, i| {
            if (b != ones) continue;
            if ((ones and e > best_e) or (!ones and e < best_e)) {
                best_e = e;
                best = @intCast(i);
            }
        }
        return best;
    }
};

fn cellAverage(gpa: Allocator, r: *const Raster, cell: u32) !Raster {
    const w = (r.w + cell - 1) / cell;
    const h = (r.h + cell - 1) / cell;
    var out: Raster = try .init(gpa, w, h, .{ 0, 0, 0 });
    const counts = try gpa.alloc(f32, @as(usize, w) * h);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (0..r.h) |y| for (0..r.w) |x| {
        const i = (y / cell) * w + x / cell;
        common.setPixel(&out, i, common.pixel(&out, i) + common.pixel(r, y * r.w + x));
        counts[i] += 1;
    };
    for (counts, 0..) |c, i| common.setPixel(&out, i, common.pixel(&out, i) / @as(V3, @splat(c)));
    return out;
}

test "dither: bayer 2x2 matrix has the classic order" {
    const gpa = std.testing.allocator;
    const m: ThresholdMap = try .bayer(gpa, 2);
    defer gpa.free(m.t);
    // Ranks 0 2 / 3 1, as thresholds (rank + 0.5) / 4.
    try std.testing.expectEqualSlices(f32, &.{ 0.125, 0.625, 0.875, 0.375 }, m.t);
}

test "dither: bayer 4x4 is a permutation of all ranks" {
    const gpa = std.testing.allocator;
    const m: ThresholdMap = try .bayer(gpa, 4);
    defer gpa.free(m.t);
    var seen: [16]bool = @splat(false);
    for (m.t) |t| seen[@intFromFloat(t * 16 - 0.5)] = true;
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expectEqual(@as(f32, 0.5 / 16.0), m.t[0]);
    try std.testing.expectEqual(@as(f32, 8.5 / 16.0), m.t[1]);
}

test "dither: blue noise map is a permutation with no clumped neighbours" {
    const gpa = std.testing.allocator;
    const m: ThresholdMap = try .blueNoise(gpa, 16, blue_seed);
    defer gpa.free(m.t);
    var seen: [256]bool = @splat(false);
    for (m.t) |t| seen[@intFromFloat(t * 256 - 0.5)] = true;
    for (seen) |s| try std.testing.expect(s);
    // The darkest 10% should never touch each other.
    for (0..16) |y| for (0..16) |x| {
        if (m.at(@intCast(x), @intCast(y)) >= 0.1) continue;
        try std.testing.expect(m.at(@intCast(x + 1), @intCast(y)) >= 0.1);
        try std.testing.expect(m.at(@intCast(x), @intCast(y + 1)) >= 0.1);
    };
}

test "dither: posterize rounds to levels" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 1, .{ 0.2, 0.4, 0.9 });
    defer r.deinit(gpa);
    try apply(gpa, &r, &.{ .method = .none, .levels = 3 }, .whole(&r, 1));
    try std.testing.expectEqual(Rgb{ 0, 0.5, 1 }, r.get(0, 0));
}

test "dither: bayer 50% gray to two levels is half on" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 4, .{ 0.5, 0.5, 0.5 });
    defer r.deinit(gpa);
    try apply(gpa, &r, &.{ .method = .bayer, .matrix = 4 }, .whole(&r, 1));
    var on: u32 = 0;
    for (0..16) |i| on += @intFromFloat(r.pix[i * 3]);
    try std.testing.expectEqual(@as(u32, 8), on);
}

test "dither: floyd keeps the average and uses only palette colors" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 8, 8, .{ 0.25, 0.25, 0.25 });
    defer r.deinit(gpa);
    const palette = [_]Rgb{ .{ 0, 0, 0 }, .{ 1, 1, 1 } };
    try apply(gpa, &r, &.{ .method = .floyd, .palette = &palette }, .whole(&r, 1));
    var on: u32 = 0;
    for (0..64) |i| {
        const c = r.get(@intCast(i % 8), @intCast(i / 8));
        try std.testing.expect(c[0] == c[1] and c[1] == c[2]);
        try std.testing.expect(c[0] == 0 or c[0] == 1);
        on += @intFromFloat(c[0]);
    }
    try std.testing.expect(on >= 15 and on <= 17);
}

test "dither: cell makes uniform blocks of cell pixels" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 4, .{ 0.5, 0.5, 0.5 });
    defer r.deinit(gpa);
    // One scene unit at scale 2 is a 2x2 dot.
    try apply(gpa, &r, &.{ .method = .bayer, .matrix = 2, .cell = 1 }, .whole(&r, 2));
    for (0..2) |cy| for (0..2) |cx| {
        const v = r.get(@intCast(cx * 2), @intCast(cy * 2));
        try std.testing.expectEqual(v, r.get(@intCast(cx * 2 + 1), @intCast(cy * 2 + 1)));
    };
    try std.testing.expectEqual(Rgb{ 0, 0, 0 }, r.get(0, 0));
    try std.testing.expectEqual(Rgb{ 1, 1, 1 }, r.get(2, 0));
}
