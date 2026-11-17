//! Boolean operations on two contour sets: union, intersection,
//! difference and xor.
//!
//! The sweep is the one from Martinez, Rueda and Feito, "A new algorithm
//! for computing Boolean operations on polygons", Computers & Geosciences
//! 35 (2009), and its follow-up by Martinez, Ogayar, Jimenez and Rueda, "A
//! simple algorithm for Boolean operations on polygons", Advances in
//! Engineering Software 64 (2013): endpoint events in lexicographic order,
//! a status line of segments ordered bottom to top, and subdivision of
//! every crossing and collinear overlap when two segments become
//! neighbours.
//!
//! Where the papers flag each edge with in/out parity and give overlapping
//! edges special types, here every edge carries a winding delta per
//! operand. Coincident edges are merged by adding their deltas and a
//! second sweep over the subdivided edges assigns winding numbers, so each
//! operand may follow the nonzero or even-odd rule and may overlap itself.
//! Orientation tests are exact (see geom.orient).

const std = @import("std");
const libm = @import("../libm.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const geom = @import("geom.zig");
const Vec2 = geom.Vec2;
const FillRule = geom.FillRule;

pub const Op = enum { @"union", intersect, difference, xor };

pub const Error = error{TooComplex} || Allocator.Error;

/// Combine `subject` and `clip` with `op`. Contours are closed implicitly.
/// The result's outer contours turn positively (see geom.orient) and its
/// holes negatively, so it fills correctly under either rule. Caller owns
/// the result, free it with geom.freeContours.
pub fn compute(gpa: Allocator, subject: geom.Contours, clip: geom.Contours, op: Op, rule: FillRule) Error![][]Vec2 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const edges = try subdivide(arena, subject, clip);
    const result = try classify(arena, edges, op, rule);
    return connect(gpa, arena, result);
}

/// One end of a piece of an input edge. `line` is the input edge the piece
/// came from, in sweep order. Collinearity, status order and crossing
/// points are all decided on these lines, so a piece cut at a rounded
/// point still sorts, overlaps and splits exactly like its siblings.
const Event = struct {
    point: Vec2,
    other: u32,
    line: [2]Vec2,
    left: bool,
    /// Winding change for subject and clip, crossing from below to above.
    wind: [2]i32,
};

const Edge = struct {
    l: Vec2,
    r: Vec2,
    line: [2]Vec2,
    wind: [2]i32,
};

fn side(line: [2]Vec2, p: Vec2) f64 {
    return geom.orient(line[0], line[1], p);
}

fn linesCollinear(a: [2]Vec2, b: [2]Vec2) bool {
    return side(a, b[0]) == 0 and side(a, b[1]) == 0;
}

/// Strict order of two pieces in the status line, a below b. Pieces on
/// one line fall back on their ids so the order stays total.
fn segmentBelow(al: Vec2, ar: Vec2, la: [2]Vec2, aid: u32, bl: Vec2, br: Vec2, lb: [2]Vec2, bid: u32) bool {
    if (aid == bid) return false;
    if (linesCollinear(la, lb)) return aid < bid;
    if (geom.eql(al, bl)) {
        const o = side(la, br);
        if (o != 0) return o > 0;
        return side(lb, ar) < 0;
    }
    if (al[0] == bl[0]) return al[1] < bl[1];
    if (geom.lexLess(bl, al)) {
        var o = side(lb, al);
        if (o == 0) o = side(lb, ar);
        return o < 0;
    }
    var o = side(la, bl);
    if (o == 0) o = side(la, br);
    return o > 0;
}

/// Intersect two pieces, each given by its endpoints and its line.
fn intersectPieces(al: Vec2, ar: Vec2, la: [2]Vec2, bl: Vec2, br: Vec2, lb: [2]Vec2) geom.Intersection {
    if (linesCollinear(la, lb)) {
        const lo = if (geom.lexLess(al, bl)) bl else al;
        const hi = if (geom.lexLess(ar, br)) ar else br;
        if (geom.lexLess(lo, hi)) return .{ .overlap = .{ lo, hi } };
        if (geom.eql(lo, hi)) return .{ .point = lo };
        return .none;
    }
    const o1 = side(la, bl);
    const o2 = side(la, br);
    if ((o1 > 0 and o2 > 0) or (o1 < 0 and o2 < 0)) return .none;
    const o3 = side(lb, al);
    const o4 = side(lb, ar);
    if ((o3 > 0 and o4 > 0) or (o3 < 0 and o4 < 0)) return .none;
    const p: Vec2 = if (o1 == 0) bl else if (o2 == 0) br else if (o3 == 0) al else if (o4 == 0) ar else geom.lineCrossing(la, lb);
    return .{ .point = geom.clampInto(geom.clampInto(p, al, ar), bl, br) };
}

