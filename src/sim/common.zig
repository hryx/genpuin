//! Small pieces shared by the simulations.

const std = @import("std");
const assert = std.debug.assert;

const Field = @import("../Field.zig");

pub const Vec2 = [2]f64;

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn contains(r: Rect, p: Vec2) bool {
        return p[0] >= r.x and p[1] >= r.y and p[0] <= r.x + r.w and p[1] <= r.y + r.h;
    }

    pub fn clamp(r: Rect, p: Vec2) Vec2 {
        return .{ std.math.clamp(p[0], r.x, r.x + r.w), std.math.clamp(p[1], r.y, r.y + r.h) };
    }
};

/// Where a simulation may spread a step's independent parts.
/// `workers_max` counts the calling thread, so 1 is sequential.
pub const Threads = struct {
    io: std.Io,
    workers_max: u32,
};

/// Run `func(ctx, start, end)` over [0, len) cut into contiguous bands.
/// Each call must write only inside its own band and read nothing another
/// band writes, so the result is the same for any band count. Workers,
/// the calling thread among them, take bands from a shared counter, a few
/// per worker so a slow core does not hold up the rest. `handoff_len` is
/// how many items take as long as starting one worker. With null
/// `threads` there is one band.
pub fn forBands(threads: ?Threads, len: usize, handoff_len: usize, ctx: anytype, comptime func: fn (@TypeOf(ctx), usize, usize) void) void {
    assert(handoff_len > 0);
    const t = threads orelse return func(ctx, 0, len);
    const workers = workerCount(t.workers_max, len, handoff_len);
    if (workers <= 1) return func(ctx, 0, len);

    const Bands = struct {
        ctx: @TypeOf(ctx),
        len: usize,
        count: usize,
        next: std.atomic.Value(usize) = .init(0),

        fn work(b: *@This()) void {
            while (true) {
                const i = b.next.fetchAdd(1, .monotonic);
                if (i >= b.count) return;
                func(b.ctx, b.len * i / b.count, b.len * (i + 1) / b.count);
            }
        }
    };
    var bands: Bands = .{ .ctx = ctx, .len = len, .count = @min(len, workers * bands_per_worker) };
    var group: std.Io.Group = .init;
    for (1..workers) |_| {
        group.concurrent(t.io, Bands.work, .{&bands}) catch group.async(t.io, Bands.work, .{&bands});
    }
    bands.work();
    // The bands have no cancelation points, so every one has finished
    // here either way. Leave the request for the caller's next one.
    group.await(t.io) catch |err| switch (err) {
        error.Canceled => t.io.recancel(),
    };
}

const bands_per_worker = 4;

/// How many workers forBands uses. They start one after another, so k
/// of them finish len items in about len / k + k * handoff_len, which is
/// least at k = sqrt(len / handoff_len).
pub fn workerCount(workers_max: u32, len: usize, handoff_len: usize) u32 {
    return @min(workers_max, std.math.sqrt(len / handoff_len));
}

/// A Field read over a rect in point units. A point is inside when the
/// bilinear sample there is above one half.
pub const Mask = struct {
    field: *const Field,
    rect: Rect,

    pub fn allows(m: Mask, p: Vec2) bool {
        if (!m.rect.contains(p)) return false;
        const u = (p[0] - m.rect.x) / m.rect.w * @as(f64, @floatFromInt(m.field.w));
        const v = (p[1] - m.rect.y) / m.rect.h * @as(f64, @floatFromInt(m.field.h));
        return m.field.sample(u, v) > 0.5;
    }
};

/// Fill a w x h grid from `source`, stretched bilinearly when the sizes differ.
pub fn resample(target: []f32, w: u32, h: u32, source: *const Field) void {
    assert(target.len == @as(usize, w) * h);
    if (source.w == w and source.h == h) {
        @memcpy(target, source.data);
        return;
    }
    const sx = @as(f64, @floatFromInt(source.w)) / @as(f64, @floatFromInt(w));
    const sy = @as(f64, @floatFromInt(source.h)) / @as(f64, @floatFromInt(h));
    for (0..h) |y| for (0..w) |x| {
        const u = (@as(f64, @floatFromInt(x)) + 0.5) * sx;
        const v = (@as(f64, @floatFromInt(y)) + 0.5) * sy;
        target[y * w + x] = source.sample(u, v);
    };
}

/// Uniform direction by rejection from the unit square, no trig.
pub fn randomUnit(rng: std.Random) Vec2 {
    while (true) {
        const x = rng.float(f64) * 2 - 1;
        const y = rng.float(f64) * 2 - 1;
        const d2 = x * x + y * y;
        if (d2 > 1e-6 and d2 <= 1) {
            const inv = 1 / @sqrt(d2);
            return .{ x * inv, y * inv };
        }
    }
}

pub fn dist(a: Vec2, b: Vec2) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

test "common: resample stretches a two cell field" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 2, 1, 0);
    defer f.deinit(gpa);
    f.set(1, 0, 1);
    var out: [4]f32 = undefined;
    resample(&out, 4, 1, &f);
    try std.testing.expectEqual(@as(f32, 0), out[0]);
    try std.testing.expectEqual(@as(f32, 0.25), out[1]);
    try std.testing.expectEqual(@as(f32, 0.75), out[2]);
    try std.testing.expectEqual(@as(f32, 1), out[3]);
}

test "common: forBands visits every index once for any worker count" {
    const Hits = struct {
        fn mark(hits: []std.atomic.Value(u32), start: usize, end: usize) void {
            for (hits[start..end]) |*h| _ = h.fetchAdd(1, .monotonic);
        }
    };
    var hits: [1001]std.atomic.Value(u32) = undefined;
    for ([_]u32{ 1, 2, 3, 7, 31 }) |workers| {
        for (&hits) |*h| h.* = .init(0);
        const threads: Threads = .{ .io = std.testing.io, .workers_max = workers };
        forBands(threads, hits.len, 1, @as([]std.atomic.Value(u32), &hits), Hits.mark);
        for (&hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
    }
}

test "common: workerCount grows with the square root of the work" {
    try std.testing.expectEqual(@as(u32, 0), workerCount(8, 99, 100));
    try std.testing.expectEqual(@as(u32, 1), workerCount(8, 3, 1));
    try std.testing.expectEqual(@as(u32, 2), workerCount(8, 4, 1));
    try std.testing.expectEqual(@as(u32, 3), workerCount(8, 900, 100));
    try std.testing.expectEqual(@as(u32, 8), workerCount(8, 1 << 20, 1));
}
