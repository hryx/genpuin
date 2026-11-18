//! core.algo: the gen.* algorithm toolbox. Each Lua state gets one
//! random stream and one Perlin table, kept in a userdata in the
//! registry. The modules in src/lua/prelude/ wrap these functions with
//! option defaults and shape constructors.
//!
//! On LuaJIT the hottest entry points are also exported as C function
//! pointers (see `ffi`), so prelude/compat.lua can call them through the
//! FFI from inside compiled traces.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const util = @import("util.zig");
const Lua = util.Lua;
const Vec2 = util.Vec2;
const algo = genpuin.algo;
const Rng = algo.Rng;
const Perlin = algo.Perlin;

pub const functions = [_]zlua.FnReg{
    .{ .name = "seed", .func = zlua.wrap(seed) },
    .{ .name = "rand", .func = zlua.wrap(rand) },
    .{ .name = "randRange", .func = zlua.wrap(randRange) },
    .{ .name = "randInt", .func = zlua.wrap(randInt) },
    .{ .name = "gaussian", .func = zlua.wrap(gaussian) },
    .{ .name = "pick", .func = zlua.wrap(pick) },
    .{ .name = "shuffle", .func = zlua.wrap(shuffle) },
    .{ .name = "weightedPick", .func = zlua.wrap(weightedPick) },
    .{ .name = "randInCircle", .func = zlua.wrap(randInCircle) },
    .{ .name = "randOnCircle", .func = zlua.wrap(randOnCircle) },
    .{ .name = "randInRect", .func = zlua.wrap(randInRect) },
    .{ .name = "poissonDisk", .func = zlua.wrap(poissonDisk) },
    .{ .name = "noiseSeed", .func = zlua.wrap(noiseSeed) },
    .{ .name = "perlin", .func = zlua.wrap(perlin) },
    .{ .name = "fbm", .func = zlua.wrap(fbm) },
    .{ .name = "mod", .func = zlua.wrap(mod) },
    .{ .name = "ffi", .func = zlua.wrap(ffiTable) },
    .{ .name = "band", .func = zlua.wrap(bitOp(.band)) },
    .{ .name = "bxor", .func = zlua.wrap(bitOp(.bxor)) },
    .{ .name = "rshift", .func = zlua.wrap(bitOp(.rshift)) },
    .{ .name = "lshift", .func = zlua.wrap(bitOp(.lshift)) },
    .{ .name = "voronoi", .func = zlua.wrap(voronoi) },
    .{ .name = "relax", .func = zlua.wrap(relax) },
    .{ .name = "pointInPolygon", .func = zlua.wrap(pointInPolygon) },
    .{ .name = "nearest", .func = zlua.wrap(nearest) },
    .{ .name = "withinRadius", .func = zlua.wrap(withinRadius) },
    .{ .name = "separate", .func = zlua.wrap(separate) },
    .{ .name = "packCircles", .func = zlua.wrap(packCircles) },
    .{ .name = "elementary", .func = zlua.wrap(elementary) },
    .{ .name = "lifeStep", .func = zlua.wrap(lifeStep) },
    .{ .name = "markovChain", .func = zlua.wrap(markovChain) },
    .{ .name = "markovFromSequence", .func = zlua.wrap(markovFromSequence) },
    .{ .name = "markovStep", .func = zlua.wrap(markovStep) },
    .{ .name = "markovGenerate", .func = zlua.wrap(markovGenerate) },
    .{ .name = "rewrite", .func = zlua.wrap(rewrite) },
    .{ .name = "sampleAlong", .func = zlua.wrap(sampleAlong) },
    .{ .name = "subdivide", .func = zlua.wrap(subdivide) },
    .{ .name = "smooth", .func = zlua.wrap(smooth) },
    .{ .name = "jitter", .func = zlua.wrap(jitter) },
    .{ .name = "taper", .func = zlua.wrap(taper) },
    .{ .name = "stipple", .func = zlua.wrap(stipple) },
    .{ .name = "dash", .func = zlua.wrap(dash) },
    .{ .name = "bezierPoint", .func = zlua.wrap(bezierPoint) },
    .{ .name = "bezierTangent", .func = zlua.wrap(bezierTangent) },
    .{ .name = "catmullRomToBezier", .func = zlua.wrap(catmullRomToBezier) },
    .{ .name = "splineToBeziers", .func = zlua.wrap(splineToBeziers) },
    .{ .name = "radial", .func = zlua.wrap(radial) },
    .{ .name = "spiral", .func = zlua.wrap(spiral) },
    .{ .name = "alongPath", .func = zlua.wrap(alongPath) },
    .{ .name = "traceNoise", .func = zlua.wrap(traceNoise) },
    .{ .name = "penFlatten", .func = zlua.wrap(penFlatten) },
    .{ .name = "colormapSolve", .func = zlua.wrap(colormapSolve) },
    .{ .name = "colormapApply", .func = zlua.wrap(colormapApply) },
};

const State = struct {
    rng: Rng,
    perlin: Perlin,
};

// Only the address matters. It keys the State userdata in the registry.
// A var, because identical constants may be merged to one address and
// this address is the registry key.
var state_key: u8 = 0;

fn getState(lua: *Lua) *State {
    lua.pushLightUserdata(&state_key);
    _ = lua.getTableRaw(zlua.registry_index);
    if (lua.toUserdata(State, -1)) |s| {
        lua.pop(1);
        return s;
    } else |_| {}
    lua.pop(1);

    const s = util.newUserdata(lua, State);
    s.* = initialState(lua);
    lua.pushLightUserdata(&state_key);
    lua.pushValue(-2);
    lua.setTableRaw(zlua.registry_index);
    lua.pop(1);
    return s;
}

