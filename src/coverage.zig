//! Coverage primitives. Each one writes per-pixel coverage (0..1) into a
//! Mask, keeping the max where a shape overlaps itself, so one paint op
//! composites each pixel exactly once.
//!
//! Coordinates are pixel space where pixel (px, py) spans [px, px+1].

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Vec2 = [2]f64;

pub const Cap = enum { butt, round, square };

pub const Mask = struct {
    w: u32,
    h: u32,
    cov: []f32,
    touched: std.ArrayList(u32),

    pub fn init(gpa: Allocator, w: u32, h: u32) !Mask {
        const cov = try gpa.alloc(f32, @as(usize, w) * h);
        @memset(cov, 0);
        return .{ .w = w, .h = h, .cov = cov, .touched = .empty };
    }

    pub fn deinit(self: *Mask, gpa: Allocator) void {
        gpa.free(self.cov);
        self.touched.deinit(gpa);
        self.* = undefined;
    }

    pub fn cover(self: *Mask, gpa: Allocator, x: i64, y: i64, c: f32) !void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        if (c <= 0) return;
        const i: u32 = @intCast(@as(u64, @intCast(y)) * self.w + @as(u64, @intCast(x)));
        const old = self.cov[i];
        if (old == 0) try self.touched.append(gpa, i);
        if (c > old) self.cov[i] = @min(c, 1);
    }

    /// Drop all coverage without compositing.
    pub fn clear(self: *Mask) void {
        for (self.touched.items) |i| self.cov[i] = 0;
        self.touched.clearRetainingCapacity();
    }
};

/// Overlap of the pixel footprint [v - 0.5, v + 0.5] with [lo, hi].
fn overlap(v: f64, lo: f64, hi: f64) f32 {
    const o = @min(v + 0.5, hi) - @max(v - 0.5, lo);
    return @floatCast(std.math.clamp(o, 0, 1));
}

pub fn fillCircle(gpa: Allocator, m: *Mask, cx: f64, cy: f64, r: f64) !void {
    if (r <= 0) return;
    const outer = r + 0.75;
    const y0 = @max(0, @floor(cy - outer));
    const y1 = @min(@as(f64, @floatFromInt(m.h)), @ceil(cy + outer));
    var py = y0;
    while (py < y1) : (py += 1) {
        const dy = py + 0.5 - cy;
        const chord2 = outer * outer - dy * dy;
        if (chord2 <= 0) continue;
        const chord = @sqrt(chord2);
        var px = @max(0, @floor(cx - chord));
        const px1 = @min(@as(f64, @floatFromInt(m.w)), @ceil(cx + chord));
        while (px < px1) : (px += 1) {
            const dx = px + 0.5 - cx;
            const d = @sqrt(dx * dx + dy * dy);
            try m.cover(gpa, @intFromFloat(px), @intFromFloat(py), overlap(d, -r, r));
        }
    }
}

/// Annulus of half-width `hw` around radius `r`.
pub fn strokeRing(gpa: Allocator, m: *Mask, cx: f64, cy: f64, r: f64, hw: f64) !void {
    if (hw <= 0) return;
    const outer = r + hw + 0.75;
    const inner = r - hw - 0.75;
    const y0 = @max(0, @floor(cy - outer));
    const y1 = @min(@as(f64, @floatFromInt(m.h)), @ceil(cy + outer));
    var py = y0;
    while (py < y1) : (py += 1) {
        const dy = py + 0.5 - cy;
        const o2 = outer * outer - dy * dy;
        if (o2 <= 0) continue;
        const ox = @sqrt(o2);
        const ix: f64 = if (inner > 0 and inner * inner - dy * dy > 0) @sqrt(inner * inner - dy * dy) else -1;
        const spans = [2][2]f64{
            .{ cx - ox, if (ix > 0) cx - ix else cx + ox },
            .{ if (ix > 0) cx + ix else cx + ox, cx + ox },
        };
        for (spans) |s| {
            var px = @max(0, @floor(s[0]));
            const px1 = @min(@as(f64, @floatFromInt(m.w)), @ceil(s[1]));
            while (px < px1) : (px += 1) {
                const dx = px + 0.5 - cx;
                const d = @sqrt(dx * dx + dy * dy) - r;
                try m.cover(gpa, @intFromFloat(px), @intFromFloat(py), overlap(d, -hw, hw));
            }
        }
    }
}

