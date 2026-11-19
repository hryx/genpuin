//! core.texture: noise samplers, noise grids, curl flow tracing, field
//! filters, and density renders (attractors, fractal flames, splats).
//! Option names are camelCase in Lua and map onto snake_case Zig enums.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const util = @import("util.zig");
const Lua = util.Lua;
const Field = util.Field;
const noise = genpuin.noise;
const density = genpuin.density;
const flame = density.flame;
const attractor = density.attractor;

pub const functions = [_]zlua.FnReg{
    .{ .name = "simplex", .func = zlua.wrap(simplex) },
    .{ .name = "valueNoise", .func = zlua.wrap(valueNoise) },
    .{ .name = "worley", .func = zlua.wrap(worley) },
    .{ .name = "curl", .func = zlua.wrap(curl) },
    .{ .name = "curlAngle", .func = zlua.wrap(curlAngle) },
    .{ .name = "noiseGrid", .func = zlua.wrap(noiseGrid) },
    .{ .name = "traceFlow", .func = zlua.wrap(traceFlow) },
    .{ .name = "blur", .func = zlua.wrap(blur) },
    .{ .name = "gradient", .func = zlua.wrap(gradient) },
    .{ .name = "attractor", .func = zlua.wrap(attractorFn) },
    .{ .name = "flame", .func = zlua.wrap(flameFn) },
    .{ .name = "randomFlame", .func = zlua.wrap(randomFlame) },
    .{ .name = "splat", .func = zlua.wrap(splat) },
    .{ .name = "checkSnap", .func = zlua.wrap(checkSnap) },
};

/// Fold any Lua number into a 32-bit noise seed.
fn seed32(v: f64) u32 {
    const u = seed64(v);
    return @truncate(u ^ (u >> 32));
}

fn seed64(v: f64) u64 {
    const limit: f64 = 9.0e18;
    const i: i64 = @intFromFloat(std.math.clamp(@floor(v), -limit, limit));
    return @bitCast(i);
}

/// An enum option whose Lua name is the camelCase form of a snake_case tag.
fn optCamelEnum(lua: *Lua, comptime E: type, index: i32, key: [:0]const u8, default: E) E {
    if (!lua.isTable(index)) return default;
    defer lua.pop(1);
    switch (lua.getField(index, key)) {
        .nil, .none => return default,
        .string => {
            const s = lua.toString(-1) catch unreachable; // type checked by the switch
            return camelToEnum(E, s) orelse
                lua.raiseErrorStr("option '%s': unknown value '%s'", .{ key.ptr, s.ptr });
        },
        else => lua.raiseErrorStr("option '%s' must be a string", .{key.ptr}),
    }
}