/// An unseeded state matches the original library. --seed n and
/// --noise-seed n start it as seed(n) and noiseSeed(n) would.
fn initialState(lua: *Lua) State {
    const seeds = util.getHost(lua).seeds;
    return .{
        .rng = if (seeds.seed) |n| .init(@floatFromInt(n)) else .unseeded,
        .perlin = .init(if (seeds.noise_seed) |n| @floatFromInt(n) else 0),
    };
}

fn checkVec2(lua: *Lua, arg: i32) Vec2 {
    return util.readVec2(lua, arg) orelse lua.argError(arg, "expected a point {x, y}");
}

fn checkBounds(lua: *Lua, arg: i32) algo.rand.Bounds {
    if (!lua.isTable(arg)) lua.argError(arg, "expected bounds {x, y, w, h}");
    var b: [4]f64 = undefined;
    for (&b, 1..) |*v, i| v.* = util.numberAt(lua, arg, i) orelse lua.argError(arg, "expected bounds {x, y, w, h}");
    return .{ .x = b[0], .y = b[1], .w = b[2], .h = b[3] };
}

fn checkList(lua: *Lua, arg: i32) usize {
    lua.checkType(arg, .table);
    return util.len(lua, arg);
}

/// Read list[1..n] as numbers.
fn readNumbers(lua: *Lua, arena: Allocator, arg: i32, n: usize) ![]f64 {
    const out = try arena.alloc(f64, n);
    for (out, 1..) |*v, i| {
        v.* = util.numberAt(lua, arg, i) orelse
            lua.raiseErrorStr("element %d is not a number", .{@as(c_int, @intCast(i))});
    }
    return out;
}

/// seed(n). --seed replaces n.
fn seed(lua: *Lua) i32 {
    const n = lua.checkNumber(1);
    const forced = util.getHost(lua).seeds.seed;
    getState(lua).rng = .init(if (forced) |f| @floatFromInt(f) else n);
    return 0;
}

fn rand(lua: *Lua) i32 {
    lua.pushNumber(getState(lua).rng.next());
    return 1;
}

fn randRange(lua: *Lua) i32 {
    const lo = lua.checkNumber(1);
    const hi = lua.checkNumber(2);
    lua.pushNumber(getState(lua).rng.range(lo, hi));
    return 1;
}

/// Integer bounds give an integer subtype on Lua 5.3 and later, as the
/// original math.floor did.
fn randInt(lua: *Lua) i32 {
    const lo = lua.checkNumber(1);
    const hi = lua.checkNumber(2);
    const v = getState(lua).rng.int(lo, hi);
    switch (zlua.lang) {
        .lua53, .lua54, .lua55 => if (lua.isInteger(1) and lua.isInteger(2) and @abs(v) < 0x1p63) {
            lua.pushInteger(@intFromFloat(v));
            return 1;
        },
        else => {},
    }
    lua.pushNumber(v);
    return 1;
}

fn gaussian(lua: *Lua) i32 {
    const mean = lua.checkNumber(1);
    const stddev = lua.checkNumber(2);
    lua.pushNumber(getState(lua).rng.gaussian(mean, stddev));
    return 1;
}

fn pick(lua: *Lua) i32 {
    const n = checkList(lua, 1);
    const i = getState(lua).rng.int(1, @floatFromInt(n));
    _ = util.rawGet(lua, 1, @intFromFloat(i));
    return 1;
}

fn shuffle(lua: *Lua) !i32 {
    const n = checkList(lua, 1);
    const gpa = lua.allocator();
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    for (order, 1..) |*o, i| o.* = @intCast(i);
    getState(lua).rng.shuffle(u32, order);
    lua.createTable(@intCast(n), 0);
    for (order, 1..) |o, i| {
        _ = util.rawGet(lua, 1, o);
        util.rawSet(lua, -2, i);
    }
    return 1;
}

fn weightedPick(lua: *Lua) !i32 {
    const n = checkList(lua, 1);
    const weights_len = checkList(lua, 2);
    if (weights_len < n) lua.argError(2, "fewer weights than items");
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const weights = try readNumbers(lua, arena_state.allocator(), 2, weights_len);
    const i = getState(lua).rng.weightedIndex(weights, n) orelse {
        lua.pushNil();
        return 1;
    };
    _ = util.rawGet(lua, 1, i + 1);
    return 1;
}

fn randInCircle(lua: *Lua) i32 {
    const c = checkVec2(lua, 1);
    const r = lua.checkNumber(2);
    util.pushVec2(lua, getState(lua).rng.inCircle(c, r));
    return 1;
}

fn randOnCircle(lua: *Lua) i32 {
    const c = checkVec2(lua, 1);
    const r = lua.checkNumber(2);
    util.pushVec2(lua, getState(lua).rng.onCircle(c, r));
    return 1;
}

fn randInRect(lua: *Lua) i32 {
    const x = lua.checkNumber(1);
    const y = lua.checkNumber(2);
    const w = lua.checkNumber(3);
    const h = lua.checkNumber(4);
    util.pushVec2(lua, getState(lua).rng.inRect(x, y, w, h));
    return 1;
}

/// poissonDisk(bounds, minDist, maxAttempts) -> points
fn poissonDisk(lua: *Lua) !i32 {
    const b = checkBounds(lua, 1);
    const min_dist = lua.checkNumber(2);
    const attempts = lua.checkNumber(3);
    if (!(min_dist > 0)) lua.argError(2, "minDist must be positive");
    const gpa = lua.allocator();
    const pts = try algo.rand.poissonDisk(gpa, &getState(lua).rng, b, min_dist, attempts);
    defer gpa.free(pts);
    util.pushPoints(lua, pts);
    return 1;
}