const Sweep = struct {
    arena: Allocator,
    events: std.ArrayList(Event),
    queue: Queue,
    status: std.ArrayList(u32),

    const Queue = std.PriorityQueue(u32, *const std.ArrayList(Event), queueOrder);

    fn queueOrder(events: *const std.ArrayList(Event), a: u32, b: u32) std.math.Order {
        if (a == b) return .eq;
        return if (eventLess(events.items, a, b)) .lt else .gt;
    }

    fn leftOf(ev: []const Event, i: u32) u32 {
        return if (ev[i].left) i else ev[i].other;
    }

    /// Sweep order: by point, right endpoints before left ones, then the
    /// lower piece first.
    fn eventLess(ev: []const Event, a: u32, b: u32) bool {
        const ea = ev[a];
        const eb = ev[b];
        if (!geom.eql(ea.point, eb.point)) return geom.lexLess(ea.point, eb.point);
        if (ea.left != eb.left) return !ea.left;
        if (!linesCollinear(ea.line, eb.line)) {
            const o = geom.orient(ea.point, ev[ea.other].point, ev[eb.other].point);
            if (o != 0) return o > 0;
        }
        return leftOf(ev, a) < leftOf(ev, b);
    }

    fn right(s: *const Sweep, e: u32) Vec2 {
        return s.events.items[s.events.items[e].other].point;
    }

    fn below(s: *const Sweep, a: u32, b: u32) bool {
        const ev = s.events.items;
        return segmentBelow(ev[a].point, ev[ev[a].other].point, ev[a].line, a, ev[b].point, ev[ev[b].other].point, ev[b].line, b);
    }

    fn collinear(s: *const Sweep, a: u32, b: u32) bool {
        return linesCollinear(s.events.items[a].line, s.events.items[b].line);
    }

    fn addContour(s: *Sweep, c: []const Vec2, operand: usize) !void {
        for (c, 0..) |a, i| {
            const b = c[(i + 1) % c.len];
            if (geom.eql(a, b)) continue;
            const forward = geom.lexLess(a, b);
            const line: [2]Vec2 = if (forward) .{ a, b } else .{ b, a };
            var wind: [2]i32 = .{ 0, 0 };
            wind[operand] = if (forward) 1 else -1;
            const l: u32 = @intCast(s.events.items.len);
            try s.events.append(s.arena, .{ .point = line[0], .other = l + 1, .line = line, .left = true, .wind = wind });
            try s.events.append(s.arena, .{ .point = line[1], .other = l, .line = line, .left = false, .wind = wind });
        }
    }

    /// Split the piece whose left event is `e` at p, strictly inside it.
    fn divide(s: *Sweep, e: u32, p: Vec2) !void {
        const old_right = s.events.items[e].other;
        const wind = s.events.items[e].wind;
        const line = s.events.items[e].line;
        const r: u32 = @intCast(s.events.items.len);
        const l = r + 1;
        try s.events.append(s.arena, .{ .point = p, .other = e, .line = line, .left = false, .wind = wind });
        try s.events.append(s.arena, .{ .point = p, .other = old_right, .line = line, .left = true, .wind = wind });
        s.events.items[old_right].other = l;
        s.events.items[e].other = r;
        try s.queue.push(s.arena, r);
        try s.queue.push(s.arena, l);
    }

    fn divideInside(s: *Sweep, e: u32, p: Vec2) !void {
        if (geom.lexLess(s.events.items[e].point, p) and geom.lexLess(p, s.right(e))) try s.divide(e, p);
    }

    /// Subdivide two status neighbours, a below b, so that they meet only
    /// at shared endpoints. An overlap is cut down to one coincident piece
    /// and, once both pieces are in the status, b is merged into a and
    /// removed. Returns the removed piece.
    fn possibleIntersection(s: *Sweep, a: u32, b: u32) !?u32 {
        const ev = s.events.items;
        switch (intersectPieces(ev[a].point, s.right(a), ev[a].line, ev[b].point, s.right(b), ev[b].line)) {
            .none => return null,
            .point => |p| {
                try s.divideInside(a, p);
                try s.divideInside(b, p);
                return null;
            },
            .overlap => |o| {
                for ([2]u32{ a, b }) |e| {
                    try s.divideInside(e, o[1]);
                    try s.divideInside(e, o[0]);
                }
                return s.mergeCoincident(a, b);
            },
        }
    }

    fn mergeCoincident(s: *Sweep, a: u32, b: u32) ?u32 {
        const ev = s.events.items;
        if (!geom.eql(ev[a].point, ev[b].point) or !geom.eql(s.right(a), s.right(b))) return null;
        ev[a].wind[0] += ev[b].wind[0];
        ev[a].wind[1] += ev[b].wind[1];
        ev[b].wind = .{ 0, 0 };
        ev[ev[a].other].wind = ev[a].wind;
        ev[ev[b].other].wind = ev[b].wind;
        const idx = std.mem.indexOfScalar(u32, s.status.items, b).?;
        _ = s.status.orderedRemove(idx);
        return b;
    }

    fn insert(s: *Sweep, e: u32) !void {
        var lo: usize = 0;
        var hi: usize = s.status.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.below(e, s.status.items[mid])) hi = mid else lo = mid + 1;
        }
        try s.status.insert(s.arena, lo, e);
    }

    /// Check the new piece against its neighbours, walking on past
    /// collinear ones so stacked overlaps all get cut and merged.
    fn checkNeighbours(s: *Sweep, e: u32) !void {
        var skip: usize = 0;
        while (true) {
            const idx = std.mem.indexOfScalar(u32, s.status.items, e) orelse return;
            if (idx + 1 + skip >= s.status.items.len) break;
            const n = s.status.items[idx + 1 + skip];
            const removed = try s.possibleIntersection(e, n);
            if (removed == e) return;
            if (removed == n) continue;
            if (!s.collinear(e, n)) break;
            skip += 1;
        }
        skip = 0;
        while (true) {
            const idx = std.mem.indexOfScalar(u32, s.status.items, e) orelse return;
            if (idx < 1 + skip) break;
            const n = s.status.items[idx - 1 - skip];
            const removed = try s.possibleIntersection(n, e);
            if (removed == e) return;
            if (removed == n) continue;
            if (!s.collinear(e, n)) break;
            skip += 1;
        }
    }
};

