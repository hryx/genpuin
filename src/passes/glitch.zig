//! Passes that move pixels around: channel shift, displacement, slab
//! tears and datamosh-style block repeats.

const std = @import("std");
const libm = @import("../libm.zig");
const Allocator = std.mem.Allocator;

const Field = @import("../Field.zig");
const Raster = @import("../Raster.zig");
const common = @import("common.zig");

const Frame = common.Frame;
const V3 = common.V3;

pub const Axis = enum { x, y };

pub const ChannelShift = struct {
    /// Scene-unit offsets for red, green and blue.
    offsets: [3][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
    /// Wrap around the edges instead of clamping to them.
    wrap: bool = false,
};

pub fn channelShift(gpa: Allocator, r: *Raster, p: *const ChannelShift, frame: Frame) !void {
    var src = try r.clone(gpa);
    defer src.deinit(gpa);
    const w: i64 = r.w;
    const h: i64 = r.h;
    for (p.offsets, 0..) |off, ch| {
        const dx = frame.pxInt(off[0], std.math.minInt(i64));
        const dy = frame.pxInt(off[1], std.math.minInt(i64));
        if (dx == 0 and dy == 0) continue;
        for (0..r.h) |y| {
            const sy = edge(@as(i64, @intCast(y)) - dy, h, p.wrap);
            for (0..r.w) |x| {
                const sx = edge(@as(i64, @intCast(x)) - dx, w, p.wrap);
                r.pix[r.index(@intCast(x), @intCast(y)) + ch] = src.pix[src.index(sx, sy) + ch];
            }
        }
    }
}

fn edge(v: i64, len: i64, wrap: bool) u32 {
    return @intCast(if (wrap) @mod(v, len) else std.math.clamp(v, 0, len - 1));
}

pub const Displace = struct {
    /// Fields stretched over the image. A value of 0.5 is no move, 0 and
    /// 1 move by minus and plus `amount`.
    field_x: ?*const Field = null,
    field_y: ?*const Field = null,
    /// Scene units.
    amount: f64 = 10,
    /// Sine displacement in scene units. Rows move along x by
    /// amp_x * sin(2 pi y / period_x + phase), columns along y likewise.
    amp_x: f64 = 0,
    period_x: f64 = 100,
    amp_y: f64 = 0,
    period_y: f64 = 100,
    phase: f64 = 0,
};

pub fn displace(gpa: Allocator, r: *Raster, p: *const Displace, frame: Frame) !void {
    var src = try r.clone(gpa);
    defer src.deinit(gpa);
    const amount = frame.px(p.amount) * 2;
    const tau = 2 * std.math.pi;
    const kx = tau / @max(1e-9, frame.px(p.period_x));
    const ky = tau / @max(1e-9, frame.px(p.period_y));
    const ax = frame.px(p.amp_x);
    const ay = frame.px(p.amp_y);
    for (0..r.h) |yi| {
        const y: f64 = @floatFromInt(yi);
        const gy = y + @as(f64, @floatFromInt(frame.y0));
        const wave_x = ax * libm.sin(gy * kx + p.phase);
        for (0..r.w) |xi| {
            const x: f64 = @floatFromInt(xi);
            const gx = x + @as(f64, @floatFromInt(frame.x0));
            var dx = wave_x;
            var dy = ay * libm.sin(gx * ky + p.phase);
            if (p.field_x) |f| dx += (frame.sampleField(f, x, y) - 0.5) * amount;
            if (p.field_y) |f| dy += (frame.sampleField(f, x, y) - 0.5) * amount;
            const c = common.sampleBilinear(&src, @floatCast(x - dx), @floatCast(y - dy));
            r.set(@intCast(xi), @intCast(yi), c);
        }
    }
}

pub const Tear = struct {
    /// x shifts bands of rows sideways, y shifts bands of columns.
    axis: Axis = .x,
    /// Band thickness range in scene units.
    height_min: f64 = 2,
    height_max: f64 = 30,
    /// Shift magnitude range in scene units. The sign is random.
    shift_min: f64 = 5,
    shift_max: f64 = 80,
    /// Probability that a band moves.
    chance: f32 = 0.3,
    wrap: bool = true,
    seed: u64 = 1,
};

pub fn tear(gpa: Allocator, r: *Raster, p: *const Tear, frame: Frame) !void {
    const n: u32 = if (p.axis == .x) r.w else r.h;
    const bands: u32 = if (p.axis == .x) r.h else r.w;
    const buf = try gpa.alloc(f32, @as(usize, n) * 3);
    defer gpa.free(buf);
    var prng: std.Random.DefaultPrng = .init(p.seed);
    const rand = prng.random();
    const h_lo = frame.px(@min(p.height_min, p.height_max));
    const h_hi = frame.px(@max(p.height_min, p.height_max));
    const s_lo = frame.px(@min(p.shift_min, p.shift_max));
    const s_hi = frame.px(@max(p.shift_min, p.shift_max));

    var start: u32 = 0;
    while (start < bands) {
        const thick: u32 = @intFromFloat(@max(1, @round(h_lo + (h_hi - h_lo) * rand.float(f64))));
        const end = @min(bands, start + thick);
        const moves = rand.float(f32) < p.chance;
        const mag = s_lo + (s_hi - s_lo) * rand.float(f64);
        const shift: i64 = @intFromFloat(@round(if (rand.boolean()) mag else -mag));
        if (moves and shift != 0) {
            for (start..end) |b| shiftLine(r, p, buf, @intCast(b), shift);
        }
        start = end;
    }
}

fn shiftLine(r: *Raster, p: *const Tear, buf: []f32, b: u32, shift: i64) void {
    const n: i64 = @intCast(buf.len / 3);
    for (0..buf.len / 3) |k| {
        const i = lineIndex(r, p.axis, b, @intCast(k));
        buf[k * 3 ..][0..3].* = r.pix[i..][0..3].*;
    }
    for (0..buf.len / 3) |k| {
        const s = edge(@as(i64, @intCast(k)) - shift, n, p.wrap);
        const i = lineIndex(r, p.axis, b, @intCast(k));
        r.pix[i..][0..3].* = buf[@as(usize, s) * 3 ..][0..3].*;
    }
}

fn lineIndex(r: *const Raster, axis: Axis, b: u32, k: u32) usize {
    return switch (axis) {
        .x => r.index(k, b),
        .y => r.index(b, k),
    };
}

pub const BlockMode = enum {
    /// Copy a block from a random place elsewhere.
    copy,
    /// Repeat the block's left column across it, streaking along x.
    smear_x,
    /// Repeat the block's top row down it, streaking along y.
    smear_y,
    /// Pick one of the above per block.
    mixed,
};

pub const BlockRepeat = struct {
    count: u32 = 40,
    /// Block side range in scene units.
    size_min: f64 = 10,
    size_max: f64 = 80,
    /// Scene units. Snap block corners and sizes to this grid, like codec
    /// macroblocks. 0 turns snapping off.
    grid: f64 = 0,
    mode: BlockMode = .mixed,
    seed: u64 = 1,
};

pub fn blockRepeat(gpa: Allocator, r: *Raster, p: *const BlockRepeat, frame: Frame) !void {
    _ = gpa;
    var prng: std.Random.DefaultPrng = .init(p.seed);
    const rand = prng.random();
    const lo = frame.px(@min(p.size_min, p.size_max));
    const hi = frame.px(@max(p.size_min, p.size_max));
    const grid: u32 = @intCast(frame.pxInt(p.grid, 1));
    for (0..p.count) |_| {
        const bw = snap(lo + (hi - lo) * rand.float(f64), grid, r.w);
        const bh = snap(lo + (hi - lo) * rand.float(f64), grid, r.h);
        const x = snapPos(rand.uintLessThan(u32, r.w - bw + 1), grid);
        const y = snapPos(rand.uintLessThan(u32, r.h - bh + 1), grid);
        const mode: BlockMode = switch (p.mode) {
            .mixed => switch (rand.uintLessThan(u32, 3)) {
                0 => .copy,
                1 => .smear_x,
                else => .smear_y,
            },
            .copy, .smear_x, .smear_y => p.mode,
        };
        switch (mode) {
            .copy => {
                const sx = snapPos(rand.uintLessThan(u32, r.w - bw + 1), grid);
                const sy = snapPos(rand.uintLessThan(u32, r.h - bh + 1), grid);
                copyBlock(r, sx, sy, x, y, bw, bh);
            },
            .smear_x => for (y..y + bh) |yy| {
                const c = r.get(x, @intCast(yy));
                for (x..x + bw) |xx| r.set(@intCast(xx), @intCast(yy), c);
            },
            .smear_y => for (y + 1..y + bh) |yy| {
                const row = r.index(x, y);
                const i = r.index(x, @intCast(yy));
                @memcpy(r.pix[i..][0 .. bw * 3], r.pix[row..][0 .. bw * 3]);
            },
            .mixed => unreachable, // resolved by the switch above
        }
    }
}

fn snap(v: f64, grid: u32, limit: u32) u32 {
    const g: f64 = @floatFromInt(grid);
    const s: u32 = @intFromFloat(@max(g, @round(v / g) * g));
    return @min(s, limit);
}

fn snapPos(v: u32, grid: u32) u32 {
    return v / grid * grid;
}

fn copyBlock(r: *Raster, sx: u32, sy: u32, tx: u32, ty: u32, bw: u32, bh: u32) void {
    // Source and target may overlap. Walk rows and pixels in the order
    // that never reads something already written.
    for (0..bh) |k| {
        const row: u32 = @intCast(if (ty > sy) bh - 1 - k else k);
        const s = r.index(sx, sy + row);
        const t = r.index(tx, ty + row);
        const source = r.pix[s..][0 .. bw * 3];
        const target = r.pix[t..][0 .. bw * 3];
        if (t <= s) std.mem.copyForwards(f32, target, source) else std.mem.copyBackwards(f32, target, source);
    }
}

fn redRow(r: *const Raster, y: u32, out: []f32) void {
    for (out, 0..) |*v, x| v.* = r.get(@intCast(x), y)[0];
}

test "channelShift: moves only the shifted channel, in scene units" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 6, 1, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(1, 0, .{ 1, 1, 1 });
    try channelShift(gpa, &r, &.{ .offsets = .{ .{ 1.5, 0 }, .{ 0, 0 }, .{ -0.5, 0 } } }, .whole(&r, 2));
    try std.testing.expectEqual(common.Rgb{ 0, 1, 0 }, r.get(1, 0));
    try std.testing.expectEqual(common.Rgb{ 1, 0, 0 }, r.get(4, 0));
    try std.testing.expectEqual(common.Rgb{ 0, 0, 1 }, r.get(0, 0));
}