pub fn fillRect(gpa: Allocator, m: *Mask, x0: f64, y0: f64, x1: f64, y1: f64) !void {
    const left = @min(x0, x1);
    const right = @max(x0, x1);
    const top = @min(y0, y1);
    const bottom = @max(y0, y1);
    var py = @max(0, @floor(top));
    const py1 = @min(@as(f64, @floatFromInt(m.h)), @ceil(bottom));
    while (py < py1) : (py += 1) {
        const ycov = overlap(py + 0.5, top, bottom);
        var px = @max(0, @floor(left));
        const px1 = @min(@as(f64, @floatFromInt(m.w)), @ceil(right));
        while (px < px1) : (px += 1) {
            try m.cover(gpa, @intFromFloat(px), @intFromFloat(py), ycov * overlap(px + 0.5, left, right));
        }
    }
}

/// x-range [lo, hi] for which |k*x + c| <= r, or null when empty.
fn slab(k: f64, c: f64, r: f64) ?[2]f64 {
    if (@abs(k) < 1e-12) return if (@abs(c) <= r) .{ -std.math.inf(f64), std.math.inf(f64) } else null;
    const a = (-r - c) / k;
    const b = (r - c) / k;
    return .{ @min(a, b), @max(a, b) };
}

/// One stroked segment. `cap_a` and `cap_b` pick the end treatment so
/// polylines can use round joins at interior vertices.
pub fn strokeSegment(gpa: Allocator, m: *Mask, a: Vec2, b: Vec2, hw: f64, cap_a: Cap, cap_b: Cap) !void {
    if (hw <= 0) return;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-9) {
        if (cap_a == .round or cap_b == .round) return fillCircle(gpa, m, a[0], a[1], hw);
        if (cap_a == .square or cap_b == .square) return fillRect(gpa, m, a[0] - hw, a[1] - hw, a[0] + hw, a[1] + hw);
        return;
    }
    const ux = dx / len;
    const uy = dy / len;
    const reach = hw + 1;
    const lo_t: f64 = switch (cap_a) {
        .butt => 0,
        .square => -hw,
        .round => -std.math.inf(f64),
    };
    const hi_t: f64 = switch (cap_b) {
        .butt => len,
        .square => len + hw,
        .round => std.math.inf(f64),
    };

    const ymin = @max(0, @floor(@min(a[1], b[1]) - reach));
    const ymax = @min(@as(f64, @floatFromInt(m.h)), @ceil(@max(a[1], b[1]) + reach));
    var py = ymin;
    while (py < ymax) : (py += 1) {
        const yc = py + 0.5;
        // n = (x - ax) * -uy + (yc - ay) * ux, t = (x - ax) * ux + (yc - ay) * uy
        const n_c = -a[0] * -uy + (yc - a[1]) * ux;
        const t_c = -a[0] * ux + (yc - a[1]) * uy;
        const sn = slab(-uy, n_c, reach) orelse continue;
        const st = slab(ux, t_c - len / 2, len / 2 + reach) orelse continue;
        const xa = @max(@max(sn[0], st[0]), 0);
        const xb = @min(@min(sn[1], st[1]), @as(f64, @floatFromInt(m.w)));
        if (xa > xb) continue;
        var px = @floor(xa - 0.5);
        if (px < 0) px = 0;
        const px1 = @min(@ceil(xb + 0.5), @as(f64, @floatFromInt(m.w)));
        while (px < px1) : (px += 1) {
            const xc = px + 0.5;
            const vx = xc - a[0];
            const vy = yc - a[1];
            const t = vx * ux + vy * uy;
            const n = vx * -uy + vy * ux;
            var c: f32 = undefined;
            if (t < 0 and cap_a == .round) {
                c = overlap(@sqrt(vx * vx + vy * vy), -hw, hw);
            } else if (t > len and cap_b == .round) {
                const ex = xc - b[0];
                const ey = yc - b[1];
                c = overlap(@sqrt(ex * ex + ey * ey), -hw, hw);
            } else {
                c = overlap(n, -hw, hw) * overlap(t, lo_t, hi_t);
            }
            try m.cover(gpa, @intFromFloat(px), @intFromFloat(py), c);
        }
    }
}