/// noiseSeed(n) -> the seed used, which is n unless --noise-seed
/// replaces it. prelude/noise.lua keeps it for the other noise kinds.
fn noiseSeed(lua: *Lua) i32 {
    const n = lua.checkNumber(1);
    const forced = util.getHost(lua).seeds.noise_seed;
    const used = if (forced) |f| @as(f64, @floatFromInt(f)) else n;
    getState(lua).perlin = .init(used);
    lua.pushNumber(used);
    return 1;
}

fn perlin(lua: *Lua) i32 {
    const x = lua.checkNumber(1);
    const y = lua.checkNumber(2);
    lua.pushNumber(getState(lua).perlin.noise(x, y));
    return 1;
}

/// fbm(x, y, octaves, lacunarity, gain), defaults filled by noise.lua.
fn fbm(lua: *Lua) i32 {
    const x = lua.checkNumber(1);
    const y = lua.checkNumber(2);
    const octaves = lua.checkNumber(3);
    const lacunarity = lua.checkNumber(4);
    const gain = lua.checkNumber(5);
    lua.pushNumber(getState(lua).perlin.fbm(x, y, octaves, lacunarity, gain));
    return 1;
}

/// mod(a, b), the floored modulo of src/math.zig.
fn mod(lua: *Lua) i32 {
    lua.pushNumber(genpuin.math.mod(lua.checkNumber(1), lua.checkNumber(2)));
    return 1;
}

/// C entry points for the LuaJIT FFI. Each one that reads the stream or
/// the noise table takes the State pointer that `ffi()` hands out first.
/// The signatures are mirrored in compat.lua.
const ffi = struct {
    fn mod(a: f64, b: f64) callconv(.c) f64 {
        return genpuin.math.mod(a, b);
    }
    fn rand(s: *State) callconv(.c) f64 {
        return s.rng.next();
    }
    fn randRange(s: *State, lo: f64, hi: f64) callconv(.c) f64 {
        return s.rng.range(lo, hi);
    }
    fn randInt(s: *State, lo: f64, hi: f64) callconv(.c) f64 {
        return s.rng.int(lo, hi);
    }
    fn gaussian(s: *State, mean: f64, stddev: f64) callconv(.c) f64 {
        return s.rng.gaussian(mean, stddev);
    }
    fn perlin(s: *State, x: f64, y: f64) callconv(.c) f64 {
        return s.perlin.noise(x, y);
    }
    fn fbm(s: *State, x: f64, y: f64, octaves: f64, lacunarity: f64, gain: f64) callconv(.c) f64 {
        return s.perlin.fbm(x, y, octaves, lacunarity, gain);
    }
};

/// ffi() -> {state = lightuserdata, rand = lightuserdata, ...}. The
/// state lives as long as the Lua state, so the pointer stays valid.
fn ffiTable(lua: *Lua) i32 {
    const s = getState(lua);
    lua.createTable(0, 9);
    lua.pushLightUserdata(s);
    lua.setField(-2, "state");
    const exports = .{
        .{ "rand", &ffi.rand },
        .{ "randRange", &ffi.randRange },
        .{ "randInt", &ffi.randInt },
        .{ "gaussian", &ffi.gaussian },
        .{ "perlin", &ffi.perlin },
        .{ "fbm", &ffi.fbm },
        .{ "mod", &ffi.mod },
    };
    inline for (exports) |e| {
        lua.pushLightUserdata(@ptrCast(e[1]));
        lua.setField(-2, e[0]);
    }
    return 1;
}

const BitOp = enum { band, bxor, rshift, lshift };

/// Numbers to u32 modulo 2^32. Shift counts use their low five bits, as
/// LuaJIT's bit library does.
fn bitOp(comptime op: BitOp) fn (*Lua) i32 {
    return struct {
        fn f(lua: *Lua) i32 {
            const a = toU32(lua.checkNumber(1));
            const b = toU32(lua.checkNumber(2));
            const shift: u5 = @truncate(b);
            const r = switch (op) {
                .band => a & b,
                .bxor => a ^ b,
                .rshift => a >> shift,
                .lshift => a << shift,
            };
            lua.pushNumber(@floatFromInt(r));
            return 1;
        }
    }.f;
}

fn toU32(x: f64) u32 {
    const m = genpuin.math.mod(@floor(x), 4294967296.0);
    return if (m >= 0 and m < 4294967296.0) @intFromFloat(m) else 0;
}

fn pushNumbers(lua: *Lua, xs: []const f64) void {
    lua.createTable(@intCast(xs.len), 0);
    for (xs, 1..) |x, i| {
        lua.pushNumber(x);
        util.rawSet(lua, -2, i);
    }
}

fn pushIndices(lua: *Lua, xs: []const u32) void {
    lua.createTable(@intCast(xs.len), 0);
    for (xs, 1..) |x, i| {
        lua.pushInteger(@intCast(x + 1));
        util.rawSet(lua, -2, i);
    }
}

fn checkPoints(lua: *Lua, arena: Allocator, arg: i32) ![]Vec2 {
    lua.checkType(arg, .table);
    return util.readPoints(lua, arena, arg);
}

