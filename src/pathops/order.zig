//! Plotter path planning: reorder and flip paths to cut pen-up travel,
//! and join paths whose ends meet.
//!
//! Ordering is greedy nearest neighbour over a grid of path endpoints,
//! then 2-opt moves (Croes, "A method for solving traveling-salesman
//! problems", Operations Research 6, 1958) that reverse a run of paths,
//! tried only against each path's nearest neighbours and capped by a
//! budget of move evaluations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const geom = @import("geom.zig");
const Vec2 = geom.Vec2;

/// Uniform grid over points with removable entries.
const PointGrid = struct {
    lo: Vec2,
    cell: f64,
    nx: u32,
    ny: u32,
    start: []u32,
    count: []u32,
    items: []u32,

    fn init(arena: Allocator, pts: []const Vec2, cell_hint: f64) !PointGrid {
        var lo: Vec2 = .{ std.math.inf(f64), std.math.inf(f64) };
        var hi: Vec2 = .{ -std.math.inf(f64), -std.math.inf(f64) };
        for (pts) |p| {
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
        }
        const w = @max(hi[0] - lo[0], 1e-9);
        const h = @max(hi[1] - lo[1], 1e-9);
        const n_f: f64 = @floatFromInt(@max(pts.len, 1));
        var cell = if (cell_hint > 0) cell_hint else @sqrt(w * h / n_f);
        cell = @max(cell, @max(w, h) / 2048);
        const nx: u32 = @intFromFloat(@min(@floor(w / cell) + 1, 2048));
        const ny: u32 = @intFromFloat(@min(@floor(h / cell) + 1, 2048));
        var g: PointGrid = .{
            .lo = lo,
            .cell = cell,
            .nx = nx,
            .ny = ny,
            .start = try arena.alloc(u32, @as(usize, nx) * ny + 1),
            .count = try arena.alloc(u32, @as(usize, nx) * ny),
            .items = try arena.alloc(u32, pts.len),
        };
        @memset(g.start, 0);
        @memset(g.count, 0);
        for (pts) |p| g.count[g.cellOf(p)] += 1;
        for (g.count, 0..) |c, i| g.start[i + 1] = g.start[i] + c;
        @memset(g.count, 0);
        for (pts, 0..) |p, i| {
            const c = g.cellOf(p);
            g.items[g.start[c] + g.count[c]] = @intCast(i);
            g.count[c] += 1;
        }
        return g;
    }

    fn coord(g: *const PointGrid, v: f64, axis: usize, n: u32) u32 {
        const f = @floor((v - g.lo[axis]) / g.cell);
        return @intFromFloat(std.math.clamp(f, 0, @as(f64, @floatFromInt(n - 1))));
    }

    fn cellOf(g: *const PointGrid, p: Vec2) usize {
        return @as(usize, g.coord(p[1], 1, g.ny)) * g.nx + g.coord(p[0], 0, g.nx);
    }

    /// Visit live entries of the cells at Chebyshev ring r around p's
    /// cell. `alive` decides liveness, and dead entries are dropped.
    /// Returns false once the ring lies wholly outside the grid.
    fn ring(g: *PointGrid, p: Vec2, r: u32, ctx: anytype, comptime alive: fn (@TypeOf(ctx), u32) bool, comptime visit: fn (@TypeOf(ctx), u32) void) bool {
        const cx: i64 = g.coord(p[0], 0, g.nx);
        const cy: i64 = g.coord(p[1], 1, g.ny);
        const ri: i64 = r;
        if (cx - ri < 0 and cy - ri < 0 and cx + ri >= g.nx and cy + ri >= g.ny) return false;
        var y = cy - ri;
        while (y <= cy + ri) : (y += 1) {
            if (y < 0 or y >= g.ny) continue;
            const edge_row = y == cy - ri or y == cy + ri;
            var x = cx - ri;
            while (x <= cx + ri) : (x += if (edge_row or ri == 0) 1 else 2 * ri) {
                if (x < 0 or x >= g.nx) continue;
                const c = @as(usize, @intCast(y)) * g.nx + @as(usize, @intCast(x));
                const base = g.start[c];
                var k: u32 = 0;
                while (k < g.count[c]) {
                    const id = g.items[base + k];
                    if (!alive(ctx, id)) {
                        g.count[c] -= 1;
                        g.items[base + k] = g.items[base + g.count[c]];
                        continue;
                    }
                    visit(ctx, id);
                    k += 1;
                }
            }
        }
        return true;
    }
};

