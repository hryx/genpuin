//! Offset curves: the exact signed distance to the contours, sampled on a
//! grid and traced at each offset distance, then simplified. Inflating
//! rounds convex corners like a Minkowski sum with a disc. Deflating keeps
//! sharp corners up to the grid resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Field = @import("../Field.zig");
const geom = @import("geom.zig");
const Vec2 = geom.Vec2;
const EdgeSet = @import("EdgeSet.zig");
const contour = @import("contour.zig");
const simplify = @import("simplify.zig");
const Rect = @import("sdf.zig").Rect;

pub const Options = struct {
    /// Grid cell size in scene units. Zero picks one from the extent.
    resolution: f64 = 0,
    /// Simplification tolerance. Negative picks a fifth of a cell.
    tolerance: f64 = -1,
    rule: geom.FillRule = .nonzero,
    /// Treat the contours as open paths and outline them.
    open: bool = false,
};

const cells_max = 4096;

/// One result per distance, positive grows the shape. Each result is a
/// set of closed contours, outer ones turning positively and holes
/// negatively. Caller owns everything, free with freeOffsets.
pub fn offsets(gpa: Allocator, contours: geom.Contours, distances: []const f64, opts: Options) ![][][]Vec2 {
    const out = try gpa.alloc([][]Vec2, distances.len);
    for (out) |*o| o.* = &.{};
    errdefer freeOffsets(gpa, out);
    const box = geom.bounds(contours) orelse return out;

    // Reach is how far the result can extend past the input, depth how
    // far the distance field must stay exact on either side.
    var reach: f64 = 0;
    var depth: f64 = 0;
    for (distances) |d| {
        reach = @max(reach, if (opts.open) @abs(d) else d);
        depth = @max(depth, @abs(d));
    }
    const span = @max(box[1][0] - box[0][0], box[1][1] - box[0][1]) + 2 * reach;
    const cell = if (opts.resolution > 0) opts.resolution else @max(span / 512, 1e-6);
    const margin = reach + 2 * cell;
    const fw = @max(box[1][0] - box[0][0] + 2 * margin, cell);
    const fh = @max(box[1][1] - box[0][1] + 2 * margin, cell);
    const cols: u32 = @intFromFloat(std.math.clamp(@ceil(fw / cell), 2, cells_max));
    const rows: u32 = @intFromFloat(std.math.clamp(@ceil(fh / cell), 2, cells_max));
    const rect: Rect = .{ .x = box[0][0] - margin, .y = box[0][1] - margin, .w = fw, .h = fh };

    var set: EdgeSet = try .init(gpa, contours, !opts.open);
    defer set.deinit(gpa);
    var field: Field = try .init(gpa, cols, rows, 0);
    defer field.deinit(gpa);
    try distanceField(gpa, &set, &field, rect, if (opts.open) null else opts.rule, depth + 4 * cell);

    const tol = if (opts.tolerance >= 0) opts.tolerance else @min(fw / @as(f64, @floatFromInt(cols)), fh / @as(f64, @floatFromInt(rows))) * 0.2;
    for (distances, out) |d, *o| o.* = try traceLevel(gpa, &field, rect, @floatCast(d), tol);
    return out;
}

pub fn freeOffsets(gpa: Allocator, out: []const []const []const Vec2) void {
    for (out) |o| geom.freeContours(gpa, o);
    gpa.free(out);
}

fn traceLevel(gpa: Allocator, field: *const Field, rect: Rect, level: f32, tol: f64) ![][]Vec2 {
    const lines = try contour.trace(gpa, field, level, rect);
    defer contour.freeLines(gpa, lines);
    var out: std.ArrayList([]Vec2) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    for (lines) |l| {
        const s = try simplify.simplify(gpa, l.points, tol, true, .distance);
        if (s.len < 3) {
            gpa.free(s);
            continue;
        }
        out.append(gpa, s) catch |err| {
            gpa.free(s);
            return err;
        };
    }
    return out.toOwnedSlice(gpa);
}

const Crossing = struct {
    x: f64,
    sign: i32,

    fn less(_: void, a: Crossing, b: Crossing) bool {
        return a.x < b.x;
    }
};

