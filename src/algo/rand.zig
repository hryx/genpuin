//! The genpuin random stream: xoshiro256++ (Blackman and Vigna 2018),
//! seeded through SplitMix64 by std.Random.Xoshiro256. Only its raw u64
//! words are taken from std. Floats and ranges are derived here, so the
//! stream depends on std only through the generator itself, which the
//! tests pin.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");

pub const Vec2 = [2]f64;

pub const Rng = struct {
    x: std.Random.Xoshiro256,

    pub fn init(seed: u64) Rng {
        return .{ .x = .init(seed) };
    }

    /// The seed of stream `k` under base seed `base`: the first output
    /// of SplitMix64 started at base * 2^32 + k. Each (base, k) pair is
    /// its own 64-bit start, and the SplitMix64 finalizer spreads
    /// neighboring ones across the whole range.
    pub fn mix(base: u32, k: u32) u64 {
        var sm: std.Random.SplitMix64 = .init(@as(u64, base) << 32 | k);
        return sm.next();
    }

    /// Uniform in [0, 1), the top 53 bits of a word.
    pub fn next(r: *Rng) f64 {
        return @as(f64, @floatFromInt(r.x.next() >> 11)) * 0x1p-53;
    }

    /// Uniform in [lo, hi).
    pub fn range(r: *Rng, lo: f64, hi: f64) f64 {
        return lo + r.next() * (hi - lo);
    }

    /// Integer in [lo, hi] for integer bounds, as a float.
    pub fn int(r: *Rng, lo: f64, hi: f64) f64 {
        return lo + @floor(r.next() * (1 + hi - lo));
    }

    /// Box-Muller, one sample per two draws. The log takes 1 - u, which
    /// is never 0.
    pub fn gaussian(r: *Rng, mean: f64, stddev: f64) f64 {
        const uniform1 = r.next();
        const uniform2 = r.next();
        const z = @sqrt(-2 * math.log(1 - uniform1)) * math.cos(2 * std.math.pi * uniform2);
        return mean + z * stddev;
    }

    /// Index into a list of `list_len` items picked with `weights`, or
    /// null for an empty list. `weights` must cover the list.
    pub fn weightedIndex(r: *Rng, weights: []const f64, list_len: usize) ?usize {
        std.debug.assert(weights.len >= list_len);
        var total: f64 = 0;
        for (weights) |w| total += w;
        const x = r.next() * total;
        var acc: f64 = 0;
        for (weights[0..list_len], 0..) |w, i| {
            acc += w;
            if (x < acc) return i;
        }
        return if (list_len == 0) null else list_len - 1;
    }

    /// Fisher-Yates from the back, as the Lua shuffle did.
    pub fn shuffle(r: *Rng, comptime T: type, items: []T) void {
        var i = items.len;
        while (i >= 2) : (i -= 1) {
            const j: usize = @intFromFloat(r.int(1, @floatFromInt(i)));
            std.mem.swap(T, &items[i - 1], &items[j - 1]);
        }
    }

    pub fn inCircle(r: *Rng, center: Vec2, radius: f64) Vec2 {
        const angle = r.next() * 2 * std.math.pi;
        const dist = radius * @sqrt(r.next());
        return .{ center[0] + dist * math.cos(angle), center[1] + dist * math.sin(angle) };
    }

    pub fn onCircle(r: *Rng, center: Vec2, radius: f64) Vec2 {
        const angle = r.next() * 2 * std.math.pi;
        return .{ center[0] + radius * math.cos(angle), center[1] + radius * math.sin(angle) };
    }

    pub fn inRect(r: *Rng, x: f64, y: f64, w: f64, h: f64) Vec2 {
        const px = x + r.next() * w;
        return .{ px, y + r.next() * h };
    }
};

pub const Bounds = struct { x: f64, y: f64, w: f64, h: f64 };

