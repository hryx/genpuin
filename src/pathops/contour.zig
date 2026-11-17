//! Iso-lines of a Field by marching squares over the cell centers, with
//! linear interpolation along cell edges and saddles resolved by the
//! asymptotic decider (Nielson and Hamann, "The asymptotic decider:
//! resolving the ambiguity in marching cubes", IEEE Visualization 1991).
//!
//! Every segment is directed with values at or above the level on its
//! right (see geom.orient), so neighboring cells chain head to tail and
//! a closed line around a low region turns positively.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const geom = @import("geom.zig");
const Vec2 = geom.Vec2;
const Rect = @import("sdf.zig").Rect;

pub const Line = struct {
    points: []Vec2,
    closed: bool,
};

pub fn freeLines(gpa: Allocator, lines: []const Line) void {
    for (lines) |l| gpa.free(l.points);
    gpa.free(lines);
}

const none = std.math.maxInt(u32);

const Crossing = struct {
    p: Vec2,
    next: u32 = none,
    has_prev: bool = false,
    visited: bool = false,
};

const Tracer = struct {
    gpa: Allocator,
    field: *const Field,
    level: f32,
    rect: Rect,
    crossings: std.ArrayList(Crossing) = .empty,

    /// Scene position of grid point (i, j), the center of that cell.
    fn pos(t: *const Tracer, i: f64, j: f64) Vec2 {
        return .{
            t.rect.x + (i + 0.5) * t.rect.w / @as(f64, @floatFromInt(t.field.w)),
            t.rect.y + (j + 0.5) * t.rect.h / @as(f64, @floatFromInt(t.field.h)),
        };
    }

    /// The crossing on the grid edge from (i0, j0) to (i1, j1), made once
    /// and shared by both cells through `slot`.
    fn crossing(t: *Tracer, slot: *u32, ia: u32, ja: u32, ib: u32, jb: u32) !u32 {
        if (slot.* != none) return slot.*;
        const va = t.field.get(ia, ja);
        const vb = t.field.get(ib, jb);
        const s: f64 = @floatCast((t.level - va) / (vb - va));
        const fia: f64 = @floatFromInt(ia);
        const fja: f64 = @floatFromInt(ja);
        const fib: f64 = @floatFromInt(ib);
        const fjb: f64 = @floatFromInt(jb);
        const p = t.pos(fia + (fib - fia) * s, fja + (fjb - fja) * s);
        slot.* = @intCast(t.crossings.items.len);
        try t.crossings.append(t.gpa, .{ .p = p });
        return slot.*;
    }

    fn link(t: *Tracer, from: u32, to: u32) void {
        assert(t.crossings.items[from].next == none);
        t.crossings.items[from].next = to;
        t.crossings.items[to].has_prev = true;
    }

    fn high(t: *const Tracer, v: f32) bool {
        return v >= t.level;
    }

    fn run(t: *Tracer) !void {
        const w = t.field.w;
        const h = t.field.h;
        if (w < 2 or h < 2) return;
        // Slots for the crossings of the top and bottom edges of the
        // current row of cells, and of its vertical edges.
        const top = try t.gpa.alloc(u32, w);
        defer t.gpa.free(top);
        const bottom = try t.gpa.alloc(u32, w);
        defer t.gpa.free(bottom);
        const sides = try t.gpa.alloc(u32, w);
        defer t.gpa.free(sides);
        @memset(top, none);

        var top_slots = top;
        var bottom_slots = bottom;
        for (0..h - 1) |jj| {
            const j: u32 = @intCast(jj);
            @memset(bottom_slots, none);
            @memset(sides, none);
            for (0..w - 1) |ii| {
                const i: u32 = @intCast(ii);
                const v = [4]f32{ t.field.get(i, j), t.field.get(i + 1, j), t.field.get(i + 1, j + 1), t.field.get(i, j + 1) };
                const hi = [4]bool{ t.high(v[0]), t.high(v[1]), t.high(v[2]), t.high(v[3]) };
                if (hi[0] == hi[1] and hi[1] == hi[2] and hi[2] == hi[3]) continue;
                // Edge k joins corner k and corner k + 1, going around
                // the cell positively.
                var ids: [4]u32 = .{ none, none, none, none };
                if (hi[0] != hi[1]) ids[0] = try t.crossing(&top_slots[i], i, j, i + 1, j);
                if (hi[1] != hi[2]) ids[1] = try t.crossing(&sides[i + 1], i + 1, j, i + 1, j + 1);
                if (hi[2] != hi[3]) ids[2] = try t.crossing(&bottom_slots[i], i, j + 1, i + 1, j + 1);
                if (hi[3] != hi[0]) ids[3] = try t.crossing(&sides[i], i, j, i, j + 1);
                t.cell(v, hi, ids);
            }
            std.mem.swap([]u32, &top_slots, &bottom_slots);
        }
    }

    /// Join crossings inside one cell. A chord from edge k1 forward to
    /// edge k2 cuts off corners k1 + 1 to k2. Walking the cell boundary
    /// positively, that part lies right of the chord taken k1 to k2, so the
    /// chord runs that way when those corners are high.
    fn cell(t: *Tracer, v: [4]f32, hi: [4]bool, ids: [4]u32) void {
        var on: [4]usize = undefined;
        var n: usize = 0;
        for (ids, 0..) |id, k| if (id != none) {
            on[n] = k;
            n += 1;
        };
        assert(n == 2 or n == 4);
        if (n == 2) return t.chord(hi, ids, on[0], on[1]);
        const denom = v[0] + v[2] - v[1] - v[3];
        const center = if (denom != 0) (v[0] * v[2] - v[1] * v[3]) / denom else (v[0] + v[1] + v[2] + v[3]) / 4;
        // Corners 0 and 2 share a state in a saddle. When the center agrees
        // with them they connect, and chords cut off corners 1 and 3.
        if (t.high(center) == hi[0]) {
            t.chord(hi, ids, 0, 1);
            t.chord(hi, ids, 2, 3);
        } else {
            t.chord(hi, ids, 3, 0);
            t.chord(hi, ids, 1, 2);
        }
    }

    fn chord(t: *Tracer, hi: [4]bool, ids: [4]u32, k1: usize, k2: usize) void {
        if (hi[(k1 + 1) % 4]) t.link(ids[k1], ids[k2]) else t.link(ids[k2], ids[k1]);
    }

    fn collect(t: *Tracer, out: *std.ArrayList(Line)) !void {
        const cs = t.crossings.items;
        var pts: std.ArrayList(Vec2) = .empty;
        defer pts.deinit(t.gpa);
        for (0..2) |pass| {
            for (cs, 0..) |c, start| {
                if (c.visited) continue;
                // Open lines start where nothing leads in, at the field
                // border. Whatever is left afterward is closed.
                if (pass == 0 and c.has_prev) continue;
                pts.clearRetainingCapacity();
                var cur: u32 = @intCast(start);
                while (cur != none and !cs[cur].visited) {
                    cs[cur].visited = true;
                    try pts.append(t.gpa, cs[cur].p);
                    cur = cs[cur].next;
                }
                const closed = pass == 1;
                if (pts.items.len < 2 or (closed and pts.items.len < 3)) continue;
                const owned = try t.gpa.dupe(Vec2, pts.items);
                errdefer t.gpa.free(owned);
                try out.append(t.gpa, .{ .points = owned, .closed = closed });
            }
        }
    }
};

