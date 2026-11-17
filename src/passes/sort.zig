//! Pixel sorting. The image is cut into parallel lines at an angle, each
//! line into runs of selected pixels, and each run is sorted by a key.

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const Raster = @import("../Raster.zig");
const common = @import("common.zig");

const Frame = common.Frame;
const Rgb = common.Rgb;

pub const Key = enum {
    luma,
    hue,
    sat,
    r,
    g,
    b,

    pub fn of(self: Key, c: Rgb) f32 {
        return switch (self) {
            .luma => Raster.luminance(c),
            .hue => common.hue(c),
            .sat => common.saturation(c),
            .r => c[0],
            .g => c[1],
            .b => c[2],
        };
    }
};

pub const PixelSort = struct {
    /// Degrees. 0 runs along rows left to right, 90 down columns.
    angle: f64 = 0,
    /// Selects which pixels join a run, through the lo..hi window.
    key: Key = .luma,
    /// The value runs are ordered by.
    sort_by: Key = .luma,
    /// With lo > hi the window selects values outside hi..lo.
    lo: f32 = 0.25,
    hi: f32 = 0.8,
    /// Replaces the key window: a pixel is selected where the mask,
    /// stretched over the image, is at least `mask_threshold`.
    mask: ?*const Field = null,
    mask_threshold: f32 = 0.5,
    reverse: bool = false,
    /// Scene units. Shorter runs are left alone.
    length_min: f64 = 0,
    /// Scene units. Longer runs are cut. 0 means no limit.
    length_max: f64 = 0,
    /// 0..1. Each run's limit shrinks by up to this fraction at random.
    jitter: f32 = 0,
    /// Probability that a run is sorted at all.
    chance: f32 = 1,
    seed: u64 = 1,
    /// Null sorts runs fully. A count stops the sort after that many
    /// odd-even transposition passes, so a pixel moves at most that far.
    passes: ?u32 = null,
    /// Scales `passes` per run by the field's mean over the run, clamped
    /// to 0..1, so the partial sort can vary across the image.
    passes_field: ?*const Field = null,
};

const SortKey = packed struct(u64) {
    index: u32,
    key: u32,
};

pub fn apply(gpa: Allocator, r: *Raster, p: *const PixelSort, frame: Frame) !void {
    assert(@as(u64, r.w) * r.h < std.math.maxInt(u32));
    const rad = std.math.degreesToRadians(p.angle);
    const dir_x = math.cos(rad);
    const dir_y = math.sin(rad);
    const steep = @abs(dir_y) > @abs(dir_x);
    const primary = if (steep) dir_y else dir_x;
    const secondary = if (steep) dir_x else dir_y;
    const n: u32 = if (steep) r.h else r.w;
    const m: u32 = if (steep) r.w else r.h;
    const forward = primary >= 0;
    const slope = secondary / @abs(primary);

    const offsets = try gpa.alloc(i32, n);
    defer gpa.free(offsets);
    for (offsets, 0..) |*o, k| o.* = @intFromFloat(@round(@as(f64, @floatFromInt(k)) * slope));
    const off_lo: i64 = @min(0, offsets[n - 1]);
    const off_hi: i64 = @max(0, offsets[n - 1]);

    var line: Line = try .init(gpa, n);
    defer line.deinit(gpa);

    var prng: std.Random.DefaultPrng = .init(p.seed);
    const rand = prng.random();
    const len_min: u32 = @intCast(frame.pxInt(p.length_min, 0));
    const len_max: u32 = if (p.length_max > 0) @intCast(frame.pxInt(p.length_max, 1)) else n;

    var q0: i64 = -off_hi;
    while (q0 < @as(i64, m) - off_lo) : (q0 += 1) {
        line.len = 0;
        for (0..n) |k| {
            const q = q0 + offsets[k];
            if (q < 0 or q >= m) continue;
            const pk: u32 = if (forward) @intCast(k) else n - 1 - @as(u32, @intCast(k));
            const qk: u32 = @intCast(q);
            const x = if (steep) qk else pk;
            const y = if (steep) pk else qk;
            line.push(r, p, frame, x, y);
        }
        line.sortRuns(r, p, rand, len_min, len_max);
    }
}

