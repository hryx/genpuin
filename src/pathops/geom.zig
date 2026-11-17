//! Points, exact orientation and the small vector helpers the path
//! operations share.

const std = @import("std");

pub const Vec2 = [2]f64;

pub const FillRule = enum { nonzero, evenodd };

pub fn inside(rule: FillRule, winding: i32) bool {
    return switch (rule) {
        .nonzero => winding != 0,
        .evenodd => @mod(winding, 2) != 0,
    };
}

pub fn eql(a: Vec2, b: Vec2) bool {
    return a[0] == b[0] and a[1] == b[1];
}

/// Lexicographic order, x first. The sweep line moves in this order.
pub fn lexLess(a: Vec2, b: Vec2) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

pub fn sub(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub fn scale(a: Vec2, s: f64) Vec2 {
    return .{ a[0] * s, a[1] * s };
}

pub fn dot(a: Vec2, b: Vec2) f64 {
    return a[0] * b[0] + a[1] * b[1];
}

pub fn cross(a: Vec2, b: Vec2) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

pub fn length(a: Vec2) f64 {
    return @sqrt(dot(a, a));
}

pub fn dist(a: Vec2, b: Vec2) f64 {
    return length(sub(a, b));
}

/// Squared distance from p to the segment a-b.
pub fn segmentDist2(p: Vec2, a: Vec2, b: Vec2) f64 {
    const ab = sub(b, a);
    const ap = sub(p, a);
    const len2 = dot(ab, ab);
    const t = if (len2 > 0) std.math.clamp(dot(ap, ab) / len2, 0, 1) else 0;
    const d = sub(ap, scale(ab, t));
    return dot(d, d);
}

/// Twice the signed area of a closed contour, positive when it turns
/// the same way as a positive `orient`.
pub fn area2(pts: []const Vec2) f64 {
    if (pts.len < 3) return 0;
    var s: f64 = 0;
    var prev = pts[pts.len - 1];
    for (pts) |p| {
        s += cross(prev, p);
        prev = p;
    }
    return s;
}

/// Positive when c lies left of the directed line a to b (counterclockwise
/// with y up), negative when right, zero when the three are collinear.
/// The sign is exact, the magnitude only when the fast path decides,
/// since the exact fallback returns plus or minus one. Shewchuk's filtered orient2d ("Adaptive Precision
/// Floating-Point Arithmetic and Fast Robust Geometric Predicates", 1997)
/// with an exact expansion sum as the fallback.
pub fn orient(a: Vec2, b: Vec2, c: Vec2) f64 {
    const l = (a[0] - c[0]) * (b[1] - c[1]);
    const r = (a[1] - c[1]) * (b[0] - c[0]);
    const det = l - r;
    const bound = orient_err_bound * (@abs(l) + @abs(r));
    if (det > bound or -det > bound) return det;
    if (l == 0 and r == 0) return 0;
    return orientExact(a, b, c);
}

const half_eps = std.math.floatEps(f64) * 0.5;
const orient_err_bound = (3.0 + 16.0 * half_eps) * half_eps;

fn orientExact(a: Vec2, b: Vec2, c: Vec2) f64 {
    // The determinant expanded into six products (the c.x * c.y terms
    // cancel), each split into an exact head and tail.
    const terms = [6][2]f64{
        .{ a[0], b[1] },  .{ -a[0], c[1] }, .{ -c[0], b[1] },
        .{ -a[1], b[0] }, .{ a[1], c[0] },  .{ c[1], b[0] },
    };
    var e: [16]f64 = undefined;
    var n: usize = 0;
    for (terms) |t| {
        const p = twoProduct(t[0], t[1]);
        n = growExpansion(&e, n, p[0]);
        n = growExpansion(&e, n, p[1]);
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        if (e[i] != 0) return if (e[i] > 0) 1 else -1;
    }
    return 0;
}

// Plain f64 arithmetic only below: no fused multiply-add, f128 or libm
// calls. Any of those links compiler-rt's math routines into the
// executable, and the embedded LuaJIT then binds math.sin and friends to
// them instead of the system libm, which shifts Lua results by an ulp.

const splitter: f64 = 134217729; // 2^27 + 1

fn split(a: f64) [2]f64 {
    const c = splitter * a;
    const hi = c - (c - a);
    return .{ hi, a - hi };
}

/// Exact product as head and tail, Dekker's algorithm with Veltkamp's split.
fn twoProduct(a: f64, b: f64) [2]f64 {
    const p = a * b;
    const x = split(a);
    const y = split(b);
    const err = ((x[0] * y[0] - p) + x[0] * y[1] + x[1] * y[0]) + x[1] * y[1];
    return .{ p, err };
}

/// a * b - c * d with both products exact and one rounding at the end.
fn diffProducts(a: f64, b: f64, c: f64, d: f64) f64 {
    const x = twoProduct(a, b);
    const y = twoProduct(c, d);
    return (x[0] - y[0]) + (x[1] - y[1]);
}

/// Shewchuk's grow-expansion with zero elimination. Components stay
/// nonoverlapping and increase in magnitude, so the last nonzero one
/// carries the sign.
fn growExpansion(e: *[16]f64, n: usize, b: f64) usize {
    var q = b;
    var m: usize = 0;
    for (0..n) |i| {
        const s = q + e[i];
        const bv = s - q;
        const err = (q - (s - bv)) + (e[i] - bv);
        q = s;
        if (err != 0) {
            e[m] = err;
            m += 1;
        }
    }
    e[m] = q;
    return m + 1;
}

pub const Intersection = union(enum) {
    none,
    point: Vec2,
    /// Collinear overlap from the first to the second point, in sweep order.
    overlap: [2]Vec2,
};

/// Intersect two segments given with their endpoints in sweep order.
/// Crossing points that are not an endpoint are clamped into both
/// segments' extents.
pub fn intersect(a0: Vec2, a1: Vec2, b0: Vec2, b1: Vec2) Intersection {
    std.debug.assert(!lexLess(a1, a0));
    std.debug.assert(!lexLess(b1, b0));
    const o1 = orient(a0, a1, b0);
    const o2 = orient(a0, a1, b1);
    if (o1 == 0 and o2 == 0) {
        const lo = if (lexLess(a0, b0)) b0 else a0;
        const hi = if (lexLess(a1, b1)) a1 else b1;
        if (lexLess(lo, hi)) return .{ .overlap = .{ lo, hi } };
        if (eql(lo, hi)) return .{ .point = lo };
        return .none;
    }
    if ((o1 > 0 and o2 > 0) or (o1 < 0 and o2 < 0)) return .none;
    const o3 = orient(b0, b1, a0);
    const o4 = orient(b0, b1, a1);
    if ((o3 > 0 and o4 > 0) or (o3 < 0 and o4 < 0)) return .none;
    if (o1 == 0) return .{ .point = b0 };
    if (o2 == 0) return .{ .point = b1 };
    if (o3 == 0) return .{ .point = a0 };
    if (o4 == 0) return .{ .point = a1 };

    return .{ .point = clampInto(clampInto(lineCrossing(.{ a0, a1 }, .{ b0, b1 }), a0, a1), b0, b1) };
}

/// Crossing point of two lines that are not parallel. The cross products
/// are compensated, so the point is close to correctly rounded.
pub fn lineCrossing(la: [2]Vec2, lb: [2]Vec2) Vec2 {
    const r = sub(la[1], la[0]);
    const s = sub(lb[1], lb[0]);
    const q = sub(lb[0], la[0]);
    const t = diffProducts(q[0], s[1], q[1], s[0]) / diffProducts(r[0], s[1], r[1], s[0]);
    return .{ la[0][0] + t * r[0], la[0][1] + t * r[1] };
}

const pio2_hi: f64 = 1.57079632673412561417e+00;
const pio2_lo: f64 = 6.07710050650619224932e-11;

/// Sine and cosine of x without libm (see the note above twoProduct).
/// Cody-Waite reduction by quarter turns, then Taylor series on
/// [-pi/4, pi/4], good to about 1e-16 for |x| up to a few thousand turns.
pub fn sinCos(x: f64) [2]f64 {
    if (!(@abs(x) < 1e9)) return .{ std.math.nan(f64), std.math.nan(f64) };
    const q = @round(x / (std.math.pi / 2.0));
    const r = (x - q * pio2_hi) - q * pio2_lo;
    const r2 = r * r;
    var sn: f64 = 0;
    var cs: f64 = 0;
    // Horner over 1/n! from the highest term down.
    var k: u32 = 17;
    while (k >= 1) : (k -= 2) {
        sn = 1 - sn * r2 / @as(f64, @floatFromInt((k + 1) * (k + 2)));
        if (k == 1) break;
    }
    sn *= r;
    k = 16;
    while (true) : (k -= 2) {
        cs = 1 - cs * r2 / @as(f64, @floatFromInt((k + 1) * (k + 2)));
        if (k == 0) break;
    }
    const quadrant: u2 = @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(q)))));
    return switch (quadrant) {
        0 => .{ sn, cs },
        1 => .{ cs, -sn },
        2 => .{ -sn, -cs },
        3 => .{ -cs, sn },
    };
}