/// Trace the iso-line at `level`, mapping the field over `rect`. Caller
/// owns the lines, free them with freeLines.
pub fn trace(gpa: Allocator, field: *const Field, level: f32, rect: Rect) ![]Line {
    var t: Tracer = .{ .gpa = gpa, .field = field, .level = level, .rect = rect };
    defer t.crossings.deinit(gpa);
    try t.run();
    var out: std.ArrayList(Line) = .empty;
    errdefer {
        for (out.items) |l| gpa.free(l.points);
        out.deinit(gpa);
    }
    try t.collect(&out);
    return out.toOwnedSlice(gpa);
}

test "contour: a circle bump gives one closed loop" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 21, 21, 0);
    defer f.deinit(gpa);
    for (0..21) |j| for (0..21) |i| {
        const dx = @as(f32, @floatFromInt(i)) - 10;
        const dy = @as(f32, @floatFromInt(j)) - 10;
        f.set(@intCast(i), @intCast(j), @sqrt(dx * dx + dy * dy));
    };
    const lines = try trace(gpa, &f, 6, .{ .x = -0.5, .y = -0.5, .w = 21, .h = 21 });
    defer freeLines(gpa, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(lines[0].closed);
    // Low inside, so the loop turns positively.
    const a = geom.area2(lines[0].points) / 2;
    try std.testing.expect(a > 0);
    try std.testing.expectApproxEqRel(std.math.pi * 36.0, a, 0.02);
    for (lines[0].points) |p| try std.testing.expectApproxEqAbs(@as(f64, 6), geom.dist(p, .{ 10, 10 }), 0.05);
}

test "contour: a ramp gives one open line across the field" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 4, 3, 0);
    defer f.deinit(gpa);
    for (0..3) |j| for (0..4) |i| f.set(@intCast(i), @intCast(j), @floatFromInt(i));
    const lines = try trace(gpa, &f, 1.5, .{ .x = 0, .y = 0, .w = 4, .h = 3 });
    defer freeLines(gpa, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(!lines[0].closed);
    try std.testing.expectEqual(@as(usize, 3), lines[0].points.len);
    for (lines[0].points) |p| try std.testing.expectEqual(@as(f64, 2), p[0]);
}

test "contour: saddle follows the asymptotic decider" {
    const gpa = std.testing.allocator;
    var f: Field = try .init(gpa, 2, 2, 0);
    defer f.deinit(gpa);
    // High at corners 0 and 2, center value (1*1 - 0*0) / 2 = 0.5.
    f.set(0, 0, 1);
    f.set(1, 1, 1);
    const joined = try trace(gpa, &f, 0.4, .{ .x = 0, .y = 0, .w = 2, .h = 2 });
    defer freeLines(gpa, joined);
    const split = try trace(gpa, &f, 0.6, .{ .x = 0, .y = 0, .w = 2, .h = 2 });
    defer freeLines(gpa, split);
    try std.testing.expectEqual(@as(usize, 2), joined.len);
    try std.testing.expectEqual(@as(usize, 2), split.len);
    // Connected highs cut off the low corner (1, 0) near it.
    var near_low = false;
    for (joined) |l| near_low = near_low or (l.points[0][0] > 1 and l.points[1][1] < 1) or (l.points[1][0] > 1 and l.points[0][1] < 1);
    try std.testing.expect(near_low);
}
