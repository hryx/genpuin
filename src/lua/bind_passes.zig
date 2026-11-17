//! core.post: read the options of a gen.post.name(opts) call into a Pass.
//! The options are documented on gen.post in src/lua/prelude/raster.lua.
//! Distances are scene units, so a script looks the same at any -s.
//! Random passes read opts.seed.
//!
//! gen.post.name runs core.post.check when it is called, so a bad pass
//! fails at the script's line. parse runs again when the canvas is rendered.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const core = @import("core.zig");
const util = @import("util.zig");
const Lua = util.Lua;
const Field = util.Field;
const passes = genpuin.passes;
const Pass = passes.Pass;
const Rgb = genpuin.Raster.Rgb;

pub const functions = [_]zlua.FnReg{
    .{ .name = "check", .func = zlua.wrap(check) },
};

const Name = enum {
    invert,
    pixel_sort,
    channel_shift,
    displace,
    tear,
    block_repeat,
    dither,
    posterize,
    blur,
    bloom,
    grain,
    levels,
    scanlines,
};

const names: std.StaticStringMap(Name) = .initComptime(.{
    .{ "invert", .invert },
    .{ "pixelSort", .pixel_sort },
    .{ "channelShift", .channel_shift },
    .{ "displace", .displace },
    .{ "tear", .tear },
    .{ "blockRepeat", .block_repeat },
    .{ "dither", .dither },
    .{ "posterize", .posterize },
    .{ "blur", .blur },
    .{ "bloom", .bloom },
    .{ "grain", .grain },
    .{ "levels", .levels },
    .{ "scanlines", .scanlines },
});

/// The pass names a script can use, as gen.post keys.
pub fn passNames() []const []const u8 {
    return names.keys();
}

/// Build a Pass from its name and the options table at `opts`. Every pass
/// takes region = {x, y, w, h} in scene units.
pub fn parse(lua: *Lua, arena: Allocator, name: []const u8, opts: i32) !Pass {
    const tag = names.get(name) orelse {
        var near: core.Nearest = .init(name);
        for (names.keys()) |k| near.consider(k);
        const name_z = try arena.dupeSentinel(u8, name, 0);
        if (near.best) |b| {
            lua.raiseErrorStr("unknown post pass '%s' (did you mean '%s'?)", .{ name_z.ptr, (try arena.dupeSentinel(u8, b, 0)).ptr });
        }
        lua.raiseErrorStr("unknown post pass '%s'", .{name_z.ptr});
    };
    const pass: Pass = switch (tag) {
        .invert => .invert,
        .pixel_sort => .{ .pixel_sort = try pixelSort(lua, arena, opts) },
        .channel_shift => .{ .channel_shift = channelShift(lua, opts) },
        .displace => .{ .displace = displace(lua, opts) },
        .tear => .{ .tear = tear(lua, opts) },
        .block_repeat => .{ .block_repeat = try blockRepeat(lua, arena, opts) },
        .dither => .{ .dither = try dither(lua, arena, opts, .bayer) },
        .posterize => .{ .posterize = try dither(lua, arena, opts, .none) },
        .blur => .{ .blur = blur(lua, opts) },
        .bloom => .{ .bloom = bloom(lua, opts) },
        .grain => .{ .grain = grain(lua, opts) },
        .levels => .{ .levels = levels(lua, opts) },
        .scanlines => .{ .scanlines = try scanlines(lua, arena, opts) },
    };
    const rect = readRegion(lua, opts) orelse return pass;
    const inner = try arena.create(Pass);
    inner.* = pass;
    return .{ .region = .{ .rect = rect, .inner = inner } };
}

