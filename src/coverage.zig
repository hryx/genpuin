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
    if (dist(a, b) < degenerate_len) {
        const cap: Cap = if (cap_a == .round or cap_b == .round) .round else if (cap_a == .square or cap_b == .square) .square else .butt;
        return strokeDot(gpa, m, a, .{ 1, 0 }, hw, cap);
    }
    return segment(gpa, m, a, b, hw, cap_a, cap_b, .{});
}

/// Below this length in pixels a segment has no direction.
const degenerate_len = 1e-9;

/// The plane across a butt end of an open stroke. A round join at a
/// vertex near the end is a full disc here, and the part of the disc
/// behind this plane is cut away so the join never reaches past the end.
const Cut = struct {
    p: Vec2,
    /// Unit direction from the end into the stroke.
    u: Vec2,

    /// Whether any pixel the segment a-b covers at half-width `hw` can
    /// lie where `keep` cuts.
    fn reaches(cut: Cut, a: Vec2, b: Vec2, hw: f64) bool {
        // Pixel centers sit within hw + 1 + sqrt(1/2) of the segment.
        const margin = hw + 2;
        const ta = (a[0] - cut.p[0]) * cut.u[0] + (a[1] - cut.p[1]) * cut.u[1];
        const tb = (b[0] - cut.p[0]) * cut.u[0] + (b[1] - cut.p[1]) * cut.u[1];
        if (@min(ta, tb) > margin + 0.5) return false;
        return distToSegment(cut.p, a, b) <= margin + hw + 1;
    }

    /// The share of a pixel at (x, y) in front of the plane. Pixels more
    /// than `near` from the end are left alone, since only joins within
    /// half a stroke width of the end can poke past it.
    fn keep(cut: Cut, x: f64, y: f64, near: f64) f32 {
        const vx = x - cut.p[0];
        const vy = y - cut.p[1];
        const t = vx * cut.u[0] + vy * cut.u[1];
        if (t >= 0.5 or vx * vx + vy * vy > near * near) return 1;
        return overlap(t, 0, std.math.inf(f64));
    }
};

const Cuts = struct {
    start: ?Cut = null,
    end: ?Cut = null,

    fn keep(cuts: Cuts, x: f64, y: f64, near: f64) f32 {
        var k: f32 = 1;
        if (cuts.start) |c| k *= c.keep(x, y, near);
        if (cuts.end) |c| k *= c.keep(x, y, near);
        return k;
    }
};

fn segment(gpa: Allocator, m: *Mask, a: Vec2, b: Vec2, hw: f64, cap_a: Cap, cap_b: Cap, cuts: Cuts) !void {
    if (cuts.start == null and cuts.end == null) return segmentCut(gpa, m, a, b, hw, cap_a, cap_b, cuts, false);
    return segmentCut(gpa, m, a, b, hw, cap_a, cap_b, cuts, true);
}

fn segmentCut(gpa: Allocator, m: *Mask, a: Vec2, b: Vec2, hw: f64, cap_a: Cap, cap_b: Cap, cuts: Cuts, comptime cut: bool) !void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    assert(len >= degenerate_len);
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

    // A square cap's far corners lie up to hw * sqrt(2) from the end
    // point along the y axis.
    const reach_y = if (cap_a == .square or cap_b == .square) hw * std.math.sqrt2 + 1 else reach;
    const ymin = @max(0, @floor(@min(a[1], b[1]) - reach_y));
    const ymax = @min(@as(f64, @floatFromInt(m.h)), @ceil(@max(a[1], b[1]) + reach_y));
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
            const near_a = cut and cap_a == .round and t < 0.5;
            const near_b = cut and cap_b == .round and t > len - 0.5;
            if (near_a or near_b) {
                const keep = cuts.keep(xc, yc, reach);
                // Where a cut takes the disc away, the segment's own body
                // still covers what its edge reaches.
                if (keep < 1) {
                    var disc = c;
                    if (t >= 0 and t <= len) {
                        const e = if (near_a and (!near_b or t < len / 2)) a else b;
                        const ex = xc - e[0];
                        const ey = yc - e[1];
                        disc = overlap(@sqrt(ex * ex + ey * ey), -hw, hw);
                    }
                    const body = overlap(n, -hw, hw) * overlap(t, if (cap_a == .round) 0 else lo_t, if (cap_b == .round) len else hi_t);
                    c = @max(disc * keep, body);
                }
            }
            try m.cover(gpa, @intFromFloat(px), @intFromFloat(py), c);
        }
    }
}

