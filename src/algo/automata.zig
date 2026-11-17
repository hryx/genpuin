//! Elementary (one-dimensional, two-state, radius-one) cellular automata
//! in Wolfram's rule numbering, on a ring.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");

/// Rows 0..steps of `width` cells each, flattened. Row 0 is `first`.
pub fn elementary(gpa: Allocator, rule: f64, first: []const u1, steps: usize) ![]u1 {
    var lookup: [8]u1 = undefined;
    for (&lookup, 0..) |*l, i| {
        const bit = math.mod(@floor(rule / math.pow(2, @floatFromInt(i))), 2);
        l.* = @intFromBool(bit == 1);
    }
    const w = first.len;
    const cells = try gpa.alloc(u1, w * (steps + 1));
    @memcpy(cells[0..w], first);
    for (1..steps + 1) |g| {
        const prev = cells[(g - 1) * w ..][0..w];
        const next = cells[g * w ..][0..w];
        for (next, 0..) |*c, i| {
            const l: u3 = prev[(i + w - 1) % w];
            const m: u3 = prev[i];
            const r: u3 = prev[(i + 1) % w];
            c.* = lookup[l * 4 + m * 2 + r];
        }
    }
    return cells;
}

/// A single live cell at the centre, as Lua's math.ceil(width / 2).
pub fn centreSeed(cells: []u1) void {
    @memset(cells, 0);
    if (cells.len > 0) cells[(cells.len + 1) / 2 - 1] = 1;
}

const testing = std.testing;

test "automata: rule 90 draws a Sierpinski triangle" {
    var first: [7]u1 = undefined;
    centreSeed(&first);
    const rows = try elementary(testing.allocator, 90, &first, 2);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u1, &.{ 0, 0, 0, 1, 0, 0, 0 }, rows[0..7]);
    try testing.expectEqualSlices(u1, &.{ 0, 0, 1, 0, 1, 0, 0 }, rows[7..14]);
    try testing.expectEqualSlices(u1, &.{ 0, 1, 0, 0, 0, 1, 0 }, rows[14..21]);
}

test "automata: the ring wraps" {
    const first = [_]u1{ 1, 0, 0, 0 };
    const rows = try elementary(testing.allocator, 90, &first, 1);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u1, &.{ 0, 1, 0, 1 }, rows[4..8]);
}

test "automata: even width seeds left of centre" {
    var first: [4]u1 = undefined;
    centreSeed(&first);
    try testing.expectEqualSlices(u1, &.{ 0, 1, 0, 0 }, &first);
}