/// voronoi(sites, bounds) -> cells, siteIndices. Sites without a cell
/// of three or more vertices are skipped.
fn voronoi(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sites = try checkPoints(lua, arena, 1);
    const b = checkBounds(lua, 2);
    const cells = try algo.voronoi.diagram(arena, sites, b);
    lua.createTable(@intCast(cells.len), 0);
    for (cells, 1..) |c, i| {
        util.pushPoints(lua, c.points);
        util.rawSet(lua, -2, i);
    }
    lua.createTable(@intCast(cells.len), 0);
    for (cells, 1..) |c, i| {
        lua.pushInteger(@intCast(c.site + 1));
        util.rawSet(lua, -2, i);
    }
    return 2;
}

/// relax(sites, bounds, iterations) -> relaxed copy of sites
fn relax(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sites = try checkPoints(lua, arena, 1);
    const b = checkBounds(lua, 2);
    const iterations = lua.checkNumber(3);
    try algo.voronoi.relax(arena, sites, b, iterations);
    util.pushPoints(lua, sites);
    return 1;
}

/// pointInPolygon(point, points) -> bool
fn pointInPolygon(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const p = checkVec2(lua, 1);
    const poly = try checkPoints(lua, arena_state.allocator(), 2);
    lua.pushBoolean(algo.spatial.pointInPolygon(p, poly));
    return 1;
}

/// nearest(query, points) -> index, dist, or nothing for no points
fn nearest(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const q = checkVec2(lua, 1);
    const pts = try checkPoints(lua, arena_state.allocator(), 2);
    const hit = algo.spatial.nearest(q, pts) orelse return 0;
    lua.pushInteger(@intCast(hit.index + 1));
    lua.pushNumber(hit.dist);
    return 2;
}

/// withinRadius(query, points, radius) -> indices, dists, nearest first
fn withinRadius(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = checkVec2(lua, 1);
    const pts = try checkPoints(lua, arena, 2);
    const hits = try algo.spatial.withinRadius(arena, q, pts, lua.checkNumber(3));
    lua.createTable(@intCast(hits.len), 0);
    for (hits, 1..) |h, i| {
        lua.pushInteger(@intCast(h.index + 1));
        util.rawSet(lua, -2, i);
    }
    lua.createTable(@intCast(hits.len), 0);
    for (hits, 1..) |h, i| {
        lua.pushNumber(h.dist);
        util.rawSet(lua, -2, i);
    }
    return 2;
}

fn readCircles(lua: *Lua, arena: Allocator, arg: i32) ![]algo.spatial.Circle {
    const n = checkList(lua, arg);
    const out = try arena.alloc(algo.spatial.Circle, n);
    for (out, 1..) |*c, i| {
        _ = util.rawGet(lua, arg, i);
        defer lua.pop(1);
        const bad = "circle %d needs center {x, y} and r";
        if (!lua.isTable(-1)) lua.raiseErrorStr(bad, .{@as(c_int, @intCast(i))});
        _ = lua.getField(-1, "center");
        const center = util.readVec2(lua, -1) orelse lua.raiseErrorStr(bad, .{@as(c_int, @intCast(i))});
        lua.pop(1);
        if (lua.getField(-1, "r") != .number) lua.raiseErrorStr(bad, .{@as(c_int, @intCast(i))});
        c.* = .{ .c = center, .r = lua.toNumber(-1) catch unreachable }; // type checked on the line above
        lua.pop(1);
    }
    return out;
}

fn optBounds(lua: *Lua, arg: i32) ?algo.Bounds {
    return if (lua.isNoneOrNil(arg)) null else checkBounds(lua, arg);
}

/// separate(circles, iterations, padding, strength, bounds?) moves the
/// circles' center tables in place.
fn separate(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const circles = try readCircles(lua, arena_state.allocator(), 1);
    const opts: algo.spatial.SeparateOptions = .{
        .iterations = lua.checkNumber(2),
        .padding = lua.checkNumber(3),
        .strength = lua.checkNumber(4),
        .bounds = optBounds(lua, 5),
    };
    algo.spatial.separate(&getState(lua).rng, circles, opts);
    for (circles, 1..) |c, i| {
        _ = util.rawGet(lua, 1, i);
        _ = lua.getField(-1, "center");
        lua.pushNumber(c.c[0]);
        util.rawSet(lua, -2, 1);
        lua.pushNumber(c.c[1]);
        util.rawSet(lua, -2, 2);
        lua.pop(2);
    }
    return 0;
}

/// packCircles(bounds, count, radius?, minRadius, maxRadius, padding,
/// maxAttempts, separation) -> centers, radii
fn packCircles(lua: *Lua) !i32 {
    const fixed = lua.isNumber(3);
    const opts: algo.spatial.PackOptions = .{
        .bounds = checkBounds(lua, 1),
        .count = lua.checkNumber(2),
        .radius = if (fixed) lua.checkNumber(3) else null,
        .radius_min = if (fixed) 0 else lua.checkNumber(4),
        .radius_max = if (fixed) 0 else lua.checkNumber(5),
        .padding = lua.checkNumber(6),
        .attempts = lua.checkNumber(7),
        .separation = lua.checkNumber(8),
    };
    const gpa = lua.allocator();
    const circles = try algo.spatial.packCircles(gpa, &getState(lua).rng, opts);
    defer gpa.free(circles);
    lua.createTable(@intCast(circles.len), 0);
    for (circles, 1..) |c, i| {
        util.pushVec2(lua, c.c);
        util.rawSet(lua, -2, i);
    }
    lua.createTable(@intCast(circles.len), 0);
    for (circles, 1..) |c, i| {
        lua.pushNumber(c.r);
        util.rawSet(lua, -2, i);
    }
    return 2;
}