pub const Options = struct {
    /// Pen position before the first path.
    start: Vec2 = .{ 0, 0 },
    /// Upper bound on 2-opt move evaluations.
    budget: u64 = 4_000_000,
    /// Neighbours per path that 2-opt tries.
    neighbours: u32 = 10,
};

pub const Order = struct {
    /// Path indices in drawing order.
    order: []u32,
    /// Whether the path at the same position is drawn end to start.
    reversed: []bool,
    travel_before: f64,
    travel_after: f64,

    pub fn deinit(self: *Order, gpa: Allocator) void {
        gpa.free(self.order);
        gpa.free(self.reversed);
        self.* = undefined;
    }
};

/// Plan the order of paths given by their start and end points.
pub fn orderPaths(gpa: Allocator, ends: []const [2]Vec2, opts: Options) !Order {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n = ends.len;
    const seq = try gpa.alloc(u32, n);
    errdefer gpa.free(seq);
    const rev = try gpa.alloc(bool, n);
    errdefer gpa.free(rev);
    var plan: Plan = .{ .ends = ends, .seq = seq, .rev = rev, .pos = try arena.alloc(u32, n), .start = opts.start };
    for (plan.seq, plan.rev, 0..) |*s, *r, i| {
        s.* = @intCast(i);
        r.* = false;
    }
    const before = plan.travel();
    if (n > 1) {
        const pts = try arena.alloc(Vec2, 2 * n);
        for (ends, 0..) |e, i| {
            pts[2 * i] = e[0];
            pts[2 * i + 1] = e[1];
        }
        try greedy(arena, &plan, pts);
        const near = try neighbours(arena, pts, opts.neighbours);
        plan.twoOpt(near, opts.neighbours, opts.budget);
    }
    return .{ .order = plan.seq, .reversed = plan.rev, .travel_before = before, .travel_after = plan.travel() };
}

const Plan = struct {
    ends: []const [2]Vec2,
    seq: []u32,
    rev: []bool,
    pos: []u32,
    start: Vec2,

    fn head(p: *const Plan, i: usize) Vec2 {
        return p.ends[p.seq[i]][@intFromBool(p.rev[i])];
    }

    fn tail(p: *const Plan, i: usize) Vec2 {
        return p.ends[p.seq[i]][@intFromBool(!p.rev[i])];
    }

    fn before(p: *const Plan, i: usize) Vec2 {
        return if (i == 0) p.start else p.tail(i - 1);
    }

    fn travel(p: *const Plan) f64 {
        var t: f64 = 0;
        for (0..p.seq.len) |i| t += geom.dist(p.before(i), p.head(i));
        return t;
    }

    /// Reverse positions i..j inclusive, flipping each path.
    fn reverse(p: *Plan, i: usize, j: usize) void {
        std.mem.reverse(u32, p.seq[i .. j + 1]);
        std.mem.reverse(bool, p.rev[i .. j + 1]);
        for (i..j + 1) |k| {
            p.rev[k] = !p.rev[k];
            p.pos[p.seq[k]] = @intCast(k);
        }
    }

    fn twoOpt(p: *Plan, near: []const u32, k: u32, budget: u64) void {
        var spent: u64 = 0;
        var improved = true;
        while (improved and spent < budget) {
            improved = false;
            for (1..p.seq.len) |i| {
                const prev_path = p.seq[i - 1];
                for (near[@as(usize, prev_path) * k ..][0..k]) |q| {
                    if (q == std.math.maxInt(u32)) break;
                    spent += 1;
                    const j: usize = p.pos[q];
                    if (j < i) continue;
                    const a = p.before(i);
                    const nxt: ?Vec2 = if (j + 1 < p.seq.len) p.head(j + 1) else null;
                    const old = geom.dist(a, p.head(i)) + if (nxt) |v| geom.dist(p.tail(j), v) else 0;
                    const new = geom.dist(a, p.tail(j)) + if (nxt) |v| geom.dist(p.head(i), v) else 0;
                    if (new < old - 1e-12) {
                        p.reverse(i, j);
                        spent += j - i + 1;
                        improved = true;
                    }
                }
                if (spent >= budget) break;
            }
        }
    }
};

const GreedyCtx = struct {
    used: []const bool,
    q: Vec2,
    pts: []const Vec2,
    best: f64 = std.math.inf(f64),
    best_id: u32 = std.math.maxInt(u32),

    fn alive(c: *GreedyCtx, id: u32) bool {
        return !c.used[id / 2];
    }

    fn visit(c: *GreedyCtx, id: u32) void {
        const d = geom.dist(c.q, c.pts[id]);
        if (d < c.best) {
            c.best = d;
            c.best_id = id;
        }
    }
};