/// Snap p into the extent of the segment lo..hi given in sweep order.
pub fn clampInto(p: Vec2, lo: Vec2, hi: Vec2) Vec2 {
    if (!lexLess(lo, p)) return lo;
    if (!lexLess(p, hi)) return hi;
    return .{
        std.math.clamp(p[0], @min(lo[0], hi[0]), @max(lo[0], hi[0])),
        std.math.clamp(p[1], @min(lo[1], hi[1]), @max(lo[1], hi[1])),
    };
}

/// Arena-friendly list of contours, each a slice of points.
pub const Contours = []const []const Vec2;

pub fn freeContours(gpa: std.mem.Allocator, contours: []const []const Vec2) void {
    for (contours) |c| gpa.free(c);
    gpa.free(contours);
}

/// Bounding box of every point, or null when there are none.
pub fn bounds(contours: Contours) ?[2]Vec2 {
    var lo: Vec2 = .{ std.math.inf(f64), std.math.inf(f64) };
    var hi: Vec2 = .{ -std.math.inf(f64), -std.math.inf(f64) };
    var any = false;
    for (contours) |c| for (c) |p| {
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
        any = true;
    };
    return if (any) .{ lo, hi } else null;
}

test "geom: orient is exact on nearly collinear points" {
    const a: Vec2 = .{ 0.5, 0.5 };
    const b: Vec2 = .{ 12, 12 };
    const c: Vec2 = .{ 24, 24 };
    try std.testing.expectEqual(@as(f64, 0), orient(a, b, c));
    const d: Vec2 = .{ 24, std.math.nextAfter(f64, 24, 25) };
    try std.testing.expect(orient(a, b, d) > 0);
    const e: Vec2 = .{ 24, std.math.nextAfter(f64, 24, 23) };
    try std.testing.expect(orient(a, b, e) < 0);
}