/// elementary(rule, width, steps, init?) -> rows[generation][cell]
fn elementary(lua: *Lua) !i32 {
    const rule = lua.checkNumber(1);
    const width_f = lua.checkNumber(2);
    const steps_f = lua.checkNumber(3);
    if (!(width_f >= 1 and width_f <= 1 << 24 and @floor(width_f) == width_f)) lua.argError(2, "width must be a positive integer");
    const width: usize = @intFromFloat(width_f);
    const steps: usize = if (steps_f >= 1) @intFromFloat(@min(@floor(steps_f), 1 << 24)) else 0;
    const gpa = lua.allocator();

    const first = try gpa.alloc(u1, width);
    defer gpa.free(first);
    if (lua.isNoneOrNil(4)) {
        algo.automata.centerSeed(first);
    } else {
        lua.checkType(4, .table);
        for (first, 1..) |*c, i| {
            c.* = switch (util.rawGet(lua, 4, i)) {
                .nil => 0,
                .boolean => if (lua.toBoolean(-1)) lua.argError(4, "init cells must be 0 or 1") else 0,
                .number => blk: {
                    const v = lua.toNumber(-1) catch unreachable; // type checked by the switch
                    if (v == 0) break :blk 0;
                    if (v == 1) break :blk 1;
                    lua.argError(4, "init cells must be 0 or 1");
                },
                else => lua.argError(4, "init cells must be 0 or 1"),
            };
            lua.pop(1);
        }
    }

    const cells = try algo.automata.elementary(gpa, rule, first, steps);
    defer gpa.free(cells);
    lua.createTable(@intCast(steps + 1), 0);
    for (0..steps + 1) |g| {
        lua.createTable(@intCast(width), 0);
        for (cells[g * width ..][0..width], 1..) |c, i| {
            lua.pushInteger(c);
            util.rawSet(lua, -2, i);
        }
        util.rawSet(lua, -2, g + 1);
    }
    return 1;
}

/// lifeStep(grid, wrap) -> the next Game of Life generation as rows of
/// 1 and 0, or nil when the grid is not rows of numbers at least as long
/// as the first, so the caller can run the general rule loop instead.
/// A cell is alive when it is not 0.
fn lifeStep(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    const wrap = lua.toBoolean(2);
    const h = util.len(lua, 1);
    if (h == 0 or util.rawGet(lua, 1, 1) != .table) return 0;
    const w = util.len(lua, -1);
    lua.pop(1);
    if (w == 0) return 0;
    const gpa = lua.allocator();
    const cells = try gpa.alloc(u1, 2 * w * h);
    defer gpa.free(cells);
    for (0..h) |y| {
        if (util.rawGet(lua, 1, y + 1) != .table) return 0;
        defer lua.pop(1);
        for (0..w) |x| {
            const v = util.numberAt(lua, -1, x + 1) orelse return 0;
            cells[y * w + x] = @intFromBool(v != 0);
        }
    }
    const next = cells[w * h ..];
    algo.automata.lifeStep(cells[0 .. w * h], next, w, h, wrap);
    lua.createTable(@intCast(h), 0);
    for (0..h) |y| {
        lua.createTable(@intCast(w), 0);
        for (next[y * w ..][0..w], 1..) |c, x| {
            lua.pushInteger(c);
            util.rawSet(lua, -2, x);
        }
        util.rawSet(lua, -2, y + 1);
    }
    return 1;
}

/// markovChain(transitions) -> chain. transitions maps each state to
/// {{next, weight}, ...}. The chain maps it to {nexts, weights}.
fn markovChain(lua: *Lua) i32 {
    lua.checkType(1, .table);
    lua.newTable();
    const chain = lua.getTop();
    lua.pushNil();
    while (lua.next(1)) {
        const entries = lua.getTop();
        if (!lua.isTable(entries)) lua.raiseErrorStr("markov transitions must be lists of {next, weight}", .{});
        const n = util.len(lua, entries);
        lua.pushValue(entries - 1);
        lua.createTable(0, 2);
        lua.createTable(@intCast(n), 0);
        lua.createTable(@intCast(n), 0);
        for (1..n + 1) |i| {
            if (util.rawGet(lua, entries, i) != .table) lua.raiseErrorStr("markov transitions must be lists of {next, weight}", .{});
            _ = util.rawGet(lua, -1, 1);
            util.rawSet(lua, -4, i);
            _ = util.rawGet(lua, -1, 2);
            util.rawSet(lua, -3, i);
            lua.pop(1);
        }
        lua.setField(-3, "weights");
        lua.setField(-2, "nexts");
        lua.setTableRaw(chain);
        lua.pop(1);
    }
    return 1;
}