fn greedy(arena: Allocator, plan: *Plan, pts: []const Vec2) !void {
    const n = plan.seq.len;
    var grid: PointGrid = try .init(arena, pts, 0);
    const used = try arena.alloc(bool, n);
    @memset(used, false);
    var pen = plan.start;
    for (0..n) |i| {
        var ctx: GreedyCtx = .{ .used = used, .q = pen, .pts = pts };
        var r: u32 = 0;
        // After rings 0..r, unvisited cells are at least r cells away.
        while (grid.ring(pen, r, &ctx, GreedyCtx.alive, GreedyCtx.visit)) : (r += 1) {
            if (ctx.best <= @as(f64, @floatFromInt(r)) * grid.cell) break;
        }
        assert(ctx.best_id != std.math.maxInt(u32));
        const path = ctx.best_id / 2;
        used[path] = true;
        plan.seq[i] = path;
        plan.rev[i] = ctx.best_id % 2 == 1;
        plan.pos[path] = @intCast(i);
        pen = plan.tail(i);
    }
}

const Near = struct {
    d: f64,
    path: u32,

    fn less(_: void, a: Near, b: Near) bool {
        return a.d < b.d;
    }
};

const NearCtx = struct {
    self_path: u32,
    q: Vec2,
    pts: []const Vec2,
    found: *std.ArrayList(Near),
    arena: Allocator,
    failed: bool = false,

    fn alive(_: *NearCtx, _: u32) bool {
        return true;
    }

    fn visit(c: *NearCtx, id: u32) void {
        if (id / 2 == c.self_path) return;
        c.found.append(c.arena, .{ .d = geom.dist(c.q, c.pts[id]), .path = id / 2 }) catch {
            c.failed = true;
        };
    }
};

/// Up to k nearest other paths to each path's tail, padded with maxInt.
fn neighbours(arena: Allocator, pts: []const Vec2, k: u32) ![]u32 {
    const n = pts.len / 2;
    var grid: PointGrid = try .init(arena, pts, 0);
    const out = try arena.alloc(u32, n * k);
    @memset(out, std.math.maxInt(u32));
    var found: std.ArrayList(Near) = .empty;
    for (0..n) |path| {
        for (0..2) |end| {
            found.clearRetainingCapacity();
            const q = pts[2 * path + end];
            var ctx: NearCtx = .{ .self_path = @intCast(path), .q = q, .pts = pts, .found = &found, .arena = arena };
            var r: u32 = 0;
            while (grid.ring(q, r, &ctx, NearCtx.alive, NearCtx.visit)) : (r += 1) {
                if (found.items.len >= 2 * k) break;
            }
            if (ctx.failed) return error.OutOfMemory;
            std.mem.sortUnstable(Near, found.items, {}, Near.less);
            // Tails lead to the next path, so they get the first slots.
            const row = out[path * k ..][0..k];
            for (found.items) |f| {
                if (std.mem.indexOfScalar(u32, row, f.path) != null) continue;
                const slot = std.mem.indexOfScalar(u32, row, std.math.maxInt(u32)) orelse break;
                row[slot] = f.path;
            }
        }
    }
    return out;
}

pub const Joined = struct {
    points: []Vec2,
    closed: bool,
};

pub fn freeJoined(gpa: Allocator, paths: []const Joined) void {
    for (paths) |p| gpa.free(p.points);
    gpa.free(paths);
}

const JoinCtx = struct {
    used: []const bool,
    q: Vec2,
    pts: []const Vec2,
    tol: f64,
    best: f64,
    best_id: u32 = std.math.maxInt(u32),

    fn alive(c: *JoinCtx, id: u32) bool {
        return !c.used[id / 2];
    }

    fn visit(c: *JoinCtx, id: u32) void {
        const d = geom.dist(c.q, c.pts[id]);
        if (d <= c.tol and d < c.best) {
            c.best = d;
            c.best_id = id;
        }
    }
};

