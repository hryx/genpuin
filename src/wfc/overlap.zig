//! The overlapping model of wave function collapse, after Maxim Gumin's
//! OverlappingModel.cs (https://github.com/mxgmn/WaveFunctionCollapse).
//!
//! Every n by n window of the sample, with up to eight of its rotations
//! and reflections, becomes a pattern weighted by how often it occurs.
//! Each output cell picks one pattern, and neighboring patterns must
//! agree where they overlap, so every n by n window of the output is a
//! window of the sample.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Solver = @import("Solver.zig");

pub const Options = struct {
    /// Pattern size, 2 or more.
    n: u32 = 3,
    width: u32,
    height: u32,
    periodic_input: bool = true,
    periodic_output: bool = true,
    /// How many of the eight rotations and reflections to add, 1 to 8.
    symmetry: u32 = 8,
    /// Pin the sample's bottom-left n by n window to the output's bottom
    /// n rows and forbid it elsewhere, for samples with a floor.
    ground: bool = false,
    seed: u64 = 1,
    attempts: u32 = 10,
};

pub const Sample = struct {
    width: u32,
    height: u32,
    /// Row-major.
    values: []const i32,
};

pub const Result = struct {
    width: u32,
    height: u32,
    /// Row-major, drawn from the sample's values.
    values: []i32,
    attempts: u32,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.values);
        r.* = undefined;
    }
};

pub const Error = error{ BadSample, TooManyColors } || Solver.Error;

const Patterns = struct {
    n: u32,
    /// Pattern t occupies data[t * n * n ..][0 .. n * n], color indices.
    data: []const u8,

    fn get(ps: *const Patterns, t: u32) []const u8 {
        const nn = ps.n * ps.n;
        return ps.data[t * nn ..][0..nn];
    }

    /// Whether pattern b, shifted one step in direction d, agrees with a
    /// on their overlap.
    fn agrees(ps: *const Patterns, d: u2, a: u32, b: u32) bool {
        const n: i32 = @intCast(ps.n);
        const ox = Solver.dx[d];
        const oy = Solver.dy[d];
        const pa = ps.get(a);
        const pb = ps.get(b);
        var y: i32 = @max(oy, 0);
        while (y < @min(n, n + oy)) : (y += 1) {
            var x: i32 = @max(ox, 0);
            while (x < @min(n, n + ox)) : (x += 1) {
                const ia: usize = @intCast(x + n * y);
                const ib: usize = @intCast(x - ox + n * (y - oy));
                if (pa[ia] != pb[ib]) return false;
            }
        }
        return true;
    }
};

pub fn solve(gpa: Allocator, sample: Sample, opts: Options) Error!Result {
    const n = opts.n;
    if (n < 2 or sample.values.len != @as(usize, sample.width) * sample.height) return error.BadSample;
    if (!opts.periodic_input and (n > sample.width or n > sample.height)) return error.BadSample;
    if (n > opts.width or n > opts.height) return error.BadSample;
    assert(opts.symmetry >= 1 and opts.symmetry <= 8);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var palette: std.ArrayList(i32) = .empty;
    const indexed = try arena.alloc(u8, sample.values.len);
    for (indexed, sample.values) |*o, v| {
        const k = std.mem.indexOfScalar(i32, palette.items, v) orelse blk: {
            if (palette.items.len == 256) return error.TooManyColors;
            try palette.append(arena, v);
            break :blk palette.items.len - 1;
        };
        o.* = @intCast(k);
    }

    const extracted = try extract(arena, indexed, sample.width, sample.height, opts);
    const ps: Patterns = .{ .n = n, .data = extracted.data };
    const t_count: u32 = @intCast(extracted.weights.len);
    var prop: Solver.Propagator = try .build(arena, t_count, &ps, Patterns.agrees);

    const cells = @as(usize, opts.width) * opts.height;
    var allowed: ?[]bool = null;
    if (opts.ground) {
        const mask = try arena.alloc(bool, cells * t_count);
        for (0..opts.height) |y| {
            const bottom = y == opts.height - n;
            for (0..opts.width) |x| {
                const row = mask[(y * opts.width + x) * t_count ..][0..t_count];
                for (row, 0..) |*m, t| m.* = (t == extracted.ground) == bottom;
            }
        }
        allowed = mask;
    }

    var solver: Solver = try .init(gpa, .{
        .width = opts.width,
        .height = opts.height,
        .n = n,
        .periodic = opts.periodic_output,
        .propagator = &prop,
        .weights = extracted.weights,
        .allowed = allowed,
    });
    defer solver.deinit(gpa);
    const used = try solver.run(gpa, opts.seed, opts.attempts);

    const out = try gpa.alloc(i32, cells);
    for (0..opts.height) |y| for (0..opts.width) |x| {
        var ox: usize = 0;
        var oy: usize = 0;
        if (!opts.periodic_output) {
            if (x + n > opts.width) ox = n - 1;
            if (y + n > opts.height) oy = n - 1;
        }
        const t = solver.observed[(y - oy) * opts.width + (x - ox)];
        out[y * opts.width + x] = palette.items[ps.get(t)[ox + oy * n]];
    };
    return .{ .width = opts.width, .height = opts.height, .values = out, .attempts = used };
}

const Extracted = struct {
    data: []const u8,
    weights: []const f64,
    ground: usize,
};

