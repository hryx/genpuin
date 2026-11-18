//! Helpers shared by every binding file: reading Lua tables into Zig
//! values, pushing results back, and the Field userdata.
//!
//! Lua errors longjmp past Zig defers. Bindings read and validate their
//! arguments into an arena first, then do the work, so a raised error
//! only ever leaks that arena while the script is already failing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

pub const Lua = zlua.Lua;
pub const Field = genpuin.Field;
const scene = genpuin.scene;
pub const Vec2 = scene.Vec2;

pub const field_meta = "genpuin.Field";

/// Per-state host data, kept in the registry as light userdata.
pub const Host = struct {
    gpa: Allocator,
    io: std.Io,
    seeds: Seeds = .{},
    /// Threads a simulation may use, the calling one included. The CLI
    /// shares its -j cap between the renders running at once.
    sim_workers: u32 = 1,
};

/// --seed and --noise-seed. Each one set replaces the argument of every
/// gen.seed or gen.noiseSeed call and is the stream's starting seed.
pub const Seeds = struct {
    seed: ?u32 = null,
    noise_seed: ?u32 = null,
};

const host_key = "genpuin.host";

pub fn setHost(lua: *Lua, h: *Host) void {
    lua.pushLightUserdata(h);
    lua.setField(zlua.registry_index, host_key);
}

pub fn getHost(lua: *Lua) *Host {
    _ = lua.getField(zlua.registry_index, host_key);
    defer lua.pop(1);
    const p = lua.toPointer(-1) orelse lua.raiseErrorStr("genpuin host missing", .{});
    return @ptrCast(@alignCast(@constCast(p)));
}

pub fn newUserdata(lua: *Lua, comptime T: type) *T {
    return switch (zlua.lang) {
        .lua54, .lua55 => lua.newUserdata(T, 0),
        else => lua.newUserdata(T),
    };
}

/// luaL_setfuncs, which 5.1 and LuaJIT lack.
pub fn setFuncs(lua: *Lua, funcs: []const zlua.FnReg) void {
    for (funcs) |f| {
        lua.pushFunction(f.func.?);
        lua.setField(-2, f.name);
    }
}

pub fn setMetatable(lua: *Lua, name: [:0]const u8) void {
    _ = lua.getField(zlua.registry_index, name);
    lua.setMetatable(-2);
}

/// luaL_testudata: the userdata at `index` if its metatable is `name`.
pub fn testUserdata(lua: *Lua, comptime T: type, index: i32, name: [:0]const u8) ?*T {
    const p = lua.toUserdata(T, index) catch return null;
    lua.getMetatable(index) catch return null;
    _ = lua.getField(zlua.registry_index, name);
    const same = lua.equalRaw(-1, -2);
    lua.pop(2);
    return if (same) p else null;
}

pub fn loadBuffer(lua: *Lua, buf: []const u8, name: [:0]const u8) !void {
    switch (zlua.lang) {
        .lua51, .luajit => try lua.loadBuffer(buf, name),
        else => try lua.loadBuffer(buf, name, .text),
    }
}

pub fn loadFile(lua: *Lua, path: [:0]const u8) !void {
    switch (zlua.lang) {
        .lua51, .luajit => try lua.loadFile(path),
        else => try lua.loadFile(path, .text),
    }
}

pub fn len(lua: *Lua, index: i32) usize {
    return lua.lenRaw(index);
}

/// Push t[i] (1-based) and return its type.
pub fn rawGet(lua: *Lua, index: i32, i: usize) zlua.LuaType {
    return lua.getIndexRaw(index, @intCast(i));
}

pub fn rawSet(lua: *Lua, index: i32, i: usize) void {
    lua.setIndexRaw(index, @intCast(i));
}

pub fn numberAt(lua: *Lua, index: i32, i: usize) ?f64 {
    defer lua.pop(1);
    if (rawGet(lua, index, i) != .number) return null;
    return lua.toNumber(-1) catch null;
}

