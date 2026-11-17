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
