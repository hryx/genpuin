//! Hatch fills and line masking. Hatching scans the region with parallel
//! lines (an active edge list over the contours rotated so the lines run
//! along x) and keeps the spans inside under the fill rule. Connected
//! hatching joins the spans of neighbouring lines end to end into
//! zigzags when the joining stroke stays inside, near the boundary.

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const geom = @import("geom.zig");
const Vec2 = geom.Vec2;
const EdgeSet = @import("EdgeSet.zig");
const offset = @import("offset.zig");

pub const Options = struct {
    /// Direction of the lines in radians.
    angle: f64 = 0,
    spacing: f64 = 4,
    /// Shift of the line lattice across the lines, in scene units.
    offset: f64 = 0,
    /// Shrink the region by this much first, negative grows it.
    inset: f64 = 0,
    /// Random shift of each line, as a fraction of spacing up to 0.49.
    jitter: f64 = 0,
    seed: u64 = 1,
    rule: geom.FillRule = .nonzero,
    /// Add a second pass at right angles.
    cross: bool = false,
    /// Grid cell for the inset, zero picks one.
    resolution: f64 = 0,
};

pub const Error = error{TooManyLines} || Allocator.Error;

const lines_max = 1 << 20;

const Span = struct { x0: f64, x1: f64 };

const Row = struct {
    y: f64,
    spans: []Span,
};

const Frame = struct {
    c: f64,
    s: f64,

    fn init(angle: f64) Frame {
        return .{ .c = math.cos(angle), .s = math.sin(angle) };
    }

    /// Into the frame where hatch lines run along x.
    fn to(f: Frame, p: Vec2) Vec2 {
        return .{ p[0] * f.c + p[1] * f.s, -p[0] * f.s + p[1] * f.c };
    }

    fn from(f: Frame, p: Vec2) Vec2 {
        return .{ p[0] * f.c - p[1] * f.s, p[0] * f.s + p[1] * f.c };
    }
};

const ScanEdge = struct {
    a: Vec2,
    b: Vec2,
    y0: f64,
    y1: f64,

    fn less(_: void, x: ScanEdge, y: ScanEdge) bool {
        return x.y0 < y.y0;
    }
};

const Crossing = struct {
    x: f64,
    sign: i32,

    fn less(_: void, a: Crossing, b: Crossing) bool {
        return a.x < b.x;
    }
};

/// Scan rotated contours with lines y = offset + k * spacing.
fn scan(arena: Allocator, rotated: geom.Contours, opts: Options, rnd: std.Random) Error![]Row {
    var edges: std.ArrayList(ScanEdge) = .empty;
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (rotated) |c| for (c, 0..) |a, i| {
        const b = c[(i + 1) % c.len];
        if (a[1] == b[1]) continue;
        try edges.append(arena, .{ .a = a, .b = b, .y0 = @min(a[1], b[1]), .y1 = @max(a[1], b[1]) });
        lo = @min(lo, a[1], b[1]);
        hi = @max(hi, a[1], b[1]);
    };
    if (edges.items.len == 0 or !(opts.spacing > 0)) return &.{};
    std.mem.sortUnstable(ScanEdge, edges.items, {}, ScanEdge.less);

    const jitter = std.math.clamp(opts.jitter, 0, 0.49) * opts.spacing;
    const k0 = @floor((lo - opts.offset) / opts.spacing) - 1;
    const k1 = @ceil((hi - opts.offset) / opts.spacing) + 1;
    if (k1 - k0 > lines_max) return error.TooManyLines;

    var rows: std.ArrayList(Row) = .empty;
    var active: std.ArrayList(ScanEdge) = .empty;
    var xs: std.ArrayList(Crossing) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var next: usize = 0;
    var k = k0;
    while (k <= k1) : (k += 1) {
        const y = opts.offset + k * opts.spacing + if (jitter > 0) (rnd.float(f64) * 2 - 1) * jitter else 0;
        while (next < edges.items.len and edges.items[next].y0 <= y) : (next += 1) try active.append(arena, edges.items[next]);
        var n: usize = 0;
        xs.clearRetainingCapacity();
        for (active.items) |e| {
            if (e.y1 <= y) continue;
            active.items[n] = e;
            n += 1;
            const x = e.a[0] + (y - e.a[1]) * (e.b[0] - e.a[0]) / (e.b[1] - e.a[1]);
            try xs.append(arena, .{ .x = x, .sign = if (e.a[1] < e.b[1]) 1 else -1 });
        }
        active.items.len = n;
        if (xs.items.len == 0) continue;
        std.mem.sortUnstable(Crossing, xs.items, {}, Crossing.less);
        spans.clearRetainingCapacity();
        var w: i32 = 0;
        var start: f64 = 0;
        for (xs.items) |x| {
            const was = geom.inside(opts.rule, w);
            w += x.sign;
            const now = geom.inside(opts.rule, w);
            if (!was and now) start = x.x;
            if (was and !now and x.x - start > opts.spacing * 1e-6) try spans.append(arena, .{ .x0 = start, .x1 = x.x });
        }
        if (spans.items.len > 0) try rows.append(arena, .{ .y = y, .spans = try arena.dupe(Span, spans.items) });
    }
    return rows.items;
}

