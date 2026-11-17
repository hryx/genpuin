//! The simple tiled model of wave function collapse, after Maxim Gumin's
//! SimpleTiledModel.cs (https://github.com/mxgmn/WaveFunctionCollapse).
//!
//! Adjacency comes from edge sockets instead of an explicit neighbor
//! list. Each edge label is read clockwise around its tile, so two
//! touching edges fit when one label is the reverse of the other. A
//! palindrome like "a" or "aba" fits itself, "ab" fits only "ba".
//! Atomic labels ignore reading order and fit only themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Field = @import("../Field.zig");
const Solver = @import("Solver.zig");

pub const Socket = struct {
    label: []const u8,
    atomic: bool = false,
};

/// Gumin's symmetry classes, named after the letter whose symmetries the
/// tile shares. `slash` is the diagonal "/" class.
pub const Symmetry = enum { x, i, l, t, slash, f };

pub const Tile = struct {
    /// North, east, south, west.
    edges: [4]Socket,
    weight: f64 = 1,
    symmetry: Symmetry = .x,
    /// Multiplies `weight` per cell. Sampled bilinearly with the field
    /// stretched over the whole grid. Zero or less forbids the tile.
    weight_map: ?*const Field = null,
};

/// A tile mirrored horizontally when `flip`, then turned `rot` quarter
/// turns clockwise.
pub const Variant = struct {
    tile: u32,
    rot: u2 = 0,
    flip: bool = false,
};

/// An edge of a placed variant.
pub const Edge = struct {
    socket: Socket,
    reversed: bool = false,

    fn char(e: Edge, k: usize) u8 {
        const s = e.socket.label;
        return if (e.reversed) s[s.len - 1 - k] else s[k];
    }

    fn eql(a: Edge, b: Edge) bool {
        if (a.socket.atomic != b.socket.atomic) return false;
        if (a.socket.atomic) return std.mem.eql(u8, a.socket.label, b.socket.label);
        if (a.socket.label.len != b.socket.label.len) return false;
        for (0..a.socket.label.len) |k| if (a.char(k) != b.char(k)) return false;
        return true;
    }
};

/// Whether edge `a` of one tile may touch edge `b` of its neighbor.
pub fn fits(a: Edge, b: Edge) bool {
    if (a.socket.atomic != b.socket.atomic) return false;
    if (a.socket.atomic) return std.mem.eql(u8, a.socket.label, b.socket.label);
    const n = a.socket.label.len;
    if (n != b.socket.label.len) return false;
    for (0..n) |k| if (a.char(k) != b.char(n - 1 - k)) return false;
    return true;
}

/// Edges north, east, south, west of a tile after flip then rotation.
pub fn variantEdges(tile: *const Tile, rot: u2, flip: bool) [4]Edge {
    var e: [4]Edge = undefined;
    for (&e, tile.edges) |*o, s| o.* = .{ .socket = s };
    if (flip) {
        const before = e;
        e = .{ before[0], before[3], before[2], before[1] };
        for (&e) |*o| o.reversed = !o.reversed;
    }
    for (0..rot) |_| {
        const before = e;
        e = .{ before[3], before[0], before[1], before[2] };
    }
    return e;
}

/// The visually distinct variants of a symmetry class.
pub fn symmetryVariants(sym: Symmetry) []const Variant {
    return switch (sym) {
        .x => &.{.{ .tile = 0 }},
        .i, .slash => &.{ .{ .tile = 0 }, .{ .tile = 0, .rot = 1 } },
        .l, .t => &.{ .{ .tile = 0 }, .{ .tile = 0, .rot = 1 }, .{ .tile = 0, .rot = 2 }, .{ .tile = 0, .rot = 3 } },
        .f => &.{
            .{ .tile = 0 },               .{ .tile = 0, .rot = 1 },               .{ .tile = 0, .rot = 2 },               .{ .tile = 0, .rot = 3 },
            .{ .tile = 0, .flip = true }, .{ .tile = 0, .rot = 1, .flip = true }, .{ .tile = 0, .rot = 2, .flip = true }, .{ .tile = 0, .rot = 3, .flip = true },
        },
    };
}