pub fn strokePolyline(gpa: Allocator, m: *Mask, pts: []const Vec2, hw: f64, closed: bool, cap: Cap) !void {
    if (pts.len < 2) {
        if (pts.len == 1 and cap == .round) try fillCircle(gpa, m, pts[0][0], pts[0][1], hw);
        return;
    }
    const segs = if (closed) pts.len else pts.len - 1;
    for (0..segs) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % pts.len];
        const first = i == 0 and !closed;
        const last = i == segs - 1 and !closed;
        try strokeSegment(gpa, m, a, b, hw, if (first) cap else .round, if (last) cap else .round);
    }
}

/// Dashed stroke. `dash` is {on, off}, `offset` shifts the pattern start.
pub fn strokeDashed(gpa: Allocator, m: *Mask, pts: []const Vec2, hw: f64, cap: Cap, dash: [2]f64, offset: f64) !void {
    if (pts.len < 2) return;
    const on = @max(dash[0], 1e-3);
    const cycle = on + @max(dash[1], 0);
    var d = -@mod(offset, cycle);
    var seg_i: usize = 0;
    var seg_start: f64 = 0;
    var total: f64 = 0;
    for (1..pts.len) |i| total += dist(pts[i - 1], pts[i]);

    var buf: std.ArrayList(Vec2) = .empty;
    defer buf.deinit(gpa);
    while (d < total) : (d += cycle) {
        const d0 = @max(d, 0);
        const d1 = @min(d + on, total);
        if (d1 <= d0) continue;
        buf.clearRetainingCapacity();
        // Walk forward to the segment holding d0.
        while (seg_i + 1 < pts.len - 1 and seg_start + dist(pts[seg_i], pts[seg_i + 1]) < d0) {
            seg_start += dist(pts[seg_i], pts[seg_i + 1]);
            seg_i += 1;
        }
        try buf.append(gpa, pointAt(pts, seg_i, seg_start, d0));
        var j = seg_i;
        var acc = seg_start;
        while (j + 1 < pts.len) : (j += 1) {
            const l = dist(pts[j], pts[j + 1]);
            if (acc + l >= d1) break;
            acc += l;
            try buf.append(gpa, pts[j + 1]);
        }
        try buf.append(gpa, pointAt(pts, @min(j, pts.len - 2), acc, d1));
        try strokePolyline(gpa, m, buf.items, hw, false, cap);
    }
}