/// Poisson disk sampling by Bridson's algorithm ("Fast Poisson disk
/// sampling in arbitrary dimensions", 2007). Points are at least
/// `min_dist` apart inside `bounds`. Caller owns the result.
pub fn poissonDisk(gpa: Allocator, r: *Rng, bounds: Bounds, min_dist: f64, max_attempts: f64) ![]Vec2 {
    const cell = min_dist / @sqrt(@as(f64, 2));
    const cols = try gridSize(@ceil(bounds.w / cell));
    const rows = try gridSize(@ceil(bounds.h / cell));
    if (cols * rows > grid_cells_max) return error.OutOfMemory;

    // Slot k holds 1 + the index of the point in cell k, or 0.
    const grid = try gpa.alloc(u32, @intCast(cols * rows));
    defer gpa.free(grid);
    @memset(grid, 0);

    var points: std.ArrayList(Vec2) = .empty;
    errdefer points.deinit(gpa);
    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(gpa);

    const g: Grid = .{ .cells = grid, .cols = cols, .rows = rows, .origin = .{ bounds.x, bounds.y }, .cell = cell };

    const first_x = bounds.x + r.next() * bounds.w;
    const first: Vec2 = .{ first_x, bounds.y + r.next() * bounds.h };
    try points.append(gpa, first);
    g.put(first, 1);
    try active.append(gpa, 0);

    const min_dist_sq = min_dist * min_dist;
    while (active.items.len > 0) {
        const ai: usize = @intFromFloat(r.int(1, @floatFromInt(active.items.len)) - 1);
        const origin = points.items[active.items[ai]];
        var attempt: f64 = 1;
        const found = while (attempt <= max_attempts) : (attempt += 1) {
            const angle = r.next() * 2 * std.math.pi;
            const dist = min_dist + r.next() * min_dist;
            const p: Vec2 = .{ origin[0] + math.cos(angle) * dist, origin[1] + math.sin(angle) * dist };
            if (!(p[0] >= bounds.x and p[0] < bounds.x + bounds.w and p[1] >= bounds.y and p[1] < bounds.y + bounds.h)) continue;
            if (tooClose(g, points.items, p, min_dist_sq)) continue;
            try points.append(gpa, p);
            g.put(p, @intCast(points.items.len));
            try active.append(gpa, @intCast(points.items.len - 1));
            break true;
        } else false;
        if (!found) _ = active.orderedRemove(ai);
    }
    return points.toOwnedSlice(gpa);
}

const grid_cells_max = 1 << 31;

fn gridSize(cells: f64) error{OutOfMemory}!i64 {
    if (!(cells >= 1)) return 0;
    if (cells > grid_cells_max) return error.OutOfMemory;
    return @intFromFloat(cells);
}

const Grid = struct {
    cells: []u32,
    cols: i64,
    rows: i64,
    origin: Vec2,
    cell: f64,

    /// Cell coordinates, or null when `p` is nowhere near the grid.
    fn coord(g: Grid, p: Vec2) ?[2]i64 {
        const x = @floor((p[0] - g.origin[0]) / g.cell);
        const y = @floor((p[1] - g.origin[1]) / g.cell);
        const margin = 3;
        if (!(x >= -margin and x <= @as(f64, @floatFromInt(g.cols + margin)))) return null;
        if (!(y >= -margin and y <= @as(f64, @floatFromInt(g.rows + margin)))) return null;
        return .{ @intFromFloat(x), @intFromFloat(y) };
    }

    // A point on the far edge can round into the next row's first
    // cell, which is where the flat index lands it in the Lua original.
    fn put(g: Grid, p: Vec2, slot: u32) void {
        const c = g.coord(p) orelse return;
        const k = c[1] * g.cols + c[0];
        if (k >= 0 and k < g.cells.len) g.cells[@intCast(k)] = slot;
    }
};

fn tooClose(g: Grid, points: []const Vec2, p: Vec2, min_dist_sq: f64) bool {
    const c = g.coord(p) orelse return false;
    var dr: i64 = -2;
    while (dr <= 2) : (dr += 1) {
        var dc: i64 = -2;
        while (dc <= 2) : (dc += 1) {
            const nc = c[0] + dc;
            const nr = c[1] + dr;
            if (nc < 0 or nc >= g.cols or nr < 0 or nr >= g.rows) continue;
            const slot = g.cells[@intCast(nr * g.cols + nc)];
            if (slot == 0) continue;
            const other = points[slot - 1];
            const dx = p[0] - other[0];
            const dy = p[1] - other[1];
            if (dx * dx + dy * dy < min_dist_sq) return true;
        }
    }
    return false;
}

const testing = std.testing;

// Expected words come from a Python port of the reference C code for
// SplitMix64 and xoshiro256++, so a change to std's seeding fails here.