/// A pre-collapsed cell. Null `rot` or `flip` accepts any variant of the
/// tile. A given orientation matches every variant with the same edges.
pub const Constraint = struct {
    x: u32,
    y: u32,
    tile: u32,
    rot: ?u2 = null,
    flip: ?bool = null,
};

pub const Options = struct {
    width: u32,
    height: u32,
    wrap: bool = false,
    seed: u64 = 1,
    attempts: u32 = 10,
    constraints: []const Constraint = &.{},
};

pub const Result = struct {
    width: u32,
    height: u32,
    /// Row-major.
    cells: []Variant,
    attempts: u32,

    pub fn at(r: *const Result, x: u32, y: u32) Variant {
        return r.cells[@as(usize, y) * r.width + x];
    }

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.cells);
        r.* = undefined;
    }
};

pub const Error = error{ NoTiles, BadConstraint } || Solver.Error;

const Context = struct {
    edges: []const [4]Edge,

    fn agrees(ctx: *const Context, d: u2, a: u32, b: u32) bool {
        return fits(ctx.edges[a][d], ctx.edges[b][Solver.opposite(d)]);
    }
};

pub fn solve(gpa: Allocator, tiles: []const Tile, opts: Options) Error!Result {
    if (tiles.len == 0) return error.NoTiles;
    assert(opts.width > 0 and opts.height > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var variants: std.ArrayList(Variant) = .empty;
    var edges: std.ArrayList([4]Edge) = .empty;
    var weights: std.ArrayList(f64) = .empty;
    for (tiles, 0..) |*tile, ti| {
        for (symmetryVariants(tile.symmetry)) |v| {
            try variants.append(arena, .{ .tile = @intCast(ti), .rot = v.rot, .flip = v.flip });
            try edges.append(arena, variantEdges(tile, v.rot, v.flip));
            try weights.append(arena, @max(tile.weight, 0));
        }
    }
    const t_count: u32 = @intCast(variants.items.len);
    const cells = @as(usize, opts.width) * opts.height;

    const ctx: Context = .{ .edges = edges.items };
    var prop: Solver.Propagator = try .build(arena, t_count, &ctx, Context.agrees);

    const cell_weights = try cellWeights(arena, tiles, variants.items, opts);
    const allowed = try constraintMask(arena, tiles, variants.items, edges.items, opts);

    var solver: Solver = try .init(gpa, .{
        .width = opts.width,
        .height = opts.height,
        .periodic = opts.wrap,
        .propagator = &prop,
        .weights = weights.items,
        .cell_weights = cell_weights,
        .allowed = allowed,
    });
    defer solver.deinit(gpa);
    const used = try solver.run(gpa, opts.seed, opts.attempts);

    const out = try gpa.alloc(Variant, cells);
    for (out, solver.observed) |*o, t| o.* = variants.items[t];
    return .{ .width = opts.width, .height = opts.height, .cells = out, .attempts = used };
}

fn cellWeights(arena: Allocator, tiles: []const Tile, variants: []const Variant, opts: Options) !?[]f64 {
    for (tiles) |t| {
        if (t.weight_map != null) break;
    } else return null;
    const t_count = variants.len;
    const out = try arena.alloc(f64, @as(usize, opts.width) * opts.height * t_count);
    const w: f64 = @floatFromInt(opts.width);
    const h: f64 = @floatFromInt(opts.height);
    for (0..opts.height) |y| for (0..opts.width) |x| {
        const row = out[(y * opts.width + x) * t_count ..][0..t_count];
        for (row, variants) |*o, v| {
            const tile = &tiles[v.tile];
            const base = @max(tile.weight, 0);
            const m = tile.weight_map orelse {
                o.* = base;
                continue;
            };
            const u = (@as(f64, @floatFromInt(x)) + 0.5) / w * @as(f64, @floatFromInt(m.w));
            const vv = (@as(f64, @floatFromInt(y)) + 0.5) / h * @as(f64, @floatFromInt(m.h));
            o.* = base * @max(m.sample(u, vv), 0);
        }
    };
    return out;
}

fn constraintMask(
    arena: Allocator,
    tiles: []const Tile,
    variants: []const Variant,
    edges: []const [4]Edge,
    opts: Options,
) !?[]bool {
    if (opts.constraints.len == 0) return null;
    const t_count = variants.len;
    const mask = try arena.alloc(bool, @as(usize, opts.width) * opts.height * t_count);
    @memset(mask, true);
    for (opts.constraints) |c| {
        if (c.x >= opts.width or c.y >= opts.height or c.tile >= tiles.len) return error.BadConstraint;
        const want = variantEdges(&tiles[c.tile], c.rot orelse 0, c.flip orelse false);
        const row = mask[(@as(usize, c.y) * opts.width + c.x) * t_count ..][0..t_count];
        var any = false;
        for (row, variants, edges) |*m, v, e| {
            const ok = v.tile == c.tile and (c.rot == null or sameEdges(e, want));
            m.* = m.* and ok;
            any = any or m.*;
        }
        if (!any) return error.BadConstraint;
    }
    return mask;
}

fn sameEdges(a: [4]Edge, b: [4]Edge) bool {
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

// Pipe tiles with atomic sockets: "p" carries a pipe, "o" is blank.
const pipe: Socket = .{ .label = "p", .atomic = true };
const blank: Socket = .{ .label = "o", .atomic = true };
const pipe_tiles = [_]Tile{
    .{ .edges = .{ blank, blank, blank, blank }, .weight = 1 },
    .{ .edges = .{ pipe, blank, pipe, blank }, .symmetry = .i, .weight = 2 },
    .{ .edges = .{ pipe, pipe, blank, blank }, .symmetry = .l, .weight = 2 },
    .{ .edges = .{ pipe, pipe, pipe, blank }, .symmetry = .t },
    .{ .edges = .{ pipe, pipe, pipe, pipe } },
};

fn expectSocketsHold(tiles: []const Tile, r: *const Result, wrap: bool) !void {
    for (0..r.height) |y| for (0..r.width) |x| {
        const v = r.at(@intCast(x), @intCast(y));
        const e = variantEdges(&tiles[v.tile], v.rot, v.flip);
        if (wrap or x + 1 < r.width) {
            const east = r.at(@intCast((x + 1) % r.width), @intCast(y));
            try std.testing.expect(fits(e[1], variantEdges(&tiles[east.tile], east.rot, east.flip)[3]));
        }
        if (wrap or y + 1 < r.height) {
            const south = r.at(@intCast(x), @intCast((y + 1) % r.height));
            try std.testing.expect(fits(e[2], variantEdges(&tiles[south.tile], south.rot, south.flip)[0]));
        }
    };
}

test "tiled: reversed labels fit, palindromes fit themselves" {
    const ab: Edge = .{ .socket = .{ .label = "ab" } };
    const ba: Edge = .{ .socket = .{ .label = "ba" } };
    const aba: Edge = .{ .socket = .{ .label = "aba" } };
    try std.testing.expect(fits(ab, ba));
    try std.testing.expect(!fits(ab, ab));
    try std.testing.expect(fits(aba, aba));
    try std.testing.expect(fits(ab, .{ .socket = .{ .label = "ab" }, .reversed = true }));
    try std.testing.expect(!fits(.{ .socket = .{ .label = "12", .atomic = true } }, .{ .socket = .{ .label = "21", .atomic = true } }));
}

test "tiled: rotation and flip permute edges" {
    const s = struct {
        fn sock(l: []const u8) Socket {
            return .{ .label = l };
        }
    }.sock;
    const tile: Tile = .{ .edges = .{ s("n"), s("e"), s("s"), s("w") }, .symmetry = .f };
    const r1 = variantEdges(&tile, 1, false);
    try std.testing.expectEqualStrings("w", r1[0].socket.label);
    try std.testing.expectEqualStrings("n", r1[1].socket.label);
    const f0 = variantEdges(&tile, 0, true);
    try std.testing.expectEqualStrings("w", f0[1].socket.label);
    try std.testing.expect(f0[1].reversed);
}

test "tiled: every adjacent pair satisfies the socket rule" {
    const gpa = std.testing.allocator;
    inline for (.{ false, true }) |wrap| {
        var r = try solve(gpa, &pipe_tiles, .{ .width = 24, .height = 17, .wrap = wrap, .seed = 3 });
        defer r.deinit(gpa);
        try expectSocketsHold(&pipe_tiles, &r, wrap);
    }
}

test "tiled: directional sockets chain in one direction" {
    const gpa = std.testing.allocator;
    const ab: Socket = .{ .label = "ab" };
    const ba: Socket = .{ .label = "ba" };
    const x: Socket = .{ .label = "x" };
    // Arrow tiles: east edge "ab" needs a west edge "ba".
    const tiles = [_]Tile{
        .{ .edges = .{ x, ab, x, ba }, .symmetry = .f },
        .{ .edges = .{ x, x, x, x } },
    };
    var r = try solve(gpa, &tiles, .{ .width = 16, .height = 16, .wrap = true, .seed = 11 });
    defer r.deinit(gpa);
    try expectSocketsHold(&tiles, &r, true);
}

test "tiled: pre-collapsed cells are honored" {
    const gpa = std.testing.allocator;
    const constraints = [_]Constraint{
        .{ .x = 0, .y = 0, .tile = 4 },
        .{ .x = 5, .y = 3, .tile = 2, .rot = 3 },
        .{ .x = 9, .y = 9, .tile = 1, .rot = 3 }, // same edges as rot 1
    };
    var r = try solve(gpa, &pipe_tiles, .{ .width = 10, .height = 10, .wrap = true, .seed = 5, .constraints = &constraints });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4), r.at(0, 0).tile);
    try std.testing.expectEqual(Variant{ .tile = 2, .rot = 3 }, r.at(5, 3));
    try std.testing.expectEqual(Variant{ .tile = 1, .rot = 1 }, r.at(9, 9));
    try expectSocketsHold(&pipe_tiles, &r, true);
}