/// The stroke of a zero-length subpath, as SVG 2 defines it. Nothing for
/// butt caps, a disc for round, and for square a square turned to `u`.
fn strokeDot(gpa: Allocator, m: *Mask, p: Vec2, u: Vec2, hw: f64, cap: Cap) !void {
    switch (cap) {
        .butt => {},
        .round => try fillCircle(gpa, m, p[0], p[1], hw),
        .square => {
            const a: Vec2 = .{ p[0] - u[0] * hw, p[1] - u[1] * hw };
            const b: Vec2 = .{ p[0] + u[0] * hw, p[1] + u[1] * hw };
            try segment(gpa, m, a, b, hw, .butt, .butt, .{});
        },
    }
}

/// A stroked polyline with round joins. Zero-length segments are
/// skipped, and a polyline with no other kind is a dot.
pub fn strokePolyline(gpa: Allocator, m: *Mask, pts: []const Vec2, hw: f64, closed: bool, cap: Cap) !void {
    return polyline(gpa, m, pts, hw, closed, cap, .{ 1, 0 });
}

/// `dot_u` turns the square a zero-length polyline strokes to.
fn polyline(gpa: Allocator, m: *Mask, pts: []const Vec2, hw: f64, closed: bool, cap: Cap, dot_u: Vec2) !void {
    if (hw <= 0 or pts.len == 0) return;
    const segs = if (closed) pts.len else pts.len - 1;
    var first: ?usize = null;
    var last: usize = 0;
    var total: f64 = 0;
    for (0..segs) |i| {
        const l = dist(pts[i], pts[(i + 1) % pts.len]);
        if (l < degenerate_len) continue;
        if (first == null) first = i;
        last = i;
        total += l;
    }
    if (first == null) return strokeDot(gpa, m, pts[0], dot_u, hw, cap);

    if (closed) {
        for (0..segs) |i| {
            const a = pts[i];
            const b = pts[(i + 1) % pts.len];
            if (dist(a, b) < degenerate_len) continue;
            try segment(gpa, m, a, b, hw, .round, .round, .{});
        }
        return;
    }

    // Square caps cover every join's reach past an end, and round caps
    // are discs that do too. Butt ends cut the joins near them. Past
    // half a turn of arc, which takes at least pi * hw of length when
    // the curve is no tighter than the stroke, the path may come back
    // over its own end legitimately, so joins that far along stay whole.
    var cut_start: ?Cut = null;
    var cut_end: ?Cut = null;
    if (cap == .butt) {
        cut_start = .{ .p = pts[first.?], .u = direction(pts[first.?], pts[first.? + 1]) };
        cut_end = .{ .p = pts[last + 1], .u = direction(pts[last + 1], pts[last]) };
    }
    const cut_len = std.math.pi * hw;

    var s: f64 = 0;
    for (first.?..last + 1) |i| {
        const a = pts[i];
        const b = pts[i + 1];
        const l = dist(a, b);
        if (l < degenerate_len) continue;
        defer s += l;
        const cuts: Cuts = .{
            .start = if (s <= cut_len) cutFor(cut_start, a, b, hw) else null,
            .end = if (total - s - l <= cut_len) cutFor(cut_end, a, b, hw) else null,
        };
        try segment(gpa, m, a, b, hw, if (i == first.?) cap else .round, if (i == last) cap else .round, cuts);
    }
}

/// Dashed stroke. `dash` is {on, off}, `offset` shifts the pattern start.
/// A closed path repeats its first point at the end, and its dashes run
/// on across that point. Dashes follow cairo where SVG leaves room: one
/// that starts on a vertex keeps the join there, and one that ends on a
/// vertex does not. A dash on a path of zero length is a dot.
pub fn strokeDashed(gpa: Allocator, m: *Mask, pts: []const Vec2, hw: f64, cap: Cap, dash: [2]f64, offset: f64, closed: bool) !void {
    if (pts.len == 0) return;
    const on = @max(dash[0], 1e-3);
    const cycle = on + @max(dash[1], 0);
    var d = -@mod(offset, cycle);
    var total: f64 = 0;
    for (1..pts.len) |i| total += dist(pts[i - 1], pts[i]);
    if (total < degenerate_len) {
        if (d + on > 0) try strokeDot(gpa, m, pts[0], .{ 1, 0 }, hw, cap);
        return;
    }
    if (closed and d + on >= total) return polyline(gpa, m, pts[0 .. pts.len - 1], hw, true, cap, .{ 1, 0 });

    var walk: DashWalk = .{ .pts = pts, .closed = closed };
    var piece: std.ArrayList(Vec2) = .empty;
    defer piece.deinit(gpa);
    // The first dash of a closed path waits, since the last one may run
    // on into it.
    var head: std.ArrayList(Vec2) = .empty;
    defer head.deinit(gpa);
    var head_lead = false;
    var head_u: Vec2 = .{ 1, 0 };
    while (d < total) : (d += cycle) {
        const d0 = @max(d, 0);
        const d1 = @min(d + on, total);
        if (d1 <= d0) continue;
        piece.clearRetainingCapacity();
        if (closed and d0 == 0) {
            head_lead = try walk.collect(gpa, &head, d0, d1);
            head_u = walk.here();
            continue;
        }
        _ = try walk.collect(gpa, &piece, d0, d1);
        if (closed and d1 == total and head.items.len > 0) {
            const skip: usize = if (head_lead) 2 else 1;
            try piece.appendSlice(gpa, head.items[skip..]);
            head.clearRetainingCapacity();
        }
        try polyline(gpa, m, piece.items, hw, false, cap, walk.here());
    }
    if (head.items.len > 0) try polyline(gpa, m, head.items, hw, false, cap, head_u);
}