test "rand: std seeds xoshiro256++ through SplitMix64" {
    const cases = .{
        .{ 0, [_]u64{ 0x53175d61490b23df, 0x61da6f3dc380d507, 0x5c0fdf91ec9a7bfc, 0x02eebf8c3bbe5e1a } },
        .{ 42, [_]u64{ 0xd0764d4f4476689f, 0x519e4174576f3791, 0xfbe07cfb0c24ed8c, 0xb37d9f600cd835b8 } },
    };
    inline for (cases) |c| {
        var r: Rng = .init(c[0]);
        for (c[1]) |e| try testing.expectEqual(e, r.x.next());
    }
}

test "rand: floats are the top 53 bits" {
    var r: Rng = .init(42);
    try testing.expectEqual(@as(f64, 0.8143051451229099), r.next());
    try testing.expectEqual(@as(f64, 0.3188210400616611), r.next());
    try testing.expectEqual(@as(f64, 0.9838941681774888), r.next());
}

test "rand: mix is SplitMix64 of base and k" {
    try testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), Rng.mix(0, 0));
    try testing.expectEqual(@as(u64, 0x910a2dec89025cc1), Rng.mix(0, 1));
    try testing.expectEqual(@as(u64, 0xb631e75c64bc496a), Rng.mix(5, 0));
    try testing.expectEqual(@as(u64, 0x710738f7e219399e), Rng.mix(5, 1));
    try testing.expectEqual(@as(u64, 0xe7464efc70add902), Rng.mix(6, 1));
    try testing.expectEqual(@as(u64, 0xe4d971771b652c20), Rng.mix(0xffffffff, 0xffffffff));
}

test "rand: int, range and gaussian derive from the stream" {
    var want: Rng = .init(42);
    var r: Rng = .init(42);
    try testing.expectEqual(1 + @floor(want.next() * 100), r.int(1, 100));
    try testing.expectEqual(-3 + want.next() * 10, r.range(-3, 7));
    const u1_ = want.next();
    const u2_ = want.next();
    const z = @sqrt(-2 * math.log(1 - u1_)) * math.cos(2 * std.math.pi * u2_);
    try testing.expectEqual(10 + z * 2, r.gaussian(10, 2));
    for (0..1000) |_| {
        const v = r.int(-5, 5);
        try testing.expect(v >= -5 and v <= 5 and @floor(v) == v);
    }
}

test "rand: weightedIndex never picks a zero weight" {
    var r: Rng = .init(5);
    for (0..100) |_| {
        const i = r.weightedIndex(&.{ 1, 0, 2 }, 3).?;
        try testing.expect(i != 1);
    }
    try testing.expectEqual(@as(?usize, null), r.weightedIndex(&.{}, 0));
}

test "rand: shuffle permutes" {
    var r: Rng = .init(9);
    var items = [_]u8{ 1, 2, 3, 4, 5, 6 };
    r.shuffle(u8, &items);
    var sum: u32 = 0;
    for (items) |x| sum += x;
    try testing.expectEqual(@as(u32, 21), sum);
}

test "rand: poissonDisk keeps points apart and in bounds" {
    var want: Rng = .init(3);
    var r: Rng = .init(3);
    const pts = try poissonDisk(testing.allocator, &r, .{ .x = 0, .y = 0, .w = 50, .h = 50 }, 10, 30);
    defer testing.allocator.free(pts);
    try testing.expect(pts.len >= 10);
    try testing.expectEqual(want.next() * 50, pts[0][0]);
    try testing.expectEqual(want.next() * 50, pts[0][1]);
    for (pts, 0..) |a, i| {
        try testing.expect(a[0] >= 0 and a[0] < 50 and a[1] >= 0 and a[1] < 50);
        for (pts[i + 1 ..]) |b| try testing.expect(std.math.hypot(a[0] - b[0], a[1] - b[1]) >= 10);
    }
}

test "rand: poissonDisk survives NaN bounds" {
    var r: Rng = .init(3);
    const pts = try poissonDisk(testing.allocator, &r, .{ .x = 0, .y = 0, .w = std.math.nan(f64), .h = 10 }, 1, 5);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 1), pts.len);
}

test "rand: poissonDisk refuses a huge grid" {
    var r: Rng = .init(3);
    try testing.expectError(error.OutOfMemory, poissonDisk(testing.allocator, &r, .{ .x = 0, .y = 0, .w = 1e9, .h = 1e9 }, 1, 5));
}

test "rand: poissonDisk with empty bounds keeps the first point" {
    var r: Rng = .init(3);
    const pts = try poissonDisk(testing.allocator, &r, .{ .x = 0, .y = 0, .w = 0, .h = 10 }, 1, 5);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 1), pts.len);
}