/// markovFromSequence(sequence) -> chain with transition counts as
/// weights. Each state's nexts are in order of first appearance.
fn markovFromSequence(lua: *Lua) i32 {
    const n = checkList(lua, 1);
    lua.newTable();
    const chain = lua.getTop();
    if (n < 2) return 1;
    // Per source state, the position of each target in its nexts list.
    lua.newTable();
    const positions = lua.getTop();
    for (1..n) |i| {
        if (util.rawGet(lua, 1, i) == .nil) lua.raiseErrorStr("markov sequence has a hole at %d", .{@as(c_int, @intCast(i))});
        const from = lua.getTop();
        if (util.rawGet(lua, 1, i + 1) == .nil) lua.raiseErrorStr("markov sequence has a hole at %d", .{@as(c_int, @intCast(i + 1))});
        const to = lua.getTop();

        lua.pushValue(from);
        if (lua.getTableRaw(chain) == .nil) {
            lua.pop(1);
            lua.createTable(0, 2);
            lua.newTable();
            lua.setField(-2, "nexts");
            lua.newTable();
            lua.setField(-2, "weights");
            lua.pushValue(from);
            lua.pushValue(-2);
            lua.setTableRaw(chain);
            lua.pushValue(from);
            lua.newTable();
            lua.setTableRaw(positions);
        }
        const entry = lua.getTop();
        _ = lua.getField(entry, "nexts");
        const nexts = lua.getTop();
        _ = lua.getField(entry, "weights");
        const weights = lua.getTop();
        lua.pushValue(from);
        _ = lua.getTableRaw(positions);
        const pos = lua.getTop();

        lua.pushValue(to);
        const k: usize = if (lua.getTableRaw(pos) == .number) @intFromFloat(lua.toNumber(-1) catch unreachable) else blk: { // type checked by the condition
            const k = util.len(lua, nexts) + 1;
            lua.pushValue(to);
            util.rawSet(lua, nexts, k);
            lua.pushValue(to);
            lua.pushInteger(@intCast(k));
            lua.setTableRaw(pos);
            break :blk k;
        };
        lua.pop(1);
        const count = util.numberAt(lua, weights, k) orelse 0;
        lua.pushInteger(@intFromFloat(count + 1));
        util.rawSet(lua, weights, k);
        lua.setTop(from - 1);
    }
    lua.pop(1);
    return 1;
}

/// Pick the next state for the value on top of the stack, replacing it.
/// Leaves nil for a dead end.
fn markovAdvance(lua: *Lua, chain: i32, rng: *Rng, weights: *std.ArrayList(f64), gpa: Allocator) !void {
    if (lua.isNil(-1)) return;
    if (lua.getTable(chain) != .table) {
        lua.pop(1);
        lua.pushNil();
        return;
    }
    const entry = lua.getTop();
    _ = lua.getField(entry, "nexts");
    const nexts = lua.getTop();
    if (!lua.isTable(nexts)) lua.raiseErrorStr("markov chain entry has no nexts", .{});
    _ = lua.getField(entry, "weights");
    const ws = lua.getTop();
    if (!lua.isTable(ws)) lua.raiseErrorStr("markov chain entry has no weights", .{});
    const n = util.len(lua, nexts);
    const wn = util.len(lua, ws);
    if (wn < n) lua.raiseErrorStr("markov chain entry has fewer weights than nexts", .{});
    weights.clearRetainingCapacity();
    for (1..wn + 1) |i| {
        try weights.append(gpa, util.numberAt(lua, ws, i) orelse lua.raiseErrorStr("markov weight %d is not a number", .{@as(c_int, @intCast(i))}));
    }
    if (rng.weightedIndex(weights.items, n)) |i| {
        _ = util.rawGet(lua, nexts, i + 1);
    } else {
        lua.pushNil();
    }
    lua.replace(entry);
    lua.setTop(entry);
}

/// markovStep(chain, current) -> next state or nil
fn markovStep(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    lua.setTop(2);
    var weights: std.ArrayList(f64) = .empty;
    defer weights.deinit(lua.allocator());
    try markovAdvance(lua, 1, &getState(lua).rng, &weights, lua.allocator());
    return 1;
}

/// markovGenerate(chain, start, n) -> {start, ...} up to n states,
/// stopping at a dead end
fn markovGenerate(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    const n = lua.checkNumber(3);
    lua.setTop(3);
    const rng = &getState(lua).rng;
    var weights: std.ArrayList(f64) = .empty;
    defer weights.deinit(lua.allocator());
    lua.newTable();
    const seq = lua.getTop();
    lua.pushValue(2);
    util.rawSet(lua, seq, 1);
    lua.pushValue(2);
    var len: usize = 1;
    var k: f64 = 2;
    while (k <= n) : (k += 1) {
        try markovAdvance(lua, 1, rng, &weights, lua.allocator());
        if (lua.isNil(-1)) break;
        len += 1;
        lua.pushValue(-1);
        util.rawSet(lua, seq, len);
    }
    lua.pop(1);
    return 1;
}

/// rewrite(axiom, rules, n) -> string
fn rewrite(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const axiom = try arena.dupe(u8, lua.checkString(1));
    lua.checkType(2, .table);
    const n = lua.checkNumber(3);

    var rules: algo.lsystem.Rules = @splat(null);
    lua.pushNil();
    while (lua.next(2)) {
        defer lua.pop(1);
        if (lua.typeOf(-2) != .string) continue;
        const key = lua.toString(-2) catch unreachable; // type checked on the line above
        if (key.len != 1) continue;
        rules[key[0]] = try readRule(lua, arena, lua.getTop());
    }

    const out = algo.lsystem.rewrite(arena, &getState(lua).rng, axiom, &rules, n) catch |err| switch (err) {
        error.InvalidRule => lua.raiseErrorStr("rewrite: a rule must be a string or a list of {replacement, weight}", .{}),
        error.OutOfMemory => return err,
    };
    _ = lua.pushString(out);
    return 1;
}

fn readRule(lua: *Lua, arena: Allocator, index: i32) !algo.lsystem.Rule {
    switch (lua.typeOf(index)) {
        .string => return .{ .text = try arena.dupe(u8, lua.toString(index) catch unreachable) }, // type checked by the switch
        .table => {},
        else => return .invalid,
    }
    const n = util.len(lua, index);
    if (n == 0) return .invalid;
    const choices = try arena.alloc(algo.lsystem.Choice, n);
    for (choices, 1..) |*c, i| {
        defer lua.pop(1);
        if (util.rawGet(lua, index, i) != .table) return .invalid;
        const w = util.numberAt(lua, -1, 2) orelse return .invalid;
        _ = util.rawGet(lua, -1, 1);
        defer lua.pop(1);
        if (!lua.isString(-1)) return .invalid;
        c.* = .{ .text = try arena.dupe(u8, lua.toString(-1) catch unreachable), .weight = w }; // type checked on the line above
    }
    return .{ .choices = choices };
}

