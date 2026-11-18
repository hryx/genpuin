//! Affine transforms of shape geometry for gen.translate, gen.rotate and
//! friends. Each named transform keeps its own formula rather than going
//! through a shared matrix, so a point maps to the same bits as the Lua
//! library this was ported from.
//!
//! Shapes the renderer only knows axis aligned (rect, ellipse, circle)
//! keep their kind while the linear part allows it and otherwise flatten
//! to a polygon. An arc survives rotation, uniform scale and reflection.
//! A field image takes translation and positive axis scales only.

const std = @import("std");

const math = @import("../math.zig");

pub const Vec2 = [2]f64;

/// Lua's math.min and math.max, which keep the first argument unless the
/// second is strictly beyond it. That differs from @min and @max on
/// signed zeros and NaN.
fn luaMin(a: f64, b: f64) f64 {
    return if (b < a) b else a;
}

fn luaMax(a: f64, b: f64) f64 {
    return if (b > a) b else a;
}

pub const Transform = union(enum) {
    translate: Vec2,
    rotate: Turn,
    rotate_around: struct { turn: Turn, pivot: Vec2 },
    scale: Vec2,
    scale_around: struct { factor: Vec2, pivot: Vec2 },
    reflect_x,
    reflect_y,
    /// Mirror across the axis through `pivot` at `angle`, held as the
    /// cosine and sine of twice the angle.
    reflect: struct { turn: Turn, pivot: Vec2 },

    pub const Turn = struct {
        c: f64,
        s: f64,

        pub fn init(angle: f64) Turn {
            return .{ .c = math.cos(angle), .s = math.sin(angle) };
        }
    };

    pub fn rotateAround(angle: f64, pivot: Vec2) Transform {
        return .{ .rotate_around = .{ .turn = .init(angle), .pivot = pivot } };
    }

    pub fn reflectAcross(pivot: Vec2, angle: f64) Transform {
        return .{ .reflect = .{ .turn = .init(2 * angle), .pivot = pivot } };
    }

    pub fn apply(t: Transform, p: Vec2) Vec2 {
        return switch (t) {
            .translate => |d| .{ p[0] + d[0], p[1] + d[1] },
            .rotate => |r| .{ p[0] * r.c - p[1] * r.s, p[0] * r.s + p[1] * r.c },
            .rotate_around => |r| {
                const dx = p[0] - r.pivot[0];
                const dy = p[1] - r.pivot[1];
                return .{ r.pivot[0] + dx * r.turn.c - dy * r.turn.s, r.pivot[1] + dx * r.turn.s + dy * r.turn.c };
            },
            .scale => |f| .{ p[0] * f[0], p[1] * f[1] },
            .scale_around => |s| .{
                s.pivot[0] + (p[0] - s.pivot[0]) * s.factor[0],
                s.pivot[1] + (p[1] - s.pivot[1]) * s.factor[1],
            },
            .reflect_x => .{ -p[0], p[1] },
            .reflect_y => .{ p[0], -p[1] },
            .reflect => |r| {
                const dx = p[0] - r.pivot[0];
                const dy = p[1] - r.pivot[1];
                return .{ r.pivot[0] + dx * r.turn.c + dy * r.turn.s, r.pivot[1] + dx * r.turn.s - dy * r.turn.c };
            },
        };
    }

    pub fn linear(t: Transform) Linear {
        return switch (t) {
            .translate => .{ .a = 1, .b = 0, .c = 0, .d = 1 },
            .rotate => |r| .rotation(r),
            .rotate_around => |r| .rotation(r.turn),
            .scale => |f| .{ .a = f[0], .b = 0, .c = 0, .d = f[1] },
            .scale_around => |s| .{ .a = s.factor[0], .b = 0, .c = 0, .d = s.factor[1] },
            .reflect_x => .{ .a = -1, .b = 0, .c = 0, .d = 1 },
            .reflect_y => .{ .a = 1, .b = 0, .c = 0, .d = -1 },
            .reflect => |r| .{ .a = r.turn.c, .b = r.turn.s, .c = r.turn.s, .d = -r.turn.c },
        };
    }
};