fn camelToEnum(comptime E: type, s: []const u8) ?E {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |ch| {
        if (n + 2 > buf.len or ch == '_') return null;
        if (std.ascii.isUpper(ch)) {
            buf[n] = '_';
            n += 1;
        }
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    return std.meta.stringToEnum(E, buf[0..n]);
}

fn optRange(lua: *Lua, index: i32, key: [:0]const u8, default: f64, lo: f64, hi: f64) f64 {
    const v = util.optNumber(lua, index, key, default);
    if (!(v >= lo and v <= hi)) lua.raiseErrorStr("option '%s' is out of range", .{key.ptr});
    return v;
}

fn optSize(lua: *Lua, index: i32, key: [:0]const u8, default: f64) u32 {
    return @intFromFloat(@floor(optRange(lua, index, key, default, 1, 1 << 16)));
}

fn readNoise(lua: *Lua, index: i32, seed: u32) noise.Options {
    return .{
        .basis = optCamelEnum(lua, noise.Basis, index, "kind", .simplex),
        .metric = optCamelEnum(lua, noise.Metric, index, "metric", .euclidean),
        .jitter = @floatCast(optRange(lua, index, "jitter", 1, 0, 1)),
        .fractal = optCamelEnum(lua, noise.Fractal, index, "fractal", .fbm),
        .octaves = @intFromFloat(@floor(optRange(lua, index, "octaves", 1, 1, 16))),
        .lacunarity = @floatCast(util.optNumber(lua, index, "lacunarity", 2)),
        .gain = @floatCast(util.optNumber(lua, index, "gain", 0.5)),
        .warp = @floatCast(util.optNumber(lua, index, "warp", 0)),
        .warp_scale = @floatCast(util.optNumber(lua, index, "warpScale", 1)),
        .warp_octaves = if (util.optNumber(lua, index, "warpOctaves", 0) >= 1)
            @intFromFloat(@floor(optRange(lua, index, "warpOctaves", 1, 1, 16)))
        else
            null,
        .warp_depth = @intFromFloat(@floor(optRange(lua, index, "warpDepth", 1, 1, 4))),
        .seed = seed,
    };
}

fn optZ(lua: *Lua, index: i32) ?f32 {
    if (!lua.isTable(index)) return null;
    defer lua.pop(1);
    return switch (lua.getField(index, "z")) {
        .number => @floatCast(lua.toNumber(-1) catch 0),
        .nil, .none => null,
        else => lua.raiseErrorStr("option 'z' must be a number", .{}),
    };
}

fn optOffset(lua: *Lua, index: i32) [2]f32 {
    if (!lua.isTable(index)) return .{ 0, 0 };
    defer lua.pop(1);
    _ = lua.getField(index, "offset");
    if (lua.isNoneOrNil(-1)) return .{ 0, 0 };
    const v = util.readVec2(lua, -1) orelse lua.raiseErrorStr("option 'offset' must be {x, y}", .{});
    return .{ @floatCast(v[0]), @floatCast(v[1]) };
}

/// A rect from the table at `index` under `key`, as {x, y, w, h} or
/// {x = , y = , w = , h = }.
fn optRect(lua: *Lua, index: i32, key: [:0]const u8) ?[4]f64 {
    if (!lua.isTable(index)) return null;
    defer lua.pop(1);
    if (lua.getField(index, key) != .table) {
        if (lua.isNoneOrNil(-1)) return null;
        lua.raiseErrorStr("option '%s' must be a rect", .{key.ptr});
    }
    return readRect(lua, -1) orelse lua.raiseErrorStr("option '%s' must be {x, y, w, h}", .{key.ptr});
}

fn readRect(lua: *Lua, index_in: i32) ?[4]f64 {
    const index = lua.absIndex(index_in);
    var r: [4]f64 = undefined;
    const names = [_][:0]const u8{ "x", "y", "w", "h" };
    for (&r, names, 1..) |*v, name, i| {
        v.* = util.numberAt(lua, index, i) orelse util.optNumber(lua, index, name, std.math.nan(f64));
        if (std.math.isNan(v.*)) return null;
    }
    if (r[2] == 0 or r[3] == 0) return null;
    return r;
}

/// The scene rect given inline as opts.x, y, w, h, if all four are set.
fn inlineRect(lua: *Lua, index: i32) ?[4]f64 {
    const nan = std.math.nan(f64);
    const r: [4]f64 = .{
        util.optNumber(lua, index, "x", nan),
        util.optNumber(lua, index, "y", nan),
        util.optNumber(lua, index, "w", nan),
        util.optNumber(lua, index, "h", nan),
    };
    for (r) |v| if (std.math.isNan(v)) return null;
    return r;
}

fn toRect(r: [4]f64) density.Rect {
    return .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] };
}

/// simplex(seed, x, y, z?)
fn simplex(lua: *Lua) i32 {
    const seed = seed32(lua.checkNumber(1));
    const x: f32 = @floatCast(lua.checkNumber(2));
    const y: f32 = @floatCast(lua.checkNumber(3));
    const v = if (lua.optNumber(4)) |z| noise.simplex3(seed, x, y, @floatCast(z)) else noise.simplex2(seed, x, y);
    lua.pushNumber(v);
    return 1;
}