/// Collect distinct patterns in first-seen order, as the reference does.
fn extract(arena: Allocator, sample: []const u8, sw: u32, sh: u32, opts: Options) !Extracted {
    const n = opts.n;
    const nn = n * n;
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    var data: std.ArrayList(u8) = .empty;
    var weights: std.ArrayList(f64) = .empty;
    var ground: usize = 0;

    const xmax = if (opts.periodic_input) sw else sw - n + 1;
    const ymax = if (opts.periodic_input) sh else sh - n + 1;
    var variants: [8][]u8 = undefined;
    for (&variants) |*v| v.* = try arena.alloc(u8, nn);
    for (0..ymax) |y| for (0..xmax) |x| {
        for (0..n) |py| for (0..n) |px| {
            variants[0][px + py * n] = sample[(x + px) % sw + ((y + py) % sh) * sw];
        };
        reflect(variants[1], variants[0], n);
        rotate(variants[2], variants[0], n);
        reflect(variants[3], variants[2], n);
        rotate(variants[4], variants[2], n);
        reflect(variants[5], variants[4], n);
        rotate(variants[6], variants[4], n);
        reflect(variants[7], variants[6], n);
        for (variants[0..opts.symmetry], 0..) |v, k| {
            const gop = try index.getOrPut(arena, v);
            if (gop.found_existing) {
                weights.items[gop.value_ptr.*] += 1;
            } else {
                gop.key_ptr.* = try arena.dupe(u8, v);
                gop.value_ptr.* = @intCast(weights.items.len);
                try weights.append(arena, 1);
                try data.appendSlice(arena, v);
            }
            if (k == 0 and x == 0 and y == sh - n) ground = gop.value_ptr.*;
        }
    };
    return .{ .data = data.items, .weights = weights.items, .ground = ground };
}

fn rotate(out: []u8, p: []const u8, n: u32) void {
    for (0..n) |y| for (0..n) |x| {
        out[x + y * n] = p[n - 1 - y + x * n];
    };
}

fn reflect(out: []u8, p: []const u8, n: u32) void {
    for (0..n) |y| for (0..n) |x| {
        out[x + y * n] = p[n - 1 - x + y * n];
    };
}

/// Blocks of 1, 2 and 7 on a field of 0.
const test_sample = [_]i32{
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 0, 0, 2, 0, 0,
    0, 1, 1, 0, 0, 2, 0, 0,
    0, 0, 0, 0, 0, 2, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 7, 7, 7, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};

fn windowInSample(sample: Sample, n: u32, out: *const Result, ox: usize, oy: usize, wrap_out: bool) bool {
    for (0..sample.height) |sy| for (0..sample.width) |sx| {
        var same = true;
        for (0..n) |py| for (0..n) |px| {
            const s = sample.values[(sx + px) % sample.width + ((sy + py) % sample.height) * sample.width];
            const x = if (wrap_out) (ox + px) % out.width else ox + px;
            const y = if (wrap_out) (oy + py) % out.height else oy + py;
            if (s != out.values[y * out.width + x]) same = false;
        };
        if (same) return true;
    };
    return false;
}

test "overlap: every output window is a sample window" {
    const gpa = std.testing.allocator;
    const sample: Sample = .{ .width = 8, .height = 8, .values = &test_sample };
    inline for (.{ false, true }) |wrap| {
        var r = try solve(gpa, sample, .{ .n = 3, .width = 20, .height = 14, .symmetry = 1, .periodic_output = wrap, .seed = 4 });
        defer r.deinit(gpa);
        const ymax = if (wrap) r.height else r.height - 2;
        const xmax = if (wrap) r.width else r.width - 2;
        for (0..ymax) |y| for (0..xmax) |x| {
            try std.testing.expect(windowInSample(sample, 3, &r, x, y, wrap));
        };
    }
}

test "overlap: output values come from the sample" {
    const gpa = std.testing.allocator;
    const sample: Sample = .{ .width = 8, .height = 8, .values = &test_sample };
    var r = try solve(gpa, sample, .{ .n = 2, .width = 32, .height = 32, .seed = 8 });
    defer r.deinit(gpa);
    var seen_seven = false;
    for (r.values) |v| {
        try std.testing.expect(v == 0 or v == 1 or v == 2 or v == 7);
        seen_seven = seen_seven or v == 7;
    }
    try std.testing.expect(seen_seven);
}

test "overlap: same seed repeats, different seeds differ" {
    const gpa = std.testing.allocator;
    const sample: Sample = .{ .width = 8, .height = 8, .values = &test_sample };
    var a = try solve(gpa, sample, .{ .n = 3, .width = 24, .height = 24, .seed = 1 });
    defer a.deinit(gpa);
    var b = try solve(gpa, sample, .{ .n = 3, .width = 24, .height = 24, .seed = 1 });
    defer b.deinit(gpa);
    var c = try solve(gpa, sample, .{ .n = 3, .width = 24, .height = 24, .seed = 2 });
    defer c.deinit(gpa);
    try std.testing.expectEqualSlices(i32, a.values, b.values);
    try std.testing.expect(!std.mem.eql(i32, a.values, c.values));
}

test "overlap: ground pins the bottom row" {
    const gpa = std.testing.allocator;
    // Sky 0 over a floor of 5 with a 3 sprout.
    const values = [_]i32{
        0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
        0, 0, 3, 0, 0, 0,
        0, 0, 3, 0, 0, 0,
        5, 5, 5, 5, 5, 5,
    };
    const sample: Sample = .{ .width = 6, .height = 5, .values = &values };
    var r = try solve(gpa, sample, .{ .n = 2, .width = 16, .height = 10, .symmetry = 1, .ground = true, .periodic_input = false, .periodic_output = false, .seed = 3 });
    defer r.deinit(gpa);
    for (0..16) |x| try std.testing.expectEqual(@as(i32, 5), r.values[9 * 16 + x]);
}
