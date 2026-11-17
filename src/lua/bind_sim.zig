//! core.sim: run the simulations in genpuin.sim from an options table.
//! Grid simulations return their state as Fields, which can be passed
//! back in to keep stepping.

const std = @import("std");

const zlua = @import("zlua");
const genpuin = @import("genpuin");
const sim = genpuin.sim;

const util = @import("util.zig");
const Lua = util.Lua;
const Field = util.Field;
const Vec2 = util.Vec2;

pub const functions = [_]zlua.FnReg{
    .{ .name = "reactionDiffusion", .func = zlua.wrap(reactionDiffusion) },
    .{ .name = "physarum", .func = zlua.wrap(physarum) },
    .{ .name = "dla", .func = zlua.wrap(dla) },
    .{ .name = "differentialGrowth", .func = zlua.wrap(differentialGrowth) },
};

fn optField(lua: *Lua, index: i32, key: [:0]const u8) ?*Field {
    defer lua.pop(1);
    return switch (lua.getField(index, key)) {
        .nil, .none => null,
        else => util.toField(lua, -1) orelse lua.raiseErrorStr("option '%s' must be a Field", .{key.ptr}),
    };
}

fn optF32(lua: *Lua, index: i32, key: [:0]const u8, default: f32) f32 {
    return @floatCast(util.optNumber(lua, index, key, default));
}

fn optSize(lua: *Lua, index: i32, key: [:0]const u8, default: u32) u32 {
    const v = util.optInt(lua, index, key, default);
    if (v < 3 or v > 1 << 15) lua.raiseErrorStr("option '%s' must be 3 to 32768", .{key.ptr});
    return @intCast(v);
}

fn optCount(lua: *Lua, index: i32, key: [:0]const u8, default: u32) u32 {
    const v = util.optInt(lua, index, key, default);
    if (v < 0 or v > std.math.maxInt(u32)) lua.raiseErrorStr("option '%s' must be a count", .{key.ptr});
    return @intCast(v);
}

fn optVec2(lua: *Lua, index: i32, key: [:0]const u8, default: Vec2) Vec2 {
    defer lua.pop(1);
    return switch (lua.getField(index, key)) {
        .nil, .none => default,
        else => util.readVec2(lua, -1) orelse lua.raiseErrorStr("option '%s' must be {x, y}", .{key.ptr}),
    };
}