/// First sweep: split every edge at every crossing and overlap, then
/// merge coincident pieces.
fn subdivide(arena: Allocator, subject: geom.Contours, clip: geom.Contours) Error![]Edge {
    var s: Sweep = .{
        .arena = arena,
        .events = .empty,
        .queue = undefined,
        .status = .empty,
    };
    for (subject) |c| try s.addContour(c, 0);
    for (clip) |c| try s.addContour(c, 1);
    s.queue = .initContext(&s.events);
    for (0..s.events.items.len) |i| try s.queue.push(arena, @intCast(i));

    // Each split adds two events. A pathological input could keep
    // splitting on rounded points, so the total is capped.
    const limit = 16 * s.events.items.len + 4_000_000;
    while (s.queue.pop()) |e| {
        if (s.events.items.len > limit) return error.TooComplex;
        if (s.events.items[e].left) {
            try s.insert(e);
            try s.checkNeighbours(e);
            continue;
        }
        const l = s.events.items[e].other;
        const idx = std.mem.indexOfScalar(u32, s.status.items, l) orelse continue;
        _ = s.status.orderedRemove(idx);
        if (idx > 0 and idx < s.status.items.len) {
            _ = try s.possibleIntersection(s.status.items[idx - 1], s.status.items[idx]);
        }
    }

    var edges: std.ArrayList(Edge) = .empty;
    for (s.events.items) |ev| {
        if (!ev.left or (ev.wind[0] == 0 and ev.wind[1] == 0)) continue;
        const r = s.events.items[ev.other].point;
        if (geom.eql(ev.point, r)) continue;
        assert(geom.lexLess(ev.point, r));
        try edges.append(arena, .{ .l = ev.point, .r = r, .line = ev.line, .wind = ev.wind });
    }
    std.mem.sortUnstable(Edge, edges.items, {}, edgeLess);

    var n: usize = 0;
    for (edges.items) |e| {
        if (n > 0 and geom.eql(edges.items[n - 1].l, e.l) and geom.eql(edges.items[n - 1].r, e.r)) {
            edges.items[n - 1].wind[0] += e.wind[0];
            edges.items[n - 1].wind[1] += e.wind[1];
            continue;
        }
        edges.items[n] = e;
        n += 1;
    }
    var m: usize = 0;
    for (edges.items[0..n]) |e| {
        if (e.wind[0] == 0 and e.wind[1] == 0) continue;
        edges.items[m] = e;
        m += 1;
    }
    return edges.items[0..m];
}