fn rotate(arena: Allocator, contours: geom.Contours, f: Frame) ![][]Vec2 {
    const out = try arena.alloc([]Vec2, contours.len);
    for (contours, out) |c, *o| {
        o.* = try arena.alloc(Vec2, c.len);
        for (c, o.*) |p, *q| q.* = f.to(p);
    }
    return out;
}

/// The region after the inset, in the arena.
fn region(arena: Allocator, contours: geom.Contours, opts: Options) !struct { contours: geom.Contours, rule: geom.FillRule } {
    if (opts.inset == 0) return .{ .contours = contours, .rule = opts.rule };
    const res = try offset.offsets(arena, contours, &.{-opts.inset}, .{ .resolution = opts.resolution, .rule = opts.rule });
    return .{ .contours = res[0], .rule = .nonzero };
}

/// Hatch the region as separate segments. Caller owns the result.
pub fn hatch(gpa: Allocator, contours: geom.Contours, opts: Options) Error![][2]Vec2 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(opts.seed);
    const reg = try region(arena, contours, opts);
    var o = opts;
    o.rule = reg.rule;

    var out: std.ArrayList([2]Vec2) = .empty;
    errdefer out.deinit(gpa);
    const passes: usize = if (opts.cross) 2 else 1;
    for (0..passes) |pass| {
        const f: Frame = .init(opts.angle + @as(f64, @floatFromInt(pass)) * std.math.pi / 2.0);
        const rows = try scan(arena, try rotate(arena, reg.contours, f), o, prng.random());
        for (rows) |r| for (r.spans) |s| {
            try out.append(gpa, .{ f.from(.{ s.x0, r.y }), f.from(.{ s.x1, r.y }) });
        };
    }
    return out.toOwnedSlice(gpa);
}

const Chain = struct {
    pts: std.ArrayList(Vec2),
    at_right: bool,
    open: bool,
};

/// Hatch the region as zigzag polylines, joining a span to one on the
/// next line when the joining stroke stays inside and hugs the boundary.
/// Caller owns the result, free it with geom.freeContours.
pub fn hatchConnected(gpa: Allocator, contours: geom.Contours, opts: Options) Error![][]Vec2 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(opts.seed);
    const reg = try region(arena, contours, opts);
    var o = opts;
    o.rule = reg.rule;

    var out: std.ArrayList([]Vec2) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    const passes: usize = if (opts.cross) 2 else 1;
    for (0..passes) |pass| {
        const f: Frame = .init(opts.angle + @as(f64, @floatFromInt(pass)) * std.math.pi / 2.0);
        const rotated = try rotate(arena, reg.contours, f);
        const rows = try scan(arena, rotated, o, prng.random());
        var set: EdgeSet = try .init(arena, rotated, true);
        const chains = try zigzag(arena, &set, rows, o);
        for (chains) |c| {
            const pts = try gpa.alloc(Vec2, c.pts.items.len);
            for (c.pts.items, pts) |p, *q| q.* = f.from(p);
            out.append(gpa, pts) catch |err| {
                gpa.free(pts);
                return err;
            };
        }
    }
    return out.toOwnedSlice(gpa);
}

