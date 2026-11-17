//! core.wfc: wave function collapse from Lua. Grids cross as nested
//! tables indexed [y][x] from 1.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");
const tiled_mod = genpuin.wfc.tiled;
const overlap_mod = genpuin.wfc.overlap;

const util = @import("util.zig");
const Lua = util.Lua;

pub const functions = [_]zlua.FnReg{
    .{ .name = "tiled", .func = zlua.wrap(tiled) },
    .{ .name = "overlap", .func = zlua.wrap(overlap) },
};

fn checkSize(lua: *Lua, key: [:0]const u8) u32 {
    const v = util.optInt(lua, 1, key, 0);
    if (v < 1 or v > 1 << 14) lua.raiseErrorStr("wfc: option '%s' must be a size from 1 to 16384", .{key.ptr});
    return @intCast(v);
}

fn attempts(lua: *Lua) u32 {
    const retries = util.optInt(lua, 1, "retries", 10);
    if (retries < 0 or retries > 1 << 20) lua.raiseErrorStr("wfc: retries must be 0 or more", .{});
    return @intCast(retries + 1);
}

fn raiseContradiction(lua: *Lua, tries: u32) noreturn {
    lua.raiseErrorStr("wfc: no solution, every attempt hit a contradiction (%d retries)", .{@as(c_int, @intCast(tries - 1))});
}

/// tiled(opts) -> grid of {tile, rot, flip}. See prelude/wfc.lua.
fn tiled(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_state.allocator();

    const w = checkSize(lua, "w");
    const h = checkSize(lua, "h");
    const tries = attempts(lua);
    const tiles = try readTiles(lua, arena);
    try readWeightMap(lua, tiles);
    const constraints = try readConstraints(lua, arena, tiles, w, h);

    var result = tiled_mod.solve(gpa, tiles.list, .{
        .width = w,
        .height = h,
        .wrap = util.optBool(lua, 1, "wrap", false),
        .seed = util.optSeed(lua, 1),
        .attempts = tries,
        .constraints = constraints,
    }) catch |err| {
        arena_state.deinit();
        switch (err) {
            error.Contradiction => raiseContradiction(lua, tries),
            error.TooManyPatterns => lua.raiseErrorStr("wfc: more than 65535 patterns or tile variants", .{}),
            error.BadConstraint => lua.raiseErrorStr("wfc: a constraint names no variant of its tile", .{}),
            error.NoTiles => lua.raiseErrorStr("wfc: opts.tiles is empty", .{}),
            error.OutOfMemory => return err,
        }
    };
    defer result.deinit(gpa);
    defer arena_state.deinit();

    lua.createTable(@intCast(h), 0);
    for (0..h) |y| {
        lua.createTable(@intCast(w), 0);
        for (0..w) |x| {
            const v = result.at(@intCast(x), @intCast(y));
            lua.createTable(0, 3);
            if (tiles.names[v.tile]) |name| {
                _ = lua.pushString(name);
            } else {
                lua.pushInteger(@intCast(v.tile + 1));
            }
            lua.setField(-2, "tile");
            lua.pushInteger(v.rot);
            lua.setField(-2, "rot");
            lua.pushBoolean(v.flip);
            lua.setField(-2, "flip");
            util.rawSet(lua, -2, x + 1);
        }
        util.rawSet(lua, -2, y + 1);
    }
    lua.pushInteger(@intCast(result.attempts));
    return 2;
}

const Tiles = struct {
    list: []tiled_mod.Tile,
    names: []?[:0]const u8,
};

fn readTiles(lua: *Lua, arena: Allocator) !Tiles {
    if (lua.getField(1, "tiles") != .table) lua.raiseErrorStr("wfc: opts.tiles must be a list of tiles", .{});
    defer lua.pop(1);
    const count = util.len(lua, -1);
    const list = try arena.alloc(tiled_mod.Tile, count);
    const names = try arena.alloc(?[:0]const u8, count);
    for (list, names, 1..) |*tile, *name, i| {
        if (util.rawGet(lua, -1, i) != .table) lua.raiseErrorStr("wfc: tile %d is not a table", .{@as(c_int, @intCast(i))});
        defer lua.pop(1);
        const t = lua.absIndex(-1);
        name.* = switch (lua.getField(t, "name")) {
            .string => try arena.dupeSentinel(u8, lua.toString(-1) catch unreachable, 0), // type checked by the switch
            else => null,
        };
        lua.pop(1);
        tile.* = .{
            .edges = try readEdges(lua, arena, t, i),
            .weight = util.optNumber(lua, t, "weight", 1),
            .symmetry = readSymmetry(lua, t),
        };
    }
    return .{ .list = list, .names = names };
}