/// valueNoise(seed, x, y, z?)
fn valueNoise(lua: *Lua) i32 {
    const seed = seed32(lua.checkNumber(1));
    const x: f32 = @floatCast(lua.checkNumber(2));
    const y: f32 = @floatCast(lua.checkNumber(3));
    const v = if (lua.optNumber(4)) |z| noise.value3(seed, x, y, @floatCast(z)) else noise.value2(seed, x, y);
    lua.pushNumber(v);
    return 1;
}

/// worley(seed, x, y, {metric, jitter}?) -> f1, f2
fn worley(lua: *Lua) i32 {
    const seed = seed32(lua.checkNumber(1));
    const x: f32 = @floatCast(lua.checkNumber(2));
    const y: f32 = @floatCast(lua.checkNumber(3));
    const metric = optCamelEnum(lua, noise.Metric, 4, "metric", .euclidean);
    const jitter: f32 = @floatCast(optRange(lua, 4, "jitter", 1, 0, 1));
    const r = noise.worley2(seed, x, y, metric, jitter);
    lua.pushNumber(r[0]);
    lua.pushNumber(r[1]);
    return 2;
}

fn curlAt(lua: *Lua) [2]f32 {
    const seed = seed32(lua.checkNumber(1));
    const x = lua.checkNumber(2);
    const y = lua.checkNumber(3);
    const o = readNoise(lua, 4, seed);
    const scale = util.optNumber(lua, 4, "scale", 1);
    const off = optOffset(lua, 4);
    return noise.curl(&o, @floatCast(x * scale + off[0]), @floatCast(y * scale + off[1]), optZ(lua, 4));
}

/// curl(seed, x, y, opts?) -> dx, dy
fn curl(lua: *Lua) i32 {
    const v = curlAt(lua);
    lua.pushNumber(v[0]);
    lua.pushNumber(v[1]);
    return 2;
}

/// curlAngle(seed, x, y, opts?) -> radians
fn curlAngle(lua: *Lua) i32 {
    const v = curlAt(lua);
    lua.pushNumber(genpuin.math.atan2(v[1], v[0]));
    return 1;
}

/// noiseGrid(w, h, opts, default_seed) -> Field
fn noiseGrid(lua: *Lua) !i32 {
    const w = util.checkU32(lua, 1);
    const h = util.checkU32(lua, 2);
    const seed = seed32(util.optNumber(lua, 3, "seed", lua.optNumber(4) orelse 0));
    const o = readNoise(lua, 3, seed);
    const m: noise.Mapping = .{
        .rect = inlineRect(lua, 3),
        .scale = @floatCast(util.optNumber(lua, 3, "scale", 0.01)),
        .offset = optOffset(lua, 3),
        .z = optZ(lua, 3),
    };
    util.pushField(lua, try noise.grid(lua.allocator(), w, h, &o, m));
    return 1;
}

/// traceFlow(opts, default_seed) -> {{x, y}, ...} per path
fn traceFlow(lua: *Lua) !i32 {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    lua.checkType(1, .table);
    const seed = util.optNumber(lua, 1, "seed", lua.optNumber(2) orelse 0);
    _ = lua.getField(1, "field");
    const angle_field = util.toField(lua, -1);
    lua.pop(1);
    var bounds = optRect(lua, 1, "bounds");
    if (bounds == null) {
        if (angle_field) |f| bounds = .{ 0, 0, @floatFromInt(f.w), @floatFromInt(f.h) };
    }
    const source: noise.flow.Source = if (angle_field) |f|
        .{ .angle = .{ .field = f, .rect = bounds.? } }
    else
        .{ .curl = .{
            .noise = readNoise(lua, 1, seed32(seed)),
            .scale = @floatCast(util.optNumber(lua, 1, "scale", 0.005)),
            .offset = optOffset(lua, 1),
            .z = optZ(lua, 1),
        } };

    const starts = blk: {
        if (lua.getField(1, "starts") == .table) {
            const pts = try util.readPoints(lua, arena, -1);
            lua.pop(1);
            break :blk pts;
        }
        lua.pop(1);
        const n = optRange(lua, 1, "n", 500, 0, 1e7);
        const r = bounds orelse lua.raiseErrorStr("traceFlow needs starts, bounds or field", .{});
        break :blk try noise.flow.randomStarts(arena, seed64(seed), @intFromFloat(n), r);
    };
    const clip = util.optBool(lua, 1, "clip", true);
    var paths = try noise.flow.trace(gpa, .{
        .source = source,
        .starts = starts,
        .steps = @intFromFloat(optRange(lua, 1, "steps", 200, 0, 1e6)),
        .step_size = util.optNumber(lua, 1, "stepSize", 1),
        .bounds = if (clip) bounds else null,
    });
    defer paths.deinit(gpa);

    lua.createTable(@intCast(paths.ends.len), 0);
    for (0..paths.ends.len) |i| {
        util.pushPoints(lua, paths.path(i));
        util.rawSet(lua, -2, i + 1);
    }
    return 1;
}