const Line = struct {
    pix: []u32,
    color: []Rgb,
    selected: []bool,
    keys: []u64,
    /// passes_field sampled at each pixel, when there is one.
    weight: []f32,
    len: u32 = 0,

    fn init(gpa: Allocator, n: u32) !Line {
        const pix = try gpa.alloc(u32, n);
        errdefer gpa.free(pix);
        const color = try gpa.alloc(Rgb, n);
        errdefer gpa.free(color);
        const selected = try gpa.alloc(bool, n);
        errdefer gpa.free(selected);
        const keys = try gpa.alloc(u64, n);
        errdefer gpa.free(keys);
        const weight = try gpa.alloc(f32, n);
        return .{ .pix = pix, .color = color, .selected = selected, .keys = keys, .weight = weight };
    }

    fn deinit(self: *Line, gpa: Allocator) void {
        gpa.free(self.pix);
        gpa.free(self.color);
        gpa.free(self.selected);
        gpa.free(self.keys);
        gpa.free(self.weight);
        self.* = undefined;
    }

    fn push(self: *Line, r: *const Raster, p: *const PixelSort, frame: Frame, x: u32, y: u32) void {
        const i = self.len;
        const c = r.get(x, y);
        self.pix[i] = y * r.w + x;
        self.color[i] = c;
        self.selected[i] = if (p.mask) |mask|
            frame.sampleField(mask, @floatFromInt(x), @floatFromInt(y)) >= p.mask_threshold
        else blk: {
            const v = p.key.of(c);
            break :blk if (p.lo <= p.hi) v >= p.lo and v <= p.hi else v >= p.lo or v <= p.hi;
        };
        if (p.passes_field) |f| self.weight[i] = frame.sampleField(f, @floatFromInt(x), @floatFromInt(y));
        self.len += 1;
    }

    fn sortRuns(self: *Line, r: *Raster, p: *const PixelSort, rand: std.Random, len_min: u32, len_max: u32) void {
        var k: u32 = 0;
        while (k < self.len) {
            if (!self.selected[k]) {
                k += 1;
                continue;
            }
            const cap: u32 = if (p.jitter > 0)
                @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(len_max)) * (1 - p.jitter * rand.float(f32)))))
            else
                len_max;
            const start = k;
            while (k < self.len and self.selected[k] and k - start < cap) k += 1;
            const run_len = k - start;
            if (run_len < 2 or run_len < len_min) continue;
            if (p.chance < 1 and rand.float(f32) >= p.chance) continue;
            self.sortRun(r, p, start, run_len);
        }
    }

    fn sortRun(self: *Line, r: *Raster, p: *const PixelSort, start: u32, run_len: u32) void {
        const keys = self.keys[0..run_len];
        for (keys, 0..) |*key, j| {
            const v = std.math.clamp(p.sort_by.of(self.color[start + j]), 0, 1);
            const sk: SortKey = .{ .index = @intCast(j), .key = @intFromFloat(v * 16777215) };
            key.* = @bitCast(sk);
        }
        if (p.passes) |passes| {
            oddEvenTransposition(keys, self.runPasses(p, passes, start, run_len), p.reverse);
            for (keys, start..) |key, target| {
                const sk: SortKey = @bitCast(key);
                const i = @as(usize, self.pix[target]) * 3;
                r.pix[i..][0..3].* = self.color[start + sk.index];
            }
            return;
        }
        std.mem.sortUnstable(u64, keys, {}, std.sort.asc(u64));
        for (keys, 0..) |key, j| {
            const sk: SortKey = @bitCast(key);
            const target = if (p.reverse) start + run_len - 1 - @as(u32, @intCast(j)) else start + @as(u32, @intCast(j));
            const i = @as(usize, self.pix[target]) * 3;
            r.pix[i..][0..3].* = self.color[start + sk.index];
        }
    }

    fn runPasses(self: *const Line, p: *const PixelSort, passes: u32, start: u32, run_len: u32) u32 {
        if (p.passes_field == null) return passes;
        var sum: f64 = 0;
        for (self.weight[start..][0..run_len]) |w| sum += w;
        const mean = std.math.clamp(sum / @as(f64, @floatFromInt(run_len)), 0, 1);
        return @intFromFloat(@round(@as(f64, @floatFromInt(passes)) * mean));
    }
};