/// Fill `field` over `rect` with the distance to the edges, capped at
/// `limit` and negative inside under `rule` when there is one. Winding
/// comes from one scanline of crossings per row.
pub fn distanceField(gpa: Allocator, set: *const EdgeSet, field: *Field, rect: Rect, rule: ?geom.FillRule, limit: f64) !void {
    var xs: std.ArrayList(Crossing) = .empty;
    defer xs.deinit(gpa);
    const sx = rect.w / @as(f64, @floatFromInt(field.w));
    const sy = rect.h / @as(f64, @floatFromInt(field.h));
    for (0..field.h) |j| {
        const y = rect.y + (@as(f64, @floatFromInt(j)) + 0.5) * sy;
        xs.clearRetainingCapacity();
        var w: i32 = 0;
        if (rule != null) {
            for (set.band(y)) |e| {
                const a = set.edges[e][0];
                const b = set.edges[e][1];
                const up = a[1] <= y and b[1] > y;
                const down = b[1] <= y and a[1] > y;
                if (!up and !down) continue;
                const x = a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
                const sign: i32 = if (up) 1 else -1;
                try xs.append(gpa, .{ .x = x, .sign = sign });
                w += sign;
            }
            std.mem.sortUnstable(Crossing, xs.items, {}, Crossing.less);
        }
        var next: usize = 0;
        const row = field.data[j * field.w ..][0..field.w];
        for (row, 0..) |*v, i| {
            const x = rect.x + (@as(f64, @floatFromInt(i)) + 0.5) * sx;
            while (next < xs.items.len and xs.items[next].x <= x) : (next += 1) w -= xs.items[next].sign;
            const d = set.distance(.{ x, y }, limit);
            const in = if (rule) |r| geom.inside(r, w) else false;
            v.* = @floatCast(if (in) -d else d);
        }
    }
}

test "offset: a square grows by its distance and gains round corners" {
    const gpa = std.testing.allocator;
    const sq = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const out = try offsets(gpa, &.{&sq}, &.{ 2, -2 }, .{ .resolution = 0.1 });
    defer freeOffsets(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out[0].len);
    // Square plus four 10 x 2 strips plus a disc of radius 2.
    const grown = geom.area2(out[0][0]) / 2;
    try std.testing.expectApproxEqRel(100 + 80 + std.math.pi * 4.0, grown, 0.01);
    try std.testing.expect(out[0][0].len < 80);
    const shrunk = geom.area2(out[1][0]) / 2;
    try std.testing.expectApproxEqRel(@as(f64, 36), shrunk, 0.01);
}

test "offset: deep inward offsets of one field" {
    const gpa = std.testing.allocator;
    var circle: [256]Vec2 = undefined;
    for (&circle, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / 256 * std.math.tau;
        p.* = .{ 20 * @cos(t), 20 * @sin(t) };
    }
    const out = try offsets(gpa, &.{&circle}, &.{ -5, -15, -25 }, .{});
    defer freeOffsets(gpa, out);
    try std.testing.expectApproxEqRel(std.math.pi * 225.0, geom.area2(out[0][0]) / 2, 0.01);
    try std.testing.expectApproxEqRel(std.math.pi * 25.0, geom.area2(out[1][0]) / 2, 0.02);
    try std.testing.expectEqual(@as(usize, 0), out[2].len);
}

test "offset: a ring with a hole keeps its hole" {
    const gpa = std.testing.allocator;
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 20 }, .{ 0, 20 } };
    const hole = [_]Vec2{ .{ 5, 5 }, .{ 5, 15 }, .{ 15, 15 }, .{ 15, 5 } };
    const out = try offsets(gpa, &.{ &outer, &hole }, &.{1}, .{ .resolution = 0.1 });
    defer freeOffsets(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out[0].len);
    var total: f64 = 0;
    for (out[0]) |c| total += geom.area2(c) / 2;
    // 22 x 22 with rounded corners, minus 8 x 8.
    try std.testing.expectApproxEqRel(484 - (4 - std.math.pi) - 64, total, 0.01);
}

test "offset: an open path gets a closed outline" {
    const gpa = std.testing.allocator;
    const path = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 } };
    const out = try offsets(gpa, &.{&path}, &.{1}, .{ .resolution = 0.05, .open = true });
    defer freeOffsets(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out[0].len);
    try std.testing.expectApproxEqRel(20 + std.math.pi, geom.area2(out[0][0]) / 2, 0.01);
}