fn zigzag(arena: Allocator, set: *const EdgeSet, rows: []const Row, opts: Options) ![]Chain {
    var chains: std.ArrayList(Chain) = .empty;
    var candidates: std.ArrayList(u32) = .empty;
    var prev_y: f64 = -std.math.inf(f64);
    for (rows) |r| {
        const taken = try arena.alloc(bool, r.spans.len);
        @memset(taken, false);
        // Rows with no spans were skipped, so only join across one step.
        const adjacent = r.y - prev_y < opts.spacing * 1.5;
        for (chains.items) |*c| {
            if (!c.open) continue;
            if (!adjacent) {
                c.open = false;
                continue;
            }
            const end = c.pts.items[c.pts.items.len - 1];
            var best: ?usize = null;
            var best_cost: f64 = std.math.inf(f64);
            for (r.spans, 0..) |s, i| {
                if (taken[i]) continue;
                const near: Vec2 = .{ if (c.at_right) s.x1 else s.x0, r.y };
                const cost = @abs(near[0] - end[0]);
                if (cost >= best_cost) continue;
                if (!try joinInside(arena, set, end, near, opts, &candidates)) continue;
                best = i;
                best_cost = cost;
            }
            const i = best orelse {
                c.open = false;
                continue;
            };
            taken[i] = true;
            const s = r.spans[i];
            if (c.at_right) {
                try c.pts.append(arena, .{ s.x1, r.y });
                try c.pts.append(arena, .{ s.x0, r.y });
            } else {
                try c.pts.append(arena, .{ s.x0, r.y });
                try c.pts.append(arena, .{ s.x1, r.y });
            }
            c.at_right = !c.at_right;
        }
        for (r.spans, taken) |s, t| {
            if (t) continue;
            var pts: std.ArrayList(Vec2) = .empty;
            try pts.append(arena, .{ s.x0, r.y });
            try pts.append(arena, .{ s.x1, r.y });
            try chains.append(arena, .{ .pts = pts, .at_right = true, .open = true });
        }
        prev_y = r.y;
    }
    return chains.items;
}

/// Whether the stroke a to b, both on the boundary, runs inside without
/// crossing an edge and stays within one spacing of the boundary.
fn joinInside(arena: Allocator, set: *const EdgeSet, a: Vec2, b: Vec2, opts: Options, scratch: *std.ArrayList(u32)) !bool {
    const mid = geom.scale(geom.add(a, b), 0.5);
    // A join along a boundary edge lies on it, so test just to either side.
    const d = geom.sub(b, a);
    const len = geom.length(d);
    if (len == 0) return true;
    const nudge = geom.scale(.{ -d[1], d[0] }, opts.spacing * 1e-3 / len);
    if (!geom.inside(opts.rule, set.winding(geom.add(mid, nudge))) and
        !geom.inside(opts.rule, set.winding(geom.sub(mid, nudge)))) return false;
    if (set.distance(mid, opts.spacing * 2) > opts.spacing) return false;
    scratch.clearRetainingCapacity();
    try set.query(arena, .{ @min(a[0], b[0]), @min(a[1], b[1]) }, .{ @max(a[0], b[0]), @max(a[1], b[1]) }, scratch);
    // Both ends sit on the boundary, often on the very edge the join runs
    // along, so only a clear crossing away from the ends counts.
    for (scratch.items) |i| {
        const e = set.edges[i];
        const ed = geom.sub(e[1], e[0]);
        const s1 = geom.cross(d, geom.sub(e[0], a));
        const s2 = geom.cross(d, geom.sub(e[1], a));
        const s3 = geom.cross(ed, geom.sub(a, e[0]));
        const s4 = geom.cross(ed, geom.sub(b, e[0]));
        const eps = 1e-7 * len * geom.length(ed);
        if (@min(@abs(s1), @abs(s2), @abs(s3), @abs(s4)) <= eps) continue;
        if (s1 * s2 < 0 and s3 * s4 < 0) return false;
    }
    return true;
}

/// Keep the parts of each polyline inside the region, or outside it when
/// `outside` is set. Caller owns the result, free it with geom.freeContours.
pub fn clipLines(gpa: Allocator, lines: geom.Contours, contours: geom.Contours, rule: geom.FillRule, outside: bool) ![][]Vec2 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var set: EdgeSet = try .init(arena, contours, true);

    var out: std.ArrayList([]Vec2) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    var piece: std.ArrayList(Vec2) = .empty;
    var hits: std.ArrayList(u32) = .empty;
    var ts: std.ArrayList(f64) = .empty;
    for (lines) |line| {
        piece.clearRetainingCapacity();
        for (0..line.len -| 1) |i| {
            const p0 = line[i];
            const p1 = line[i + 1];
            const d = geom.sub(p1, p0);
            ts.clearRetainingCapacity();
            try ts.append(arena, 0);
            hits.clearRetainingCapacity();
            try set.query(arena, .{ @min(p0[0], p1[0]), @min(p0[1], p1[1]) }, .{ @max(p0[0], p1[0]), @max(p0[1], p1[1]) }, &hits);
            for (hits.items) |h| {
                const e = set.edges[h];
                const ed = geom.sub(e[1], e[0]);
                const denom = geom.cross(d, ed);
                if (denom == 0) continue;
                const q = geom.sub(e[0], p0);
                const t = geom.cross(q, ed) / denom;
                const u = geom.cross(q, d) / denom;
                if (t > 0 and t < 1 and u >= 0 and u <= 1) try ts.append(arena, t);
            }
            try ts.append(arena, 1);
            std.mem.sortUnstable(f64, ts.items, {}, std.sort.asc(f64));
            for (ts.items[0 .. ts.items.len - 1], ts.items[1..]) |t0, t1| {
                if (t1 <= t0) continue;
                const mid = geom.add(p0, geom.scale(d, (t0 + t1) / 2));
                if (geom.inside(rule, set.winding(mid)) == outside) {
                    try flush(gpa, &out, &piece);
                    continue;
                }
                if (piece.items.len == 0) try piece.append(arena, geom.add(p0, geom.scale(d, t0)));
                try piece.append(arena, if (t1 == 1) p1 else geom.add(p0, geom.scale(d, t1)));
            }
        }
        try flush(gpa, &out, &piece);
    }
    return out.toOwnedSlice(gpa);
}