/// Cuts dash pieces out of a polyline front to back.
const DashWalk = struct {
    pts: []const Vec2,
    closed: bool,
    seg: usize = 0,
    seg_start: f64 = 0,

    /// Dash positions this close to a vertex count as on it.
    const snap = 1e-6;
    /// Length of the stub that carries the incoming direction into a
    /// dash starting on a vertex, so the join there is drawn.
    const lead_len = 1e-6;

    /// Append the path between arc lengths d0 and d1 to `out`. Returns
    /// whether it starts with a lead stub. Calls come in increasing d0.
    fn collect(w: *DashWalk, gpa: Allocator, out: *std.ArrayList(Vec2), d0: f64, d1: f64) !bool {
        const pts = w.pts;
        while (w.seg + 1 < pts.len - 1 and w.seg_start + dist(pts[w.seg], pts[w.seg + 1]) <= d0 + snap) {
            w.seg_start += dist(pts[w.seg], pts[w.seg + 1]);
            w.seg += 1;
        }
        const p0 = pointAt(pts, w.seg, w.seg_start, d0);
        var lead = false;
        if (@abs(d0 - w.seg_start) <= snap) {
            if (w.incoming()) |u| {
                try out.append(gpa, .{ p0[0] - u[0] * lead_len, p0[1] - u[1] * lead_len });
                lead = true;
            }
        }
        try out.append(gpa, p0);
        var j = w.seg;
        var acc = w.seg_start;
        while (j + 1 < pts.len) : (j += 1) {
            const l = dist(pts[j], pts[j + 1]);
            if (acc + l >= d1) break;
            acc += l;
            try out.append(gpa, pts[j + 1]);
        }
        try out.append(gpa, pointAt(pts, @min(j, pts.len - 2), acc, d1));
        return lead;
    }

    /// Direction of the last segment with a length before the vertex the
    /// walk stands on, wrapping around on a closed path.
    fn incoming(w: *const DashWalk) ?Vec2 {
        const pts = w.pts;
        var i = w.seg;
        while (i > 0) {
            i -= 1;
            if (dist(pts[i], pts[i + 1]) >= degenerate_len) return direction(pts[i], pts[i + 1]);
        }
        if (!w.closed) return null;
        i = pts.len - 1;
        while (i > w.seg + 1) {
            i -= 1;
            if (dist(pts[i], pts[i + 1]) >= degenerate_len) return direction(pts[i], pts[i + 1]);
        }
        return null;
    }

    /// Direction of the path where the walk stands.
    fn here(w: *const DashWalk) Vec2 {
        return pathDirection(w.pts, w.seg);
    }
};

fn cutFor(cut: ?Cut, a: Vec2, b: Vec2, hw: f64) ?Cut {
    const c = cut orelse return null;
    return if (c.reaches(a, b, hw)) c else null;
}

fn distToSegment(p: Vec2, a: Vec2, b: Vec2) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    const t = if (len2 > 0) std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1) else 0;
    return std.math.hypot(p[0] - a[0] - dx * t, p[1] - a[1] - dy * t);
}

/// Unit direction from `a` to `b`, which must not coincide.
fn direction(a: Vec2, b: Vec2) Vec2 {
    const l = dist(a, b);
    assert(l >= degenerate_len);
    return .{ (b[0] - a[0]) / l, (b[1] - a[1]) / l };
}