test "tiled: same seed repeats, different seeds differ" {
    const gpa = std.testing.allocator;
    var a = try solve(gpa, &pipe_tiles, .{ .width = 20, .height = 20, .seed = 42 });
    defer a.deinit(gpa);
    var b = try solve(gpa, &pipe_tiles, .{ .width = 20, .height = 20, .seed = 42 });
    defer b.deinit(gpa);
    var c = try solve(gpa, &pipe_tiles, .{ .width = 20, .height = 20, .seed = 43 });
    defer c.deinit(gpa);
    try std.testing.expectEqualSlices(Variant, a.cells, b.cells);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(a.cells), std.mem.sliceAsBytes(c.cells)));
}

test "tiled: unsatisfiable tile set reports a contradiction" {
    const gpa = std.testing.allocator;
    const a: Socket = .{ .label = "a", .atomic = true };
    const b: Socket = .{ .label = "b", .atomic = true };
    // North is "a" and south is "b", so nothing can stack vertically.
    const tiles = [_]Tile{.{ .edges = .{ a, a, b, a } }};
    try std.testing.expectError(error.Contradiction, solve(gpa, &tiles, .{ .width = 4, .height = 4, .attempts = 3 }));
}

test "tiled: a zero weight map region excludes the tile" {
    const gpa = std.testing.allocator;
    var map: Field = try .init(gpa, 1, 2, 1);
    defer map.deinit(gpa);
    map.set(0, 0, 0);
    var tiles = pipe_tiles;
    tiles[4].weight_map = &map;
    var r = try solve(gpa, &tiles, .{ .width = 12, .height = 12, .seed = 9 });
    defer r.deinit(gpa);
    // Bilinear sampling is exactly zero only in the top quarter.
    for (0..3) |y| for (0..12) |x| {
        try std.testing.expect(r.at(@intCast(x), @intCast(y)).tile != 4);
    };
    try expectSocketsHold(&tiles, &r, false);
}