/// The linear part of a transform: (x, y) maps to (a x + b y, c x + d y).
/// Its classification decides which shape kinds survive.
pub const Linear = struct {
    a: f64,
    b: f64,
    c: f64,
    d: f64,

    const eps = 1e-9;

    fn near(x: f64, y: f64) bool {
        return @abs(x - y) < eps;
    }

    fn rotation(r: Transform.Turn) Linear {
        return .{ .a = r.c, .b = -r.s, .c = r.s, .d = r.c };
    }

    pub fn axisKeeping(m: Linear) bool {
        return near(m.b, 0) and near(m.c, 0);
    }

    pub fn axisSwapping(m: Linear) bool {
        return near(m.a, 0) and near(m.d, 0);
    }

    pub fn rotationLike(m: Linear) bool {
        return near(m.a, m.d) and near(m.b, -m.c);
    }

    pub fn reflectionLike(m: Linear) bool {
        return near(m.a, -m.d) and near(m.b, m.c);
    }

    /// The square root of the absolute determinant, the scale a circle's
    /// radius takes.
    pub fn radiusScale(m: Linear) f64 {
        return @sqrt(@abs(m.a * m.d - m.b * m.c));
    }
};

/// A closed outline of an axis-aligned ellipse, about one point per unit
/// of circumference, 64 to 4096 points.
pub const EllipseOutline = struct {
    center: Vec2,
    rx: f64,
    ry: f64,
    count: f64,

    pub fn init(center: Vec2, rx: f64, ry: f64) EllipseOutline {
        const circumference = 2 * std.math.pi * luaMax(rx, ry);
        return .{ .center = center, .rx = rx, .ry = ry, .count = luaMax(64, luaMin(4096, @ceil(circumference))) };
    }

    pub fn len(o: EllipseOutline) usize {
        return @intFromFloat(o.count);
    }

    pub fn point(o: EllipseOutline, index: usize) Vec2 {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(index)) / o.count;
        return .{ o.center[0] + o.rx * math.cos(t), o.center[1] + o.ry * math.sin(t) };
    }
};

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rx: ?f64 = null,
    ry: ?f64 = null,
};

/// A rect's outline. Corner order and arc parameterization follow the
/// renderer's rounded rect.
pub const RectOutline = struct {
    rect: Rect,
    rx: f64,
    ry: f64,
    /// Segments per rounded corner, or 0 for square corners.
    corner_segments: f64,

    pub fn init(r: Rect) RectOutline {
        const rx0 = r.rx orelse 0;
        const ry0 = r.ry orelse 0;
        if (rx0 <= 0 and ry0 <= 0) return .{ .rect = r, .rx = 0, .ry = 0, .corner_segments = 0 };
        const rx = luaMin(if (rx0 > 0) rx0 else ry0, r.w / 2);
        const ry = luaMin(if (ry0 > 0) ry0 else rx0, r.h / 2);
        const n = luaMax(4, @ceil(std.math.pi / 2.0 * luaMax(rx, ry)));
        return .{ .rect = r, .rx = rx, .ry = ry, .corner_segments = n };
    }

    pub fn len(o: RectOutline) usize {
        if (o.corner_segments == 0) return 4;
        return 4 * (@as(usize, @intFromFloat(o.corner_segments)) + 1);
    }

    pub fn point(o: RectOutline, index: usize) Vec2 {
        const r = o.rect;
        if (o.corner_segments == 0) {
            const corners = [4]Vec2{ .{ r.x, r.y }, .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h } };
            return corners[index];
        }
        const corner_len = @as(usize, @intFromFloat(o.corner_segments)) + 1;
        const corner = roundedCorners(r, o.rx, o.ry)[index / corner_len];
        const i: f64 = @floatFromInt(index % corner_len);
        const t = corner.start + std.math.pi / 2.0 * i / o.corner_segments;
        return .{ corner.center[0] + o.rx * math.cos(t), corner.center[1] + o.ry * math.sin(t) };
    }

    const Corner = struct { center: Vec2, start: f64 };

    fn roundedCorners(r: Rect, rx: f64, ry: f64) [4]Corner {
        return .{
            .{ .center = .{ r.x + r.w - rx, r.y + ry }, .start = -std.math.pi / 2.0 },
            .{ .center = .{ r.x + r.w - rx, r.y + r.h - ry }, .start = 0 },
            .{ .center = .{ r.x + rx, r.y + r.h - ry }, .start = std.math.pi / 2.0 },
            .{ .center = .{ r.x + rx, r.y + ry }, .start = std.math.pi },
        };
    }
};