/// A rect from {x = , y = , w = , h = } (a gen.rect works) or {x, y, w, h}.
fn optRect(lua: *Lua, index: i32, key: [:0]const u8) ?sim.Rect {
    defer lua.pop(1);
    switch (lua.getField(index, key)) {
        .nil, .none => return null,
        .table => {},
        else => lua.raiseErrorStr("option '%s' must be a rect", .{key.ptr}),
    }
    const t = lua.absIndex(-1);
    var v: [4]f64 = undefined;
    const names = [_][:0]const u8{ "x", "y", "w", "h" };
    for (names, 0..) |name, i| {
        v[i] = util.numberAt(lua, t, i + 1) orelse
            util.optNumber(lua, t, name, std.math.nan(f64));
        if (std.math.isNan(v[i])) lua.raiseErrorStr("option '%s' needs x, y, w and h", .{key.ptr});
    }
    if (!(v[2] > 0 and v[3] > 0)) lua.raiseErrorStr("option '%s' must have a positive size", .{key.ptr});
    return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

/// reactionDiffusion(opts) -> b, a
fn reactionDiffusion(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    const resume_a = optField(lua, 1, "a");
    const resume_b = optField(lua, 1, "b");
    const init_b = optField(lua, 1, "init");
    const sized_by = resume_b orelse resume_a orelse init_b;
    const w = optSize(lua, 1, "w", if (sized_by) |f| f.w else 256);
    const h = optSize(lua, 1, "h", if (sized_by) |f| f.h else 256);

    var rates: sim.ReactionDiffusion.Rates = .{ .feed = 0.055, .kill = 0.062 };
    _ = lua.getField(1, "preset");
    const has_preset = !lua.isNil(-1);
    lua.pop(1);
    if (has_preset) rates = sim.ReactionDiffusion.presetRates(util.optEnum(lua, sim.ReactionDiffusion.Preset, 1, "preset", .coral));
    const opts: sim.ReactionDiffusion.Options = .{
        .w = w,
        .h = h,
        .feed = optF32(lua, 1, "feed", rates.feed),
        .kill = optF32(lua, 1, "kill", rates.kill),
        .da = optF32(lua, 1, "dA", 1),
        .db = optF32(lua, 1, "dB", 0.5),
        .dt = optF32(lua, 1, "dt", 1),
        .wrap = util.optBool(lua, 1, "wrap", true),
        .feed_map = optField(lua, 1, "feedMap"),
        .kill_map = optField(lua, 1, "killMap"),
    };
    const steps = optCount(lua, 1, "steps", 2000);
    const seed = util.optSeed(lua, 1);

    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Blob = struct { x: f64, y: f64, r: f64 };
    var blobs: []Blob = &.{};
    var random_blobs: u32 = 0;
    const blob_r = util.optNumber(lua, 1, "seedRadius", 5);
    switch (lua.getField(1, "seeds")) {
        .number => random_blobs = optCount(lua, 1, "seeds", 0),
        .table => {
            const n = util.len(lua, -1);
            blobs = try arena.alloc(Blob, n);
            for (blobs, 1..) |*b, i| {
                _ = util.rawGet(lua, -1, i);
                const p = util.readVec2(lua, -1) orelse lua.raiseErrorStr("seed %d is not {x, y, r}", .{@as(c_int, @intCast(i))});
                b.* = .{ .x = p[0], .y = p[1], .r = util.numberAt(lua, -1, 3) orelse blob_r };
                lua.pop(1);
            }
        },
        .nil, .none => if (resume_b == null and init_b == null) {
            random_blobs = @max(1, (w * h) / (64 * 64));
        },
        else => lua.raiseErrorStr("option 'seeds' must be a count or a list of {x, y, r}", .{}),
    }
    lua.pop(1);

    const gpa = lua.allocator();
    var rd: sim.ReactionDiffusion = try .init(gpa, opts);
    defer rd.deinit(gpa);
    if (resume_a) |f| rd.loadA(f);
    if (resume_b orelse init_b) |f| rd.loadB(f);
    if (random_blobs > 0) rd.seedRandom(seed, random_blobs, blob_r);
    for (blobs) |b| rd.seedDisc(b.x, b.y, b.r);
    rd.step(steps);

    util.pushField(lua, .{ .w = w, .h = h, .data = rd.b });
    rd.b = &.{};
    util.pushField(lua, .{ .w = w, .h = h, .data = rd.a });
    rd.a = &.{};
    return 2;
}

/// physarum(opts) -> trail, agents
fn physarum(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    const trail_in = optField(lua, 1, "trail");
    const w = optSize(lua, 1, "w", if (trail_in) |f| f.w else 512);
    const h = optSize(lua, 1, "h", if (trail_in) |f| f.h else 512);

    var agents_in: ?*Field = null;
    var agent_count: u32 = 100_000;
    switch (lua.getField(1, "agents")) {
        .number => agent_count = optCount(lua, 1, "agents", 0),
        .nil, .none => {},
        else => {
            const f = util.toField(lua, -1) orelse lua.raiseErrorStr("option 'agents' must be a count or an agents Field", .{});
            if (f.w != 3) lua.raiseErrorStr("an agents Field has 3 columns", .{});
            agents_in = f;
            agent_count = f.h;
        },
    }
    lua.pop(1);
    if (agent_count == 0) lua.raiseErrorStr("physarum needs at least one agent", .{});

    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const SpawnName = enum { random, disc, ring };
    var spawn: sim.Physarum.Spawn = .random;
    switch (lua.getField(1, "spawn")) {
        .string => spawn = switch (util.optEnum(lua, SpawnName, 1, "spawn", .random)) {
            .random => .random,
            .disc => .disc,
            .ring => .ring,
        },
        .table => {
            const pts = try util.readPoints(lua, arena, -1);
            if (pts.len == 0) lua.raiseErrorStr("option 'spawn' has no points", .{});
            spawn = .{ .points = pts };
        },
        .nil, .none => {},
        else => lua.raiseErrorStr("option 'spawn' must be a name or a list of points", .{}),
    }
    lua.pop(1);

    const min_side: f32 = @floatFromInt(@min(w, h));
    const opts: sim.Physarum.Options = .{
        .w = w,
        .h = h,
        .agents = agent_count,
        .sensor_angle = optF32(lua, 1, "sensorAngle", std.math.pi / 4.0),
        .sensor_dist = optF32(lua, 1, "sensorDist", 9),
        .turn = optF32(lua, 1, "turn", std.math.pi / 4.0),
        .speed = optF32(lua, 1, "speed", 1),
        .deposit = optF32(lua, 1, "deposit", 5),
        .decay = optF32(lua, 1, "decay", 0.1),
        .diffuse = optF32(lua, 1, "diffuse", 1),
        .wrap = util.optBool(lua, 1, "wrap", true),
        .spawn = spawn,
        .food = optField(lua, 1, "food"),
        .food_weight = optF32(lua, 1, "foodWeight", 1),
    };
    if (!(opts.sensor_dist >= 0 and opts.sensor_dist < min_side)) lua.raiseErrorStr("sensorDist must be under the grid size", .{});
    if (!(opts.speed >= 0 and opts.speed < min_side)) lua.raiseErrorStr("speed must be under the grid size", .{});
    const steps = optCount(lua, 1, "steps", 300);
    const seed = util.optSeed(lua, 1);

    const gpa = lua.allocator();
    var p: sim.Physarum = try .init(gpa, opts, seed);
    defer p.deinit(gpa);
    if (agents_in) |f| p.loadAgents(f);
    if (trail_in) |f| p.loadTrail(f);
    p.step(steps);

    util.pushField(lua, .{ .w = w, .h = h, .data = p.trail });
    p.trail = &.{};
    util.pushField(lua, try p.agentsToField(gpa));
    return 2;
}

/// dla(opts) -> segments, points
fn dla(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bounds = optRect(lua, 1, "bounds");
    var seeds: []const Vec2 = &.{};
    var seed_line: ?[2]Vec2 = null;
    switch (lua.getField(1, "seeds")) {
        .table => {
            if (lua.getField(-1, "type") == .string) {
                const kind = lua.toString(-1) catch unreachable; // type checked on the line above
                if (!std.mem.eql(u8, kind, "line")) lua.raiseErrorStr("option 'seeds' takes points or a line", .{});
                lua.pop(1);
                seed_line = .{ optVec2(lua, -1, "a", .{ 0, 0 }), optVec2(lua, -1, "b", .{ 0, 0 }) };
            } else {
                lua.pop(1);
                seeds = try util.readPoints(lua, arena, -1);
            }
        },
        .nil, .none => {},
        else => lua.raiseErrorStr("option 'seeds' must be a list of points or a line", .{}),
    }
    lua.pop(1);
    if (seeds.len == 0 and seed_line == null) {
        const c: Vec2 = if (bounds) |b| .{ b.x + b.w / 2, b.y + b.h / 2 } else .{ 0, 0 };
        seeds = try arena.dupe(Vec2, &.{c});
    }

    const radius = util.optNumber(lua, 1, "radius", 2);
    if (!(radius > 0)) lua.raiseErrorStr("radius must be positive", .{});
    const opts: sim.Dla.Options = .{
        .radius = radius,
        .stickiness = util.optNumber(lua, 1, "stickiness", 1),
        .bias = optVec2(lua, 1, "bias", .{ 0, 0 }),
        .bounds = bounds,
        .seeds = seeds,
        .seed_line = seed_line,
        .walk_steps_max = optCount(lua, 1, "maxSteps", 1_000_000),
    };
    const n = optCount(lua, 1, "n", 1000);
    const seed = util.optSeed(lua, 1);

    const gpa = lua.allocator();
    var d: sim.Dla = try .init(gpa, opts, seed);
    defer d.deinit(gpa);
    _ = try d.grow(gpa, n);
    const sizes = try d.subtreeSizes(arena);

    const pts = d.points.items;
    const first = d.seed_count;
    lua.createTable(@intCast(pts.len - first), 0);
    for (pts[first..], first..) |p, i| {
        lua.createTable(2, 3);
        util.pushVec2(lua, pts[d.parent.items[i]]);
        util.rawSet(lua, -2, 1);
        util.pushVec2(lua, p);
        util.rawSet(lua, -2, 2);
        lua.pushInteger(@intCast(i - first + 1));
        lua.setField(-2, "order");
        lua.pushInteger(@intCast(d.depth.items[i]));
        lua.setField(-2, "depth");
        lua.pushInteger(@intCast(sizes[i]));
        lua.setField(-2, "weight");
        util.rawSet(lua, -2, i - first + 1);
    }
    util.pushPoints(lua, pts);
    return 2;
}

/// differentialGrowth(opts) -> points
fn differentialGrowth(lua: *Lua) !i32 {
    lua.checkType(1, .table);
    var arena_state: std.heap.ArenaAllocator = .init(lua.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var closed_default = true;
    var path: []Vec2 = undefined;
    switch (lua.getField(1, "points")) {
        .table => {
            if (lua.getField(-1, "points") == .table) {
                _ = lua.getField(-2, "type");
                closed_default = !std.mem.eql(u8, lua.toString(-1) catch "", "polyline");
                lua.pop(1);
                path = try util.readPoints(lua, arena, -1);
            } else {
                path = try util.readPoints(lua, arena, -2);
            }
            lua.pop(1);
        },
        else => lua.raiseErrorStr("option 'points' must be a list of points or a polyline", .{}),
    }
    lua.pop(1);
    if (path.len < 2) lua.raiseErrorStr("differentialGrowth needs at least two points", .{});

    const max_edge = util.optNumber(lua, 1, "maxEdge", 4);
    const repel_radius = util.optNumber(lua, 1, "repelRadius", 10);
    if (!(max_edge > 0 and repel_radius > 0)) lua.raiseErrorStr("maxEdge and repelRadius must be positive", .{});
    const bounds = optRect(lua, 1, "bounds");
    var mask: ?sim.Mask = null;
    if (optField(lua, 1, "mask")) |f| {
        mask = .{ .field = f, .rect = bounds orelse .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(f.w),
            .h = @floatFromInt(f.h),
        } };
    }
    _ = lua.getField(1, "restLength");
    const has_rest = !lua.isNil(-1);
    lua.pop(1);
    const opts: sim.DifferentialGrowth.Options = .{
        .closed = util.optBool(lua, 1, "closed", closed_default),
        .max_edge = max_edge,
        .rest_length = if (has_rest) util.optNumber(lua, 1, "restLength", 0) else null,
        .repel_radius = repel_radius,
        .repel = util.optNumber(lua, 1, "repel", 0.6),
        .attract = util.optNumber(lua, 1, "attract", 0.4),
        .alignment = util.optNumber(lua, 1, "align", 0.3),
        .noise = util.optNumber(lua, 1, "noise", 0.1),
        .growth = util.optNumber(lua, 1, "growth", 0),
        .max_nodes = optCount(lua, 1, "maxNodes", 20_000),
        .bounds = if (mask == null) bounds else null,
        .mask = mask,
    };
    const steps = optCount(lua, 1, "steps", 200);
    const seed = util.optSeed(lua, 1);

    const gpa = lua.allocator();
    var g: sim.DifferentialGrowth = try .init(gpa, path, opts, seed);
    defer g.deinit(gpa);
    try g.step(gpa, steps);
    util.pushPoints(lua, g.points());
    return 1;
}