fn edgeLess(_: void, a: Edge, b: Edge) bool {
    if (!geom.eql(a.l, b.l)) return geom.lexLess(a.l, b.l);
    return geom.lexLess(a.r, b.r);
}

fn member(op: Op, rule: FillRule, w: [2]i32) bool {
    const s = geom.inside(rule, w[0]);
    const c = geom.inside(rule, w[1]);
    return switch (op) {
        .@"union" => s or c,
        .intersect => s and c,
        .difference => s and !c,
        .xor => s != c,
    };
}

/// One end of an edge in the second sweep.
const End = packed struct(u32) {
    right: bool,
    edge: u31,
};

const ClassifyCtx = struct {
    edges: []const Edge,

    fn point(ctx: ClassifyCtx, end: End) Vec2 {
        const e = ctx.edges[end.edge];
        return if (end.right) e.r else e.l;
    }

    fn otherPoint(ctx: ClassifyCtx, end: End) Vec2 {
        return ctx.point(.{ .right = !end.right, .edge = end.edge });
    }

    fn less(ctx: ClassifyCtx, a: End, b: End) bool {
        const pa = ctx.point(a);
        const pb = ctx.point(b);
        if (!geom.eql(pa, pb)) return geom.lexLess(pa, pb);
        if (a.right != b.right) return a.right;
        if (!linesCollinear(ctx.edges[a.edge].line, ctx.edges[b.edge].line)) {
            const o = geom.orient(pa, ctx.otherPoint(a), ctx.otherPoint(b));
            if (o != 0) return o > 0;
        }
        return @as(u32, @bitCast(a)) < @as(u32, @bitCast(b));
    }
};

/// Second sweep over edges that no longer cross: each edge learns the
/// winding numbers just below it from its status neighbour, and edges
/// where membership changes across them make the result.
fn classify(arena: Allocator, edges: []const Edge, op: Op, rule: FillRule) ![][2]Vec2 {
    const ctx: ClassifyCtx = .{ .edges = edges };
    const ends = try arena.alloc(End, edges.len * 2);
    for (0..edges.len) |i| {
        ends[2 * i] = .{ .right = false, .edge = @intCast(i) };
        ends[2 * i + 1] = .{ .right = true, .edge = @intCast(i) };
    }
    std.mem.sortUnstable(End, ends, ctx, ClassifyCtx.less);

    const wind_below = try arena.alloc([2]i32, edges.len);
    var status: std.ArrayList(u32) = .empty;
    for (ends) |end| {
        const e: u32 = end.edge;
        if (end.right) {
            const idx = std.mem.indexOfScalar(u32, status.items, e) orelse continue;
            _ = status.orderedRemove(idx);
            continue;
        }
        var lo: usize = 0;
        var hi: usize = status.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const o = edges[status.items[mid]];
            if (segmentBelow(edges[e].l, edges[e].r, edges[e].line, e, o.l, o.r, o.line, status.items[mid])) hi = mid else lo = mid + 1;
        }
        try status.insert(arena, lo, e);
        if (lo == 0) {
            wind_below[e] = .{ 0, 0 };
        } else {
            const p = status.items[lo - 1];
            wind_below[e] = .{ wind_below[p][0] + edges[p].wind[0], wind_below[p][1] + edges[p].wind[1] };
        }
    }

    var out: std.ArrayList([2]Vec2) = .empty;
    for (edges, wind_below) |e, wb| {
        const wa: [2]i32 = .{ wb[0] + e.wind[0], wb[1] + e.wind[1] };
        const in_below = member(op, rule, wb);
        const in_above = member(op, rule, wa);
        if (in_below == in_above) continue;
        try out.append(arena, if (in_above) .{ e.l, e.r } else .{ e.r, e.l });
    }
    return out.items;
}

