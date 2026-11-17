//! L-system string rewriting with deterministic and weighted stochastic
//! productions, one byte per symbol.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Rng = @import("rand.zig").Rng;

pub const Choice = struct {
    text: []const u8,
    weight: f64,
};

pub const Rule = union(enum) {
    text: []const u8,
    choices: []const Choice,
    /// A production of a type rewrite cannot use. Rewriting fails only
    /// if the symbol occurs.
    invalid,
};

/// Productions by symbol. Symbols without one are copied.
pub const Rules = [256]?Rule;

pub const Error = error{InvalidRule} || Allocator.Error;

/// Apply `rules` to every symbol of `axiom`, `iterations` times.
/// Stochastic rules draw once per occurrence, left to right.
pub fn rewrite(gpa: Allocator, rng: *Rng, axiom: []const u8, rules: *const Rules, iterations: f64) Error![]u8 {
    var cur: std.ArrayList(u8) = .empty;
    errdefer cur.deinit(gpa);
    try cur.appendSlice(gpa, axiom);
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(gpa);

    var k: f64 = 1;
    while (k <= iterations) : (k += 1) {
        next.clearRetainingCapacity();
        for (cur.items) |ch| {
            const rule = rules[ch] orelse {
                try next.append(gpa, ch);
                continue;
            };
            switch (rule) {
                .text => |t| try next.appendSlice(gpa, t),
                .choices => |cs| try next.appendSlice(gpa, pick(rng, cs)),
                .invalid => return error.InvalidRule,
            }
        }
        std.mem.swap(std.ArrayList(u8), &cur, &next);
    }
    return cur.toOwnedSlice(gpa);
}

fn pick(rng: *Rng, choices: []const Choice) []const u8 {
    std.debug.assert(choices.len > 0);
    var total: f64 = 0;
    for (choices) |c| total = total + c.weight;
    const r = rng.next() * total;
    var acc: f64 = 0;
    for (choices) |c| {
        acc = acc + c.weight;
        if (r < acc) return c.text;
    }
    return choices[choices.len - 1].text;
}

const testing = std.testing;

test "lsystem: deterministic algae" {
    var rules: Rules = @splat(null);
    rules['A'] = .{ .text = "AB" };
    rules['B'] = .{ .text = "A" };
    var rng: Rng = .unseeded;
    const s = try rewrite(testing.allocator, &rng, "A", &rules, 4);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("ABAABABA", s);
}

test "lsystem: a zero-weight choice is never taken" {
    var rules: Rules = @splat(null);
    const cs = [_]Choice{ .{ .text = "x", .weight = 0 }, .{ .text = "y", .weight = 1 } };
    rules['F'] = .{ .choices = &cs };
    var rng: Rng = .init(1);
    const s = try rewrite(testing.allocator, &rng, "FFFF+F", &rules, 1);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("yyyy+y", s);
}

test "lsystem: an invalid rule fails only when used" {
    var rules: Rules = @splat(null);
    rules['Q'] = .invalid;
    var rng: Rng = .unseeded;
    const s = try rewrite(testing.allocator, &rng, "AB", &rules, 2);
    testing.allocator.free(s);
    try testing.expectError(error.InvalidRule, rewrite(testing.allocator, &rng, "AQ", &rules, 1));
}