fn dist(a: Vec2, b: Vec2) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn pointAt(pts: []const Vec2, seg: usize, seg_start: f64, d: f64) Vec2 {
    const a = pts[seg];
    const b = pts[seg + 1];
    const l = dist(a, b);
    if (l == 0) return a;
    const t = std.math.clamp((d - seg_start) / l, 0, 1);
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

/// Scratch buffers reused across fills.
pub const FillScratch = struct {
    acc: std.ArrayList(f32) = .empty,

    pub fn deinit(self: *FillScratch, gpa: Allocator) void {
        self.acc.deinit(gpa);
    }
};

/// Fill closed contours with the nonzero rule using signed-area
/// accumulation (the font-rs rasterizer). Coverage is exact per pixel for
/// non-overlapping edges, and |winding| is clamped to 1.
pub fn fillPath(gpa: Allocator, m: *Mask, scratch: *FillScratch, contours: []const []const Vec2) !void {
    var bx0: f64 = std.math.inf(f64);
    var by0: f64 = std.math.inf(f64);
    var bx1: f64 = -std.math.inf(f64);
    var by1: f64 = -std.math.inf(f64);
    for (contours) |c| for (c) |p| {
        bx0 = @min(bx0, p[0]);
        by0 = @min(by0, p[1]);
        bx1 = @max(bx1, p[0]);
        by1 = @max(by1, p[1]);
    };
    if (!(bx1 > bx0) or !(by1 > by0)) return;
    const ox = @max(0, @floor(bx0));
    const oy = @max(0, @floor(by0));
    const ex = @min(@as(f64, @floatFromInt(m.w)), @ceil(bx1));
    const ey = @min(@as(f64, @floatFromInt(m.h)), @ceil(by1));
    if (ex <= ox or ey <= oy) return;
    const w: usize = @intFromFloat(ex - ox);
    const h: usize = @intFromFloat(ey - oy);
    const stride = w + 2;

    try scratch.acc.resize(gpa, stride * h);
    const acc = scratch.acc.items;
    @memset(acc, 0);

    const fw: f64 = @floatFromInt(w);
    for (contours) |c| {
        if (c.len < 2) continue;
        for (0..c.len) |i| {
            const p = c[i];
            const q = c[(i + 1) % c.len];
            accumulateClipped(acc, stride, h, fw, .{ p[0] - ox, p[1] - oy }, .{ q[0] - ox, q[1] - oy });
        }
    }

    for (0..h) |y| {
        var sum: f32 = 0;
        const row = acc[y * stride ..][0..stride];
        for (0..w + 1) |x| {
            sum += row[x];
            if (x >= w) break;
            const cov = @min(@abs(sum), 1);
            if (cov > 1e-4) {
                try m.cover(gpa, @as(i64, @intFromFloat(ox)) + @as(i64, @intCast(x)), @as(i64, @intFromFloat(oy)) + @as(i64, @intCast(y)), cov);
            }
        }
    }
}

/// Split a segment at x = 0 and x = w, then clamp the outside pieces onto
/// the edge. A clamped piece still carries its winding, which is what
/// the pixels to its right need.
fn accumulateClipped(acc: []f32, stride: usize, h: usize, w: f64, p: Vec2, q: Vec2) void {
    var pts: [4]Vec2 = undefined;
    var n: usize = 0;
    pts[n] = p;
    n += 1;
    const xs = [2]f64{ 0, w };
    var ts: [2]f64 = .{ 2, 2 };
    for (xs, 0..) |xc, k| {
        if ((p[0] < xc) != (q[0] < xc) and p[0] != q[0]) ts[k] = (xc - p[0]) / (q[0] - p[0]);
    }
    if (ts[0] > ts[1]) std.mem.swap(f64, &ts[0], &ts[1]);
    for (ts) |t| {
        if (t > 0 and t < 1) {
            pts[n] = .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
            n += 1;
        }
    }
    pts[n] = q;
    n += 1;
    for (0..n - 1) |i| {
        const a: Vec2 = .{ std.math.clamp(pts[i][0], 0, w), pts[i][1] };
        const b: Vec2 = .{ std.math.clamp(pts[i + 1][0], 0, w), pts[i + 1][1] };
        accumulateLine(acc, stride, h, a, b);
    }
}

fn accumulateLine(acc: []f32, stride: usize, h: usize, p0_in: Vec2, p1_in: Vec2) void {
    if (p0_in[1] == p1_in[1]) return;
    var p0 = p0_in;
    var p1 = p1_in;
    var dir: f64 = 1;
    if (p0[1] > p1[1]) {
        dir = -1;
        std.mem.swap(Vec2, &p0, &p1);
    }
    const fh: f64 = @floatFromInt(h);
    if (p1[1] <= 0 or p0[1] >= fh) return;
    const dxdy = (p1[0] - p0[0]) / (p1[1] - p0[1]);
    var x = p0[0];
    if (p0[1] < 0) x -= p0[1] * dxdy;
    const y_start: usize = @intFromFloat(@max(0, @floor(p0[1])));
    const y_end: usize = @intFromFloat(@min(fh, @ceil(p1[1])));
    const max_x: f64 = @floatFromInt(stride - 2);
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const fy: f64 = @floatFromInt(y);
        const line = acc[y * stride ..][0..stride];
        const dy = @min(fy + 1, p1[1]) - @max(fy, p0[1]);
        const xnext = std.math.clamp(x + dxdy * dy, 0, max_x);
        const d: f64 = dy * dir;
        const x0 = @min(x, xnext);
        const x1 = @max(x, xnext);
        const x0floor = @floor(x0);
        const x0i: usize = @intFromFloat(x0floor);
        const x1ceil = @ceil(x1);
        const x1i: usize = @intFromFloat(x1ceil);
        if (x1i <= x0i + 1) {
            const xmf = 0.5 * (x + xnext) - x0floor;
            line[x0i] += @floatCast(d - d * xmf);
            line[x0i + 1] += @floatCast(d * xmf);
        } else {
            const s = 1 / (x1 - x0);
            const x0f = x0 - x0floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = x1 - x1ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            line[x0i] += @floatCast(d * a0);
            if (x1i == x0i + 2) {
                line[x0i + 1] += @floatCast(d * (1 - a0 - am));
            } else {
                const a1 = s * (1.5 - x0f);
                line[x0i + 1] += @floatCast(d * (a1 - a0));
                var xi = x0i + 2;
                while (xi < x1i - 1) : (xi += 1) line[xi] += @floatCast(d * s);
                const a2 = a1 + @as(f64, @floatFromInt(x1i - x0i - 3)) * s;
                line[x1i - 1] += @floatCast(d * (1 - a2 - am));
            }
            line[x1i] += @floatCast(d * am);
        }
        x = xnext;
    }
}