/// check(name, opts) -> true, or false and the message parse would
/// raise. Also rejects option keys the pass does not read. The prelude
/// raises the message at the caller's line.
fn check(lua: *Lua) i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    lua.pushFunction(zlua.wrap(checkProtected));
    lua.pushLightUserdata(&arena);
    lua.pushValue(1);
    lua.pushValue(2);
    lua.protectedCall(.{ .args = 3, .results = 0 }) catch {
        lua.pushBoolean(false);
        lua.insert(-2);
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

/// Runs under check's protected call, so raised errors cannot leak the
/// arena check owns.
fn checkProtected(lua: *Lua) !i32 {
    const arena = (lua.toUserdata(Allocator, 1) catch unreachable).*; // pushed by check
    if (lua.typeOf(2) != .string) lua.raiseErrorStr("post pass name must be a string", .{});
    const name = lua.toString(2) catch unreachable; // type checked on the line above
    _ = try parse(lua, arena, name, 3);
    if (!lua.isTable(3)) return 0;
    const keys = optionKeys(names.get(name).?); // parse raised for unknown names
    lua.pushNil();
    while (lua.next(3)) {
        lua.pop(1);
        if (lua.typeOf(-1) != .string) lua.raiseErrorStr("post pass '%s': option keys must be names", .{name.ptr});
        const key = lua.toString(-1) catch unreachable; // type checked on the line above
        if (isOptionKey(keys, key)) continue;
        var near: core.Nearest = .init(key);
        for (keys) |k| near.consider(k);
        for (common_keys) |k| near.consider(k);
        if (near.best) |b| {
            lua.raiseErrorStr("post pass '%s' has no option '%s' (did you mean '%s'?)", .{ name.ptr, key.ptr, (try arena.dupeSentinel(u8, b, 0)).ptr });
        }
        lua.raiseErrorStr("post pass '%s' has no option '%s'", .{ name.ptr, key.ptr });
    }
    return 0;
}

/// Keys every pass accepts. The prelude fills seed for all of them.
const common_keys = [_][]const u8{ "region", "seed" };

fn isOptionKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    for (common_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// The keys each pass's parse function reads, besides common_keys. A test
/// below checks the lists against what parse reads.
fn optionKeys(tag: Name) []const []const u8 {
    return switch (tag) {
        .invert => &.{},
        .pixel_sort => &.{ "direction", "angle", "key", "sortBy", "lo", "hi", "mask", "maskThreshold", "reverse", "minLength", "maxLength", "jitter", "chance", "passes", "passesField" },
        .channel_shift => &.{ "r", "g", "b", "wrap" },
        .displace => &.{ "fieldX", "fieldY", "amount", "ampX", "periodX", "ampY", "periodY", "phase" },
        .tear => &.{ "axis", "minHeight", "maxHeight", "minShift", "maxShift", "chance", "wrap" },
        .block_repeat => &.{ "mode", "count", "minSize", "maxSize", "grid" },
        .dither, .posterize => &.{ "levels", "matrix", "spread", "method", "palette", "cell" },
        .blur => &.{"radius"},
        .bloom => &.{ "threshold", "radius", "strength" },
        .grain => &.{ "amount", "mono", "size" },
        .levels => &.{ "black", "white", "gamma", "outBlack", "outWhite" },
        .scanlines => &.{ "axis", "period", "width", "strength" },
    };
}

fn readRegion(lua: *Lua, opts: i32) ?[4]f64 {
    if (!lua.isTable(opts)) return null;
    defer lua.pop(1);
    switch (lua.getField(opts, "region")) {
        .nil, .none => return null,
        .table => {},
        else => lua.raiseErrorStr("option 'region' must be {x, y, w, h}", .{}),
    }
    var rect: [4]f64 = undefined;
    for (&rect, 1..) |*v, i| {
        v.* = util.numberAt(lua, -1, i) orelse lua.raiseErrorStr("option 'region' must be {x, y, w, h}", .{});
    }
    return rect;
}

fn pixelSort(lua: *Lua, arena: Allocator, opts: i32) !passes.PixelSort {
    if (lua.isTable(opts)) {
        defer lua.pop(1);
        if (lua.getField(opts, "direction") == .number) {
            lua.raiseErrorStr("option 'direction' must be \"x\" or \"y\". Use angle for degrees", .{});
        }
    }
    const direction = try optAxis(lua, arena, opts, "direction");
    const angle: f64 = switch (direction) {
        .x => 0,
        .y => 90,
    };
    const key = util.optEnum(lua, passes.SortKey, opts, "key", .luma);
    const passes_count = optPasses(lua, opts);
    const passes_field = optField(lua, opts, "passesField");
    if (passes_field != null and passes_count == null) {
        lua.raiseErrorStr("option 'passesField' scales passes, so it needs passes too", .{});
    }
    return .{
        .angle = util.optNumber(lua, opts, "angle", angle),
        .key = key,
        .sort_by = util.optEnum(lua, passes.SortKey, opts, "sortBy", key),
        .lo = optF32(lua, opts, "lo", 0.25),
        .hi = optF32(lua, opts, "hi", 0.8),
        .mask = optField(lua, opts, "mask"),
        .mask_threshold = optF32(lua, opts, "maskThreshold", 0.5),
        .reverse = util.optBool(lua, opts, "reverse", false),
        .length_min = nonNegative(lua, opts, "minLength", 0),
        .length_max = nonNegative(lua, opts, "maxLength", 0),
        .jitter = std.math.clamp(optF32(lua, opts, "jitter", 0), 0, 1),
        .chance = optF32(lua, opts, "chance", 1),
        .seed = util.optSeed(lua, opts),
        .passes = passes_count,
        .passes_field = passes_field,
    };
}

fn optPasses(lua: *Lua, opts: i32) ?u32 {
    if (!lua.isTable(opts)) return null;
    defer lua.pop(1);
    return switch (lua.getField(opts, "passes")) {
        .nil, .none => null,
        .number => blk: {
            const n = lua.toNumber(-1) catch unreachable; // type checked by the switch
            if (!(n >= 0 and n == @floor(n))) lua.raiseErrorStr("option 'passes' must be a whole number, 0 or more", .{});
            break :blk @intFromFloat(@min(n, std.math.maxInt(u32)));
        },
        else => lua.raiseErrorStr("option 'passes' must be a number", .{}),
    };
}

fn channelShift(lua: *Lua, opts: i32) passes.ChannelShift {
    return .{
        .offsets = .{ optVec2(lua, opts, "r"), optVec2(lua, opts, "g"), optVec2(lua, opts, "b") },
        .wrap = util.optBool(lua, opts, "wrap", false),
    };
}

fn displace(lua: *Lua, opts: i32) passes.Displace {
    return .{
        .field_x = optField(lua, opts, "fieldX"),
        .field_y = optField(lua, opts, "fieldY"),
        .amount = util.optNumber(lua, opts, "amount", 10),
        .amp_x = util.optNumber(lua, opts, "ampX", 0),
        .period_x = positive(lua, opts, "periodX", 100),
        .amp_y = util.optNumber(lua, opts, "ampY", 0),
        .period_y = positive(lua, opts, "periodY", 100),
        .phase = util.optNumber(lua, opts, "phase", 0),
    };
}

fn tear(lua: *Lua, opts: i32) passes.Tear {
    return .{
        .axis = util.optEnum(lua, passes.Axis, opts, "axis", .x),
        .height_min = positive(lua, opts, "minHeight", 2),
        .height_max = positive(lua, opts, "maxHeight", 30),
        .shift_min = nonNegative(lua, opts, "minShift", 5),
        .shift_max = nonNegative(lua, opts, "maxShift", 80),
        .chance = optF32(lua, opts, "chance", 0.3),
        .wrap = util.optBool(lua, opts, "wrap", true),
        .seed = util.optSeed(lua, opts),
    };
}

const block_modes: std.StaticStringMap(passes.BlockMode) = .initComptime(.{
    .{ "copy", .copy },
    .{ "smearX", .smear_x },
    .{ "smearY", .smear_y },
    .{ "mixed", .mixed },
});

fn blockRepeat(lua: *Lua, arena: Allocator, opts: i32) !passes.BlockRepeat {
    const mode_name = (try util.optString(lua, arena, opts, "mode", "mixed")).?;
    const mode = block_modes.get(mode_name) orelse
        lua.raiseErrorStr("option 'mode' must be \"copy\", \"smearX\", \"smearY\" or \"mixed\"", .{});
    const count = util.optInt(lua, opts, "count", 40);
    if (count < 0 or count > 1 << 20) lua.raiseErrorStr("option 'count' out of range", .{});
    return .{
        .count = @intCast(count),
        .size_min = positive(lua, opts, "minSize", 10),
        .size_max = positive(lua, opts, "maxSize", 80),
        .grid = nonNegative(lua, opts, "grid", 0),
        .mode = mode,
        .seed = util.optSeed(lua, opts),
    };
}

/// Options for dither and posterize, which differ only in the default method.
fn dither(lua: *Lua, arena: Allocator, opts: i32, method: passes.DitherMethod) !passes.Dither {
    const levels_count = util.optInt(lua, opts, "levels", 2);
    if (levels_count < 2 or levels_count > 65536) lua.raiseErrorStr("option 'levels' must be 2 or more", .{});
    const matrix = util.optInt(lua, opts, "matrix", 4);
    switch (matrix) {
        2, 4, 8, 16 => {},
        else => lua.raiseErrorStr("option 'matrix' must be 2, 4, 8 or 16", .{}),
    }
    const spread: ?f32 = if (lua.isTable(opts)) blk: {
        defer lua.pop(1);
        break :blk switch (lua.getField(opts, "spread")) {
            .number => @floatCast(lua.toNumber(-1) catch unreachable), // type checked by the switch
            .nil, .none => null,
            else => lua.raiseErrorStr("option 'spread' must be a number", .{}),
        };
    } else null;
    return .{
        .method = util.optEnum(lua, passes.DitherMethod, opts, "method", method),
        .levels = @intCast(levels_count),
        .palette = try optPalette(lua, arena, opts),
        .matrix = @intCast(matrix),
        .cell = nonNegative(lua, opts, "cell", 0),
        .spread = spread,
    };
}

fn bloom(lua: *Lua, opts: i32) passes.Bloom {
    return .{
        .threshold = optF32(lua, opts, "threshold", 0.7),
        .radius = nonNegative(lua, opts, "radius", 20),
        .strength = optF32(lua, opts, "strength", 1),
    };
}

fn blur(lua: *Lua, opts: i32) passes.Blur {
    return .{ .radius = nonNegative(lua, opts, "radius", 4) };
}

fn grain(lua: *Lua, opts: i32) passes.Grain {
    return .{
        .amount = optF32(lua, opts, "amount", 0.1),
        .mono = util.optBool(lua, opts, "mono", true),
        .size = positive(lua, opts, "size", 1),
        .seed = util.optSeed(lua, opts),
    };
}

fn levels(lua: *Lua, opts: i32) passes.Levels {
    return .{
        .black = optF32(lua, opts, "black", 0),
        .white = optF32(lua, opts, "white", 1),
        .gamma = optF32(lua, opts, "gamma", 1),
        .out_black = optF32(lua, opts, "outBlack", 0),
        .out_white = optF32(lua, opts, "outWhite", 1),
    };
}

fn scanlines(lua: *Lua, arena: Allocator, opts: i32) !passes.Scanlines {
    const axis = try optAxis(lua, arena, opts, "axis");
    return .{
        .period = positive(lua, opts, "period", 4),
        .width = nonNegative(lua, opts, "width", 2),
        .strength = optF32(lua, opts, "strength", 0.5),
        .axis = switch (axis) {
            .x => .x,
            .y => .y,
        },
    };
}

/// "x" (the default) or "y".
fn optAxis(lua: *Lua, arena: Allocator, opts: i32, key: [:0]const u8) !passes.Axis {
    const s = (try util.optString(lua, arena, opts, key, "x")).?;
    if (std.mem.eql(u8, s, "x")) return .x;
    if (std.mem.eql(u8, s, "y")) return .y;
    lua.raiseErrorStr("option '%s' must be \"x\" or \"y\"", .{key.ptr});
}

fn optF32(lua: *Lua, opts: i32, key: [:0]const u8, default: f32) f32 {
    return @floatCast(util.optNumber(lua, opts, key, default));
}

fn positive(lua: *Lua, opts: i32, key: [:0]const u8, default: f64) f64 {
    const v = util.optNumber(lua, opts, key, default);
    if (!(v > 0)) lua.raiseErrorStr("option '%s' must be positive", .{key.ptr});
    return v;
}

fn nonNegative(lua: *Lua, opts: i32, key: [:0]const u8, default: f64) f64 {
    const v = util.optNumber(lua, opts, key, default);
    if (!(v >= 0)) lua.raiseErrorStr("option '%s' must not be negative", .{key.ptr});
    return v;
}

fn optVec2(lua: *Lua, opts: i32, key: [:0]const u8) [2]f64 {
    if (!lua.isTable(opts)) return .{ 0, 0 };
    defer lua.pop(1);
    return switch (lua.getField(opts, key)) {
        .nil, .none => .{ 0, 0 },
        else => util.readVec2(lua, -1) orelse lua.raiseErrorStr("option '%s' must be {dx, dy}", .{key.ptr}),
    };
}

/// The Field stays owned by Lua. The options table keeps it alive for as
/// long as the canvas holding the pass.
fn optField(lua: *Lua, opts: i32, key: [:0]const u8) ?*const Field {
    if (!lua.isTable(opts)) return null;
    defer lua.pop(1);
    return switch (lua.getField(opts, key)) {
        .nil, .none => null,
        else => util.toField(lua, -1) orelse lua.raiseErrorStr("option '%s' must be a Field", .{key.ptr}),
    };
}

fn optPalette(lua: *Lua, arena: Allocator, opts: i32) ![]const Rgb {
    if (!lua.isTable(opts)) return &.{};
    defer lua.pop(1);
    switch (lua.getField(opts, "palette")) {
        .nil, .none => return &.{},
        .table => {},
        else => lua.raiseErrorStr("option 'palette' must be a list of colors", .{}),
    }
    const n = util.len(lua, -1);
    if (n == 0) lua.raiseErrorStr("option 'palette' is empty", .{});
    const out = try arena.alloc(Rgb, n);
    for (out, 1..) |*c, i| {
        _ = util.rawGet(lua, -1, i);
        defer lua.pop(1);
        const rgba = util.readColor(lua, -1) orelse lua.raiseErrorStr("palette entry %d is not a color", .{@as(c_int, @intCast(i))});
        c.* = .{ rgba[0], rgba[1], rgba[2] };
    }
    return out;
}

test "bind_passes: option key lists match the keys parse reads" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    const proxy =
        \\local seen = {}
        \\return setmetatable({}, {__index = function(_, k) seen[k] = true end}), seen
    ;
    for (names.keys(), names.values()) |name, tag| {
        try util.loadBuffer(lua, proxy, "=proxy");
        try lua.protectedCall(.{ .args = 0, .results = 2 });
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        _ = try parse(lua, arena_state.allocator(), name, lua.absIndex(-2));

        const keys = optionKeys(tag);
        for (keys) |k| {
            _ = lua.getField(-1, try arena_state.allocator().dupeSentinel(u8, k, 0));
            defer lua.pop(1);
            if (!lua.toBoolean(-1)) std.debug.print("{s} lists {s}, parse does not read it\n", .{ name, k });
            try std.testing.expect(lua.toBoolean(-1));
        }
        lua.pushNil();
        while (lua.next(-2)) {
            lua.pop(1);
            const key = try lua.toString(-1);
            if (!isOptionKey(keys, key)) std.debug.print("{s} reads {s}, not in its list\n", .{ name, key });
            try std.testing.expect(isOptionKey(keys, key));
        }
        lua.pop(2);
    }
}

test "bind_passes: check names the closest option for a typo" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    lua.pushFunction(zlua.wrap(check));
    lua.setGlobal("check");
    const probe =
        \\local a = {check("tear", {axs = "y"})}
        \\local b = {check("pixelsort", {})}
        \\local c = {check("blur", {radius = 2, seed = 1, region = {0, 0, 1, 1}})}
        \\return a[2], b[2], c[1]
    ;
    try util.loadBuffer(lua, probe, "=probe");
    try lua.protectedCall(.{ .args = 0, .results = 3 });
    try std.testing.expectEqualStrings("post pass 'tear' has no option 'axs' (did you mean 'axis'?)", try lua.toString(-3));
    try std.testing.expectEqualStrings("unknown post pass 'pixelsort' (did you mean 'pixelSort'?)", try lua.toString(-2));
    try std.testing.expect(lua.toBoolean(-1));
}