fn fromLess(_: void, a: [2]Vec2, b: [2]Vec2) bool {
    return geom.lexLess(a[0], b[0]);
}

/// Chain directed result edges into closed contours. At a vertex with
/// several ways on, take the sharpest left turn, which keeps contours that
/// touch at a point apart.
fn connect(gpa: Allocator, arena: Allocator, edges: [][2]Vec2) ![][]Vec2 {
    std.mem.sortUnstable([2]Vec2, edges, {}, fromLess);
    const used = try arena.alloc(bool, edges.len);
    @memset(used, false);

    var out: std.ArrayList([]Vec2) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    var pts: std.ArrayList(Vec2) = .empty;
    for (0..edges.len) |start| {
        if (used[start]) continue;
        pts.clearRetainingCapacity();
        const origin = edges[start][0];
        var cur = start;
        used[cur] = true;
        while (true) {
            try pts.append(arena, edges[cur][0]);
            const v = edges[cur][1];
            if (geom.eql(v, origin)) break;
            cur = pickNext(edges, used, v, geom.sub(v, edges[cur][0])) orelse break;
            used[cur] = true;
        }
        dropCollinear(&pts);
        if (pts.items.len < 3) continue;
        try out.append(gpa, try gpa.dupe(Vec2, pts.items));
    }
    return out.toOwnedSlice(gpa);
}

fn pickNext(edges: []const [2]Vec2, used: []const bool, v: Vec2, din: Vec2) ?usize {
    var lo: usize = 0;
    var hi: usize = edges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (geom.lexLess(edges[mid][0], v)) lo = mid + 1 else hi = mid;
    }
    var best: ?usize = null;
    var best_turn: f64 = -std.math.inf(f64);
    var i = lo;
    while (i < edges.len and geom.eql(edges[i][0], v)) : (i += 1) {
        if (used[i]) continue;
        const dout = geom.sub(edges[i][1], v);
        const turn = libm.atan2(geom.cross(din, dout), geom.dot(din, dout));
        if (turn > best_turn) {
            best_turn = turn;
            best = i;
        }
    }
    return best;
}

/// Remove vertices that sit on the line through their neighbours, which
/// undoes the splits the sweep made along straight edges.
fn dropCollinear(pts: *std.ArrayList(Vec2)) void {
    var n: usize = 0;
    const items = pts.items;
    for (items) |p| {
        items[n] = p;
        n += 1;
        while (n >= 3 and geom.orient(items[n - 3], items[n - 2], items[n - 1]) == 0) {
            items[n - 2] = items[n - 1];
            n -= 1;
        }
    }
    var first: usize = 0;
    while (n - first >= 3) {
        if (geom.orient(items[n - 2], items[n - 1], items[first]) == 0) {
            n -= 1;
        } else if (geom.orient(items[n - 1], items[first], items[first + 1]) == 0) {
            first += 1;
        } else break;
    }
    std.mem.copyForwards(Vec2, items[0 .. n - first], items[first..n]);
    pts.items.len = n - first;
}

fn totalArea(contours: []const []const Vec2) f64 {
    var a: f64 = 0;
    for (contours) |c| a += geom.area2(c) / 2;
    return a;
}

const testing = std.testing;

fn expectArea(expected: f64, subject: geom.Contours, clip: geom.Contours, op: Op) !void {
    const r = try compute(testing.allocator, subject, clip, op, .nonzero);
    defer geom.freeContours(testing.allocator, r);
    try testing.expectApproxEqAbs(expected, totalArea(r), 1e-9);
}