test "coverage: fillPath square is exact" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 8, 8);
    defer m.deinit(gpa);
    var s: FillScratch = .{};
    defer s.deinit(gpa);
    const sq = [_]Vec2{ .{ 1, 1 }, .{ 5, 1 }, .{ 5, 5 }, .{ 1, 5 } };
    try fillPath(gpa, &m, &s, &.{&sq});
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.cov[2 * 8 + 2], 1e-5);
    try std.testing.expectEqual(@as(f32, 0), m.cov[0]);
    try std.testing.expectEqual(@as(usize, 16), m.touched.items.len);
}

test "coverage: fillPath half pixel edge" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 4, 4);
    defer m.deinit(gpa);
    var s: FillScratch = .{};
    defer s.deinit(gpa);
    const sq = [_]Vec2{ .{ 0.5, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0.5, 4 } };
    try fillPath(gpa, &m, &s, &.{&sq});
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), m.cov[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.cov[1], 1e-5);
}

test "coverage: opposite-wound hole stays empty" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 10, 10);
    defer m.deinit(gpa);
    var s: FillScratch = .{};
    defer s.deinit(gpa);
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const hole = [_]Vec2{ .{ 3, 3 }, .{ 3, 7 }, .{ 7, 7 }, .{ 7, 3 } };
    try fillPath(gpa, &m, &s, &.{ &outer, &hole });
    try std.testing.expectEqual(@as(f32, 0), m.cov[5 * 10 + 5]);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.cov[1 * 10 + 1], 1e-5);
}

test "coverage: thin line coverage matches width" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 20, 20);
    defer m.deinit(gpa);
    try strokeSegment(gpa, &m, .{ 2, 10.5 }, .{ 18, 10.5 }, 0.15, .butt, .butt);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), m.cov[10 * 20 + 10], 1e-5);
    try std.testing.expectEqual(@as(f32, 0), m.cov[9 * 20 + 10]);
}