/// sampleAlong(points, n) -> points, for at least two points
fn sampleAlong(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPathPoints(lua, arena, 1);
    util.pushPoints(lua, try algo.path.sampleAlong(arena, pts, lua.checkNumber(2)));
    return 1;
}

fn checkPathPoints(lua: *Lua, arena: Allocator, arg: i32) ![]Vec2 {
    const pts = try checkPoints(lua, arena, arg);
    if (pts.len < 2) lua.argError(arg, "a path needs at least two points");
    return pts;
}

/// subdivide(points, closed, iterations) -> points
fn subdivide(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPathPoints(lua, arena, 1);
    util.pushPoints(lua, try algo.path.subdivide(arena, pts, lua.toBoolean(2), lua.checkNumber(3)));
    return 1;
}

/// smooth(points, closed, iterations) -> points, for at least three
fn smooth(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPoints(lua, arena, 1);
    if (pts.len < 3) lua.argError(1, "smoothing needs at least three points");
    util.pushPoints(lua, try algo.path.smooth(arena, pts, lua.toBoolean(2), lua.checkNumber(3)));
    return 1;
}

/// jitter(points, amount) -> points
fn jitter(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPoints(lua, arena, 1);
    const amount = lua.checkNumber(2);
    util.pushPoints(lua, try algo.path.jitter(arena, &getState(lua).rng, pts, amount));
    return 1;
}

/// taper(points, startWidth, endWidth, segments) -> points, widths.
/// Segment i runs from points[i] to points[i + 1].
fn taper(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPathPoints(lua, arena, 1);
    const start = lua.checkNumber(2);
    const end = lua.checkNumber(3);
    const segments = lua.checkNumber(4);
    const sampled = try algo.path.sampleAlong(arena, pts, segments + 1);
    const widths = try algo.path.taperWidths(arena, sampled.len -| 1, start, end);
    util.pushPoints(lua, sampled);
    pushNumbers(lua, widths);
    return 2;
}

/// stipple(points, closed, density) -> dots
fn stipple(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPoints(lua, arena, 1);
    const closed = lua.toBoolean(2);
    const density = lua.checkNumber(3);
    util.pushPoints(lua, try algo.path.stipple(arena, &getState(lua).rng, pts, closed, density));
    return 1;
}

/// dash(points, dashLen, gapLen) -> list of point lists
fn dash(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPathPoints(lua, arena, 1);
    const dash_len = lua.checkNumber(2);
    const gap_len = lua.checkNumber(3);
    if (!(dash_len + gap_len > 0)) lua.argError(3, "dash plus gap must be positive");
    const dashes = try algo.path.dash(arena, pts, dash_len, gap_len);
    util.pushContours(lua, dashes);
    return 1;
}

fn checkCubic(lua: *Lua, first: i32) algo.path.Cubic {
    var c: algo.path.Cubic = undefined;
    for (&c, 0..) |*p, i| p.* = checkVec2(lua, first + @as(i32, @intCast(i)));
    return c;
}

fn bezierPoint(lua: *Lua) i32 {
    const c = checkCubic(lua, 1);
    util.pushVec2(lua, algo.path.bezierPoint(c, lua.checkNumber(5)));
    return 1;
}

fn bezierTangent(lua: *Lua) i32 {
    const c = checkCubic(lua, 1);
    util.pushVec2(lua, algo.path.bezierTangent(c, lua.checkNumber(5)));
    return 1;
}

fn catmullRomToBezier(lua: *Lua) i32 {
    const c = checkCubic(lua, 1);
    const b = algo.path.catmullRomToBezier(c[0], c[1], c[2], c[3]);
    util.pushPoints(lua, &b);
    return 1;
}

fn splineToBeziers(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPoints(lua, arena, 1);
    const segs = try algo.path.splineToBeziers(arena, pts);
    lua.createTable(@intCast(segs.len), 0);
    for (segs, 1..) |*s, i| {
        util.pushPoints(lua, s);
        util.rawSet(lua, -2, i);
    }
    return 1;
}

/// radial(n, center, radius) -> points, angles
fn radial(lua: *Lua) !i32 {
    const n = lua.checkNumber(1);
    const c = checkVec2(lua, 2);
    const r = lua.checkNumber(3);
    lua.newTable();
    lua.newTable();
    var i: f64 = 0;
    var k: usize = 1;
    while (i <= n - 1) : ({
        i += 1;
        k += 1;
    }) {
        const p, const a = algo.pattern.radial(c, r, i, n);
        util.pushVec2(lua, p);
        util.rawSet(lua, -3, k);
        lua.pushNumber(a);
        util.rawSet(lua, -2, k);
    }
    return 2;
}

/// spiral(n, center, angleStep, spacing, growth) -> points, angles
fn spiral(lua: *Lua) !i32 {
    const n = lua.checkNumber(1);
    const c = checkVec2(lua, 2);
    const step = lua.checkNumber(3);
    const spacing = lua.checkNumber(4);
    const growth: algo.pattern.Growth = if (std.mem.eql(u8, lua.toString(5) catch "", "sqrt")) .sqrt else .linear;
    lua.newTable();
    lua.newTable();
    var i: f64 = 0;
    var k: usize = 1;
    while (i <= n - 1) : ({
        i += 1;
        k += 1;
    }) {
        const p, const a = algo.pattern.spiral(c, step, spacing, growth, i);
        util.pushVec2(lua, p);
        util.rawSet(lua, -3, k);
        lua.pushNumber(a);
        util.rawSet(lua, -2, k);
    }
    return 2;
}