test "channelShift: wrap brings pixels round the edge" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 1, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(3, 0, .{ 1, 0, 0 });
    try channelShift(gpa, &r, &.{ .offsets = .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 0 } }, .wrap = true }, .whole(&r, 1));
    var got: [4]f32 = undefined;
    redRow(&r, 0, &got);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 0 }, got);
}

test "displace: sine wave shifts rows by whole pixels" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 8, 2, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(2, 0, .{ 1, 1, 1 });
    r.set(2, 1, .{ 1, 1, 1 });
    // period 4 puts row 1 at the sine peak, so row 1 moves by 2 pixels
    // and row 0 stays.
    try displace(gpa, &r, &.{ .amp_x = 2, .period_x = 4 }, .whole(&r, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.get(2, 0)[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.get(4, 1)[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.get(2, 1)[0], 1e-5);
}

test "displace: field offsets sample bilinearly" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 1, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    for (0..4) |x| r.set(@intCast(x), 0, @splat(@as(f32, @floatFromInt(x))));
    var f: Field = try .init(gpa, 1, 1, 0.25);
    defer f.deinit(gpa);
    // (0.25 - 0.5) * 2 * 1 = -0.5, so each pixel reads half a pixel right.
    try displace(gpa, &r, &.{ .field_x = &f, .amount = 1 }, .whole(&r, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.get(0, 0)[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), r.get(2, 0)[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), r.get(3, 0)[0], 1e-5);
}

test "tear: every band moves by the fixed shift with wrap" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 3, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    for (0..3) |y| r.set(0, @intCast(y), .{ 1, 0, 0 });
    try tear(gpa, &r, &.{ .chance = 1, .shift_min = 1, .shift_max = 1, .height_min = 1, .height_max = 1 }, .whole(&r, 1));
    for (0..3) |y| {
        var got: [4]f32 = undefined;
        redRow(&r, @intCast(y), &got);
        const right = std.mem.eql(f32, &got, &.{ 0, 1, 0, 0 });
        const left = std.mem.eql(f32, &got, &.{ 0, 0, 0, 1 });
        try std.testing.expect(right or left);
    }
}

test "tear: chance 0 leaves the image alone" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 3, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(0, 1, .{ 1, 0, 0 });
    try tear(gpa, &r, &.{ .chance = 0 }, .whole(&r, 1));
    try std.testing.expectEqual(common.Rgb{ 1, 0, 0 }, r.get(0, 1));
}