/// blur(field, sigma) -> Field
fn blur(lua: *Lua) !i32 {
    const f = util.checkField(lua, 1);
    const sigma = lua.checkNumber(2);
    if (!(sigma >= 0 and sigma <= 1000)) lua.argError(2, "expected a radius from 0 to 1000");
    util.pushField(lua, try noise.filter.blur(lua.allocator(), f, @floatCast(sigma)));
    return 1;
}

/// gradient(field) -> dx, dy
fn gradient(lua: *Lua) !i32 {
    const f = util.checkField(lua, 1);
    const g = try noise.filter.gradient(lua.allocator(), f);
    util.pushField(lua, g.dx);
    util.pushField(lua, g.dy);
    return 2;
}

const SnapUse = enum { orbit, splat };

/// opts.snap from the table at `index`: a number is the cell size, a
/// table spells out every key. Unknown keys are caught in the prelude,
/// which knows the script line.
fn optSnap(lua: *Lua, index: i32, use: SnapUse) ?density.Snap {
    if (!lua.isTable(index)) return null;
    defer lua.pop(1);
    switch (lua.getField(index, "snap")) {
        .nil, .none => return null,
        .number => return .{ .cell = snapCell(lua, lua.toNumber(-1) catch unreachable) }, // type checked by the switch
        .table => {},
        else => lua.raiseErrorStr("option 'snap' must be a cell size or a table", .{}),
    }
    const t = lua.absIndex(-1);
    if (lua.getField(t, "cell") != .number) lua.raiseErrorStr("option 'snap.cell' must be a number", .{});
    const cell = snapCell(lua, lua.toNumber(-1) catch unreachable); // type checked on the line above
    lua.pop(1);
    const feedback = switch (lua.getField(t, "feedback")) {
        .nil, .none => false,
        .boolean => lua.toBoolean(-1),
        else => lua.raiseErrorStr("option 'snap.feedback' must be true or false", .{}),
    };
    lua.pop(1);
    if (feedback and use == .splat) lua.raiseErrorStr("option 'snap.feedback' needs an orbit, gen.splat has none", .{});
    const spokes = snapNumber(lua, t, "spokes", 24, 1, 65536);
    if (spokes != @floor(spokes)) lua.raiseErrorStr("option 'snap.spokes' must be a whole number", .{});
    return .{
        .cell = cell,
        .mode = snapMode(lua, t),
        .amount = snapNumber(lua, t, "amount", 1, 0, 1),
        .jitter = snapNumber(lua, t, "jitter", 0, 0, 100),
        .chance = snapNumber(lua, t, "chance", 1, 0, 1),
        .angle = snapNumber(lua, t, "angle", 0, -1e6, 1e6),
        .center = snapCenter(lua, t),
        .spokes = @intFromFloat(spokes),
        .feedback = feedback,
    };
}

