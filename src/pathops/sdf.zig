//! Signed distance functions in 2D, negative inside. A `Node` tree is
//! compiled into a flat `Program` of stack instructions, which evaluates
//! points without recursion or allocation.
//!
//! Primitives and operators follow Inigo Quilez, "2D distance functions"
//! (iquilezles.org/articles/distfunctions2d) and "Smooth minimum"
//! (iquilezles.org/articles/smin), using the quadratic polynomial smin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const math = @import("../math.zig");

const Field = @import("../Field.zig");
const geom = @import("geom.zig");
const Vec2 = geom.Vec2;
const EdgeSet = @import("EdgeSet.zig");

pub const Combine = enum { @"union", intersect, subtract };

pub const Node = union(enum) {
    circle: struct { c: Vec2, r: f64 },
    /// Axis-aligned box from its center and half extents.
    box: struct { c: Vec2, half: Vec2 },
    /// Capsule around a segment, radius zero for the bare segment.
    segment: struct { a: Vec2, b: Vec2, r: f64 = 0 },
    /// Exact distance to the contours, signed by the fill rule.
    polygon: struct { contours: geom.Contours, rule: geom.FillRule = .nonzero },
    /// Fold over the children. Subtract removes every later child from
    /// the first. A blend radius k above zero uses the smooth versions.
    combine: struct { op: Combine, children: []const Node, k: f64 = 0 },
    round: struct { child: *const Node, r: f64 },
    onion: struct { child: *const Node, t: f64 },
    translate: struct { child: *const Node, offset: Vec2 },
    /// Rotate by angle radians around center.
    rotate: struct { child: *const Node, angle: f64, center: Vec2 = .{ 0, 0 } },
    scale: struct { child: *const Node, s: f64 },
    /// Domain repetition with the given period per axis. A count limits
    /// the copies to 0..count-1 periods along that axis, zero is endless.
    repeat: struct { child: *const Node, period: Vec2, count: [2]u32 = .{ 0, 0 } },
};

pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

pub const max_depth = 64;

const Inst = union(enum) {
    circle: struct { c: Vec2, r: f64 },
    box: struct { c: Vec2, half: Vec2 },
    segment: struct { a: Vec2, b: Vec2, r: f64 },
    polygon: struct { set: u32, rule: geom.FillRule },
    combine: struct { op: Combine, k: f64 },
    round: f64,
    onion: f64,
    translate: Vec2,
    rotate: struct { center: Vec2, cos: f64, sin: f64 },
    scale: f64,
    repeat: struct { period: Vec2, count: [2]u32 },
    /// Restore the point saved by the matching transform.
    pop: void,
    /// Restore the point and multiply the distance back by the scale.
    pop_scale: f64,
};