// Option fields on a table at `index`. A nil or missing table reads as
// the default.

pub fn optNumber(lua: *Lua, index: i32, key: [:0]const u8, default: f64) f64 {
    if (!lua.isTable(index)) return default;
    defer lua.pop(1);
    return switch (lua.getField(index, key)) {
        .number => lua.toNumber(-1) catch default,
        .nil, .none => default,
        else => lua.raiseErrorStr("option '%s' must be a number", .{key.ptr}),
    };
}

pub fn optInt(lua: *Lua, index: i32, key: [:0]const u8, default: i64) i64 {
    return @intFromFloat(@floor(optNumber(lua, index, key, @floatFromInt(default))));
}

pub fn optBool(lua: *Lua, index: i32, key: [:0]const u8, default: bool) bool {
    if (!lua.isTable(index)) return default;
    defer lua.pop(1);
    return switch (lua.getField(index, key)) {
        .nil, .none => default,
        else => lua.toBoolean(-1),
    };
}

/// The string is copied into `arena` since the Lua value may be collected.
pub fn optString(lua: *Lua, arena: Allocator, index: i32, key: [:0]const u8, default: ?[]const u8) !?[]const u8 {
    if (!lua.isTable(index)) return default;
    defer lua.pop(1);
    return switch (lua.getField(index, key)) {
        .string => try arena.dupe(u8, lua.toString(-1) catch unreachable), // type checked on the line above
        .nil, .none => default,
        else => lua.raiseErrorStr("option '%s' must be a string", .{key.ptr}),
    };
}

/// Read an enum option by tag name.
pub fn optEnum(lua: *Lua, comptime E: type, index: i32, key: [:0]const u8, default: E) E {
    if (!lua.isTable(index)) return default;
    defer lua.pop(1);
    switch (lua.getField(index, key)) {
        .nil, .none => return default,
        .string => {
            const s = lua.toString(-1) catch unreachable; // type checked by the switch
            return std.meta.stringToEnum(E, s) orelse
                lua.raiseErrorStr("option '%s': unknown value '%s'", .{ key.ptr, s.ptr });
        },
        else => lua.raiseErrorStr("option '%s' must be a string", .{key.ptr}),
    }
}

/// Seed for a Zig-side algorithm. Lua wrappers fill `seed` from
/// gen.randInt so the result follows gen.seed and --seed. An explicit
/// seed is used as written.
pub fn optSeed(lua: *Lua, index: i32) u64 {
    const s = optNumber(lua, index, "seed", 1);
    return @bitCast(@as(i64, @intFromFloat(@floor(s))));
}

pub fn readVec2(lua: *Lua, index: i32) ?Vec2 {
    if (!lua.isTable(index)) return null;
    const x = numberAt(lua, index, 1) orelse return null;
    const y = numberAt(lua, index, 2) orelse return null;
    return .{ x, y };
}

/// Read a list of {x, y} points.
pub fn readPoints(lua: *Lua, arena: Allocator, index_in: i32) ![]Vec2 {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("expected a list of points", .{});
    const n = len(lua, index);
    const pts = try arena.alloc(Vec2, n);
    for (0..n) |i| {
        _ = rawGet(lua, index, i + 1);
        pts[i] = readVec2(lua, -1) orelse lua.raiseErrorStr("point %d is not {x, y}", .{@as(c_int, @intCast(i + 1))});
        lua.pop(1);
    }
    return pts;
}

/// Read a list of point lists.
pub fn readContours(lua: *Lua, arena: Allocator, index_in: i32) ![][]Vec2 {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("expected a list of contours", .{});
    const n = len(lua, index);
    const out = try arena.alloc([]Vec2, n);
    for (0..n) |i| {
        _ = rawGet(lua, index, i + 1);
        out[i] = try readPoints(lua, arena, -1);
        lua.pop(1);
    }
    return out;
}