/// Odd-even transposition sort (Habermann 1972, "Parallel neighbor-sort"),
/// stopped after `passes` passes. Each pass swaps out-of-order neighbors
/// over disjoint pairs, alternating pairs that start at even and odd
/// indexes, so an element moves at most one place per pass. keys.len
/// passes sort fully. Keys carry their run index in the low bits, so none
/// are equal and descending order is the full sort reversed.
fn oddEvenTransposition(keys: []u64, passes: u32, descending: bool) void {
    const count = @min(passes, keys.len);
    for (0..count) |pass| {
        var i = pass % 2;
        while (i + 1 < keys.len) : (i += 2) {
            const a = keys[i];
            const b = keys[i + 1];
            if (if (descending) a < b else a > b) {
                keys[i] = b;
                keys[i + 1] = a;
            }
        }
    }
}

fn rowLumas(r: *const Raster, y: u32, out: []f32) void {
    for (out, 0..) |*v, x| v.* = Raster.luminance(r.get(@intCast(x), y));
}

test "pixelSort: sorts the selected run of a row by luma" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 6, 1, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    // 0 is outside the window, so the run is x = 1..4 and x = 5 stays.
    const row = [_]f32{ 0, 0.9, 0.3, 0.6, 0.4, 0 };
    for (row, 0..) |v, x| r.set(@intCast(x), 0, .{ v, v, v });
    try apply(gpa, &r, &.{ .lo = 0.1, .hi = 1 }, .whole(&r, 1));
    var got: [6]f32 = undefined;
    rowLumas(&r, 0, &got);
    const want = [_]f32{ 0, 0.3, 0.4, 0.6, 0.9, 0 };
    for (want, got) |w, g| try std.testing.expectApproxEqAbs(w, g, 1e-5);
}

test "pixelSort: reverse and column direction" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 4, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    const col = [_]f32{ 0.2, 0.5, 0.3, 0.7 };
    for (col, 0..) |v, y| r.set(0, @intCast(y), .{ v, v, v });
    try apply(gpa, &r, &.{ .angle = 90, .lo = 0, .hi = 1, .reverse = true }, .whole(&r, 1));
    const want = [_]f32{ 0.7, 0.5, 0.3, 0.2 };
    for (want, 0..) |w, y| try std.testing.expectApproxEqAbs(w, r.get(0, @intCast(y))[0], 1e-5);
}

test "pixelSort: angle 180 sorts right to left" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 3, 1, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    const row = [_]f32{ 0.2, 0.9, 0.5 };
    for (row, 0..) |v, x| r.set(@intCast(x), 0, .{ v, v, v });
    try apply(gpa, &r, &.{ .angle = 180, .lo = 0, .hi = 1 }, .whole(&r, 1));
    const want = [_]f32{ 0.9, 0.5, 0.2 };
    for (want, 0..) |w, x| try std.testing.expectApproxEqAbs(w, r.get(@intCast(x), 0)[0], 1e-5);
}

test "pixelSort: length_max cuts runs, scaled to pixels" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 1, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    const row = [_]f32{ 0.9, 0.3, 0.8, 0.2 };
    for (row, 0..) |v, x| r.set(@intCast(x), 0, .{ v, v, v });
    // One scene unit is two pixels, so runs are {0.9, 0.3} and {0.8, 0.2}.
    try apply(gpa, &r, &.{ .lo = 0, .hi = 1, .length_max = 1 }, .whole(&r, 2));
    const want = [_]f32{ 0.3, 0.9, 0.2, 0.8 };
    for (want, 0..) |w, x| try std.testing.expectApproxEqAbs(w, r.get(@intCast(x), 0)[0], 1e-5);
}

test "pixelSort: diagonal lines permute pixels without loss" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 5, 3, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    for (0..3) |y| for (0..5) |x| {
        const v: f32 = @floatFromInt(y * 5 + x);
        r.set(@intCast(x), @intCast(y), .{ v / 16, 0, 0 });
    };
    try apply(gpa, &r, &.{ .angle = 30, .key = .r, .sort_by = .r, .lo = 0, .hi = 1, .reverse = true }, .whole(&r, 1));
    var seen: [15]f32 = undefined;
    for (&seen, 0..) |*v, i| v.* = r.pix[i * 3] * 16;
    std.mem.sort(f32, &seen, {}, std.sort.asc(f32));
    for (seen, 0..) |v, i| try std.testing.expectEqual(@as(f32, @floatFromInt(i)), v);
    try std.testing.expect(r.get(0, 0)[0] != 0);
}

fn rampRow(gpa: Allocator, values: []const f32) !Raster {
    var r: Raster = try .init(gpa, @intCast(values.len), 1, .{ 0, 0, 0 });
    for (values, 0..) |v, x| r.set(@intCast(x), 0, .{ v, v, v });
    return r;
}

