//! Bulk particle tracing through curl noise or an angle Field. Paths come
//! back packed in one buffer so thousands of them cost two allocations.

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const noise = @import("../noise.zig");

pub const Vec2 = [2]f64;

pub const Source = union(enum) {
    /// Curl of noise read at scene point * scale + offset.
    curl: struct {
        noise: noise.Options,
        scale: f32,
        offset: [2]f32 = .{ 0, 0 },
        z: ?f32 = null,
    },
    /// Angles in radians, stretched over the scene rect {x, y, w, h}.
    angle: struct {
        field: *const Field,
        rect: [4]f64,
    },

    /// Unit direction at a scene point.
    pub fn direction(self: *const Source, p: Vec2) Vec2 {
        switch (self.*) {
            .curl => |c| {
                const x: f32 = @floatCast(p[0] * c.scale + c.offset[0]);
                const y: f32 = @floatCast(p[1] * c.scale + c.offset[1]);
                const v = noise.curl(&c.noise, x, y, c.z);
                const len = std.math.hypot(v[0], v[1]);
                if (len == 0) return .{ 0, 0 };
                return .{ v[0] / len, v[1] / len };
            },
            .angle => |a| {
                const u = (p[0] - a.rect[0]) / a.rect[2] * @as(f64, @floatFromInt(a.field.w));
                const v = (p[1] - a.rect[1]) / a.rect[3] * @as(f64, @floatFromInt(a.field.h));
                const t: f64 = a.field.sample(u, v);
                return .{ math.cos(t), math.sin(t) };
            },
        }
    }
};

pub const Options = struct {
    source: Source,
    starts: []const Vec2,
    steps: u32 = 200,
    /// Scene units per step. Negative traces upstream.
    step_size: f64 = 1,
    /// A path stops when it leaves this rect {x, y, w, h}.
    bounds: ?[4]f64 = null,
};

pub const Paths = struct {
    points: []Vec2,
    /// ends[i] is one past the last point of path i.
    ends: []u32,

    pub fn deinit(self: *Paths, gpa: Allocator) void {
        gpa.free(self.points);
        gpa.free(self.ends);
        self.* = undefined;
    }

    pub fn path(self: *const Paths, i: usize) []const Vec2 {
        const start: usize = if (i == 0) 0 else self.ends[i - 1];
        return self.points[start..self.ends[i]];
    }
};

/// Integrate every start point with the midpoint method (RK2). Each path
/// keeps its start point and gets at most `steps` more.
pub fn trace(gpa: Allocator, o: Options) !Paths {
    const cap = o.starts.len * (@as(usize, o.steps) + 1);
    var points = try gpa.alloc(Vec2, cap);
    errdefer gpa.free(points);
    const ends = try gpa.alloc(u32, o.starts.len);
    errdefer gpa.free(ends);

    var len: usize = 0;
    const h = o.step_size;
    for (o.starts, ends) |start, *end| {
        var p = start;
        points[len] = p;
        len += 1;
        for (0..o.steps) |_| {
            const d1 = o.source.direction(p);
            const mid: Vec2 = .{ p[0] + d1[0] * h * 0.5, p[1] + d1[1] * h * 0.5 };
            const d2 = o.source.direction(mid);
            if (d2[0] == 0 and d2[1] == 0) break;
            p = .{ p[0] + d2[0] * h, p[1] + d2[1] * h };
            if (o.bounds) |b| {
                if (p[0] < b[0] or p[1] < b[1] or p[0] > b[0] + b[2] or p[1] > b[1] + b[3]) break;
            }
            points[len] = p;
            len += 1;
        }
        end.* = @intCast(len);
    }
    assert(len <= cap);
    points = try gpa.realloc(points, len);
    return .{ .points = points, .ends = ends };
}

/// `count` points spread uniformly over the rect {x, y, w, h}.
pub fn randomStarts(gpa: Allocator, seed: u64, count: usize, rect: [4]f64) ![]Vec2 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const out = try gpa.alloc(Vec2, count);
    for (out) |*p| p.* = .{ rect[0] + r.float(f64) * rect[2], rect[1] + r.float(f64) * rect[3] };
    return out;
}

test "flow: a constant angle field traces straight lines" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 4, 4, std.math.pi / 2.0);
    defer f.deinit(gpa);
    const starts = [_]Vec2{ .{ 1, 1 }, .{ 2, 1 } };
    var paths = try trace(gpa, .{
        .source = .{ .angle = .{ .field = &f, .rect = .{ 0, 0, 10, 10 } } },
        .starts = &starts,
        .steps = 20,
        .step_size = 1,
        .bounds = .{ 0, 0, 10, 10 },
    });
    defer paths.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), paths.ends.len);
    // From y = 1 the path steps down to y = 10 and stops at the edge.
    const a = paths.path(0);
    try std.testing.expectEqual(@as(usize, 10), a.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), a[9][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 10), a[9][1], 1e-5);
    try std.testing.expectEqual(@as(usize, 10), paths.path(1).len);
}

test "flow: curl paths move one step size per step" {
    const gpa = std.testing.allocator;
    const starts = [_]Vec2{.{ 10, 20 }};
    var paths = try trace(gpa, .{
        .source = .{ .curl = .{ .noise = .{ .octaves = 2 }, .scale = 0.01 } },
        .starts = &starts,
        .steps = 50,
        .step_size = 2,
    });
    defer paths.deinit(gpa);
    const p = paths.path(0);
    try std.testing.expectEqual(@as(usize, 51), p.len);
    for (p[0 .. p.len - 1], p[1..]) |a, b| {
        try std.testing.expectApproxEqAbs(@as(f64, 2), std.math.hypot(b[0] - a[0], b[1] - a[1]), 1e-6);
    }
}