/// alongPath(points, n) -> points, angles, ts
fn alongPath(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pts = try checkPathPoints(lua, arena, 1);
    const a = try algo.path.alongPath(arena, pts, lua.checkNumber(2));
    util.pushPoints(lua, a.points);
    pushNumbers(lua, a.angles);
    pushNumbers(lua, a.ts);
    return 3;
}

/// traceNoise(start, steps, stepSize, scale) -> points through the
/// field angle = perlin(x * scale, y * scale) * 2pi
fn traceNoise(lua: *Lua) !i32 {
    const start = checkVec2(lua, 1);
    const steps = lua.checkNumber(2);
    const step_len = lua.checkNumber(3);
    const scale = lua.checkNumber(4);
    const count: usize = if (steps >= 1) @intFromFloat(@min(@floor(steps), 1 << 26)) else 0;
    const gpa = lua.allocator();
    const pts = try gpa.alloc(Vec2, count + 1);
    defer gpa.free(pts);
    getState(lua).perlin.trace(pts, start, scale, step_len);
    util.pushPoints(lua, pts);
    return 1;
}

/// penFlatten(points, resolution) -> the points of a gen.pen path with
/// each arc replaced by samples. A point is {x, y}, an arc's end is
/// {x, y, cx, cy, radius, startAngle, endAngle}.
fn penFlatten(lua: *Lua) !i32 {
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    lua.checkType(1, .table);
    const resolution = lua.checkNumber(2);
    const n = util.len(lua, 1);
    if (n == 0) lua.argError(1, "expected a path with a first point");
    const steps = try arena.alloc(algo.pen.Step, n - 1);
    _ = util.rawGet(lua, 1, 1);
    const first = util.readVec2(lua, -1) orelse lua.raiseErrorStr("pen point 1 is not {x, y}", .{});
    lua.pop(1);
    for (steps, 2..) |*s, i| {
        _ = util.rawGet(lua, 1, i);
        defer lua.pop(1);
        const p = util.readVec2(lua, -1) orelse lua.raiseErrorStr("pen point %d is not {x, y}", .{@as(c_int, @intCast(i))});
        var arc: [5]f64 = undefined;
        s.* = for (&arc, 3..) |*v, k| {
            v.* = util.numberAt(lua, -1, k) orelse break .{ .point = p };
        } else .{ .arc = .{ .center = .{ arc[0], arc[1] }, .radius = arc[2], .start = arc[3], .end = arc[4] } };
    }
    util.pushPoints(lua, try algo.pen.flatten(arena, first, steps, resolution));
    return 1;
}

/// The affine matrix for the {from, to} pairs at `index`, for the
/// canvas marshaller and colormapSolve.
pub fn solveColorMap(lua: *Lua, index_in: i32) !algo.colormap.Matrix {
    const index = lua.absIndex(index_in);
    if (!lua.isTable(index)) lua.raiseErrorStr("colorMap must be a list of {from, to} pairs", .{});
    const gpa = lua.allocator();
    const n = util.len(lua, index);
    const pairs = try gpa.alloc(algo.colormap.Pair, n);
    defer gpa.free(pairs);
    for (pairs, 1..) |*p, i| {
        _ = util.rawGet(lua, index, i);
        defer lua.pop(1);
        p.* = .{ .from = readRgb(lua, "from"), .to = readRgb(lua, "to") };
    }
    return algo.colormap.solve(gpa, pairs) catch |err| switch (err) {
        error.Singular => lua.raiseErrorStr("colormap: singular system (degenerate color pairs)", .{}),
        error.OutOfMemory => return err,
    };
}

fn readRgb(lua: *Lua, key: [:0]const u8) algo.colormap.Rgb {
    if (!lua.isTable(-1)) lua.raiseErrorStr("colorMap pairs must be {from = color, to = color}", .{});
    _ = lua.getField(-1, key);
    defer lua.pop(1);
    const t = lua.absIndex(-1);
    if (!lua.isTable(t)) lua.raiseErrorStr("colorMap pairs must be {from = color, to = color}", .{});
    var c: algo.colormap.Rgb = undefined;
    for (&c, 1..) |*v, i| v.* = util.numberAt(lua, t, i) orelse lua.raiseErrorStr("colorMap colors need r, g and b", .{});
    return c;
}

/// colormapSolve(pairs) -> matrix {{a, b, c, d}, x3}
fn colormapSolve(lua: *Lua) !i32 {
    const m = try solveColorMap(lua, 1);
    lua.createTable(3, 0);
    for (m, 1..) |row, i| {
        pushNumbers(lua, &row);
        util.rawSet(lua, -2, i);
    }
    return 1;
}

/// colormapApply(matrix, r, g, b) -> r, g, b
fn colormapApply(lua: *Lua) i32 {
    lua.checkType(1, .table);
    var m: algo.colormap.Matrix = undefined;
    for (&m, 1..) |*row, i| {
        if (util.rawGet(lua, 1, i) != .table) lua.argError(1, "expected a 3x4 matrix");
        for (row, 1..) |*v, k| v.* = util.numberAt(lua, -1, k) orelse lua.argError(1, "expected a 3x4 matrix");
        lua.pop(1);
    }
    const out = algo.colormap.apply(&m, .{ lua.checkNumber(2), lua.checkNumber(3), lua.checkNumber(4) });
    for (out) |v| lua.pushNumber(v);
    return 3;
}