pub const Program = struct {
    insts: []Inst,
    sets: []EdgeSet,

    pub const Error = error{ TooDeep, BadNode } || Allocator.Error;

    pub fn init(gpa: Allocator, root: *const Node) Error!Program {
        var c: Compiler = .{ .gpa = gpa };
        errdefer c.deinit();
        try c.emit(root, 0);
        assert(c.values == 1);
        const insts = try c.insts.toOwnedSlice(gpa);
        errdefer gpa.free(insts);
        return .{ .insts = insts, .sets = try c.sets.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *Program, gpa: Allocator) void {
        for (self.sets) |*s| s.deinit(gpa);
        gpa.free(self.sets);
        gpa.free(self.insts);
        self.* = undefined;
    }

    pub fn eval(self: *const Program, p0: Vec2) f64 {
        var vals: [max_depth + 2]f64 = undefined;
        var nv: usize = 0;
        var pts: [max_depth + 1]Vec2 = undefined;
        var np: usize = 0;
        var p = p0;
        for (self.insts) |inst| switch (inst) {
            .circle => |c| {
                vals[nv] = geom.dist(p, c.c) - c.r;
                nv += 1;
            },
            .box => |b| {
                const d: Vec2 = .{ @abs(p[0] - b.c[0]) - b.half[0], @abs(p[1] - b.c[1]) - b.half[1] };
                vals[nv] = geom.length(.{ @max(d[0], 0), @max(d[1], 0) }) + @min(@max(d[0], d[1]), 0);
                nv += 1;
            },
            .segment => |s| {
                vals[nv] = @sqrt(geom.segmentDist2(p, s.a, s.b)) - s.r;
                nv += 1;
            },
            .polygon => |g| {
                const set = &self.sets[g.set];
                const d = set.distance(p, std.math.inf(f64));
                vals[nv] = if (geom.inside(g.rule, set.winding(p))) -d else d;
                nv += 1;
            },
            .combine => |c| {
                nv -= 1;
                vals[nv - 1] = combine(c.op, c.k, vals[nv - 1], vals[nv]);
            },
            .round => |r| vals[nv - 1] -= r,
            .onion => |t| vals[nv - 1] = @abs(vals[nv - 1]) - t,
            .translate => |o| {
                pts[np] = p;
                np += 1;
                p = geom.sub(p, o);
            },
            .rotate => |r| {
                pts[np] = p;
                np += 1;
                const q = geom.sub(p, r.center);
                p = .{ r.center[0] + q[0] * r.cos + q[1] * r.sin, r.center[1] - q[0] * r.sin + q[1] * r.cos };
            },
            .scale => |s| {
                pts[np] = p;
                np += 1;
                p = geom.scale(p, 1 / s);
            },
            .repeat => |r| {
                pts[np] = p;
                np += 1;
                for (0..2) |axis| {
                    if (r.period[axis] <= 0) continue;
                    var k = @round(p[axis] / r.period[axis]);
                    if (r.count[axis] > 0) k = std.math.clamp(k, 0, @as(f64, @floatFromInt(r.count[axis] - 1)));
                    p[axis] -= k * r.period[axis];
                }
            },
            .pop => {
                np -= 1;
                p = pts[np];
            },
            .pop_scale => |s| {
                np -= 1;
                p = pts[np];
                vals[nv - 1] *= s;
            },
        };
        assert(nv == 1);
        assert(np == 0);
        return vals[0];
    }

    /// Sample at every cell center of `field`, laid over `rect`.
    pub fn fill(self: *const Program, field: *Field, rect: Rect) void {
        const sx = rect.w / @as(f64, @floatFromInt(field.w));
        const sy = rect.h / @as(f64, @floatFromInt(field.h));
        for (0..field.h) |j| {
            const y = rect.y + (@as(f64, @floatFromInt(j)) + 0.5) * sy;
            const row = field.data[j * field.w ..][0..field.w];
            for (row, 0..) |*v, i| {
                const x = rect.x + (@as(f64, @floatFromInt(i)) + 0.5) * sx;
                v.* = @floatCast(self.eval(.{ x, y }));
            }
        }
    }
};

/// Quadratic polynomial smooth minimum with blend radius k.
pub fn smin(a: f64, b: f64, k: f64) f64 {
    const h = @max(k - @abs(a - b), 0) / k;
    return @min(a, b) - h * h * k * 0.25;
}

fn combine(op: Combine, k: f64, a: f64, b: f64) f64 {
    if (k <= 0) return switch (op) {
        .@"union" => @min(a, b),
        .intersect => @max(a, b),
        .subtract => @max(a, -b),
    };
    return switch (op) {
        .@"union" => smin(a, b, k),
        .intersect => -smin(-a, -b, k),
        .subtract => -smin(-a, b, k),
    };
}

const Compiler = struct {
    gpa: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    sets: std.ArrayList(EdgeSet) = .empty,
    values: usize = 0,

    fn deinit(c: *Compiler) void {
        for (c.sets.items) |*s| s.deinit(c.gpa);
        c.sets.deinit(c.gpa);
        c.insts.deinit(c.gpa);
    }

    fn push(c: *Compiler, inst: Inst) !void {
        try c.insts.append(c.gpa, inst);
    }

    fn value(c: *Compiler, inst: Inst) !void {
        try c.push(inst);
        c.values += 1;
        assert(c.values <= max_depth + 2);
    }

    /// Depth is bounded by max_depth, so the recursion is too.
    fn emit(c: *Compiler, node: *const Node, depth: usize) Program.Error!void {
        if (depth > max_depth) return error.TooDeep;
        switch (node.*) {
            .circle => |n| try c.value(.{ .circle = .{ .c = n.c, .r = n.r } }),
            .box => |n| try c.value(.{ .box = .{ .c = n.c, .half = n.half } }),
            .segment => |n| try c.value(.{ .segment = .{ .a = n.a, .b = n.b, .r = n.r } }),
            .polygon => |n| {
                var set: EdgeSet = try .init(c.gpa, n.contours, true);
                errdefer set.deinit(c.gpa);
                try c.sets.append(c.gpa, set);
                try c.value(.{ .polygon = .{ .set = @intCast(c.sets.items.len - 1), .rule = n.rule } });
            },
            .combine => |n| {
                if (n.children.len == 0) return error.BadNode;
                try c.emit(&n.children[0], depth + 1);
                for (n.children[1..]) |*child| {
                    try c.emit(child, depth + 1);
                    try c.push(.{ .combine = .{ .op = n.op, .k = n.k } });
                    c.values -= 1;
                }
            },
            .round => |n| {
                try c.emit(n.child, depth + 1);
                try c.push(.{ .round = n.r });
            },
            .onion => |n| {
                try c.emit(n.child, depth + 1);
                try c.push(.{ .onion = n.t });
            },
            .translate => |n| try c.wrap(.{ .translate = n.offset }, n.child, .pop, depth),
            .rotate => |n| {
                try c.wrap(.{ .rotate = .{ .center = n.center, .cos = math.cos(n.angle), .sin = math.sin(n.angle) } }, n.child, .pop, depth);
            },
            .scale => |n| {
                if (n.s == 0) return error.BadNode;
                try c.wrap(.{ .scale = n.s }, n.child, .{ .pop_scale = @abs(n.s) }, depth);
            },
            .repeat => |n| try c.wrap(.{ .repeat = .{ .period = n.period, .count = n.count } }, n.child, .pop, depth),
        }
    }

    fn wrap(c: *Compiler, open: Inst, child: *const Node, close: Inst, depth: usize) !void {
        try c.push(open);
        try c.emit(child, depth + 1);
        try c.push(close);
    }
};

const testing = std.testing;

fn evalNode(node: Node, p: Vec2) !f64 {
    var prog: Program = try .init(testing.allocator, &node);
    defer prog.deinit(testing.allocator);
    return prog.eval(p);
}

test "sdf: primitives give exact distances" {
    try testing.expectEqual(@as(f64, -1), try evalNode(.{ .circle = .{ .c = .{ 0, 0 }, .r = 2 } }, .{ 1, 0 }));
    try testing.expectEqual(@as(f64, 5), try evalNode(.{ .box = .{ .c = .{ 0, 0 }, .half = .{ 1, 1 } } }, .{ 4, 5 }));
    try testing.expectEqual(@as(f64, -0.5), try evalNode(.{ .box = .{ .c = .{ 0, 0 }, .half = .{ 1, 2 } } }, .{ 0.5, 0 }));
    try testing.expectEqual(@as(f64, 2), try evalNode(.{ .segment = .{ .a = .{ 0, 0 }, .b = .{ 4, 0 }, .r = 1 } }, .{ 2, 3 }));
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    try testing.expectEqual(@as(f64, -1), try evalNode(.{ .polygon = .{ .contours = &.{&sq} } }, .{ 1, 2 }));
    try testing.expectEqual(@as(f64, 5), try evalNode(.{ .polygon = .{ .contours = &.{&sq} } }, .{ 7, 8 }));
}

test "sdf: combinators and transforms" {
    const a: Node = .{ .circle = .{ .c = .{ 0, 0 }, .r = 1 } };
    const b: Node = .{ .circle = .{ .c = .{ 3, 0 }, .r = 1 } };
    const pair = [_]Node{ a, b };
    try testing.expectEqual(@as(f64, 0.5), try evalNode(.{ .combine = .{ .op = .@"union", .children = &pair } }, .{ 1.5, 0 }));
    // Smooth union pulls the gap inward by k/4 where both are equal.
    const smooth = try evalNode(.{ .combine = .{ .op = .@"union", .children = &pair, .k = 2 } }, .{ 1.5, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.5 - 0.5), smooth, 1e-12);
    try testing.expectEqual(@as(f64, 1), try evalNode(.{ .combine = .{ .op = .subtract, .children = &.{ a, .{ .circle = .{ .c = .{ 0, 0 }, .r = 0.5 } } } } }, .{ 0, 0 }) * 2);
    try testing.expectEqual(@as(f64, -1), try evalNode(.{ .translate = .{ .child = &a, .offset = .{ 10, 0 } } }, .{ 10, 0 }));
    try testing.expectApproxEqAbs(@as(f64, -1), try evalNode(.{ .rotate = .{ .child = &b, .angle = std.math.pi / 2.0 } }, .{ 0, 3 }), 1e-12);
    try testing.expectEqual(@as(f64, -2), try evalNode(.{ .scale = .{ .child = &a, .s = 2 } }, .{ 0, 0 }));
    try testing.expectEqual(@as(f64, -1), try evalNode(.{ .repeat = .{ .child = &a, .period = .{ 5, 5 } } }, .{ 10, -5 }));
    try testing.expectEqual(@as(f64, 9), try evalNode(.{ .repeat = .{ .child = &a, .period = .{ 5, 0 }, .count = .{ 2, 0 } } }, .{ 15, 0 }));
    try testing.expectEqual(@as(f64, 0.5), try evalNode(.{ .onion = .{ .child = &a, .t = 0.5 } }, .{ 0, 0 }));
    try testing.expectEqual(@as(f64, -1.5), try evalNode(.{ .round = .{ .child = &a, .r = 0.5 } }, .{ 0, 0 }));
}

test "sdf: depth limit is an error" {
    const gpa = testing.allocator;
    const nodes = try gpa.alloc(Node, max_depth + 2);
    defer gpa.free(nodes);
    nodes[0] = .{ .circle = .{ .c = .{ 0, 0 }, .r = 1 } };
    for (nodes[1..], 0..) |*n, i| n.* = .{ .round = .{ .child = &nodes[i], .r = 0 } };
    try testing.expectError(error.TooDeep, Program.init(gpa, &nodes[nodes.len - 1]));
}