pub const Circle = struct { center: Vec2, r: f64 };
pub const Ellipse = struct { center: Vec2, rx: f64, ry: f64 };

/// A circle stays a circle under rotation, reflection and uniform scale,
/// becomes an ellipse under an axis scale, and a polygon otherwise.
pub const CircleImage = union(enum) {
    circle: Circle,
    ellipse: Ellipse,
    polygon: EllipseOutline,
};

pub fn circle(t: Transform, c: Circle) CircleImage {
    const m = t.linear();
    const center = t.apply(c.center);
    if (m.rotationLike() or m.reflectionLike()) return .{ .circle = .{ .center = center, .r = c.r * m.radiusScale() } };
    if (m.axisKeeping()) return .{ .ellipse = .{ .center = center, .rx = c.r * @abs(m.a), .ry = c.r * @abs(m.d) } };
    return .{ .polygon = .init(c.center, c.r, c.r) };
}

pub const EllipseImage = union(enum) {
    ellipse: Ellipse,
    polygon: EllipseOutline,
};

pub fn ellipse(t: Transform, e: Ellipse) EllipseImage {
    const m = t.linear();
    const center = t.apply(e.center);
    if (m.axisKeeping()) return .{ .ellipse = .{ .center = center, .rx = e.rx * @abs(m.a), .ry = e.ry * @abs(m.d) } };
    if (m.axisSwapping()) return .{ .ellipse = .{ .center = center, .rx = e.ry * @abs(m.b), .ry = e.rx * @abs(m.c) } };
    return .{ .polygon = .init(e.center, e.rx, e.ry) };
}

/// The axis-aligned box spanned by the images of two opposite corners.
fn box(t: Transform, r: Rect) Rect {
    const p = t.apply(.{ r.x, r.y });
    const q = t.apply(.{ r.x + r.w, r.y + r.h });
    return .{ .x = luaMin(p[0], q[0]), .y = luaMin(p[1], q[1]), .w = @abs(q[0] - p[0]), .h = @abs(q[1] - p[1]) };
}

pub const RectImage = union(enum) {
    rect: Rect,
    polygon: RectOutline,
};

pub fn rect(t: Transform, r: Rect) RectImage {
    const m = t.linear();
    if (m.axisKeeping()) {
        var b = box(t, r);
        b.rx = if (r.rx) |rx| rx * @abs(m.a) else null;
        b.ry = if (r.ry) |ry| ry * @abs(m.d) else null;
        return .{ .rect = b };
    }
    if (m.axisSwapping()) {
        var b = box(t, r);
        b.rx = if (r.ry) |ry| ry * @abs(m.b) else null;
        b.ry = if (r.rx) |rx| rx * @abs(m.c) else null;
        return .{ .rect = b };
    }
    return .{ .polygon = .init(r) };
}

pub const Arc = struct { center: Vec2, r: f64, start: f64, end: f64 };

pub fn arc(t: Transform, a: Arc) error{NonUniformScale}!Arc {
    const m = t.linear();
    const center = t.apply(a.center);
    const k = m.radiusScale();
    const phi = math.atan2(m.c, m.a);
    if (m.rotationLike()) return .{ .center = center, .r = a.r * k, .start = a.start + phi, .end = a.end + phi };
    // A reflection maps angle t to phi - t and reverses the sweep, so
    // start and end swap to keep the same piece of circle.
    if (m.reflectionLike()) return .{ .center = center, .r = a.r * k, .start = phi - a.end, .end = phi - a.start };
    return error.NonUniformScale;
}