/// Push a shallow copy of the table at `index`.
pub fn pushCopy(lua: *Lua, index_in: i32) void {
    const index = lua.absIndex(index_in);
    lua.createTable(0, 4);
    lua.pushNil();
    while (lua.next(index)) {
        lua.pushValue(-2);
        lua.insert(-2);
        lua.setTableRaw(-4);
    }
}

pub fn pushVec2(lua: *Lua, p: Vec2) void {
    lua.createTable(2, 0);
    lua.pushNumber(p[0]);
    rawSet(lua, -2, 1);
    lua.pushNumber(p[1]);
    rawSet(lua, -2, 2);
}

pub fn pushPoints(lua: *Lua, pts: []const Vec2) void {
    lua.createTable(@intCast(pts.len), 0);
    for (pts, 1..) |p, i| {
        pushVec2(lua, p);
        rawSet(lua, -2, i);
    }
}

pub fn pushContours(lua: *Lua, contours: []const []const Vec2) void {
    lua.createTable(@intCast(contours.len), 0);
    for (contours, 1..) |c, i| {
        pushPoints(lua, c);
        rawSet(lua, -2, i);
    }
}

/// Read a {r, g, b, a?} color table with channels 0..1.
pub fn readColor(lua: *Lua, index: i32) ?scene.Rgba {
    if (!lua.isTable(index)) return null;
    const r = numberAt(lua, index, 1) orelse return null;
    const g = numberAt(lua, index, 2) orelse return null;
    const b = numberAt(lua, index, 3) orelse return null;
    const a = numberAt(lua, index, 4) orelse 1;
    return .{ @floatCast(r), @floatCast(g), @floatCast(b), @floatCast(a) };
}

/// A palette is either {{offset, color}, ...} or a plain list of colors
/// spread evenly over 0..1.
pub fn readStops(lua: *Lua, arena: Allocator, index_in: i32) ![]scene.Stop {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("expected a palette", .{});
    const n = len(lua, index);
    if (n == 0) lua.raiseErrorStr("palette is empty", .{});
    const stops = try arena.alloc(scene.Stop, n);
    for (0..n) |i| {
        _ = rawGet(lua, index, i + 1);
        defer lua.pop(1);
        if (readColor(lua, -1)) |c| {
            const t: f32 = if (n == 1) 0 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
            stops[i] = .{ .offset = t, .color = c };
            continue;
        }
        const off = numberAt(lua, -1, 1) orelse lua.raiseErrorStr("bad palette stop %d", .{@as(c_int, @intCast(i + 1))});
        _ = rawGet(lua, -1, 2);
        const c = readColor(lua, -1) orelse lua.raiseErrorStr("bad palette stop %d", .{@as(c_int, @intCast(i + 1))});
        lua.pop(1);
        stops[i] = .{ .offset = @floatCast(off), .color = c };
    }
    return stops;
}

// Field userdata. The Field's data lives in the Lua state's allocator
// and is freed by __gc.

const FieldBox = struct { field: Field };

pub fn pushField(lua: *Lua, f: Field) void {
    const box = newUserdata(lua, FieldBox);
    box.* = .{ .field = f };
    setMetatable(lua, field_meta);
}

pub fn checkField(lua: *Lua, arg: i32) *Field {
    return &lua.checkUserdata(FieldBox, arg, field_meta).field;
}

pub fn toField(lua: *Lua, index: i32) ?*Field {
    const box = testUserdata(lua, FieldBox, index, field_meta) orelse return null;
    return &box.field;
}

pub fn fieldGc(lua: *Lua) i32 {
    const box = lua.checkUserdata(FieldBox, 1, field_meta);
    if (box.field.data.len > 0) box.field.deinit(lua.allocator());
    box.field.data = &.{};
    return 0;
}

pub fn checkU32(lua: *Lua, arg: i32) u32 {
    const v = lua.checkNumber(arg);
    if (!(v >= 1 and v <= 1 << 20)) lua.argError(arg, "expected a size from 1 to 2^20");
    return @intFromFloat(@floor(v));
}
