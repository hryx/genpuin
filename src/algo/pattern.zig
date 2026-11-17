//! Point layouts for the pattern helpers: evenly spaced around a circle
//! and along a phyllotaxis (Vogel 1979) or Archimedean spiral.

const std = @import("std");

const math = @import("../math.zig");

pub const Vec2 = [2]f64;

/// Point i of n on a circle and its angle.
pub fn radial(center: Vec2, radius: f64, i: f64, n: f64) struct { Vec2, f64 } {
    const angle = (i / n) * 2 * std.math.pi;
    return .{ .{ center[0] + radius * math.cos(angle), center[1] + radius * math.sin(angle) }, angle };
}

pub const Growth = enum { sqrt, linear };

/// Point i of a spiral and its angle. `sqrt` growth spaces points
/// evenly by area, `linear` by turn.
pub fn spiral(center: Vec2, angle_step: f64, spacing: f64, growth: Growth, i: f64) struct { Vec2, f64 } {
    const a = i * angle_step;
    const r = switch (growth) {
        .sqrt => spacing * @sqrt(i),
        .linear => spacing * i,
    };
    return .{ .{ center[0] + r * math.cos(a), center[1] + r * math.sin(a) }, a };
}

const testing = std.testing;

test "pattern: radial starts on the positive x axis" {
    const p, const a = radial(.{ 1, 2 }, 3, 0, 4);
    try testing.expectEqual(Vec2{ 4, 2 }, p);
    try testing.expectEqual(@as(f64, 0), a);
    _, const quarter = radial(.{ 0, 0 }, 1, 1, 4);
    try testing.expectEqual(std.math.pi / 2.0, quarter);
}

test "pattern: spiral radius grows with sqrt or linearly" {
    const p, _ = spiral(.{ 0, 0 }, 0, 2, .sqrt, 4);
    try testing.expectEqual(Vec2{ 4, 0 }, p);
    const q, _ = spiral(.{ 0, 0 }, 0, 2, .linear, 4);
    try testing.expectEqual(Vec2{ 8, 0 }, q);
}