/// A field image's rect. Images draw axis aligned and unflipped only.
pub fn image(t: Transform, r: Rect) error{ImageTransform}!Rect {
    const m = t.linear();
    if (!(m.axisKeeping() and m.a > 0 and m.d > 0)) return error.ImageTransform;
    return box(t, r);
}

const testing = std.testing;

test "xform: rotateAround turns about the pivot" {
    const t: Transform = .rotateAround(std.math.pi, .{ 1, 1 });
    const p = t.apply(.{ 2, 1 });
    try testing.expectApproxEqAbs(@as(f64, 0), p[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), p[1], 1e-12);
}

test "xform: reflect across the diagonal swaps coordinates" {
    const t: Transform = .reflectAcross(.{ 0, 0 }, std.math.pi / 4.0);
    const p = t.apply(.{ 3, 1 });
    try testing.expectApproxEqAbs(@as(f64, 1), p[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3), p[1], 1e-12);
}

test "xform: a circle under an axis scale becomes an ellipse" {
    const img = circle(.{ .scale = .{ 2, -3 } }, .{ .center = .{ 1, 1 }, .r = 2 });
    try testing.expectEqual(CircleImage{ .ellipse = .{ .center = .{ 2, -3 }, .rx = 4, .ry = 6 } }, img);
}

test "xform: a circle stays a circle under rotation" {
    const img = circle(.{ .rotate = .init(0.3) }, .{ .center = .{ 0, 0 }, .r = 5 });
    try testing.expectApproxEqAbs(@as(f64, 5), img.circle.r, 1e-12);
}

test "xform: a rotated ellipse flattens to at least 64 points" {
    const img = ellipse(.{ .rotate = .init(0.3) }, .{ .center = .{ 0, 0 }, .rx = 2, .ry = 1 });
    try testing.expectEqual(@as(usize, 64), img.polygon.len());
    try testing.expectEqual(Vec2{ 2, 0 }, img.polygon.point(0));
}

test "xform: an ellipse under a quarter turn swaps radii" {
    const img = ellipse(.{ .rotate = .init(std.math.pi / 2.0) }, .{ .center = .{ 0, 0 }, .rx = 2, .ry = 1 });
    try testing.expectEqual(@as(f64, 1), img.ellipse.rx);
    try testing.expectEqual(@as(f64, 2), img.ellipse.ry);
}

test "xform: rect under reflectX keeps its box" {
    const img = rect(.reflect_x, .{ .x = 1, .y = 2, .w = 3, .h = 4, .rx = 1 });
    try testing.expectEqual(Rect{ .x = -4, .y = 2, .w = 3, .h = 4, .rx = 1, .ry = null }, img.rect);
}

test "xform: rounded rect outline has four corner arcs" {
    const o: RectOutline = .init(.{ .x = 0, .y = 0, .w = 10, .h = 10, .rx = 2 });
    try testing.expectEqual(@as(f64, 4), o.corner_segments);
    try testing.expectEqual(@as(usize, 20), o.len());
    const first = o.point(0);
    try testing.expectApproxEqAbs(@as(f64, 8), first[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), first[1], 1e-12);
    const square: RectOutline = .init(.{ .x = 0, .y = 0, .w = 10, .h = 5 });
    try testing.expectEqual(Vec2{ 10, 5 }, square.point(2));
}

test "xform: an arc refuses a non-uniform scale" {
    const a: Arc = .{ .center = .{ 0, 0 }, .r = 1, .start = 0, .end = 1 };
    try testing.expectError(error.NonUniformScale, arc(.{ .scale = .{ 2, 1 } }, a));
    const mirrored = try arc(.reflect_x, a);
    try testing.expectEqual(std.math.pi - 1.0, mirrored.start);
    try testing.expectEqual(std.math.pi, mirrored.end);
}

test "xform: an image refuses a flip" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 };
    try testing.expectError(error.ImageTransform, image(.reflect_y, r));
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 4, .h = 4 }, try image(.{ .scale_around = .{ .factor = .{ 2, 2 }, .pivot = .{ -1, -2 } } }, r));
}