fn flush(gpa: Allocator, out: *std.ArrayList([]Vec2), piece: *std.ArrayList(Vec2)) !void {
    defer piece.clearRetainingCapacity();
    if (piece.items.len < 2) return;
    const owned = try gpa.dupe(Vec2, piece.items);
    errdefer gpa.free(owned);
    try out.append(gpa, owned);
}

const testing = std.testing;

fn totalLength(segs: []const [2]Vec2) f64 {
    var s: f64 = 0;
    for (segs) |g| s += geom.dist(g[0], g[1]);
    return s;
}

test "hatch: horizontal lines across a square" {
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const segs = try hatch(testing.allocator, &.{&sq}, .{ .spacing = 2, .offset = 1 });
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 5), segs.len);
    for (segs, 0..) |s, i| {
        try testing.expectEqual(Vec2{ 0, 1 + 2 * @as(f64, @floatFromInt(i)) }, s[0]);
        try testing.expectEqual(Vec2{ 10, 1 + 2 * @as(f64, @floatFromInt(i)) }, s[1]);
    }
}

test "hatch: holes are skipped and the rule matters" {
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner_same = [_]Vec2{ .{ 4, 4 }, .{ 6, 4 }, .{ 6, 6 }, .{ 4, 6 } };
    const nz = try hatch(testing.allocator, &.{ &outer, &inner_same }, .{ .spacing = 1, .offset = 0.5 });
    defer testing.allocator.free(nz);
    try testing.expectApproxEqAbs(@as(f64, 100), totalLength(nz), 1e-9);
    const eo = try hatch(testing.allocator, &.{ &outer, &inner_same }, .{ .spacing = 1, .offset = 0.5, .rule = .evenodd });
    defer testing.allocator.free(eo);
    try testing.expectApproxEqAbs(@as(f64, 96), totalLength(eo), 1e-9);
}

test "hatch: rotated and crossed passes cover the area twice" {
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const segs = try hatch(testing.allocator, &.{&sq}, .{ .spacing = 0.5, .angle = 0.4, .cross = true });
    defer testing.allocator.free(segs);
    // Line length per unit of spacing approximates the area.
    try testing.expectApproxEqRel(@as(f64, 2 * 100 / 0.5), totalLength(segs), 0.02);
}

test "hatch: connected zigzag makes one path in a convex shape" {
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const paths = try hatchConnected(testing.allocator, &.{&sq}, .{ .spacing = 2, .offset = 1 });
    defer geom.freeContours(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqual(@as(usize, 10), paths[0].len);
    try testing.expectEqual(Vec2{ 10, 1 }, paths[0][1]);
    try testing.expectEqual(Vec2{ 10, 3 }, paths[0][2]);
}

test "hatch: connected zigzag fills a disc in one path per pass" {
    var disc: [90]Vec2 = undefined;
    for (&disc, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / 90 * std.math.tau;
        p.* = .{ 10 * math.cos(t), 10 * math.sin(t) };
    }
    const paths = try hatchConnected(testing.allocator, &.{&disc}, .{ .spacing = 1, .angle = 0.3, .cross = true });
    defer geom.freeContours(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
}

test "hatch: clipLines keeps the inside or the outside" {
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const line = [_]Vec2{ .{ -5, 5 }, .{ 5, 5 }, .{ 15, 5 } };
    const in = try clipLines(testing.allocator, &.{&line}, &.{&sq}, .nonzero, false);
    defer geom.freeContours(testing.allocator, in);
    try testing.expectEqual(@as(usize, 1), in.len);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 5 }, .{ 5, 5 }, .{ 10, 5 } }, in[0]);
    const out = try clipLines(testing.allocator, &.{&line}, &.{&sq}, .nonzero, true);
    defer geom.freeContours(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.len);
}