const unit = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
const right_unit = [_]Vec2{ .{ 1, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 1, 1 } };

test "boolean: squares sharing an edge" {
    try expectArea(2, &.{&unit}, &.{&right_unit}, .@"union");
    try expectArea(0, &.{&unit}, &.{&right_unit}, .intersect);
    try expectArea(1, &.{&unit}, &.{&right_unit}, .difference);
    try expectArea(2, &.{&unit}, &.{&right_unit}, .xor);

    const r = try compute(testing.allocator, &.{&unit}, &.{&right_unit}, .@"union", .nonzero);
    defer geom.freeContours(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(usize, 4), r[0].len);
}

test "boolean: a polygon with itself" {
    const tri = [_]Vec2{ .{ 0, 0 }, .{ 4, 1 }, .{ 1, 3 } };
    try expectArea(5.5, &.{&tri}, &.{&tri}, .@"union");
    try expectArea(5.5, &.{&tri}, &.{&tri}, .intersect);
    try expectArea(0, &.{&tri}, &.{&tri}, .difference);
    try expectArea(0, &.{&tri}, &.{&tri}, .xor);
}

test "boolean: squares touching at a corner stay two contours" {
    const corner = [_]Vec2{ .{ 1, 1 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 } };
    const r = try compute(testing.allocator, &.{&unit}, &.{&corner}, .@"union", .nonzero);
    defer geom.freeContours(testing.allocator, r);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectApproxEqAbs(@as(f64, 2), totalArea(r), 1e-12);
    try expectArea(0, &.{&unit}, &.{&corner}, .intersect);
}

test "boolean: collinear overlapping edges and a hole" {
    const big = [_]Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const hole = [_]Vec2{ .{ 1, 1 }, .{ 1, 3 }, .{ 3, 3 }, .{ 3, 1 } };
    const bar = [_]Vec2{ .{ 2, 0 }, .{ 6, 0 }, .{ 6, 2 }, .{ 2, 2 } };
    // big minus hole is 12. The bar adds 4 outside and fills 1 of the hole.
    try expectArea(17, &.{ &big, &hole }, &.{&bar}, .@"union");
    try expectArea(4 - 1, &.{ &big, &hole }, &.{&bar}, .intersect);
    try expectArea(12 - 3, &.{ &big, &hole }, &.{&bar}, .difference);
}