/// checkSnap(opts, use) -> true, or false and the message reading
/// opts.snap would raise. `use` is "orbit" or "splat". The prelude raises
/// the message at the caller's line.
fn checkSnap(lua: *Lua) i32 {
    lua.pushFunction(zlua.wrap(checkSnapProtected));
    lua.pushValue(1);
    lua.pushValue(2);
    lua.protectedCall(.{ .args = 2, .results = 0 }) catch {
        lua.pushBoolean(false);
        lua.insert(-2);
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

fn checkSnapProtected(lua: *Lua) i32 {
    const name = lua.toString(2) catch lua.raiseErrorStr("checkSnap needs a use", .{});
    const use = std.meta.stringToEnum(SnapUse, name) orelse lua.raiseErrorStr("unknown snap use '%s'", .{name.ptr});
    _ = optSnap(lua, 1, use);
    return 0;
}

fn snapCell(lua: *Lua, cell: f64) f64 {
    if (!(cell > 0 and cell <= 1e6)) lua.raiseErrorStr("option 'snap.cell' must be above 0 and at most 1e6", .{});
    return cell;
}

fn snapNumber(lua: *Lua, t: i32, key: [:0]const u8, default: f64, lo: f64, hi: f64) f64 {
    defer lua.pop(1);
    const v = switch (lua.getField(t, key)) {
        .nil, .none => return default,
        .number => lua.toNumber(-1) catch unreachable, // type checked by the switch
        else => lua.raiseErrorStr("option 'snap.%s' must be a number", .{key.ptr}),
    };
    if (!(v >= lo and v <= hi)) lua.raiseErrorStr("option 'snap.%s' is out of range", .{key.ptr});
    return v;
}

fn snapMode(lua: *Lua, t: i32) density.Snap.Mode {
    defer lua.pop(1);
    switch (lua.getField(t, "mode")) {
        .nil, .none => return .grid,
        .string => {
            const s = lua.toString(-1) catch unreachable; // type checked by the switch
            return std.meta.stringToEnum(density.Snap.Mode, s) orelse lua.raiseErrorStr(
                "option 'snap.mode': unknown value '%s' (grid, rows, columns, hex or polar)",
                .{s.ptr},
            );
        },
        else => lua.raiseErrorStr("option 'snap.mode' must be a string", .{}),
    }
}

fn snapCenter(lua: *Lua, t: i32) ?[2]f64 {
    defer lua.pop(1);
    if (lua.getField(t, "center") == .nil) return null;
    const c = util.readVec2(lua, -1) orelse lua.raiseErrorStr("option 'snap.center' must be {x, y}", .{});
    if (!(std.math.isFinite(c[0]) and std.math.isFinite(c[1]))) {
        lua.raiseErrorStr("option 'snap.center' must be finite", .{});
    }
    return c;
}

fn readParams(lua: *Lua, kind: attractor.Kind) attractor.Params {
    const d = attractor.defaults(kind);
    return .{
        .a = util.optNumber(lua, 1, "a", d.a),
        .b = util.optNumber(lua, 1, "b", d.b),
        .c = util.optNumber(lua, 1, "c", d.c),
        .d = util.optNumber(lua, 1, "d", d.d),
        .e = util.optNumber(lua, 1, "e", d.e),
        .degree = @intFromFloat(optRange(lua, 1, "degree", @floatFromInt(d.degree), 0, 64)),
    };
}

/// attractor(opts, default_seed) -> Field
fn attractorFn(lua: *Lua) !i32 {
    const kind = optCamelEnum(lua, attractor.Kind, 1, "kind", .clifford);
    const o: attractor.Options = .{
        .kind = kind,
        .params = readParams(lua, kind),
        .iterations = @intFromFloat(optRange(lua, 1, "n", 2e6, 0, 1e11)),
        .w = optSize(lua, 1, "w", 800),
        .h = optSize(lua, 1, "h", 800),
        .seed = seed64(util.optNumber(lua, 1, "seed", lua.optNumber(2) orelse 1)),
        .supersample = @intFromFloat(optRange(lua, 1, "supersample", 1, 1, 8)),
        .splat = util.optEnum(lua, density.Splat, 1, "splat", .bilinear),
        .bounds = if (optRect(lua, 1, "bounds")) |r| toRect(r) else null,
        .snap = optSnap(lua, 1, .orbit),
    };
    util.pushField(lua, try attractor.render(lua.allocator(), o));
    return 1;
}

fn readAffine(lua: *Lua, index: i32, key: [:0]const u8) ?flame.Affine {
    defer lua.pop(1);
    if (lua.getField(index, key) != .table) return null;
    var a: flame.Affine = undefined;
    for (&a, 1..) |*v, i| {
        v.* = util.numberAt(lua, -1, i) orelse lua.raiseErrorStr("'%s' needs six numbers", .{key.ptr});
    }
    return a;
}

/// One transform table at `index`: {weight, affine = {6}, post = {6}?,
/// variations = {name = weight}, color, colorSpeed}.
fn readTransform(lua: *Lua, arena: Allocator, index_in: i32) !flame.Transform {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("a flame transform must be a table", .{});
    var t: flame.Transform = .{
        .weight = util.numberAt(lua, index, 1) orelse util.optNumber(lua, index, "weight", 1),
        .affine = readAffine(lua, index, "affine") orelse flame.identity,
        .post = readAffine(lua, index, "post"),
        .color = util.optNumber(lua, index, "color", 0),
        .color_speed = util.optNumber(lua, index, "colorSpeed", 0.5),
    };
    var terms: std.ArrayList(flame.Term) = .empty;
    if (lua.getField(index, "variations") == .table) {
        const vt = lua.absIndex(-1);
        lua.pushNil();
        while (lua.next(vt)) {
            if (lua.typeOf(-2) != .string) lua.raiseErrorStr("variation names must be strings", .{});
            const name = lua.toString(-2) catch unreachable; // type checked above
            const v = std.meta.stringToEnum(flame.Variation, name) orelse
                lua.raiseErrorStr("unknown variation '%s'", .{name.ptr});
            const w = lua.toNumber(-1) catch lua.raiseErrorStr("variation '%s' needs a number weight", .{name.ptr});
            try terms.append(arena, .{ .variation = v, .weight = w });
            lua.pop(1);
        }
    }
    lua.pop(1);
    if (terms.items.len > 0) t.terms = terms.items;
    return t;
}

/// flame(opts, default_seed) -> density, color
fn flameFn(lua: *Lua) !i32 {
    const gpa = lua.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    lua.checkType(1, .table);
    if (lua.getField(1, "transforms") != .table) lua.raiseErrorStr("flame needs a transforms list", .{});
    const n = util.len(lua, -1);
    if (n == 0) lua.raiseErrorStr("flame needs at least one transform", .{});
    const ts = try arena.alloc(flame.Transform, n);
    for (ts, 1..) |*t, i| {
        _ = util.rawGet(lua, -1, i);
        t.* = try readTransform(lua, arena, -1);
        lua.pop(1);
    }
    lua.pop(1);
    const final: ?flame.Transform = if (lua.getField(1, "final") == .table) try readTransform(lua, arena, -1) else null;
    lua.pop(1);

    const o: flame.Options = .{
        .transforms = ts,
        .final = final,
        .symmetry = @intFromFloat(optRange(lua, 1, "symmetry", 1, -64, 64)),
        .iterations = @intFromFloat(optRange(lua, 1, "n", 2e6, 0, 1e11)),
        .w = optSize(lua, 1, "w", 800),
        .h = optSize(lua, 1, "h", 800),
        .seed = seed64(util.optNumber(lua, 1, "seed", lua.optNumber(2) orelse 1)),
        .supersample = @intFromFloat(optRange(lua, 1, "supersample", 1, 1, 8)),
        .splat = util.optEnum(lua, density.Splat, 1, "splat", .bilinear),
        .bounds = if (optRect(lua, 1, "bounds")) |r| toRect(r) else null,
        .snap = optSnap(lua, 1, .orbit),
    };
    const res = flame.render(gpa, o) catch |err| switch (err) {
        error.NoWeight => lua.raiseErrorStr("flame transforms need a positive total weight", .{}),
        error.OutOfMemory => return err,
    };
    util.pushField(lua, res.density);
    util.pushField(lua, res.color);
    return 2;
}

fn pushAffine(lua: *Lua, a: flame.Affine) void {
    lua.createTable(6, 0);
    for (a, 1..) |v, i| {
        lua.pushNumber(v);
        util.rawSet(lua, -2, i);
    }
}

/// randomFlame(seed, count) -> {transforms = {...}, symmetry = n}
fn randomFlame(lua: *Lua) !i32 {
    const seed = seed64(lua.checkNumber(1));
    const count = lua.optNumber(2) orelse 3;
    if (!(count >= 1 and count <= 16)) lua.argError(2, "expected 1 to 16 transforms");
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const r = try flame.random(arena_state.allocator(), seed, @intFromFloat(count));

    lua.createTable(0, 2);
    lua.createTable(@intCast(r.transforms.len), 0);
    for (r.transforms, 1..) |t, i| {
        lua.createTable(0, 4);
        lua.pushNumber(t.weight);
        lua.setField(-2, "weight");
        pushAffine(lua, t.affine);
        lua.setField(-2, "affine");
        lua.createTable(0, @intCast(t.terms.len));
        for (t.terms) |term| {
            lua.pushNumber(term.weight);
            lua.setField(-2, @tagName(term.variation));
        }
        lua.setField(-2, "variations");
        lua.pushNumber(t.color);
        lua.setField(-2, "color");
        util.rawSet(lua, -2, i);
    }
    lua.setField(-2, "transforms");
    lua.pushInteger(r.symmetry);
    lua.setField(-2, "symmetry");
    return 1;
}

/// splat(field, points, opts?, default_seed?) adds {x, y, weight?}
/// points in place.
fn splat(lua: *Lua) !i32 {
    const f = util.checkField(lua, 1);
    lua.checkType(2, .table);
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rect = inlineRect(lua, 3) orelse [4]f64{ 0, 0, @floatFromInt(f.w), @floatFromInt(f.h) };
    if (rect[2] == 0 or rect[3] == 0) lua.raiseErrorStr("splat rect has zero size", .{});
    const mode = util.optEnum(lua, density.Splat, 3, "splat", .bilinear);
    const base: f32 = @floatCast(util.optNumber(lua, 3, "weight", 1));
    const n = util.len(lua, 2);
    const pts = try arena.alloc([2]f64, n);
    const ws = try arena.alloc(f32, n);
    for (pts, ws, 1..) |*p, *w, i| {
        _ = util.rawGet(lua, 2, i);
        p.* = util.readVec2(lua, -1) orelse lua.raiseErrorStr("point %d is not {x, y}", .{@as(c_int, @intCast(i))});
        w.* = base * @as(f32, @floatCast(util.numberAt(lua, -1, 3) orelse 1));
        lua.pop(1);
    }
    var snapper: ?density.Snapper = if (optSnap(lua, 3, .splat)) |s|
        .init(s, f.w, f.h, 1, seed64(util.optNumber(lua, 3, "seed", lua.optNumber(4) orelse 1)))
    else
        null;
    density.splatPoints(f, toRect(rect), mode, pts, ws, if (snapper) |*s| s else null);
    lua.pushValue(1);
    return 1;
}

test "bind_texture: camelCase option names map onto snake_case tags" {
    try std.testing.expectEqual(noise.Basis.worley_edge, camelToEnum(noise.Basis, "worleyEdge").?);
    try std.testing.expectEqual(attractor.Kind.gumowski_mira, camelToEnum(attractor.Kind, "gumowskiMira").?);
    try std.testing.expectEqual(@as(?noise.Basis, null), camelToEnum(noise.Basis, "worley_edge"));
}
