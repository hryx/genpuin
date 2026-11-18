//! Flattening a gen.pen path. The pen records straight moves as points
//! and arcTo turns as circular arcs, and a stroke needs a polyline.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");

pub const Vec2 = [2]f64;

pub const Arc = struct {
    center: Vec2,
    radius: f64,
    start: f64,
    end: f64,

    /// The point a fraction `t` of the way from start to end.
    pub fn at(a: Arc, t: f64) Vec2 {
        const angle = a.start + (a.end - a.start) * t;
        return .{ a.center[0] + a.radius * math.cos(angle), a.center[1] + a.radius * math.sin(angle) };
    }
};

/// A step of a pen path: a point reached by a straight move, or the end
/// of an arc.
pub const Step = union(enum) {
    point: Vec2,
    arc: Arc,
};

/// Samples per arc at `resolution`: 1 to floor(resolution), as a Lua
/// numeric for loop counts.
pub fn arcSamples(resolution: f64) usize {
    if (!(resolution >= 1)) return 0;
    return @intFromFloat(@floor(@min(resolution, 1 << 24)));
}

/// The polyline through `first` and the steps, each arc replaced by
/// samples at fractions 1/resolution, 2/resolution and so on of its sweep.
pub fn flatten(gpa: Allocator, first: Vec2, steps: []const Step, resolution: f64) ![]Vec2 {
    const per_arc = arcSamples(resolution);
    var len: usize = 1;
    for (steps) |s| len += switch (s) {
        .point => 1,
        .arc => per_arc,
    };
    const out = try gpa.alloc(Vec2, len);
    out[0] = first;
    var k: usize = 1;
    for (steps) |s| switch (s) {
        .point => |p| {
            out[k] = p;
            k += 1;
        },
        .arc => |a| for (1..per_arc + 1) |i| {
            out[k] = a.at(@as(f64, @floatFromInt(i)) / resolution);
            k += 1;
        },
    };
    std.debug.assert(k == len);
    return out;
}

const testing = std.testing;

test "pen: a quarter arc flattens to its samples" {
    const arc: Arc = .{ .center = .{ 0, 0 }, .radius = 2, .start = 0, .end = std.math.pi / 2.0 };
    const steps = [_]Step{ .{ .arc = arc }, .{ .point = .{ 5, 5 } } };
    const pts = try flatten(testing.allocator, .{ 2, 0 }, &steps, 2);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 4), pts.len);
    try testing.expectEqual(Vec2{ 2, 0 }, pts[0]);
    try testing.expectApproxEqAbs(@sqrt(2.0), pts[1][0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), pts[2][1], 1e-12);
    try testing.expectEqual(Vec2{ 5, 5 }, pts[3]);
}

test "pen: a fractional resolution samples as a Lua for loop" {
    try testing.expectEqual(@as(usize, 2), arcSamples(2.9));
    try testing.expectEqual(@as(usize, 0), arcSamples(0.5));
    try testing.expectEqual(@as(usize, 0), arcSamples(std.math.nan(f64)));
}