fn readEdges(lua: *Lua, arena: Allocator, t: i32, tile_number: usize) ![4]tiled_mod.Socket {
    if (lua.getField(t, "edges") != .table) {
        lua.raiseErrorStr("wfc: tile %d needs edges = {n, e, s, w}", .{@as(c_int, @intCast(tile_number))});
    }
    defer lua.pop(1);
    var edges: [4]tiled_mod.Socket = undefined;
    for (&edges, 1..) |*e, k| {
        defer lua.pop(1);
        e.* = switch (util.rawGet(lua, -1, k)) {
            .string => .{ .label = try arena.dupe(u8, lua.toString(-1) catch unreachable) }, // type checked by the switch
            .number => .{ .label = try std.fmt.allocPrint(arena, "{d}", .{lua.toNumber(-1) catch unreachable}), .atomic = true },
            else => lua.raiseErrorStr("wfc: tile %d edge %d must be a string or number", .{
                @as(c_int, @intCast(tile_number)), @as(c_int, @intCast(k)),
            }),
        };
    }
    return edges;
}

fn readSymmetry(lua: *Lua, t: i32) tiled_mod.Symmetry {
    if (lua.getField(t, "symmetry") != .string) {
        lua.pop(1);
        return .x;
    }
    defer lua.pop(1);
    const s = lua.toString(-1) catch unreachable; // type checked above
    const table = .{
        .{ "X", .x }, .{ "I", .i }, .{ "L", .l }, .{ "T", .t }, .{ "/", .slash }, .{ "\\", .slash }, .{ "F", .f },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    lua.raiseErrorStr("wfc: unknown symmetry '%s', use X I L T / F", .{s.ptr});
}

/// opts.weightMap = {[name or index] = Field}. The Fields stay alive on
/// the Lua stack through opts for the whole call.
fn readWeightMap(lua: *Lua, tiles: Tiles) !void {
    if (lua.getField(1, "weightMap") != .table) {
        lua.pop(1);
        return;
    }
    defer lua.pop(1);
    for (tiles.list, tiles.names, 1..) |*tile, name, i| {
        _ = util.rawGet(lua, -1, i);
        if (lua.isNil(-1)) {
            lua.pop(1);
            if (name) |n| _ = lua.getField(-1, n) else lua.pushNil();
        }
        defer lua.pop(1);
        if (lua.isNil(-1)) continue;
        tile.weight_map = util.toField(lua, -1) orelse lua.raiseErrorStr("wfc: weightMap values must be Fields", .{});
    }
}

fn tileIndex(lua: *Lua, tiles: Tiles, index: i32) u32 {
    switch (lua.typeOf(index)) {
        .number => {
            const v = lua.toNumber(index) catch unreachable; // type checked by the switch
            if (v >= 1 and v <= @as(f64, @floatFromInt(tiles.list.len))) return @intFromFloat(v - 1);
        },
        .string => {
            const s = lua.toString(index) catch unreachable; // type checked by the switch
            for (tiles.names, 0..) |name, i| {
                if (name != null and std.mem.eql(u8, name.?, s)) return @intCast(i);
            }
            lua.raiseErrorStr("wfc: no tile named '%s'", .{s.ptr});
        },
        else => {},
    }
    lua.raiseErrorStr("wfc: constraint tile must be a tile name or index", .{});
}

fn readConstraints(lua: *Lua, arena: Allocator, tiles: Tiles, w: u32, h: u32) ![]tiled_mod.Constraint {
    if (lua.getField(1, "constraints") != .table) {
        lua.pop(1);
        return &.{};
    }
    defer lua.pop(1);
    const count = util.len(lua, -1);
    const out = try arena.alloc(tiled_mod.Constraint, count);
    for (out, 1..) |*c, i| {
        if (util.rawGet(lua, -1, i) != .table) lua.raiseErrorStr("wfc: constraint %d is not a table", .{@as(c_int, @intCast(i))});
        defer lua.pop(1);
        const t = lua.absIndex(-1);
        const x = util.optInt(lua, t, "x", 0);
        const y = util.optInt(lua, t, "y", 0);
        if (x < 1 or y < 1 or x > w or y > h) lua.raiseErrorStr("wfc: constraint %d is outside the grid", .{@as(c_int, @intCast(i))});
        _ = lua.getField(t, "tile");
        const tile = tileIndex(lua, tiles, -1);
        lua.pop(1);
        const has_rot = lua.getField(t, "rot") != .nil;
        lua.pop(1);
        const has_flip = lua.getField(t, "flip") != .nil;
        lua.pop(1);
        c.* = .{
            .x = @intCast(x - 1),
            .y = @intCast(y - 1),
            .tile = tile,
            .rot = if (has_rot) @intCast(@mod(util.optInt(lua, t, "rot", 0), 4)) else null,
            .flip = if (has_flip) util.optBool(lua, t, "flip", false) else null,
        };
    }
    return out;
}

/// overlap(opts) -> grid of sample values. See prelude/wfc.lua.
fn overlap(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_state.allocator();

    const w = checkSize(lua, "w");
    const h = checkSize(lua, "h");
    const tries = attempts(lua);
    const n = util.optInt(lua, 1, "n", 3);
    if (n < 2 or n > 8) lua.raiseErrorStr("wfc: n must be 2 to 8", .{});
    const symmetry = util.optInt(lua, 1, "symmetry", 8);
    if (symmetry < 1 or symmetry > 8) lua.raiseErrorStr("wfc: symmetry must be 1 to 8", .{});
    const sample = try readSample(lua, arena);

    var result = overlap_mod.solve(gpa, sample, .{
        .n = @intCast(n),
        .width = w,
        .height = h,
        .periodic_input = util.optBool(lua, 1, "periodicInput", true),
        .periodic_output = util.optBool(lua, 1, "periodicOutput", true),
        .symmetry = @intCast(symmetry),
        .ground = util.optBool(lua, 1, "ground", false),
        .seed = util.optSeed(lua, 1),
        .attempts = tries,
    }) catch |err| {
        arena_state.deinit();
        switch (err) {
            error.Contradiction => raiseContradiction(lua, tries),
            error.TooManyPatterns => lua.raiseErrorStr("wfc: more than 65535 patterns or tile variants", .{}),
            error.BadSample => lua.raiseErrorStr("wfc: sample is smaller than n, or output is smaller than n", .{}),
            error.TooManyColours => lua.raiseErrorStr("wfc: sample has more than 256 distinct values", .{}),
            error.OutOfMemory => return err,
        }
    };
    arena_state.deinit();
    defer result.deinit(gpa);

    lua.createTable(@intCast(h), 0);
    for (0..h) |y| {
        lua.createTable(@intCast(w), 0);
        for (0..w) |x| {
            lua.pushInteger(result.values[y * w + x]);
            util.rawSet(lua, -2, x + 1);
        }
        util.rawSet(lua, -2, y + 1);
    }
    lua.pushInteger(@intCast(result.attempts));
    return 2;
}

fn readSample(lua: *Lua, arena: Allocator) !overlap_mod.Sample {
    if (lua.getField(1, "sample") != .table) lua.raiseErrorStr("wfc: opts.sample must be a grid sample[y][x]", .{});
    defer lua.pop(1);
    const sh = util.len(lua, -1);
    if (sh == 0) lua.raiseErrorStr("wfc: sample is empty", .{});
    var sw: usize = 0;
    var values: std.ArrayList(i32) = .empty;
    for (1..sh + 1) |y| {
        if (util.rawGet(lua, -1, y) != .table) lua.raiseErrorStr("wfc: sample row %d is not a table", .{@as(c_int, @intCast(y))});
        defer lua.pop(1);
        const row_len = util.len(lua, -1);
        if (y == 1) sw = row_len;
        if (row_len != sw or sw == 0) lua.raiseErrorStr("wfc: sample rows must all have the same length", .{});
        for (1..sw + 1) |x| {
            const v = util.numberAt(lua, -1, x) orelse lua.raiseErrorStr("wfc: sample[%d][%d] is not a number", .{
                @as(c_int, @intCast(y)), @as(c_int, @intCast(x)),
            });
            try values.append(arena, @intFromFloat(@floor(v)));
        }
    }
    return .{ .width = @intCast(sw), .height = @intCast(sh), .values = values.items };
}