test "blockRepeat: smear_x fills a whole-image block with its left column" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 3, 2, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(0, 0, .{ 1, 0, 0 });
    r.set(0, 1, .{ 0, 1, 0 });
    try blockRepeat(gpa, &r, &.{ .count = 1, .size_min = 3, .size_max = 3, .mode = .smear_x }, .whole(&r, 1));
    for (0..3) |x| {
        try std.testing.expectEqual(common.Rgb{ 1, 0, 0 }, r.get(@intCast(x), 0));
        try std.testing.expectEqual(common.Rgb{ 0, 1, 0 }, r.get(@intCast(x), 1));
    }
}

test "blockRepeat: overlapping copy reads the original rows" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 1, 4, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    for (0..4) |y| r.set(0, @intCast(y), @splat(@as(f32, @floatFromInt(y))));
    copyBlock(&r, 0, 0, 0, 1, 1, 3);
    for ([_]f32{ 0, 0, 1, 2 }, 0..) |want, y| try std.testing.expectEqual(want, r.get(0, @intCast(y))[0]);
    copyBlock(&r, 0, 1, 0, 0, 1, 3);
    for ([_]f32{ 0, 1, 2, 2 }, 0..) |want, y| try std.testing.expectEqual(want, r.get(0, @intCast(y))[0]);
}