/// Merge paths whose endpoints lie within `tolerance` of each other,
/// flipping them as needed. A merged path whose ends meet is closed and
/// does not repeat its first point. Caller owns the result.
pub fn joinPaths(gpa: Allocator, paths: geom.Contours, tolerance: f64) ![]Joined {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n = paths.len;
    const pts = try arena.alloc(Vec2, 2 * n);
    for (paths, 0..) |p, i| {
        pts[2 * i] = if (p.len > 0) p[0] else .{ 0, 0 };
        pts[2 * i + 1] = if (p.len > 0) p[p.len - 1] else .{ 0, 0 };
    }
    var grid: PointGrid = try .init(arena, pts, @max(tolerance, 0) * 2);
    const used = try arena.alloc(bool, n);
    for (paths, used) |p, *u| u.* = p.len == 0;

    var out: std.ArrayList(Joined) = .empty;
    errdefer {
        for (out.items) |j| gpa.free(j.points);
        out.deinit(gpa);
    }
    var chain: std.ArrayList(Vec2) = .empty;
    for (0..n) |first| {
        if (used[first]) continue;
        used[first] = true;
        chain.clearRetainingCapacity();
        try chain.appendSlice(arena, paths[first]);
        for (0..2) |_| {
            while (true) {
                const q = chain.items[chain.items.len - 1];
                var ctx: JoinCtx = .{ .used = used, .q = q, .pts = pts, .tol = tolerance, .best = std.math.inf(f64) };
                _ = grid.ring(q, 0, &ctx, JoinCtx.alive, JoinCtx.visit);
                _ = grid.ring(q, 1, &ctx, JoinCtx.alive, JoinCtx.visit);
                if (ctx.best_id == std.math.maxInt(u32)) break;
                const path = ctx.best_id / 2;
                used[path] = true;
                const p = paths[path];
                if (ctx.best_id % 2 == 0) {
                    try chain.appendSlice(arena, p[1..]);
                } else {
                    var k = p.len - 1;
                    while (k > 0) {
                        k -= 1;
                        try chain.append(arena, p[k]);
                    }
                }
            }
            // Grow the other end by flipping the chain, and flip it back
            // after so the first path keeps its direction.
            std.mem.reverse(Vec2, chain.items);
        }
        var items = chain.items;
        const closed = items.len >= 3 and geom.dist(items[0], items[items.len - 1]) <= tolerance;
        if (closed) items = items[0 .. items.len - 1];
        const owned = try gpa.dupe(Vec2, items);
        errdefer gpa.free(owned);
        try out.append(gpa, .{ .points = owned, .closed = closed });
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "order: greedy plus 2-opt beats a scrambled order" {
    const gpa = testing.allocator;
    // Short dashes along a line, given in a scrambled order and direction.
    var ends: [40][2]Vec2 = undefined;
    for (&ends, 0..) |*e, i| {
        const k: f64 = @floatFromInt((i * 17) % 40);
        e.* = if (i % 2 == 0) .{ .{ k * 2, 0 }, .{ k * 2 + 1, 0 } } else .{ .{ k * 2 + 1, 0 }, .{ k * 2, 0 } };
    }
    var o = try orderPaths(gpa, &ends, .{});
    defer o.deinit(gpa);
    try testing.expect(o.travel_before > 500);
    // Ideal travel is the 39 one-unit gaps.
    try testing.expectApproxEqAbs(@as(f64, 39), o.travel_after, 1e-9);
    var seen: [40]bool = @splat(false);
    for (o.order) |i| seen[i] = true;
    for (seen) |s| try testing.expect(s);
}

test "order: 2-opt untangles a crossing" {
    var plan: Plan = undefined;
    const ends = [_][2]Vec2{
        .{ .{ 0, 0 }, .{ 0, 1 } },
        .{ .{ 10, 0 }, .{ 10, 1 } },
        .{ .{ 1, 1 }, .{ 1, 0 } },
        .{ .{ 11, 1 }, .{ 11, 0 } },
    };
    var seq = [_]u32{ 0, 1, 2, 3 };
    var rev = [_]bool{ false, false, false, false };
    var pos = [_]u32{ 0, 1, 2, 3 };
    plan = .{ .ends = &ends, .seq = &seq, .rev = &rev, .pos = &pos, .start = .{ 0, 0 } };
    const near = [_]u32{ 2, 1, 3, 0, 3, 2, 0, 1 };
    const before = plan.travel();
    plan.twoOpt(&near, 2, 1000);
    try testing.expect(plan.travel() < before);
    try testing.expectEqual(@as(u32, 2), plan.seq[1]);
}

test "order: joinPaths merges touching paths and closes loops" {
    const gpa = testing.allocator;
    const a = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 } };
    const b = [_]Vec2{ .{ 1, 1 }, .{ 1, 0 } };
    const c = [_]Vec2{ .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } };
    const d = [_]Vec2{ .{ 5, 5 }, .{ 6, 5 } };
    const out = try joinPaths(gpa, &.{ &a, &b, &c, &d }, 1e-9);
    defer freeJoined(gpa, out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expect(out[0].closed);
    try testing.expectEqualSlices(Vec2, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, out[0].points);
    try testing.expect(!out[1].closed);
}