/// Direction of the path at segment `seg`, or of the next segment with a
/// length when that one has none.
fn pathDirection(pts: []const Vec2, seg: usize) Vec2 {
    for (seg..pts.len - 1) |i| {
        if (dist(pts[i], pts[i + 1]) >= degenerate_len) return direction(pts[i], pts[i + 1]);
    }
    return .{ 1, 0 };
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

fn covAt(m: *const Mask, x: u32, y: u32) f32 {
    return m.cov[y * m.w + x];
}

test "coverage: joins of a flattened arc stay inside its butt ends" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 64, 64);
    defer m.deinit(gpa);
    // A quarter circle of radius 30 around (32, 2) in 2 px steps, from
    // (62, 2) to (32, 32), stroked 16 wide.
    var pts: [25]Vec2 = undefined;
    for (&pts, 0..) |*p, i| {
        const a = std.math.pi / 2.0 * @as(f64, @floatFromInt(i)) / 24.0;
        p.* = .{ 32 + 30 * @cos(a), 2 + 30 * @sin(a) };
    }
    try strokePolyline(gpa, &m, &pts, 8, false, .butt);
    // The start runs straight down, so its butt end is the line y = 2.
    try std.testing.expectEqual(@as(f32, 0), covAt(&m, 58, 0));
    try std.testing.expectEqual(@as(f32, 1), covAt(&m, 58, 4));
    // The end runs left, so its butt end is the line x = 32.
    try std.testing.expectEqual(@as(f32, 0), covAt(&m, 29, 34));
    try std.testing.expectEqual(@as(f32, 1), covAt(&m, 34, 34));
}

test "coverage: a repeated end point is not a round end" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 20, 10);
    defer m.deinit(gpa);
    const pts = [_]Vec2{ .{ 5, 5 }, .{ 5, 5 }, .{ 15, 5 }, .{ 15, 5 } };
    try strokePolyline(gpa, &m, &pts, 3, false, .butt);
    try std.testing.expectEqual(@as(f32, 0), covAt(&m, 3, 5));
    try std.testing.expectEqual(@as(f32, 0), covAt(&m, 16, 5));
    try std.testing.expectEqual(@as(f32, 1), covAt(&m, 5, 5));
}

test "coverage: a zero-length line strokes by its cap" {
    const gpa = std.testing.allocator;
    const pts = [_]Vec2{ .{ 10, 10 }, .{ 10, 10 } };
    const cases = [_]struct { cap: Cap, center: f32, corner: f32 }{
        .{ .cap = .butt, .center = 0, .corner = 0 },
        .{ .cap = .round, .center = 1, .corner = 0 },
        .{ .cap = .square, .center = 1, .corner = 1 },
    };
    for (cases) |c| {
        var m: Mask = try .init(gpa, 20, 20);
        defer m.deinit(gpa);
        try strokePolyline(gpa, &m, &pts, 4, false, c.cap);
        try std.testing.expectEqual(c.center, covAt(&m, 10, 10));
        // Pixel (6, 6) spans [6, 7] on both axes, inside the square
        // [6, 14] and outside the disc of radius 4.
        try std.testing.expectEqual(c.corner, covAt(&m, 6, 6));
    }
}

test "coverage: a dash starting on a vertex keeps only the join there" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 40, 40);
    defer m.deinit(gpa);
    // Dashes [0, 10] and [20, 30], the second starting on the corner.
    const pts = [_]Vec2{ .{ 10, 10 }, .{ 30, 10 }, .{ 30, 40 } };
    try strokeDashed(gpa, &m, &pts, 3, .butt, .{ 10, 10 }, 0, false);
    // Nothing behind the corner on the incoming side.
    try std.testing.expectEqual(@as(f32, 0), covAt(&m, 28, 8));
    // The round join on the outside of the corner.
    try std.testing.expectEqual(@as(f32, 1), covAt(&m, 30, 8));
    try std.testing.expectEqual(@as(f32, 1), covAt(&m, 29, 12));
}

test "coverage: a dash on a zero-length path is a dot only where the pattern is on" {
    const gpa = std.testing.allocator;
    const pts = [_]Vec2{ .{ 10, 10 }, .{ 10, 10 } };
    const offsets = [_]struct { offset: f64, want: f32 }{
        .{ .offset = 0, .want = 1 },
        .{ .offset = 6, .want = 0 },
    };
    for (offsets) |o| {
        var m: Mask = try .init(gpa, 20, 20);
        defer m.deinit(gpa);
        try strokeDashed(gpa, &m, &pts, 3, .round, .{ 5, 5 }, o.offset, false);
        try std.testing.expectEqual(o.want, covAt(&m, 10, 10));
    }
}

test "coverage: a square cap on a diagonal reaches its far corner" {
    const gpa = std.testing.allocator;
    var m: Mask = try .init(gpa, 40, 45);
    defer m.deinit(gpa);
    try strokeSegment(gpa, &m, .{ 10, 10 }, .{ 20, 30 }, 7, .square, .square);
    // Pixel (17, 38) lies inside the cap, more than hw + 1 below the end.
    try std.testing.expectEqual(@as(f32, 1), covAt(&m, 17, 38));
}