fn inversions(r: *const Raster) u32 {
    var count: u32 = 0;
    for (0..r.w) |i| for (i + 1..r.w) |j| {
        count += @intFromBool(r.get(@intCast(i), 0)[0] > r.get(@intCast(j), 0)[0]);
    };
    return count;
}

const descending_ramp = [_]f32{ 0.95, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6, 0.55, 0.5, 0.45, 0.4, 0.35, 0.3, 0.25, 0.2 };

test "pixelSort: zero passes leaves the image unchanged" {
    const gpa = std.testing.allocator;
    var r = try rampRow(gpa, &descending_ramp);
    defer r.deinit(gpa);
    try apply(gpa, &r, &.{ .lo = 0, .hi = 1, .passes = 0 }, .whole(&r, 1));
    for (descending_ramp, 0..) |v, x| try std.testing.expectEqual(v, r.get(@intCast(x), 0)[0]);
}

test "pixelSort: enough passes equal the full sort, forward and reversed" {
    const gpa = std.testing.allocator;
    // Pixels 1 and 4 share a red key with different green, so ties must
    // land as the full sort puts them.
    const row = [_]Rgb{ .{ 0.6, 0, 0 }, .{ 0.3, 0.1, 0 }, .{ 0.9, 0, 0 }, .{ 0.2, 0, 0 }, .{ 0.3, 0.7, 0 }, .{ 0.5, 0, 0 } };
    for ([_]bool{ false, true }) |reverse| {
        var full: Raster = try .init(gpa, row.len, 1, .{ 0, 0, 0 });
        defer full.deinit(gpa);
        var partial: Raster = try .init(gpa, row.len, 1, .{ 0, 0, 0 });
        defer partial.deinit(gpa);
        for (row, 0..) |c, x| {
            full.set(@intCast(x), 0, c);
            partial.set(@intCast(x), 0, c);
        }
        const opts: PixelSort = .{ .key = .r, .sort_by = .r, .lo = 0, .hi = 1, .reverse = reverse };
        try apply(gpa, &full, &opts, .whole(&full, 1));
        var many = opts;
        many.passes = 1000;
        try apply(gpa, &partial, &many, .whole(&partial, 1));
        try std.testing.expectEqualSlices(f32, full.pix, partial.pix);
    }
}

test "pixelSort: a few passes sort partway and move pixels at most that far" {
    const gpa = std.testing.allocator;
    var r = try rampRow(gpa, &descending_ramp);
    defer r.deinit(gpa);
    const before = inversions(&r);
    try std.testing.expectEqual(@as(u32, 120), before);
    const passes = 4;
    try apply(gpa, &r, &.{ .lo = 0, .hi = 1, .passes = passes }, .whole(&r, 1));
    const after = inversions(&r);
    try std.testing.expect(after > 0);
    try std.testing.expect(after < before);
    for (0..r.w) |x| {
        const v = r.get(@intCast(x), 0)[0];
        const from = std.mem.indexOfScalar(f32, &descending_ramp, v).?;
        try std.testing.expect(@max(from, x) - @min(from, x) <= passes);
    }
}

test "pixelSort: passesField scales the pass count by its mean" {
    const gpa = std.testing.allocator;
    var half: Field = try .init(gpa, 2, 2, 0.5);
    defer half.deinit(gpa);
    var zero: Field = try .init(gpa, 2, 2, 0);
    defer zero.deinit(gpa);

    var scaled = try rampRow(gpa, &descending_ramp);
    defer scaled.deinit(gpa);
    try apply(gpa, &scaled, &.{ .lo = 0, .hi = 1, .passes = 8, .passes_field = &half }, .whole(&scaled, 1));
    var direct = try rampRow(gpa, &descending_ramp);
    defer direct.deinit(gpa);
    try apply(gpa, &direct, &.{ .lo = 0, .hi = 1, .passes = 4 }, .whole(&direct, 1));
    try std.testing.expectEqualSlices(f32, direct.pix, scaled.pix);

    var still = try rampRow(gpa, &descending_ramp);
    defer still.deinit(gpa);
    try apply(gpa, &still, &.{ .lo = 0, .hi = 1, .passes = 8, .passes_field = &zero }, .whole(&still, 1));
    try std.testing.expectEqual(@as(u32, 120), inversions(&still));
}