test "geom: sinCos matches the builtins" {
    var x: f64 = -40;
    while (x < 40) : (x += 0.0137) {
        const sc = sinCos(x);
        try std.testing.expectApproxEqAbs(@sin(x), sc[0], 1e-15);
        try std.testing.expectApproxEqAbs(@cos(x), sc[1], 1e-15);
    }
    try std.testing.expectEqual(@as(f64, 0), sinCos(0)[0]);
    try std.testing.expectEqual(@as(f64, 1), sinCos(0)[1]);
}

test "geom: lineCrossing is accurate on long thin crossings" {
    const p = lineCrossing(.{ .{ 0, 0 }, .{ 3, 1e-9 } }, .{ .{ 1, 1 }, .{ 1, -1 } });
    try std.testing.expectEqual(@as(f64, 1), p[0]);
    try std.testing.expectApproxEqRel(@as(f64, 1e-9 / 3.0), p[1], 1e-15);
}

test "geom: intersect classifies crossings, touches and overlaps" {
    const x = intersect(.{ 0, 0 }, .{ 2, 2 }, .{ 0, 2 }, .{ 2, 0 });
    try std.testing.expectEqual(Vec2{ 1, 1 }, x.point);
    const t = intersect(.{ 0, 0 }, .{ 2, 0 }, .{ 1, 0 }, .{ 1, 3 });
    try std.testing.expectEqual(Vec2{ 1, 0 }, t.point);
    const o = intersect(.{ 0, 0 }, .{ 4, 0 }, .{ 2, 0 }, .{ 6, 0 });
    try std.testing.expectEqual([2]Vec2{ .{ 2, 0 }, .{ 4, 0 } }, o.overlap);
    try std.testing.expectEqual(Intersection.none, intersect(.{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 }));
}
