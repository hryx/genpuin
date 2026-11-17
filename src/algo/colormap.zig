//! Affine color maps fitted to {from, to} color pairs. Up to three
//! pairs give a per-channel linear fit with no cross-channel terms.
//! Four or more give the minimum-norm 3x4 affine matrix through the
//! pseudoinverse, x = A^T (A A^T)^-1 t.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rgb = [3]f64;

pub const Pair = struct {
    from: Rgb,
    to: Rgb,
};

/// Rows map {r, g, b, 1} to one output channel.
pub const Matrix = [3][4]f64;

pub const Error = error{Singular} || Allocator.Error;

pub fn solve(gpa: Allocator, pairs: []const Pair) Error!Matrix {
    if (pairs.len <= 3) return solveDiagonal(pairs);
    return solveAffine(gpa, pairs);
}

/// Per channel least squares of to = slope * from + offset.
fn solveDiagonal(pairs: []const Pair) Matrix {
    const n: f64 = @floatFromInt(pairs.len);
    var m: Matrix = undefined;
    for (&m, 0..) |*row, ch| {
        var sum_f: f64 = 0;
        var sum_t: f64 = 0;
        var sum_ff: f64 = 0;
        var sum_ft: f64 = 0;
        for (pairs) |p| {
            const f = p.from[ch];
            const t = p.to[ch];
            sum_f = sum_f + f;
            sum_t = sum_t + t;
            sum_ff = sum_ff + f * f;
            sum_ft = sum_ft + f * t;
        }
        const det = n * sum_ff - sum_f * sum_f;
        if (@abs(det) < 1e-12) {
            row.* = .{ 0, 0, 0, sum_t / n };
        } else {
            const slope = (n * sum_ft - sum_f * sum_t) / det;
            const offset = (sum_t - slope * sum_f) / n;
            row.* = .{ 0, 0, 0, offset };
            row[ch] = slope;
        }
    }
    return m;
}

fn solveAffine(gpa: Allocator, pairs: []const Pair) Error!Matrix {
    const n = pairs.len;
    const a = try gpa.alloc([4]f64, n);
    defer gpa.free(a);
    for (a, pairs) |*row, p| row.* = .{ p.from[0], p.from[1], p.from[2], 1 };

    const aat = try gpa.alloc(f64, n * n);
    defer gpa.free(aat);
    for (0..n) |i| for (0..n) |j| {
        var s: f64 = 0;
        for (0..4) |k| s = s + a[i][k] * a[j][k];
        aat[i * n + j] = s;
    };

    const target = try gpa.alloc(f64, n);
    defer gpa.free(target);
    const y = try gpa.alloc(f64, n);
    defer gpa.free(y);
    const scratch = try gpa.alloc(f64, n * (n + 1));
    defer gpa.free(scratch);

    var m: Matrix = undefined;
    for (&m, 0..) |*row, ch| {
        for (target, pairs) |*t, p| t.* = p.to[ch];
        try solveLinear(aat, target, scratch, y);
        for (row, 0..) |*x, k| {
            var s: f64 = 0;
            for (0..n) |i| s = s + a[i][k] * y[i];
            x.* = s;
        }
    }
    return m;
}

/// Gaussian elimination with partial pivoting on the n x n row-major
/// matrix `a`. `scratch` holds the n x (n + 1) augmented matrix.
fn solveLinear(a: []const f64, b: []const f64, scratch: []f64, x: []f64) error{Singular}!void {
    const n = b.len;
    const w = n + 1;
    std.debug.assert(a.len == n * n);
    std.debug.assert(scratch.len == n * w);
    for (0..n) |i| {
        @memcpy(scratch[i * w ..][0..n], a[i * n ..][0..n]);
        scratch[i * w + n] = b[i];
    }
    for (0..n) |col| {
        var best = @abs(scratch[col * w + col]);
        var best_row = col;
        for (col + 1..n) |row| {
            const v = @abs(scratch[row * w + col]);
            if (v > best) {
                best = v;
                best_row = row;
            }
        }
        if (best < 1e-12) return error.Singular;
        if (best_row != col) {
            for (0..w) |j| std.mem.swap(f64, &scratch[col * w + j], &scratch[best_row * w + j]);
        }
        for (col + 1..n) |row| {
            const f = scratch[row * w + col] / scratch[col * w + col];
            for (col..w) |j| scratch[row * w + j] = scratch[row * w + j] - f * scratch[col * w + j];
        }
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var s = scratch[i * w + n];
        for (i + 1..n) |j| s = s - scratch[i * w + j] * x[j];
        x[i] = s / scratch[i * w + i];
    }
}

pub fn apply(m: *const Matrix, c: Rgb) Rgb {
    var out: Rgb = undefined;
    for (&out, m) |*o, row| o.* = row[0] * c[0] + row[1] * c[1] + row[2] * c[2] + row[3];
    return out;
}

const testing = std.testing;

test "colormap: two pairs swap red and keep the rest" {
    const pairs = [_]Pair{
        .{ .from = .{ 1, 0, 0 }, .to = .{ 0, 0, 0 } },
        .{ .from = .{ 0, 1, 1 }, .to = .{ 1, 1, 1 } },
    };
    const m = try solve(testing.allocator, &pairs);
    try testing.expectEqual([4]f64{ -1, 0, 0, 1 }, m[0]);
    try testing.expectEqual([4]f64{ 0, 1, 0, 0 }, m[1]);
    try testing.expectEqual(Rgb{ 0.75, 0.5, 0.25 }, apply(&m, .{ 0.25, 0.5, 0.25 }));
}

test "colormap: a constant channel maps to its mean" {
    const pairs = [_]Pair{
        .{ .from = .{ 0.5, 0, 0 }, .to = .{ 0.2, 0, 0 } },
        .{ .from = .{ 0.5, 1, 1 }, .to = .{ 0.4, 1, 1 } },
    };
    const m = try solve(testing.allocator, &pairs);
    try testing.expectEqual([4]f64{ 0, 0, 0, 0.30000000000000004 }, m[0]);
}

test "colormap: four pairs fit the affine map exactly" {
    const pairs = [_]Pair{
        .{ .from = .{ 0, 0, 0 }, .to = .{ 1, 1, 1 } },
        .{ .from = .{ 1, 0, 0 }, .to = .{ 0, 1, 1 } },
        .{ .from = .{ 0, 1, 0 }, .to = .{ 1, 0, 1 } },
        .{ .from = .{ 0, 0, 1 }, .to = .{ 1, 1, 0 } },
    };
    const m = try solve(testing.allocator, &pairs);
    for (pairs) |p| {
        const got = apply(&m, p.from);
        for (got, p.to) |g, t| try testing.expectApproxEqAbs(t, g, 1e-12);
    }
}

test "colormap: repeated pairs are singular" {
    const p: Pair = .{ .from = .{ 0.1, 0.2, 0.3 }, .to = .{ 0, 0, 0 } };
    try testing.expectError(error.Singular, solve(testing.allocator, &.{ p, p, p, p }));
}
