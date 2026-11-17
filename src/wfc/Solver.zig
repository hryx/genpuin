//! The model-independent core of wave function collapse, after Maxim
//! Gumin's Model.cs (https://github.com/mxgmn/WaveFunctionCollapse).
//!
//! Every cell holds the set of patterns still possible there. Observe
//! collapses the lowest-entropy cell to one weighted-random pattern, and
//! propagation removes patterns that lost all support from a neighbor.
//! Support counts per cell, pattern and direction make propagation the
//! AC-4 style of the reference. A lazy min-heap keyed on entropy plus a
//! fixed per-cell noise replaces the reference's linear scan.

const std = @import("std");
const math = @import("../math.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Solver = @This();

width: u32,
height: u32,
n: u32,
periodic: bool,
pattern_count: u32,
propagator: *const Propagator,
weights: []const f64,
weight_log_weights: []f64,
cell_weights: ?[]const f64,
allowed: ?[]const bool,

wave: []bool,
/// Support counts per cell, pattern and direction.
compatible: []u16,
/// The initial support counts for one cell.
full_support: []u16,
sums_of_ones: []u32,
sums_of_weights: []f64,
sums_of_weight_log_weights: []f64,
stamps: []u32,
noise: []f64,
stack: []Ban,
stack_len: usize,
/// Cells whose possibilities changed since the last heap update.
dirty: []bool,
dirty_cells: []u32,
dirty_len: usize,
heap: Heap,
observed: []u32,

/// Directions in order north, east, south, west. North is y - 1.
pub const dx = [4]i32{ 0, 1, 0, -1 };
pub const dy = [4]i32{ -1, 0, 1, 0 };

pub fn opposite(d: u2) u2 {
    return d +% 2;
}

/// For each direction and pattern, the patterns allowed in the
/// neighboring cell that way. The relation must be symmetric:
/// b is in list(d, a) exactly when a is in list(opposite(d), b).
pub const Propagator = struct {
    pattern_count: u32,
    offsets: []u32,
    items: []u32,

    pub fn list(p: *const Propagator, d: u2, t: u32) []const u32 {
        const k = @as(usize, d) * p.pattern_count + t;
        return p.items[p.offsets[k]..p.offsets[k + 1]];
    }

    /// Build from a predicate `agrees(ctx, d, a, b)` saying b may sit in
    /// direction d of a.
    pub fn build(gpa: Allocator, pattern_count: u32, ctx: anytype, comptime agrees: fn (@TypeOf(ctx), u2, u32, u32) bool) !Propagator {
        const offsets = try gpa.alloc(u32, 4 * @as(usize, pattern_count) + 1);
        errdefer gpa.free(offsets);

        var items: std.ArrayList(u32) = .empty;
        errdefer items.deinit(gpa);
        offsets[0] = 0;
        for (0..4) |d| {
            for (0..pattern_count) |a| {
                for (0..pattern_count) |b| {
                    if (agrees(ctx, @intCast(d), @intCast(a), @intCast(b))) try items.append(gpa, @intCast(b));
                }
                offsets[d * pattern_count + a + 1] = @intCast(items.items.len);
            }
        }
        return .{ .pattern_count = pattern_count, .offsets = offsets, .items = try items.toOwnedSlice(gpa) };
    }

    pub fn deinit(p: *Propagator, gpa: Allocator) void {
        gpa.free(p.offsets);
        gpa.free(p.items);
        p.* = undefined;
    }
};

pub const Options = struct {
    width: u32,
    height: u32,
    /// Pattern size. Cells within n - 1 of the right or bottom edge of a
    /// non-periodic grid are never observed, as in the overlapping model.
    n: u32 = 1,
    periodic: bool = false,
    propagator: *const Propagator,
    /// One weight per pattern.
    weights: []const f64,
    /// Optional weight per cell and pattern, row-major cells, overriding
    /// `weights`. A weight of zero or less bans the pattern there.
    cell_weights: ?[]const f64 = null,
    /// Optional mask per cell and pattern. False bans the pattern there.
    allowed: ?[]const bool = null,
};

const Ban = struct { cell: u32, pattern: u32 };

const Entry = struct { key: f64, cell: u32, stamp: u32 };

fn entryOrder(_: void, a: Entry, b: Entry) std.math.Order {
    return std.math.order(a.key, b.key);
}

const Heap = std.PriorityQueue(Entry, void, entryOrder);

pub const Error = error{ Contradiction, TooManyPatterns } || Allocator.Error;

pub const pattern_count_max = std.math.maxInt(u16);

pub fn init(gpa: Allocator, opts: Options) Error!Solver {
    const t_count = opts.propagator.pattern_count;
    if (t_count > pattern_count_max) return error.TooManyPatterns;
    const cells = @as(usize, opts.width) * opts.height;
    assert(t_count > 0);
    assert(cells > 0);
    assert(opts.weights.len == t_count);
    if (opts.cell_weights) |cw| assert(cw.len == cells * t_count);
    if (opts.allowed) |al| assert(al.len == cells * t_count);

    const wlw = try gpa.alloc(f64, t_count);
    errdefer gpa.free(wlw);
    for (wlw, opts.weights) |*o, w| o.* = if (w > 0) w * math.log(w) else 0;

    const wave = try gpa.alloc(bool, cells * t_count);
    errdefer gpa.free(wave);
    const compatible = try gpa.alloc(u16, cells * t_count * 4);
    errdefer gpa.free(compatible);
    const full_support = try gpa.alloc(u16, @as(usize, t_count) * 4);
    errdefer gpa.free(full_support);
    for (0..t_count) |t| for (0..4) |d| {
        full_support[t * 4 + d] = @intCast(opts.propagator.list(opposite(@intCast(d)), @intCast(t)).len);
    };
    const sums_of_ones = try gpa.alloc(u32, cells);
    errdefer gpa.free(sums_of_ones);
    const sums_of_weights = try gpa.alloc(f64, cells);
    errdefer gpa.free(sums_of_weights);
    const sums_of_wlw = try gpa.alloc(f64, cells);
    errdefer gpa.free(sums_of_wlw);
    const stamps = try gpa.alloc(u32, cells);
    errdefer gpa.free(stamps);
    const noise = try gpa.alloc(f64, cells);
    errdefer gpa.free(noise);
    const stack = try gpa.alloc(Ban, cells * t_count);
    errdefer gpa.free(stack);
    const dirty = try gpa.alloc(bool, cells);
    errdefer gpa.free(dirty);
    const dirty_cells = try gpa.alloc(u32, cells);
    errdefer gpa.free(dirty_cells);
    const observed = try gpa.alloc(u32, cells);
    errdefer gpa.free(observed);

    return .{
        .width = opts.width,
        .height = opts.height,
        .n = opts.n,
        .periodic = opts.periodic,
        .pattern_count = t_count,
        .propagator = opts.propagator,
        .weights = opts.weights,
        .weight_log_weights = wlw,
        .cell_weights = opts.cell_weights,
        .allowed = opts.allowed,
        .wave = wave,
        .compatible = compatible,
        .full_support = full_support,
        .sums_of_ones = sums_of_ones,
        .sums_of_weights = sums_of_weights,
        .sums_of_weight_log_weights = sums_of_wlw,
        .stamps = stamps,
        .noise = noise,
        .stack = stack,
        .stack_len = 0,
        .dirty = dirty,
        .dirty_cells = dirty_cells,
        .dirty_len = 0,
        .heap = .empty,
        .observed = observed,
    };
}

pub fn deinit(s: *Solver, gpa: Allocator) void {
    gpa.free(s.weight_log_weights);
    gpa.free(s.wave);
    gpa.free(s.compatible);
    gpa.free(s.full_support);
    gpa.free(s.sums_of_ones);
    gpa.free(s.sums_of_weights);
    gpa.free(s.sums_of_weight_log_weights);
    gpa.free(s.stamps);
    gpa.free(s.noise);
    gpa.free(s.stack);
    gpa.free(s.dirty);
    gpa.free(s.dirty_cells);
    s.heap.deinit(gpa);
    gpa.free(s.observed);
    s.* = undefined;
}

/// Try up to `attempts` times, restarting on contradiction. On success
/// `observed` holds one pattern per cell and the return value is the
/// number of attempts used.
pub fn run(s: *Solver, gpa: Allocator, seed: u64, attempts: u32) Error!u32 {
    assert(attempts > 0);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    for (1..attempts + 1) |attempt| {
        if (try s.runOnce(gpa, random)) return @intCast(attempt);
    }
    return error.Contradiction;
}

fn runOnce(s: *Solver, gpa: Allocator, random: std.Random) !bool {
    if (!try s.clear(gpa, random)) return false;
    while (s.heap.pop()) |e| {
        if (e.stamp != s.stamps[e.cell] or s.sums_of_ones[e.cell] <= 1) continue;
        s.collapse(e.cell, random);
        if (!try s.propagate(gpa)) return false;
    }
    const t_count = s.pattern_count;
    for (s.observed, 0..) |*o, i| {
        const row = s.wave[i * t_count ..][0..t_count];
        o.* = @intCast(std.mem.indexOfScalar(bool, row, true) orelse return false);
    }
    return true;
}

fn weight(s: *const Solver, cell: usize, t: usize) f64 {
    if (s.cell_weights) |cw| return cw[cell * s.pattern_count + t];
    return s.weights[t];
}

fn weightLogWeight(s: *const Solver, cell: usize, t: usize) f64 {
    if (s.cell_weights) |cw| {
        const w = cw[cell * s.pattern_count + t];
        return if (w > 0) w * math.log(w) else 0;
    }
    return s.weight_log_weights[t];
}

fn onBoundary(s: *const Solver, cell: usize) bool {
    if (s.periodic) return false;
    const x = cell % s.width;
    const y = cell / s.width;
    return x + s.n > s.width or y + s.n > s.height;
}

fn clear(s: *Solver, gpa: Allocator, random: std.Random) !bool {
    const t_count = s.pattern_count;
    @memset(s.wave, true);
    @memset(s.stamps, 0);
    s.stack_len = 0;
    @memset(s.dirty, false);
    s.dirty_len = 0;

    for (s.observed, 0..) |*o, i| {
        o.* = 0;
        @memcpy(s.compatible[i * t_count * 4 ..][0 .. t_count * 4], s.full_support);
        var sw: f64 = 0;
        var swlw: f64 = 0;
        for (0..t_count) |t| {
            sw += s.weight(i, t);
            swlw += s.weightLogWeight(i, t);
        }
        s.sums_of_ones[i] = t_count;
        s.sums_of_weights[i] = sw;
        s.sums_of_weight_log_weights[i] = swlw;
        s.noise[i] = 1e-6 * random.float(f64);
    }

    for (0..s.observed.len) |i| {
        var needs_support: [4]bool = @splat(false);
        if (!s.onBoundary(i)) {
            for (&needs_support, 0..) |*o, d| o.* = s.neighbor(@intCast(i), opposite(@intCast(d))) != null;
        }
        for (0..t_count) |t| {
            const k = i * t_count + t;
            var banned = (s.cell_weights != null and s.weight(i, t) <= 0) or
                (s.allowed != null and !s.allowed.?[k]);
            for (needs_support, s.compatible[k * 4 ..][0..4]) |need, c| banned = banned or (need and c == 0);
            if (banned and !s.ban(i, t)) return false;
        }
    }
    if (!try s.propagate(gpa)) return false;

    s.heap.clearRetainingCapacity();
    try s.heap.ensureTotalCapacity(gpa, s.observed.len);
    for (0..s.observed.len) |i| {
        if (s.sums_of_ones[i] > 1 and !s.onBoundary(i)) try s.push(gpa, @intCast(i));
    }
    return true;
}

fn push(s: *Solver, gpa: Allocator, cell: u32) !void {
    const sw = s.sums_of_weights[cell];
    const entropy = math.log(sw) - s.sums_of_weight_log_weights[cell] / sw;
    try s.heap.push(gpa, .{ .key = entropy + s.noise[cell], .cell = cell, .stamp = s.stamps[cell] });
}

fn collapse(s: *Solver, cell: u32, random: std.Random) void {
    const t_count = s.pattern_count;
    const row = s.wave[@as(usize, cell) * t_count ..][0..t_count];
    var r = random.float(f64) * s.sums_of_weights[cell];
    var chosen: usize = t_count;
    for (row, 0..) |possible, t| {
        if (!possible) continue;
        chosen = t;
        r -= s.weight(cell, t);
        if (r < 0) break;
    }
    assert(chosen < t_count);
    for (0..t_count) |t| {
        if (row[t] and t != chosen) _ = s.ban(cell, t);
    }
}

/// Remove pattern t from a cell. False when the cell has nothing left.
fn ban(s: *Solver, cell: usize, t: usize) bool {
    const t_count = s.pattern_count;
    const k = cell * t_count + t;
    if (!s.wave[k]) return s.sums_of_ones[cell] > 0;
    s.wave[k] = false;
    @memset(s.compatible[k * 4 ..][0..4], 0);
    s.stack[s.stack_len] = .{ .cell = @intCast(cell), .pattern = @intCast(t) };
    s.stack_len += 1;
    s.sums_of_ones[cell] -= 1;
    s.sums_of_weights[cell] -= s.weight(cell, t);
    s.sums_of_weight_log_weights[cell] -= s.weightLogWeight(cell, t);
    s.stamps[cell] +%= 1;
    if (!s.dirty[cell]) {
        s.dirty[cell] = true;
        s.dirty_cells[s.dirty_len] = @intCast(cell);
        s.dirty_len += 1;
    }
    return s.sums_of_ones[cell] > 0;
}

fn neighbor(s: *const Solver, cell: u32, d: u2) ?u32 {
    const w: i32 = @intCast(s.width);
    const h: i32 = @intCast(s.height);
    var x = @as(i32, @intCast(cell % s.width)) + dx[d];
    var y = @as(i32, @intCast(cell / s.width)) + dy[d];
    if (!s.periodic) {
        const n: i32 = @intCast(s.n);
        if (x < 0 or y < 0 or x + n > w or y + n > h) return null;
    }
    x = @mod(x, w);
    y = @mod(y, h);
    return @intCast(y * w + x);
}

fn propagate(s: *Solver, gpa: Allocator) !bool {
    const t_count = s.pattern_count;
    while (s.stack_len > 0) {
        s.stack_len -= 1;
        const b = s.stack[s.stack_len];
        for (0..4) |d_index| {
            const d: u2 = @intCast(d_index);
            const cell2 = s.neighbor(b.cell, d) orelse continue;
            for (s.propagator.list(d, b.pattern)) |t2| {
                const w = @as(usize, cell2) * t_count + t2;
                if (!s.wave[w]) continue;
                const k = w * 4 + d;
                s.compatible[k] -= 1;
                if (s.compatible[k] == 0 and !s.ban(cell2, t2)) return false;
            }
        }
    }
    for (s.dirty_cells[0..s.dirty_len]) |cell| {
        s.dirty[cell] = false;
        if (s.sums_of_ones[cell] > 1 and !s.onBoundary(cell)) try s.push(gpa, cell);
    }
    s.dirty_len = 0;
    return true;
}

fn testAgrees(_: void, d: u2, a: u32, b: u32) bool {
    // Two patterns on a line: 0 may only neighbor 1 east-west, anything goes north-south.
    if (d == 1 or d == 3) return a != b;
    return true;
}

test "Solver: two-color stripes alternate horizontally" {
    const gpa = std.testing.allocator;
    var prop: Propagator = try .build(gpa, 2, {}, testAgrees);
    defer prop.deinit(gpa);
    var s: Solver = try .init(gpa, .{ .width = 6, .height = 3, .propagator = &prop, .weights = &.{ 1, 1 } });
    defer s.deinit(gpa);
    _ = try s.run(gpa, 7, 1);
    for (0..3) |y| for (0..5) |x| {
        try std.testing.expect(s.observed[y * 6 + x] != s.observed[y * 6 + x + 1]);
    };
}

test "Solver: odd periodic ring of alternating patterns is a contradiction" {
    const gpa = std.testing.allocator;
    var prop: Propagator = try .build(gpa, 2, {}, testAgrees);
    defer prop.deinit(gpa);
    var s: Solver = try .init(gpa, .{ .width = 5, .height = 1, .periodic = true, .propagator = &prop, .weights = &.{ 1, 1 } });
    defer s.deinit(gpa);
    try std.testing.expectError(error.Contradiction, s.run(gpa, 7, 4));
}