test "boolean: nonzero against even-odd on a doubled contour" {
    const twice = [_]Vec2{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const nz = try compute(testing.allocator, &.{ &twice, &twice }, &.{}, .@"union", .nonzero);
    defer geom.freeContours(testing.allocator, nz);
    try testing.expectApproxEqAbs(@as(f64, 4), totalArea(nz), 1e-12);
    const eo = try compute(testing.allocator, &.{ &twice, &twice }, &.{}, .@"union", .evenodd);
    defer geom.freeContours(testing.allocator, eo);
    try testing.expectEqual(@as(usize, 0), eo.len);
}

fn windingAt(contours: []const []const Vec2, p: Vec2) i32 {
    const EdgeSet = @import("EdgeSet.zig");
    var w: i32 = 0;
    for (contours) |c| for (c, 0..) |a, i| {
        w += EdgeSet.crossingSign(.{ a, c[(i + 1) % c.len] }, p);
    };
    return w;
}

fn starRing(gpa: Allocator) ![3][]Vec2 {
    const star = try gpa.alloc(Vec2, 10);
    for (star, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / 10 * std.math.tau;
        const r: f64 = if (i % 2 == 0) 10 else 4;
        p.* = .{ r * libm.cos(t), r * libm.sin(t) };
    }
    const outer = try gpa.alloc(Vec2, 48);
    const inner = try gpa.alloc(Vec2, 48);
    for (outer, inner, 0..) |*o, *in, i| {
        const t = @as(f64, @floatFromInt(i)) / 48 * std.math.tau;
        o.* = .{ 8 * libm.cos(t) + 1, 8 * libm.sin(t) };
        in.* = .{ 5 * libm.cos(-t) + 1, 5 * libm.sin(-t) };
    }
    return .{ star, outer, inner };
}

/// Classify random points against the inputs and against the result.
fn checkPointwise(subject: geom.Contours, clip: geom.Contours, op: Op, rule: FillRule, lo: Vec2, hi: Vec2, seed: u64) !void {
    const gpa = testing.allocator;
    const r = try compute(gpa, subject, clip, op, rule);
    defer geom.freeContours(gpa, r);
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    const n_samples = 4000;
    var hits: usize = 0;
    for (0..n_samples) |_| {
        const p: Vec2 = .{ lo[0] + rnd.float(f64) * (hi[0] - lo[0]), lo[1] + rnd.float(f64) * (hi[1] - lo[1]) };
        const want = member(op, rule, .{ windingAt(subject, p), windingAt(clip, p) });
        const got = windingAt(r, p);
        if (want) hits += 1;
        try testing.expect(got == 0 or got == 1);
        try testing.expectEqual(want, got == 1);
    }
    // Area by point sampling against the result's exact area. Four
    // thousand samples put the standard error near 0.8 percent of the box.
    const box = (hi[0] - lo[0]) * (hi[1] - lo[1]);
    const estimate = box * @as(f64, @floatFromInt(hits)) / n_samples;
    try testing.expectApproxEqAbs(estimate, totalArea(r), box * 0.04);
}

test "boolean: star against a ring with a hole" {
    const gpa = testing.allocator;
    const s = try starRing(gpa);
    defer for (s) |c| gpa.free(c);
    inline for (.{ Op.@"union", Op.intersect, Op.difference, Op.xor }) |op| {
        try checkPointwise(&.{s[0]}, &.{ s[1], s[2] }, op, .nonzero, .{ -11, -11 }, .{ 11, 11 }, 3);
    }
}

test "boolean: random degenerate polygons match point classification" {
    // Vertices come from a small integer grid or a small pool of float
    // points, forcing shared vertices, collinear overlaps (exact on the
    // grid, rounded in the pool) and self-intersections in nearly every pair.
    var prng: std.Random.DefaultPrng = .init(1234);
    const rnd = prng.random();
    var a_pts: [8]Vec2 = undefined;
    var b_pts: [8]Vec2 = undefined;
    var c_pts: [5]Vec2 = undefined;
    for (0..200) |round| {
        const na = 3 + rnd.uintLessThan(usize, 6);
        const nb = 3 + rnd.uintLessThan(usize, 6);
        const grid: u32 = if (round % 3 == 0) 3 else 6;
        const g: f64 = @floatFromInt(grid);
        var pool: [7]Vec2 = undefined;
        for (&pool) |*p| p.* = .{ rnd.float(f64) * g, rnd.float(f64) * g };
        for ([_][]Vec2{ a_pts[0..na], b_pts[0..nb], &c_pts }) |pts| for (pts) |*p| {
            p.* = if (round % 2 == 0)
                .{ @floatFromInt(rnd.uintLessThan(u32, grid)), @floatFromInt(rnd.uintLessThan(u32, grid)) }
            else
                pool[rnd.uintLessThan(usize, pool.len)];
        };
        const rule: FillRule = if (round % 4 < 2) .nonzero else .evenodd;
        inline for (.{ Op.@"union", Op.intersect, Op.difference, Op.xor }) |op| {
            try checkPointwise(&.{ a_pts[0..na], &c_pts }, &.{b_pts[0..nb]}, op, rule, .{ -0.5, -0.5 }, .{ g, g }, round);
        }
    }
}

test "boolean: random float polygons match point classification" {
    var prng: std.Random.DefaultPrng = .init(99);
    const rnd = prng.random();
    var a_pts: [12]Vec2 = undefined;
    var b_pts: [12]Vec2 = undefined;
    for (0..60) |round| {
        for (&a_pts) |*p| p.* = .{ rnd.float(f64) * 10, rnd.float(f64) * 10 };
        for (&b_pts) |*p| p.* = .{ rnd.float(f64) * 10, rnd.float(f64) * 10 };
        inline for (.{ Op.@"union", Op.intersect, Op.difference, Op.xor }) |op| {
            try checkPointwise(&.{&a_pts}, &.{&b_pts}, op, .nonzero, .{ 0, 0 }, .{ 10, 10 }, round + 500);
        }
    }
}
